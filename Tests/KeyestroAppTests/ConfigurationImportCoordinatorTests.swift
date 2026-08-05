import Foundation
import KeyestroCore
import Testing
@testable import KeyestroApp

@Test @MainActor func configurationTransactionRestoresSettingsAndPendingImportsWhenSQLiteCommitFails() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyestro-import-transaction-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        bundleIdentifier: "com.keyestro.import-transaction-tests",
        applicationSupportRoot: root.appendingPathComponent("Support", isDirectory: true),
        cachesRoot: root.appendingPathComponent("Caches", isDirectory: true)
    )
    let importedLink = try QuicklinkDefinition.inferred(
        id: "imported-link",
        title: "Imported Link",
        urlTemplate: "https://example.com"
    )
    let importedScript = try ScriptDefinition(
        id: "imported-script",
        title: "Imported Script",
        executablePath: "/private/imported-script",
        contentHash: String(repeating: "a", count: 64)
    )
    let source = ConfigurationService(
        quicklinks: InMemoryQuicklinkStore(definitions: [importedLink]),
        scripts: InMemoryScriptStore(scripts: [importedScript]),
        extensions: InMemoryExtensionStore(),
        paths: paths,
        appVersion: "1.0.0"
    )
    let data = try await source.export(settings: ["search.prefixesEnabled": .bool(false)])

    let targetQuicklinks = FailingConfigurationQuicklinkStore()
    let target = ConfigurationService(
        quicklinks: targetQuicklinks,
        scripts: InMemoryScriptStore(),
        extensions: InMemoryExtensionStore(),
        paths: paths,
        appVersion: "1.0.0"
    )
    let validated = try await target.inspectImport(data)
    let suiteName = "com.keyestro.import-transaction-tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let existingScript = try ScriptDefinition(
        id: "existing-script",
        title: "Existing Script",
        executablePath: "/private/existing-script",
        contentHash: String(repeating: "b", count: 64)
    )
    let pendingStore = PendingConfigurationImportStore(defaults: defaults)
    try pendingStore.merge(scripts: [ExportedScriptRegistration(existingScript)], extensions: [])
    let settings = SettingsStore(defaults: defaults)
    let coordinator = ConfigurationImportCoordinator(
        service: target,
        settings: settings,
        defaults: defaults,
        removeJournal: { _ in throw RetainedJournalFailure() }
    )

    await #expect(throws: ConfigurationImportTransactionError.self) {
        try await coordinator.apply(validated)
    }

    #expect(settings.prefixesEnabled)
    #expect(try pendingStore.scripts().map(\.id) == [existingScript.id])
    #expect(await targetQuicklinks.allQuicklinks().isEmpty)
    let backups = try FileManager.default.contentsOfDirectory(at: paths.backups, includingPropertiesForKeys: nil)
    #expect(backups.contains { $0.lastPathComponent.hasPrefix("Configuration-") })

    try settings.applyImportedConfiguration(["search.prefixesEnabled": .bool(false)])
    try pendingStore.merge(scripts: [ExportedScriptRegistration(importedScript)], extensions: [])
    let recovery = ConfigurationImportCoordinator(service: target, settings: settings, defaults: defaults)
    #expect(try await recovery.recoverIfNeeded())
    #expect(settings.prefixesEnabled)
    #expect(try pendingStore.scripts().map(\.id) == [existingScript.id])
}

@Test @MainActor func configurationTransactionFinishesCommittedStateFromADurableJournal() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyestro-import-commit-recovery-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        bundleIdentifier: "com.keyestro.import-commit-recovery-tests",
        applicationSupportRoot: root.appendingPathComponent("Support", isDirectory: true),
        cachesRoot: root.appendingPathComponent("Caches", isDirectory: true)
    )
    let importedLink = try QuicklinkDefinition.inferred(
        id: "committed-link",
        title: "Committed Link",
        urlTemplate: "https://example.com"
    )
    let importedScript = try ScriptDefinition(
        id: "committed-script",
        title: "Committed Script",
        executablePath: "/private/committed-script",
        contentHash: String(repeating: "c", count: 64)
    )
    let source = ConfigurationService(
        quicklinks: InMemoryQuicklinkStore(definitions: [importedLink]),
        scripts: InMemoryScriptStore(scripts: [importedScript]),
        extensions: InMemoryExtensionStore(),
        paths: paths,
        appVersion: "1.0.0"
    )
    let data = try await source.export(settings: ["search.prefixesEnabled": .bool(false)])
    let targetStore = InMemoryQuicklinkStore()
    let target = ConfigurationService(
        quicklinks: targetStore,
        scripts: InMemoryScriptStore(),
        extensions: InMemoryExtensionStore(),
        paths: paths,
        appVersion: "1.0.0"
    )
    let validated = try await target.inspectImport(data)
    let suiteName = "com.keyestro.import-commit-recovery-tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let settings = SettingsStore(defaults: defaults)
    let pendingStore = PendingConfigurationImportStore(defaults: defaults)
    let coordinator = ConfigurationImportCoordinator(
        service: target,
        settings: settings,
        defaults: defaults,
        removeJournal: { _ in throw RetainedJournalFailure() }
    )
    _ = try await coordinator.apply(validated)

    try settings.applyImportedConfiguration(["search.prefixesEnabled": .bool(true)])
    try pendingStore.restore(PendingConfigurationImportSnapshot(scripts: [], extensions: []))
    let recovery = ConfigurationImportCoordinator(service: target, settings: settings, defaults: defaults)
    #expect(try await recovery.recoverIfNeeded())
    #expect(!settings.prefixesEnabled)
    #expect(try pendingStore.scripts().map(\.id) == [importedScript.id])
    #expect(await targetStore.quicklink(id: importedLink.id) != nil)
}

@Test @MainActor func concurrentConfigurationImportsAreSerializedAcrossSettingsAndSQLite() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyestro-import-serialization-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        bundleIdentifier: "com.keyestro.import-serialization-tests",
        applicationSupportRoot: root.appendingPathComponent("Support", isDirectory: true),
        cachesRoot: root.appendingPathComponent("Caches", isDirectory: true)
    )
    let source = ConfigurationService(
        quicklinks: InMemoryQuicklinkStore(),
        scripts: InMemoryScriptStore(),
        extensions: InMemoryExtensionStore(),
        paths: paths,
        appVersion: "1.0.0"
    )
    let firstData = try await source.export(settings: ["search.prefixesEnabled": .bool(false)])
    let secondData = try await source.export(settings: ["search.prefixesEnabled": .bool(true)])
    let targetStore = SuspendedConfigurationQuicklinkStore()
    let target = ConfigurationService(
        quicklinks: targetStore,
        scripts: InMemoryScriptStore(),
        extensions: InMemoryExtensionStore(),
        paths: paths,
        appVersion: "1.0.0"
    )
    let firstImport = try await target.inspectImport(firstData)
    let secondImport = try await target.inspectImport(secondData)
    let suiteName = "com.keyestro.import-serialization-tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let settings = SettingsStore(defaults: defaults)
    let coordinator = ConfigurationImportCoordinator(service: target, settings: settings, defaults: defaults)

    let firstTask = Task { @MainActor in try await coordinator.apply(firstImport) }
    for _ in 0..<1_000 {
        if await targetStore.firstMergeIsWaiting { break }
        await Task.yield()
    }
    #expect(await targetStore.firstMergeIsWaiting)
    #expect(!settings.prefixesEnabled)

    let secondTask = Task { @MainActor in try await coordinator.apply(secondImport) }
    for _ in 0..<100 { await Task.yield() }
    #expect(!settings.prefixesEnabled)
    #expect(await targetStore.mergeCount == 1)

    await targetStore.releaseFirstMerge()
    _ = try await firstTask.value
    _ = try await secondTask.value
    #expect(settings.prefixesEnabled)
    #expect(await targetStore.mergeCount == 2)
}

private struct RetainedJournalFailure: Error {}

private actor FailingConfigurationQuicklinkStore: QuicklinkBatchStoring {
    enum Failure: Error { case rejected }

    private var definitions: [String: QuicklinkDefinition] = [:]

    func allQuicklinks() -> [QuicklinkDefinition] { Array(definitions.values) }

    func quicklink(id: String) -> QuicklinkDefinition? { definitions[id] }

    func saveQuicklink(_ definition: QuicklinkDefinition) { definitions[definition.id] = definition }

    func deleteQuicklink(id: String) { definitions[id] = nil }
    func deleteQuicklink(ifUnchanged definition: QuicklinkDefinition) -> Bool {
        guard definitions[definition.id] == definition else { return false }
        definitions[definition.id] = nil
        return true
    }

    func mergeQuicklinksAtomically(_ definitions: [QuicklinkDefinition]) throws {
        throw Failure.rejected
    }

    func mergeQuicklinksAtomically(
        _ definitions: [QuicklinkDefinition],
        transactionID: String
    ) throws {
        throw Failure.rejected
    }

    func hasCommittedConfigurationTransaction(_ transactionID: String) -> Bool { false }
}

private actor SuspendedConfigurationQuicklinkStore: QuicklinkBatchStoring {
    private var definitions: [String: QuicklinkDefinition] = [:]
    private var committedTransactions = Set<String>()
    private var firstMergeContinuation: CheckedContinuation<Void, Never>?
    private(set) var mergeCount = 0

    var firstMergeIsWaiting: Bool { firstMergeContinuation != nil }

    func allQuicklinks() -> [QuicklinkDefinition] { Array(definitions.values) }
    func quicklink(id: String) -> QuicklinkDefinition? { definitions[id] }
    func saveQuicklink(_ definition: QuicklinkDefinition) { definitions[definition.id] = definition }
    func deleteQuicklink(id: String) { definitions[id] = nil }
    func deleteQuicklink(ifUnchanged definition: QuicklinkDefinition) -> Bool {
        guard definitions[definition.id] == definition else { return false }
        definitions[definition.id] = nil
        return true
    }

    func mergeQuicklinksAtomically(_ definitions: [QuicklinkDefinition]) async {
        await merge(definitions, transactionID: nil)
    }

    func mergeQuicklinksAtomically(
        _ definitions: [QuicklinkDefinition],
        transactionID: String
    ) async {
        await merge(definitions, transactionID: transactionID)
    }

    func hasCommittedConfigurationTransaction(_ transactionID: String) -> Bool {
        committedTransactions.contains(transactionID)
    }

    func releaseFirstMerge() {
        firstMergeContinuation?.resume()
        firstMergeContinuation = nil
    }

    private func merge(_ incoming: [QuicklinkDefinition], transactionID: String?) async {
        mergeCount += 1
        if mergeCount == 1 {
            await withCheckedContinuation { firstMergeContinuation = $0 }
        }
        for definition in incoming { definitions[definition.id] = definition }
        if let transactionID { committedTransactions.insert(transactionID) }
    }
}
