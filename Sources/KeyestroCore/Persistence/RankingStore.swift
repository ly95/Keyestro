import CryptoKit
import Foundation
import KeyestroDomain
import SQLite3

public struct StoredRankingStats: Equatable, Sendable {
    public var lastUsedAt: Date?
    public var executionCount90Days: Int
    public var isPinned: Bool

    public init(lastUsedAt: Date? = nil, executionCount90Days: Int = 0, isPinned: Bool = false) {
        self.lastUsedAt = lastUsedAt
        self.executionCount90Days = executionCount90Days
        self.isPinned = isPinned
    }
}

public protocol RankingServicing: Sendable {
    func enrich(_ items: [LauncherItem], includeLearning: Bool) async throws -> [LauncherItem]
    func record(itemID: ItemID, actionID: ActionID, at date: Date) async throws
    func togglePin(itemID: ItemID, providerID: ProviderID, at date: Date) async throws -> Bool
    func clearLearning() async throws
}

extension RankingServicing {
    public func enrich(_ items: [LauncherItem]) async throws -> [LauncherItem] {
        try await enrich(items, includeLearning: true)
    }
}

public protocol RankingLearningServicing: Sendable {
    func isEnabled() -> Bool
}

/// A synchronous, lock-protected preference shared by the main-actor settings UI and ranking actors.
/// The lock is the sole access path to `enabled`, so the unchecked Sendable conformance is bounded.
public final class RankingLearningPreferences: RankingLearningServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var enabled: Bool

    public init(enabled: Bool = true) {
        self.enabled = enabled
    }

    public func isEnabled() -> Bool {
        lock.withLock { enabled }
    }

    public func setEnabled(_ enabled: Bool) {
        lock.withLock { self.enabled = enabled }
    }
}

extension LauncherDatabase {
    public func loadRankingStats(since: Date) throws -> [String: StoredRankingStats] {
        let database = try databaseHandle()
        var output: [String: StoredRankingStats] = [:]
        try withStatement(
            database: database,
            sql: """
                SELECT item_key, MAX(occurred_at), COUNT(*)
                FROM usage_events WHERE occurred_at >= ? GROUP BY item_key;
                """
        ) { statement in
            try bind(since.timeIntervalSince1970, to: 1, in: statement)
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW, let itemKey = string(at: 0, in: statement) else {
                    throw DatabaseError.corruptData(table: "usage_events")
                }
                output[itemKey] = StoredRankingStats(
                    lastUsedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    executionCount90Days: Int(sqlite3_column_int64(statement, 2)),
                    isPinned: false
                )
            }
        }
        try withStatement(database: database, sql: "SELECT item_key FROM pinned_items;") { statement in
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW, let itemKey = string(at: 0, in: statement) else {
                    throw DatabaseError.corruptData(table: "pinned_items")
                }
                var stats = output[itemKey] ?? StoredRankingStats()
                stats.isPinned = true
                output[itemKey] = stats
            }
        }
        return output
    }

    public func recordUsage(
        itemKey: String,
        providerID: ProviderID,
        actionID: ActionID,
        occurredAt: Date
    ) throws {
        let database = try databaseHandle()
        try withStatement(
            database: database,
            sql: "INSERT INTO usage_events(item_key,provider_id,action_id,occurred_at) VALUES(?,?,?,?);"
        ) { statement in
            try bind(itemKey, to: 1, in: statement)
            try bind(providerID.rawValue, to: 2, in: statement)
            try bind(actionID.rawValue, to: 3, in: statement)
            try bind(occurredAt.timeIntervalSince1970, to: 4, in: statement)
            try requireDone(statement)
        }
        let cutoff = occurredAt.addingTimeInterval(-90 * 86_400).timeIntervalSince1970
        try withStatement(database: database, sql: "DELETE FROM usage_events WHERE occurred_at < ?;") { statement in
            try bind(cutoff, to: 1, in: statement)
            try requireDone(statement)
        }
    }

    public func setPinned(itemKey: String, providerID: ProviderID, pinned: Bool, at date: Date) throws {
        let database = try databaseHandle()
        if pinned {
            try withStatement(
                database: database,
                sql: "INSERT OR REPLACE INTO pinned_items(item_key,provider_id,pinned_at) VALUES(?,?,?);"
            ) { statement in
                try bind(itemKey, to: 1, in: statement)
                try bind(providerID.rawValue, to: 2, in: statement)
                try bind(date.timeIntervalSince1970, to: 3, in: statement)
                try requireDone(statement)
            }
        } else {
            try withStatement(database: database, sql: "DELETE FROM pinned_items WHERE item_key=?;") { statement in
                try bind(itemKey, to: 1, in: statement)
                try requireDone(statement)
            }
        }
    }

    public func clearRankingLearning() throws {
        let database = try databaseHandle()
        try execute(database: database, sql: "DELETE FROM usage_events;")
    }
}

public actor RankingStore: RankingServicing {
    private let database: LauncherDatabase
    private let keys: InstallationKeyManager
    private let clock: any ClockServicing
    private let statsCacheLifetime: TimeInterval
    private var privacyKey: SymmetricKey?
    private var stats: [String: StoredRankingStats]?
    private var statsLoadedAt: Date?
    private var operationInProgress = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        database: LauncherDatabase,
        keys: InstallationKeyManager,
        clock: any ClockServicing = SystemClockService(),
        statsCacheLifetime: TimeInterval = 60
    ) {
        self.database = database
        self.keys = keys
        self.clock = clock
        self.statsCacheLifetime = min(max(1, statsCacheLifetime), 300)
    }

    public func enrich(_ items: [LauncherItem], includeLearning: Bool) async throws -> [LauncherItem] {
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()

        let key = try await resolvedPrivacyKey()
        let snapshot = try await resolvedStats(at: await clock.wallTime())
        return items.map { item in
            let itemKey = PrivacyKeyHasher.itemKey(for: item.id, key: key)
            guard let stored = snapshot[itemKey] else { return item }
            let existing = item.scoreFeatures
            return item.replacingScoreFeatures(
                ScoreFeatures(
                    lastUsedAt: includeLearning
                        ? Self.latest(existing.lastUsedAt, stored.lastUsedAt) : existing.lastUsedAt,
                    executionCount90Days: includeLearning
                        ? max(existing.executionCount90Days, stored.executionCount90Days)
                        : existing.executionCount90Days,
                    context: existing.context,
                    providerPrior: existing.providerPrior,
                    isPinned: existing.isPinned || stored.isPinned
                )
            )
        }
    }

    public func record(itemID: ItemID, actionID: ActionID, at date: Date = Date()) async throws {
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()

        let key = try await resolvedPrivacyKey()
        let itemKey = PrivacyKeyHasher.itemKey(for: itemID, key: key)
        var snapshot = try await resolvedStats(at: date)
        try await database.recordUsage(
            itemKey: itemKey,
            providerID: itemID.providerID,
            actionID: actionID,
            occurredAt: date
        )
        var value = snapshot[itemKey] ?? StoredRankingStats()
        value.lastUsedAt = Self.latest(value.lastUsedAt, date)
        value.executionCount90Days += 1
        snapshot[itemKey] = value
        stats = snapshot
        statsLoadedAt = date
    }

    public func togglePin(
        itemID: ItemID,
        providerID: ProviderID,
        at date: Date = Date()
    ) async throws -> Bool {
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()

        let key = try await resolvedPrivacyKey()
        let itemKey = PrivacyKeyHasher.itemKey(for: itemID, key: key)
        var snapshot = try await resolvedStats(at: date)
        var value = snapshot[itemKey] ?? StoredRankingStats()
        value.isPinned.toggle()
        try await database.setPinned(itemKey: itemKey, providerID: providerID, pinned: value.isPinned, at: date)
        snapshot[itemKey] = value
        stats = snapshot
        statsLoadedAt = date
        return value.isPinned
    }

    public func clearLearning() async throws {
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()

        try await database.clearRankingLearning()
        if let current = stats {
            stats = current.mapValues {
                StoredRankingStats(lastUsedAt: nil, executionCount90Days: 0, isPinned: $0.isPinned)
            }
        } else {
            stats = nil
        }
        statsLoadedAt = await clock.wallTime()
    }

    private func resolvedPrivacyKey() async throws -> SymmetricKey {
        if let privacyKey { return privacyKey }
        let key = try await keys.installPrivacyKey()
        privacyKey = key
        return key
    }

    private func resolvedStats(at now: Date) async throws -> [String: StoredRankingStats] {
        if let stats, let statsLoadedAt {
            let age = now.timeIntervalSince(statsLoadedAt)
            if age >= 0, age < statsCacheLifetime { return stats }
        }
        let loaded = try await database.loadRankingStats(since: now.addingTimeInterval(-90 * 86_400))
        stats = loaded
        statsLoadedAt = now
        return loaded
    }

    private func acquireOperation() async {
        guard operationInProgress else {
            operationInProgress = true
            return
        }
        await withCheckedContinuation { operationWaiters.append($0) }
    }

    private func releaseOperation() {
        guard !operationWaiters.isEmpty else {
            operationInProgress = false
            return
        }
        operationWaiters.removeFirst().resume()
    }

    private static func latest(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): max(lhs, rhs)
        case let (lhs?, nil): lhs
        case let (nil, rhs?): rhs
        case (nil, nil): nil
        }
    }
}
