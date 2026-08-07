import CryptoKit
import Foundation
import ImageIO
import KeyestroDomain
import SQLite3

public enum ClipboardContent: Codable, Equatable, Sendable {
    case text(String)
    case url(URL)
    case files([URL])
    case imagePNG(Data)

    public var contentType: ClipboardContentType {
        switch self {
        case .text: .text
        case .url: .url
        case .files: .files
        case .imagePNG: .image
        }
    }
}

public enum ClipboardContentType: String, CaseIterable, Codable, Hashable, Sendable {
    case text
    case url
    case files
    case image
}

public struct StoredClipboardItem: Equatable, Sendable {
    public let id: String
    public let contentType: ClipboardContentType
    public let fingerprint: String
    public let ciphertext: Data
    public let nonce: Data
    public let tag: Data
    public let thumbnailCiphertext: Data?
    public let thumbnailNonce: Data?
    public let thumbnailTag: Data?
    public let sourceBundleIdentifier: String?
    public let byteCount: Int
    public let isSensitive: Bool
    public let createdAt: Date
    public let lastCopiedAt: Date
}

public struct ClipboardSearchEntry: Equatable, Identifiable, Sendable {
    public let id: String
    public let contentType: ClipboardContentType
    public let title: String
    public let subtitle: String?
    public let thumbnailPNG: Data?
    public let sourceBundleIdentifier: String?
    public let isSensitive: Bool
    public let lastCopiedAt: Date
}

public enum ClipboardStoreState: Equatable, Sendable {
    case disabled
    case loading
    case ready(itemCount: Int)
    case keyMissing(encryptedItemCount: Int)
    case failed(ErrorDescriptor)
}

public struct ClipboardRetentionPolicy: Equatable, Sendable {
    public let maximumAge: TimeInterval?
    public let maximumItemCount: Int?
    public let maximumDiskBytes: Int

    public init(
        maximumAge: TimeInterval? = 30 * 86_400,
        maximumItemCount: Int? = 1_000,
        maximumDiskBytes: Int = 500 * 1_024 * 1_024
    ) {
        self.maximumAge = maximumAge
        self.maximumItemCount = maximumItemCount
        self.maximumDiskBytes = maximumDiskBytes
    }
}

private struct ClipboardMemoryEntry: Sendable {
    let stored: StoredClipboardItem
    let content: ClipboardContent?
    let thumbnailPNG: Data?
    let searchableText: String
}

extension LauncherDatabase {
    public func clipboardItemCount() throws -> Int {
        let database = try databaseHandle()
        return try withStatement(database: database, sql: "SELECT COUNT(*) FROM clipboard_items;") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw DatabaseError.statementFailed(code: sqlite3_errcode(database))
            }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    public func clipboardTotalBytes() throws -> Int {
        let database = try databaseHandle()
        return try withStatement(database: database, sql: "SELECT COALESCE(SUM(byte_count),0) FROM clipboard_items;") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw DatabaseError.statementFailed(code: sqlite3_errcode(database))
            }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    public func clipboardItems(limit: Int = 1_000) throws -> [StoredClipboardItem] {
        let database = try databaseHandle()
        return try withStatement(
            database: database,
            sql: """
                SELECT id,content_type,content_fingerprint,ciphertext,nonce,tag,
                       thumbnail_ciphertext,thumbnail_nonce,thumbnail_tag,
                       inferred_source_bundle_id,byte_count,is_sensitive,created_at,last_copied_at
                FROM clipboard_items ORDER BY last_copied_at DESC LIMIT ?;
                """
        ) { statement in
            try bind(Int64(min(max(1, limit), 10_000)), to: 1, in: statement)
            var items: [StoredClipboardItem] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW, let item = try decodeClipboardItem(statement) else {
                    throw DatabaseError.corruptData(table: "clipboard_items")
                }
                items.append(item)
            }
            return items
        }
    }

    public func clipboardItem(id: String) throws -> StoredClipboardItem? {
        try clipboardItem(column: "id", value: id)
    }

    public func clipboardItem(fingerprint: String) throws -> StoredClipboardItem? {
        try clipboardItem(column: "content_fingerprint", value: fingerprint)
    }

    public func insertClipboardItem(_ item: StoredClipboardItem) throws {
        let database = try databaseHandle()
        try withStatement(
            database: database,
            sql: """
                INSERT INTO clipboard_items(
                  id,content_type,content_fingerprint,ciphertext,nonce,tag,encrypted_blob_path,
                  thumbnail_ciphertext,thumbnail_nonce,thumbnail_tag,
                  inferred_source_bundle_id,byte_count,is_sensitive,created_at,last_copied_at
                ) VALUES(?,?,?,?,?,?,NULL,?,?,?,?,?,?,?,?);
                """
        ) { statement in
            try bind(item.id, to: 1, in: statement)
            try bind(item.contentType.rawValue, to: 2, in: statement)
            try bind(item.fingerprint, to: 3, in: statement)
            try bind(item.ciphertext, to: 4, in: statement)
            try bind(item.nonce, to: 5, in: statement)
            try bind(item.tag, to: 6, in: statement)
            if let thumbnailCiphertext = item.thumbnailCiphertext {
                try bind(thumbnailCiphertext, to: 7, in: statement)
            } else {
                sqlite3_bind_null(statement, 7)
            }
            if let thumbnailNonce = item.thumbnailNonce {
                try bind(thumbnailNonce, to: 8, in: statement)
            } else {
                sqlite3_bind_null(statement, 8)
            }
            if let thumbnailTag = item.thumbnailTag {
                try bind(thumbnailTag, to: 9, in: statement)
            } else {
                sqlite3_bind_null(statement, 9)
            }
            if let source = item.sourceBundleIdentifier {
                try bind(source, to: 10, in: statement)
            } else {
                sqlite3_bind_null(statement, 10)
            }
            try bind(Int64(item.byteCount), to: 11, in: statement)
            try bind(Int64(item.isSensitive ? 1 : 0), to: 12, in: statement)
            try bind(item.createdAt.timeIntervalSince1970, to: 13, in: statement)
            try bind(item.lastCopiedAt.timeIntervalSince1970, to: 14, in: statement)
            try requireDone(statement)
        }
    }

    public func updateClipboardThumbnail(
        id: String,
        ciphertext: Data,
        nonce: Data,
        tag: Data,
        encryptedByteCount: Int
    ) throws {
        let database = try databaseHandle()
        try withStatement(
            database: database,
            sql: """
                UPDATE clipboard_items SET
                  thumbnail_ciphertext=?,thumbnail_nonce=?,thumbnail_tag=?,byte_count=byte_count+?
                WHERE id=? AND content_type='image';
                """
        ) { statement in
            try bind(ciphertext, to: 1, in: statement)
            try bind(nonce, to: 2, in: statement)
            try bind(tag, to: 3, in: statement)
            try bind(Int64(max(0, encryptedByteCount)), to: 4, in: statement)
            try bind(id, to: 5, in: statement)
            try requireDone(statement)
        }
    }

    public func touchClipboardItem(id: String, at date: Date, sourceBundleIdentifier: String?) throws {
        let database = try databaseHandle()
        try withStatement(
            database: database,
            sql: "UPDATE clipboard_items SET last_copied_at=?, inferred_source_bundle_id=COALESCE(?,inferred_source_bundle_id) WHERE id=?;"
        ) { statement in
            try bind(date.timeIntervalSince1970, to: 1, in: statement)
            if let sourceBundleIdentifier {
                try bind(sourceBundleIdentifier, to: 2, in: statement)
            } else {
                sqlite3_bind_null(statement, 2)
            }
            try bind(id, to: 3, in: statement)
            try requireDone(statement)
        }
    }

    public func deleteClipboardItem(id: String) throws {
        let database = try databaseHandle()
        try withStatement(database: database, sql: "DELETE FROM clipboard_items WHERE id=?;") { statement in
            try bind(id, to: 1, in: statement)
            try requireDone(statement)
        }
    }

    public func clearClipboardItems() throws {
        let database = try databaseHandle()
        try execute(database: database, sql: "DELETE FROM clipboard_items;")
    }

    public func clearClipboardItems(contentType: ClipboardContentType) throws {
        let database = try databaseHandle()
        try withStatement(database: database, sql: "DELETE FROM clipboard_items WHERE content_type=?;") { statement in
            try bind(contentType.rawValue, to: 1, in: statement)
            try requireDone(statement)
        }
    }

    public func trimClipboardItems(olderThan cutoff: Date?, maximumCount: Int?) throws {
        let database = try databaseHandle()
        if let cutoff {
            try withStatement(database: database, sql: "DELETE FROM clipboard_items WHERE last_copied_at < ?;") { statement in
                try bind(cutoff.timeIntervalSince1970, to: 1, in: statement)
                try requireDone(statement)
            }
        }
        if let maximumCount {
            try withStatement(
                database: database,
                sql: """
                    DELETE FROM clipboard_items WHERE id IN (
                      SELECT id FROM clipboard_items ORDER BY last_copied_at DESC LIMIT -1 OFFSET ?
                    );
                    """
            ) { statement in
                try bind(Int64(max(0, maximumCount)), to: 1, in: statement)
                try requireDone(statement)
            }
        }
    }

    private func clipboardItem(column: String, value: String) throws -> StoredClipboardItem? {
        let allowedColumns = ["id", "content_fingerprint"]
        guard allowedColumns.contains(column) else {
            throw DatabaseError.statementFailed(code: SQLITE_MISUSE)
        }
        let database = try databaseHandle()
        return try withStatement(
            database: database,
            sql: """
                SELECT id,content_type,content_fingerprint,ciphertext,nonce,tag,
                       thumbnail_ciphertext,thumbnail_nonce,thumbnail_tag,
                       inferred_source_bundle_id,byte_count,is_sensitive,created_at,last_copied_at
                FROM clipboard_items WHERE \(column)=? LIMIT 1;
                """
        ) { statement in
            try bind(value, to: 1, in: statement)
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW else { throw DatabaseError.statementFailed(code: status) }
            return try decodeClipboardItem(statement)
        }
    }

    private func decodeClipboardItem(_ statement: OpaquePointer) throws -> StoredClipboardItem? {
        guard let id = string(at: 0, in: statement),
            let rawType = string(at: 1, in: statement),
            let type = ClipboardContentType(rawValue: rawType),
            let fingerprint = string(at: 2, in: statement),
            let ciphertext = data(at: 3, in: statement),
            let nonce = data(at: 4, in: statement),
            let tag = data(at: 5, in: statement)
        else { return nil }
        return StoredClipboardItem(
            id: id,
            contentType: type,
            fingerprint: fingerprint,
            ciphertext: ciphertext,
            nonce: nonce,
            tag: tag,
            thumbnailCiphertext: data(at: 6, in: statement),
            thumbnailNonce: data(at: 7, in: statement),
            thumbnailTag: data(at: 8, in: statement),
            sourceBundleIdentifier: string(at: 9, in: statement),
            byteCount: Int(sqlite3_column_int64(statement, 10)),
            isSensitive: sqlite3_column_int64(statement, 11) != 0,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 12)),
            lastCopiedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 13))
        )
    }
}

public actor ClipboardStore {
    public static let maximumSearchResults = 1_000

    private static let thumbnailContentType = "image-thumbnail"
    private static let thumbnailMaximumPixelSize = 128
    private static let thumbnailMaximumBytes = 256 * 1_024

    private let database: LauncherDatabase
    private let keyManager: InstallationKeyManager
    private let crypto: ClipboardCrypto
    private var policy: ClipboardRetentionPolicy
    private var keys: ClipboardDerivedKeys?
    private var memory: [String: ClipboardMemoryEntry] = [:]
    private var state: ClipboardStoreState = .disabled
    private var stateContinuations: [UUID: AsyncStream<ClipboardStoreState>.Continuation] = [:]
    private var initializationGeneration: UInt64 = 0
    private var operationInProgress = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        database: LauncherDatabase,
        keyManager: InstallationKeyManager,
        crypto: ClipboardCrypto = ClipboardCrypto(),
        policy: ClipboardRetentionPolicy = ClipboardRetentionPolicy()
    ) {
        self.database = database
        self.keyManager = keyManager
        self.crypto = crypto
        self.policy = policy
    }

    public func currentState() -> ClipboardStoreState { state }

    public func stateUpdates() -> AsyncStream<ClipboardStoreState> {
        let identifier = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.yield(state)
            stateContinuations[identifier] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeStateContinuation(identifier) }
            }
        }
    }

    public func initialize(enabled: Bool) async {
        initializationGeneration &+= 1
        let generation = initializationGeneration
        guard enabled else {
            updateState(.disabled)
            memory = [:]
            keys = nil
            return
        }
        updateState(.loading)
        await acquireOperation()
        defer { releaseOperation() }
        guard initializationGeneration == generation else { return }
        do {
            try Task.checkCancellation()
            let count = try await database.clipboardItemCount()
            let derivedKeys = try await keyManager.clipboardKeys(createIfMissing: count == 0)
            let records = try await database.clipboardItems(limit: policy.maximumItemCount ?? 10_000)
            var index: [String: ClipboardMemoryEntry] = [:]
            index.reserveCapacity(records.count)
            for (offset, record) in records.enumerated() {
                try Task.checkCancellation()
                if offset > 0, offset.isMultiple(of: 100) { await Task.yield() }
                if record.contentType == .image {
                    index[record.id] = ClipboardMemoryEntry(
                        stored: record,
                        content: nil,
                        thumbnailPNG: try decryptThumbnail(record, keys: derivedKeys),
                        searchableText: "image screenshot picture"
                    )
                } else {
                    let content = try decrypt(record, keys: derivedKeys)
                    index[record.id] = ClipboardMemoryEntry(
                        stored: record,
                        content: content,
                        thumbnailPNG: nil,
                        searchableText: Self.searchableText(for: content)
                    )
                }
            }
            guard initializationGeneration == generation else { return }
            keys = derivedKeys
            memory = index
            updateState(.ready(itemCount: records.count))
        } catch InstallationKeyError.missingClipboardKey {
            guard initializationGeneration == generation else { return }
            let count = (try? await database.clipboardItemCount()) ?? 0
            guard initializationGeneration == generation else { return }
            updateState(.keyMissing(encryptedItemCount: count))
            memory = [:]
            keys = nil
        } catch is CancellationError {
            guard initializationGeneration == generation else { return }
            updateState(.disabled)
        } catch let descriptor as ErrorDescriptor {
            guard initializationGeneration == generation else { return }
            updateState(.failed(descriptor))
        } catch let error as ClipboardCryptoError {
            guard initializationGeneration == generation else { return }
            updateState(.failed(error.descriptor))
        } catch let error as DatabaseError {
            guard initializationGeneration == generation else { return }
            updateState(.failed(error.descriptor))
        } catch {
            guard initializationGeneration == generation else { return }
            updateState(
                .failed(
                    ErrorDescriptor(
                        code: "clipboard.initializeFailed",
                        message: "Clipboard history could not be initialized."
                    )
                )
            )
        }
    }

    public func capture(
        _ content: ClipboardContent,
        sourceBundleIdentifier: String?,
        at date: Date = Date()
    ) async -> Result<String, ErrorDescriptor> {
        await acquireOperation()
        defer { releaseOperation() }
        let generation = initializationGeneration
        var insertedID: String?
        do {
            guard case .ready = state, let keys else {
                return .failure(ErrorDescriptor(code: "clipboard.notReady", message: "Clipboard history is not ready."))
            }
            try Task.checkCancellation()
            let plaintext = try Self.encodeAndValidate(content)
            let thumbnailPNG = try Self.makeThumbnail(for: content)
            let fingerprint = PrivacyKeyHasher.fingerprint(for: plaintext, key: keys.fingerprint)
            if let existing = try await database.clipboardItem(fingerprint: fingerprint) {
                try ensureCaptureIsCurrent(generation)
                var thumbnailCiphertext = existing.thumbnailCiphertext
                var thumbnailNonce = existing.thumbnailNonce
                var thumbnailTag = existing.thumbnailTag
                if let thumbnailPNG,
                    thumbnailCiphertext == nil || thumbnailNonce == nil || thumbnailTag == nil
                {
                    let encryptedThumbnail = try crypto.seal(
                        thumbnailPNG,
                        itemID: existing.id,
                        contentType: Self.thumbnailContentType,
                        keys: keys
                    )
                    try await database.updateClipboardThumbnail(
                        id: existing.id,
                        ciphertext: encryptedThumbnail.ciphertext,
                        nonce: encryptedThumbnail.nonce,
                        tag: encryptedThumbnail.tag,
                        encryptedByteCount: Self.encryptedByteCount(encryptedThumbnail)
                    )
                    try ensureCaptureIsCurrent(generation)
                    thumbnailCiphertext = encryptedThumbnail.ciphertext
                    thumbnailNonce = encryptedThumbnail.nonce
                    thumbnailTag = encryptedThumbnail.tag
                }
                try await database.touchClipboardItem(
                    id: existing.id,
                    at: date,
                    sourceBundleIdentifier: sourceBundleIdentifier
                )
                try ensureCaptureIsCurrent(generation)
                let updated = StoredClipboardItem(
                    id: existing.id,
                    contentType: existing.contentType,
                    fingerprint: existing.fingerprint,
                    ciphertext: existing.ciphertext,
                    nonce: existing.nonce,
                    tag: existing.tag,
                    thumbnailCiphertext: thumbnailCiphertext,
                    thumbnailNonce: thumbnailNonce,
                    thumbnailTag: thumbnailTag,
                    sourceBundleIdentifier: sourceBundleIdentifier ?? existing.sourceBundleIdentifier,
                    byteCount: existing.byteCount,
                    isSensitive: existing.isSensitive,
                    createdAt: existing.createdAt,
                    lastCopiedAt: date
                )
                memory[existing.id] = ClipboardMemoryEntry(
                    stored: updated,
                    content: content.contentType == .image ? nil : content,
                    thumbnailPNG: thumbnailPNG,
                    searchableText: Self.searchableText(for: content)
                )
                updateState(.ready(itemCount: memory.count))
                return .success(existing.id)
            }

            let id = UUID().uuidString.lowercased()
            let encrypted = try crypto.seal(
                plaintext,
                itemID: id,
                contentType: content.contentType.rawValue,
                keys: keys
            )
            let encryptedThumbnail = try thumbnailPNG.map {
                try crypto.seal(
                    $0,
                    itemID: id,
                    contentType: Self.thumbnailContentType,
                    keys: keys
                )
            }
            let storedByteCount =
                Self.encryptedByteCount(encrypted)
                + (encryptedThumbnail.map(Self.encryptedByteCount) ?? 0)
            let total = try await database.clipboardTotalBytes()
            try ensureCaptureIsCurrent(generation)
            guard total + storedByteCount <= policy.maximumDiskBytes else {
                return .failure(
                    ErrorDescriptor(
                        code: "clipboard.diskQuotaExceeded",
                        message: "Clipboard history reached its disk quota.",
                        recoverySuggestion: "Clear older items or increase the quota in settings."
                    )
                )
            }
            let item = StoredClipboardItem(
                id: id,
                contentType: content.contentType,
                fingerprint: encrypted.fingerprint,
                ciphertext: encrypted.ciphertext,
                nonce: encrypted.nonce,
                tag: encrypted.tag,
                thumbnailCiphertext: encryptedThumbnail?.ciphertext,
                thumbnailNonce: encryptedThumbnail?.nonce,
                thumbnailTag: encryptedThumbnail?.tag,
                sourceBundleIdentifier: sourceBundleIdentifier,
                byteCount: storedByteCount,
                isSensitive: Self.looksSensitive(content),
                createdAt: date,
                lastCopiedAt: date
            )
            try await database.insertClipboardItem(item)
            insertedID = id
            try ensureCaptureIsCurrent(generation)
            let retained = try await applyRetention(now: date)
            try ensureCaptureIsCurrent(generation)
            if retained.contains(id) {
                memory[id] = ClipboardMemoryEntry(
                    stored: item,
                    content: content.contentType == .image ? nil : content,
                    thumbnailPNG: thumbnailPNG,
                    searchableText: Self.searchableText(for: content)
                )
            } else {
                memory[id] = nil
            }
            updateState(.ready(itemCount: memory.count))
            insertedID = nil
            return .success(id)
        } catch is CancellationError {
            if let rollbackError = await rollbackInsertedCapture(insertedID) {
                return .failure(rollbackError)
            }
            return .failure(
                ErrorDescriptor(code: "clipboard.captureCancelled", message: "Clipboard capture was cancelled.")
            )
        } catch let descriptor as ErrorDescriptor {
            if let rollbackError = await rollbackInsertedCapture(insertedID) {
                return .failure(rollbackError)
            }
            return .failure(descriptor)
        } catch let error as ClipboardCryptoError {
            if let rollbackError = await rollbackInsertedCapture(insertedID) {
                return .failure(rollbackError)
            }
            return .failure(error.descriptor)
        } catch let error as DatabaseError {
            if let rollbackError = await rollbackInsertedCapture(insertedID) {
                return .failure(rollbackError)
            }
            return .failure(error.descriptor)
        } catch {
            if let rollbackError = await rollbackInsertedCapture(insertedID) {
                return .failure(rollbackError)
            }
            return .failure(ErrorDescriptor(code: "clipboard.captureFailed", message: "The clipboard item could not be saved."))
        }
    }

    public func search(
        _ query: String,
        contentType: ClipboardContentType? = nil,
        limit: Int = 50
    ) -> Result<[ClipboardSearchEntry], ErrorDescriptor> {
        guard case .ready = state else {
            return .failure(Self.error(for: state))
        }
        let normalized = TextNormalizer.normalize(query)
        let matches = memory.values
            .filter { entry in
                (contentType == nil || entry.stored.contentType == contentType)
                    && (normalized.isEmpty || TextNormalizer.normalize(entry.searchableText).contains(normalized))
            }
            .sorted { lhs, rhs in
                if lhs.stored.lastCopiedAt != rhs.stored.lastCopiedAt {
                    return lhs.stored.lastCopiedAt > rhs.stored.lastCopiedAt
                }
                return lhs.stored.id < rhs.stored.id
            }
            .prefix(min(max(1, limit), Self.maximumSearchResults))
            .map(Self.searchEntry)
        return .success(Array(matches))
    }

    /// Returns the newest item across every supported content type. Quick Paste
    /// uses this instead of filtering for text so an unsupported newer item can
    /// fail closed and fall back to the full history panel.
    public func latestEntry() -> Result<ClipboardSearchEntry?, ErrorDescriptor> {
        guard case .ready = state else {
            return .failure(Self.error(for: state))
        }
        let latest = memory.values.max { lhs, rhs in
            if lhs.stored.lastCopiedAt != rhs.stored.lastCopiedAt {
                return lhs.stored.lastCopiedAt < rhs.stored.lastCopiedAt
            }
            return lhs.stored.id > rhs.stored.id
        }
        return .success(latest.map(Self.searchEntry))
    }

    public func content(id: String) async -> Result<ClipboardContent, ErrorDescriptor> {
        await acquireOperation()
        defer { releaseOperation() }
        let generation = initializationGeneration
        do {
            try ensureCaptureIsCurrent(generation)
            guard case .ready = state, let keys else {
                return .failure(Self.error(for: state))
            }
            if let content = memory[id]?.content { return .success(content) }
            guard let stored = try await database.clipboardItem(id: id) else {
                return .failure(ErrorDescriptor(code: "clipboard.notFound", message: "The clipboard item was removed."))
            }
            try ensureCaptureIsCurrent(generation)
            let content = try decrypt(stored, keys: keys)
            if stored.contentType == .image,
                memory[id]?.thumbnailPNG == nil,
                let thumbnailPNG = try Self.makeThumbnail(for: content)
            {
                let encryptedThumbnail = try crypto.seal(
                    thumbnailPNG,
                    itemID: stored.id,
                    contentType: Self.thumbnailContentType,
                    keys: keys
                )
                try await database.updateClipboardThumbnail(
                    id: stored.id,
                    ciphertext: encryptedThumbnail.ciphertext,
                    nonce: encryptedThumbnail.nonce,
                    tag: encryptedThumbnail.tag,
                    encryptedByteCount: Self.encryptedByteCount(encryptedThumbnail)
                )
                try ensureCaptureIsCurrent(generation)
                memory[id] = ClipboardMemoryEntry(
                    stored: stored,
                    content: nil,
                    thumbnailPNG: thumbnailPNG,
                    searchableText: Self.searchableText(for: content)
                )
            }
            return .success(content)
        } catch is CancellationError {
            return .failure(ErrorDescriptor(code: "clipboard.readCancelled", message: "Clipboard reading was cancelled."))
        } catch let error as ClipboardCryptoError {
            return .failure(error.descriptor)
        } catch let error as DatabaseError {
            return .failure(error.descriptor)
        } catch {
            return .failure(ErrorDescriptor(code: "clipboard.decryptFailed", message: "The clipboard item could not be decrypted."))
        }
    }

    public func delete(id: String) async -> Result<Void, ErrorDescriptor> {
        await acquireOperation()
        defer { releaseOperation() }
        let generation = initializationGeneration
        do {
            try await database.deleteClipboardItem(id: id)
            if initializationGeneration == generation {
                memory[id] = nil
                if case .ready = state { updateState(.ready(itemCount: memory.count)) }
            }
            return .success(())
        } catch let error as DatabaseError {
            return .failure(error.descriptor)
        } catch {
            return .failure(ErrorDescriptor(code: "clipboard.deleteFailed", message: "The clipboard item could not be deleted."))
        }
    }

    public func clear() async -> Result<Void, ErrorDescriptor> {
        await acquireOperation()
        defer { releaseOperation() }
        let generation = initializationGeneration
        let keyWasMissing = if case .keyMissing = state { true } else { false }
        do {
            try await database.clearClipboardItems()
            guard initializationGeneration == generation else { return .success(()) }
            memory = [:]
            if keyWasMissing { updateState(.keyMissing(encryptedItemCount: 0)) }
            let replacementKeys = keyWasMissing ? try await keyManager.clipboardKeys(createIfMissing: true) : nil
            guard initializationGeneration == generation else { return .success(()) }
            if let replacementKeys {
                keys = replacementKeys
                updateState(.ready(itemCount: 0))
            } else if case .ready = state {
                updateState(.ready(itemCount: 0))
            }
            return .success(())
        } catch let error as DatabaseError {
            return .failure(error.descriptor)
        } catch {
            return .failure(ErrorDescriptor(code: "clipboard.clearFailed", message: "Clipboard history could not be cleared."))
        }
    }

    public func clear(type: ClipboardContentType) async -> Result<Void, ErrorDescriptor> {
        await acquireOperation()
        defer { releaseOperation() }
        let generation = initializationGeneration
        do {
            try await database.clearClipboardItems(contentType: type)
            let remainingCount = try await database.clipboardItemCount()
            guard initializationGeneration == generation else { return .success(()) }
            memory = memory.filter { $0.value.stored.contentType != type }
            switch state {
            case .ready:
                updateState(.ready(itemCount: memory.count))
            case .keyMissing:
                updateState(.keyMissing(encryptedItemCount: remainingCount))
            case .disabled, .loading, .failed:
                break
            }
            return .success(())
        } catch let error as DatabaseError {
            return .failure(error.descriptor)
        } catch {
            return .failure(ErrorDescriptor(code: "clipboard.clearTypeFailed", message: "Those clipboard items could not be cleared."))
        }
    }

    /// Destructive recovery must be called only after the user confirms deletion of undecryptable rows.
    public func recoverMissingKeyByDeletingHistory() async -> Result<Void, ErrorDescriptor> {
        await acquireOperation()
        defer { releaseOperation() }
        let generation = initializationGeneration
        guard case .keyMissing = state else {
            return .failure(ErrorDescriptor(code: "clipboard.recoveryNotRequired", message: "Clipboard recovery is not required."))
        }
        do {
            try await database.clearClipboardItems()
            guard initializationGeneration == generation else { return .success(()) }
            memory = [:]
            updateState(.keyMissing(encryptedItemCount: 0))
            let replacementKeys = try await keyManager.clipboardKeys(createIfMissing: true)
            guard initializationGeneration == generation else { return .success(()) }
            keys = replacementKeys
            memory = [:]
            updateState(.ready(itemCount: 0))
            return .success(())
        } catch {
            return .failure(ErrorDescriptor(code: "clipboard.recoveryFailed", message: "Clipboard history could not be reinitialized."))
        }
    }

    public func updatePolicy(_ policy: ClipboardRetentionPolicy) async -> Result<Void, ErrorDescriptor> {
        await acquireOperation()
        defer { releaseOperation() }
        self.policy = policy
        do {
            _ = try await applyRetention(now: Date())
            if case .ready = state { updateState(.ready(itemCount: memory.count)) }
            return .success(())
        } catch let error as DatabaseError {
            return .failure(error.descriptor)
        } catch {
            return .failure(
                ErrorDescriptor(
                    code: "clipboard.retentionFailed",
                    message: "Clipboard retention could not be applied."
                )
            )
        }
    }

    @discardableResult
    private func applyRetention(now: Date) async throws -> Set<String> {
        let cutoff = policy.maximumAge.map { now.addingTimeInterval(-$0) }
        try await database.trimClipboardItems(olderThan: cutoff, maximumCount: policy.maximumItemCount)
        let retained = Set(try await database.clipboardItems(limit: policy.maximumItemCount ?? 10_000).map(\.id))
        memory = memory.filter { retained.contains($0.key) }
        return retained
    }

    private func ensureCaptureIsCurrent(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard initializationGeneration == generation, case .ready = state, keys != nil else {
            throw CancellationError()
        }
    }

    private func rollbackInsertedCapture(_ id: String?) async -> ErrorDescriptor? {
        guard let id else { return nil }
        do {
            try await database.deleteClipboardItem(id: id)
            memory[id] = nil
            return nil
        } catch {
            memory = [:]
            keys = nil
            if case .disabled = state {
                // Keep the user-selected disabled state while failing closed in memory.
            } else {
                updateState(
                    .failed(
                        ErrorDescriptor(
                            code: "clipboard.captureRollbackFailed",
                            message: "An interrupted clipboard capture could not be rolled back.",
                            recoverySuggestion: "Open Privacy settings and review clipboard history before continuing."
                        )
                    )
                )
            }
            return ErrorDescriptor(
                code: "clipboard.captureRollbackFailed",
                message: "An interrupted clipboard capture could not be rolled back.",
                recoverySuggestion: "Open Privacy settings and review clipboard history before continuing."
            )
        }
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

    private func updateState(_ newState: ClipboardStoreState) {
        state = newState
        for continuation in stateContinuations.values {
            continuation.yield(newState)
        }
    }

    private func removeStateContinuation(_ identifier: UUID) {
        stateContinuations[identifier] = nil
    }

    private func decrypt(_ stored: StoredClipboardItem, keys: ClipboardDerivedKeys) throws -> ClipboardContent {
        let encrypted = EncryptedClipboardPayload(
            ciphertext: stored.ciphertext,
            nonce: stored.nonce,
            tag: stored.tag,
            fingerprint: stored.fingerprint
        )
        let plaintext = try crypto.open(
            encrypted,
            itemID: stored.id,
            contentType: stored.contentType.rawValue,
            keys: keys
        )
        return try JSONDecoder().decode(ClipboardContent.self, from: plaintext)
    }

    private func decryptThumbnail(_ stored: StoredClipboardItem, keys: ClipboardDerivedKeys) throws -> Data? {
        let components = [stored.thumbnailCiphertext, stored.thumbnailNonce, stored.thumbnailTag]
        if components.allSatisfy({ $0 == nil }) { return nil }
        guard let ciphertext = stored.thumbnailCiphertext,
            let nonce = stored.thumbnailNonce,
            let tag = stored.thumbnailTag
        else {
            throw ErrorDescriptor(
                code: "clipboard.thumbnailCorrupt",
                message: "An encrypted clipboard thumbnail is incomplete."
            )
        }
        let plaintext = try crypto.open(
            EncryptedClipboardPayload(
                ciphertext: ciphertext,
                nonce: nonce,
                tag: tag,
                fingerprint: stored.fingerprint
            ),
            itemID: stored.id,
            contentType: Self.thumbnailContentType,
            keys: keys
        )
        guard Self.isValidThumbnail(plaintext) else {
            throw ErrorDescriptor(
                code: "clipboard.thumbnailInvalid",
                message: "An encrypted clipboard thumbnail is invalid."
            )
        }
        return plaintext
    }

    private static func encodeAndValidate(_ content: ClipboardContent) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(content)
        switch content {
        case .text, .url, .files:
            guard data.count <= 2 * 1_024 * 1_024 else {
                throw ErrorDescriptor(code: "clipboard.textTooLarge", message: "This clipboard item exceeds the 2 MiB limit.")
            }
        case let .imagePNG(imageData):
            guard imageData.count <= 25 * 1_024 * 1_024 else {
                throw ErrorDescriptor(code: "clipboard.imageTooLarge", message: "This clipboard image exceeds the 25 MiB limit.")
            }
            guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                width.int64Value > 0,
                height.int64Value > 0,
                width.int64Value <= 100_000_000 / height.int64Value
            else {
                throw ErrorDescriptor(code: "clipboard.invalidImage", message: "The clipboard image is invalid or exceeds 100 megapixels.")
            }
        }
        return data
    }

    private static func makeThumbnail(for content: ClipboardContent) throws -> Data? {
        guard case let .imagePNG(imageData) = content else { return nil }
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: thumbnailMaximumPixelSize,
                    kCGImageSourceShouldCacheImmediately: false,
                ] as CFDictionary
            )
        else {
            throw ErrorDescriptor(code: "clipboard.thumbnailFailed", message: "A safe image thumbnail could not be created.")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
            throw ErrorDescriptor(code: "clipboard.thumbnailFailed", message: "A safe image thumbnail could not be created.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ErrorDescriptor(code: "clipboard.thumbnailFailed", message: "A safe image thumbnail could not be created.")
        }
        let thumbnail = output as Data
        guard isValidThumbnail(thumbnail) else {
            throw ErrorDescriptor(code: "clipboard.thumbnailFailed", message: "A safe image thumbnail could not be created.")
        }
        return thumbnail
    }

    private static func isValidThumbnail(_ data: Data) -> Bool {
        guard data.count <= thumbnailMaximumBytes,
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
            let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
            width.intValue > 0,
            height.intValue > 0,
            width.intValue <= thumbnailMaximumPixelSize,
            height.intValue <= thumbnailMaximumPixelSize
        else { return false }
        return true
    }

    private static func encryptedByteCount(_ payload: EncryptedClipboardPayload) -> Int {
        payload.ciphertext.count + payload.nonce.count + payload.tag.count
    }

    private static func searchableText(for content: ClipboardContent) -> String {
        switch content {
        case let .text(text): text
        case let .url(url): url.absoluteString
        case let .files(urls): urls.map(\.path).joined(separator: " ")
        case .imagePNG: "image screenshot picture"
        }
    }

    private static func looksSensitive(_ content: ClipboardContent) -> Bool {
        guard case let .text(text) = content else { return false }
        let normalized = text.lowercased()
        return normalized.contains("password")
            || normalized.contains("api_key")
            || normalized.contains("secret=")
            || (text.count >= 24 && text.range(of: #"^[A-Za-z0-9+/=_-]+$"#, options: .regularExpression) != nil)
    }

    private static func searchEntry(_ memory: ClipboardMemoryEntry) -> ClipboardSearchEntry {
        let title: String
        let subtitle: String?
        switch memory.content {
        case let .text(text):
            title = text.replacingOccurrences(of: "\n", with: " ").limitedToUnicodeScalars(180)
            subtitle = "Text"
        case let .url(url):
            title = url.absoluteString.limitedToUnicodeScalars(180)
            subtitle = "URL"
        case let .files(urls):
            title = urls.count == 1 ? (urls.first?.lastPathComponent ?? "File") : "\(urls.count) files"
            subtitle = urls.first?.deletingLastPathComponent().path
        case .imagePNG, .none:
            title = "Clipboard Image"
            subtitle = ByteCountFormatter.string(fromByteCount: Int64(memory.stored.byteCount), countStyle: .file)
        }
        return ClipboardSearchEntry(
            id: memory.stored.id,
            contentType: memory.stored.contentType,
            title: title,
            subtitle: subtitle,
            thumbnailPNG: memory.thumbnailPNG,
            sourceBundleIdentifier: memory.stored.sourceBundleIdentifier,
            isSensitive: memory.stored.isSensitive,
            lastCopiedAt: memory.stored.lastCopiedAt
        )
    }

    private static func error(for state: ClipboardStoreState) -> ErrorDescriptor {
        switch state {
        case .disabled:
            ErrorDescriptor(code: "clipboard.disabled", message: "Clipboard history is disabled.")
        case .loading:
            ErrorDescriptor(code: "clipboard.loading", message: "Clipboard history is loading.")
        case .ready:
            ErrorDescriptor(code: "clipboard.ready", message: "Clipboard history is ready.")
        case let .keyMissing(count):
            ErrorDescriptor(
                code: "clipboard.keyMissing",
                message: "The encryption key for \(count) clipboard items is missing.",
                recoverySuggestion: "Open Privacy settings to review recovery options."
            )
        case let .failed(error): error
        }
    }
}
