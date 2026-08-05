import Foundation
import KeyestroDomain
import Testing
@testable import KeyestroCore

@Test func rankingStorePersistsOnlyKeyedIdentifiers() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyestro-ranking-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        bundleIdentifier: "com.keyestro.ranking-tests",
        applicationSupportRoot: root.appendingPathComponent("support", isDirectory: true),
        cachesRoot: root.appendingPathComponent("cache", isDirectory: true)
    )
    let database = LauncherDatabase(paths: paths)
    let keyManager = InstallationKeyManager(keychain: InMemoryKeychainService(), service: "com.keyestro.ranking-tests")
    let itemID = ItemID(providerID: "files", providerStableID: "/Users/example/private.txt")
    let date = Date(timeIntervalSince1970: 1_000)
    let store = RankingStore(database: database, keys: keyManager, clock: ManualClockService(date: date))
    try await store.record(itemID: itemID, actionID: "open", at: date)

    let action = ActionDescriptor(id: "open", title: "Open")
    let item = LauncherItem(
        id: itemID,
        providerID: "files",
        title: "private.txt",
        actions: [action],
        defaultActionID: action.id
    )
    let enriched = try await store.enrich([item])
    #expect(enriched[0].scoreFeatures.executionCount90Days == 1)
    #expect(enriched[0].scoreFeatures.lastUsedAt == date)
    #expect(try await store.togglePin(itemID: itemID, providerID: "files", at: date))
    #expect(try await store.enrich([item])[0].scoreFeatures.isPinned)

    try await store.clearLearning()
    let cleared = try await store.enrich([item])[0]
    #expect(cleared.scoreFeatures.executionCount90Days == 0)
    #expect(cleared.scoreFeatures.lastUsedAt == nil)
    #expect(cleared.scoreFeatures.isPinned)

    let databaseBytes = try Data(contentsOf: paths.database)
    #expect(!String(decoding: databaseBytes, as: UTF8.self).contains("private.txt"))
}

@Test func rankingStoreCanExcludeLearnedUsageWithoutDisablingManualPins() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyestro-ranking-disabled-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        bundleIdentifier: "com.keyestro.ranking-disabled-tests",
        applicationSupportRoot: root.appendingPathComponent("support", isDirectory: true),
        cachesRoot: root.appendingPathComponent("cache", isDirectory: true)
    )
    let store = RankingStore(
        database: LauncherDatabase(paths: paths),
        keys: InstallationKeyManager(
            keychain: InMemoryKeychainService(),
            service: "com.keyestro.ranking-disabled-tests"
        )
    )
    let itemID = ItemID(providerID: "applications", providerStableID: "com.example.editor")
    let action = ActionDescriptor(id: "open", title: "Open")
    let item = LauncherItem(
        id: itemID,
        providerID: itemID.providerID,
        title: "Editor",
        actions: [action],
        defaultActionID: action.id
    )
    try await store.record(itemID: itemID, actionID: action.id, at: Date())
    #expect(try await store.togglePin(itemID: itemID, providerID: itemID.providerID, at: Date()))

    let enriched = try await store.enrich([item], includeLearning: false)[0]
    #expect(enriched.scoreFeatures.lastUsedAt == nil)
    #expect(enriched.scoreFeatures.executionCount90Days == 0)
    #expect(enriched.scoreFeatures.isPinned)
}

@Test func concurrentRankingEventsUpdateTheDatabaseAndInMemorySnapshotExactlyOnceEach() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyestro-ranking-concurrent-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        bundleIdentifier: "com.keyestro.ranking-concurrent-tests",
        applicationSupportRoot: root.appendingPathComponent("support", isDirectory: true),
        cachesRoot: root.appendingPathComponent("cache", isDirectory: true)
    )
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let store = RankingStore(
        database: LauncherDatabase(paths: paths),
        keys: InstallationKeyManager(
            keychain: InMemoryKeychainService(),
            service: "com.keyestro.ranking-concurrent-tests"
        ),
        clock: ManualClockService(date: start.addingTimeInterval(40)),
        statsCacheLifetime: 300
    )
    let itemID = ItemID(providerID: "applications", providerStableID: "com.example.concurrent")
    let action = ActionDescriptor(id: "open", title: "Open")
    let item = LauncherItem(
        id: itemID,
        providerID: itemID.providerID,
        title: "Concurrent",
        actions: [action],
        defaultActionID: action.id
    )
    _ = try await store.enrich([item])

    try await withThrowingTaskGroup(of: Void.self) { group in
        for index in 0..<32 {
            group.addTask {
                try await store.record(
                    itemID: itemID,
                    actionID: action.id,
                    at: start.addingTimeInterval(TimeInterval(index + 1))
                )
            }
        }
        try await group.waitForAll()
    }

    let enriched = try await store.enrich([item])[0]
    #expect(enriched.scoreFeatures.executionCount90Days == 32)
    #expect(enriched.scoreFeatures.lastUsedAt == start.addingTimeInterval(32))
}

@Test func rankingStoreExpiresNinetyDayUsageFromItsInMemorySnapshot() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyestro-ranking-expiry-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        bundleIdentifier: "com.keyestro.ranking-expiry-tests",
        applicationSupportRoot: root.appendingPathComponent("support", isDirectory: true),
        cachesRoot: root.appendingPathComponent("cache", isDirectory: true)
    )
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let clock = ManualClockService(date: start)
    let store = RankingStore(
        database: LauncherDatabase(paths: paths),
        keys: InstallationKeyManager(
            keychain: InMemoryKeychainService(),
            service: "com.keyestro.ranking-expiry-tests"
        ),
        clock: clock,
        statsCacheLifetime: 1
    )
    let itemID = ItemID(providerID: "applications", providerStableID: "com.example.frequently-used")
    let action = ActionDescriptor(id: "open", title: "Open")
    let item = LauncherItem(
        id: itemID,
        providerID: itemID.providerID,
        title: "Frequently Used",
        actions: [action],
        defaultActionID: action.id
    )
    for _ in 0..<20 { try await store.record(itemID: itemID, actionID: action.id, at: start) }
    #expect(try await store.enrich([item])[0].scoreFeatures.executionCount90Days == 20)

    await clock.advance(by: .seconds(91 * 86_400))

    let expired = try await store.enrich([item])[0]
    #expect(expired.scoreFeatures.executionCount90Days == 0)
    #expect(expired.scoreFeatures.lastUsedAt == nil)
}

@Test func rankingLearningToggleChangesQueryAndActionBehaviorImmediately() async throws {
    let preferences = RankingLearningPreferences(enabled: false)
    let ranking = RecordingRankingService()
    let provider = SuccessfulRankingProvider()
    let coordinator = QueryCoordinator(
        providers: [provider],
        rankingStore: ranking,
        rankingLearning: preferences
    )

    for await _ in await coordinator.search(rawText: "Editor") {}
    #expect(await ranking.enrichmentModes.isEmpty == false)
    #expect(await ranking.enrichmentModes.allSatisfy { !$0 })

    let resolvedAction = ResolvedAction(
        providerID: provider.descriptor.id,
        itemID: provider.itemID,
        actionID: provider.action.id,
        descriptor: provider.action,
        displayedTitle: "Editor",
        displayedSubtitle: nil,
        privacy: .normal
    )
    let runner = ActionRunner(
        providers: [provider],
        rankingStore: ranking,
        rankingLearning: preferences
    )
    _ = await runner.run(
        executionID: UUID(),
        resolvedAction: resolvedAction,
        arguments: [:],
        riskConfirmed: false
    )
    #expect(await ranking.recordedItems.isEmpty)

    preferences.setEnabled(true)
    for await _ in await coordinator.search(rawText: "Editor") {}
    #expect(await ranking.enrichmentModes.last == true)
    _ = await runner.run(
        executionID: UUID(),
        resolvedAction: resolvedAction,
        arguments: [:],
        riskConfirmed: false
    )
    #expect(await ranking.recordedItems == [provider.itemID])
}

private actor RecordingRankingService: RankingServicing {
    private(set) var enrichmentModes: [Bool] = []
    private(set) var recordedItems: [ItemID] = []

    func enrich(_ items: [LauncherItem], includeLearning: Bool) -> [LauncherItem] {
        enrichmentModes.append(includeLearning)
        return items
    }

    func record(itemID: ItemID, actionID: ActionID, at date: Date) {
        recordedItems.append(itemID)
    }

    func togglePin(itemID: ItemID, providerID: ProviderID, at date: Date) -> Bool { true }

    func clearLearning() {}
}

private struct SuccessfulRankingProvider: LauncherProvider {
    let descriptor = ProviderDescriptor(
        id: "ranking-toggle-test",
        displayName: "Ranking Toggle Test",
        supportedModes: [.all],
        supportsEmptyQuery: false
    )
    let itemID = ItemID(providerID: "ranking-toggle-test", providerStableID: "editor")
    let action = ActionDescriptor(id: "open", title: "Open")

    func search(request: QueryRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(
                .items(
                    [
                        LauncherItem(
                            id: itemID,
                            providerID: descriptor.id,
                            title: "Editor",
                            actions: [action],
                            defaultActionID: action.id
                        )
                    ],
                    isFinal: true
                )
            )
            continuation.finish()
        }
    }

    func execute(request: ProviderActionRequest) async -> ActionResult { .success() }
}
