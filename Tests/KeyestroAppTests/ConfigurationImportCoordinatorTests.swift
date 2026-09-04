import Foundation
import KeyestroCore
import Testing
@testable import KeyestroApp

@Test @MainActor func failedDatabaseCommitLeavesSettingsAndPendingImportsUntouched() async throws {
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
    settings.clipboardEnabled = true
    settings.clipboardPaused = true
    settings.quickPasteEnabled = true
    settings.quickPasteAllowsSensitiveContent = false
    settings.fileSearchEnabled = true
    settings.fileContentSearchEnabled = true
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
    #expect(settings.clipboardEnabled)
    #expect(settings.clipboardPaused)
    #expect(settings.quickPasteEnabled)
    #expect(!settings.quickPasteAllowsSensitiveContent)
    #expect(settings.fileSearchEnabled)
    #expect(settings.fileContentSearchEnabled)
    #expect(try pendingStore.scripts().map(\.id) == [existingScript.id])
    #expect(await targetQuicklinks.allQuicklinks().isEmpty)
    let backups = try FileManager.default.contentsOfDirectory(at: paths.backups, includingPropertiesForKeys: nil)
    let backupURL = try #require(backups.first { $0.lastPathComponent.hasPrefix("Configuration-") })
    let backupData = try Data(contentsOf: backupURL)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    let backup = try decoder.decode(ConfigurationDocument.self, from: backupData)
    #expect(
        backup.payload.settings.keys.allSatisfy {
            !ConfigurationService.locallyAuthorizedSettingKeys.contains($0)
        }
    )

    try settings.applyImportedConfiguration(["search.prefixesEnabled": .bool(false)])
    try pendingStore.restore(
        PendingConfigurationImportSnapshot(
            scripts: [ExportedScriptRegistration(importedScript)],
            extensions: []
        )
    )
    let recovery = ConfigurationImportCoordinator(service: target, settings: settings, defaults: defaults)
    #expect(try await recovery.recoverIfNeeded())
    #expect(!settings.prefixesEnabled)
    #expect(settings.clipboardEnabled)
    #expect(settings.clipboardPaused)
    #expect(settings.quickPasteEnabled)
    #expect(!settings.quickPasteAllowsSensitiveContent)
    #expect(settings.fileSearchEnabled)
    #expect(settings.fileContentSearchEnabled)
    #expect(try pendingStore.scripts().map(\.id) == [importedScript.id])
}

@Test @MainActor func completedJournalNeverReplaysImportedUserDefaults() async throws {
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
    #expect(settings.prefixesEnabled)
    #expect(try pendingStore.scripts().isEmpty)
    #expect(await targetStore.quicklink(id: importedLink.id) != nil)
}

@Test @MainActor func preparedCommittedJournalCompletesPortableStateExactlyOnce() async throws {
    let fixture = try ConfigurationJournalFixture(name: "prepared-commit")
    defer { fixture.cleanUp() }
    let importedScript = try ScriptDefinition(
        id: "prepared-script",
        title: "Prepared Script",
        executablePath: "/private/prepared-script",
        contentHash: String(repeating: "d", count: 64)
    )
    let transactionID = UUID().uuidString.lowercased()
    await fixture.quicklinks.mergeQuicklinksAtomically([], transactionID: transactionID)
    try fixture.writeJournal(
        schemaVersion: 2,
        state: "prepared",
        transactionID: transactionID,
        originalSettings: ["search.prefixesEnabled": .bool(true)],
        importedSettings: ["search.prefixesEnabled": .bool(false)],
        importedScripts: [ExportedScriptRegistration(importedScript)]
    )

    let coordinator = ConfigurationImportCoordinator(
        service: fixture.service,
        settings: fixture.settings,
        defaults: fixture.defaults,
        removeJournal: { _ in throw RetainedJournalFailure() }
    )
    #expect(try await coordinator.recoverIfNeeded())
    #expect(!fixture.settings.prefixesEnabled)
    #expect(try fixture.pending.scripts().map(\.id) == [importedScript.id])

    fixture.settings.prefixesEnabled = true
    try fixture.pending.restore(PendingConfigurationImportSnapshot(scripts: [], extensions: []))
    let secondRecovery = ConfigurationImportCoordinator(
        service: fixture.service,
        settings: fixture.settings,
        defaults: fixture.defaults
    )
    #expect(try await secondRecovery.recoverIfNeeded())
    #expect(fixture.settings.prefixesEnabled)
    #expect(try fixture.pending.scripts().isEmpty)
}

@Test @MainActor func legacyCommittedJournalRevokesImportedCapabilitiesBeforeApplyingPortableState() async throws {
    let fixture = try ConfigurationJournalFixture(name: "legacy-commit")
    defer { fixture.cleanUp() }
    let transactionID = UUID().uuidString.lowercased()
    await fixture.quicklinks.mergeQuicklinksAtomically([], transactionID: transactionID)

    // Simulate capability values written by the schema-v1 implementation before it
    // crashed. fileSearchEnabled is intentionally absent from the older snapshot.
    fixture.settings.clipboardEnabled = true
    fixture.settings.quickPasteEnabled = true
    fixture.settings.fileSearchEnabled = true
    try fixture.writeJournal(
        schemaVersion: 1,
        state: nil,
        transactionID: transactionID,
        originalSettings: [
            "search.prefixesEnabled": .bool(true),
            "clipboard.enabled": .bool(false),
            "clipboard.quickPaste.enabled": .bool(false),
        ],
        importedSettings: [
            "search.prefixesEnabled": .bool(false),
            "clipboard.enabled": .bool(true),
            "clipboard.quickPaste.enabled": .bool(true),
            "files.searchEnabled": .bool(false),
        ]
    )

    let coordinator = ConfigurationImportCoordinator(
        service: fixture.service,
        settings: fixture.settings,
        defaults: fixture.defaults
    )
    #expect(try await coordinator.recoverIfNeeded())
    #expect(!fixture.settings.clipboardEnabled)
    #expect(!fixture.settings.quickPasteEnabled)
    #expect(fixture.settings.fileSearchEnabled)
    #expect(!fixture.settings.prefixesEnabled)
}

@Test @MainActor func legacyUncommittedJournalRestoresCapabilitiesAndPortableState() async throws {
    let fixture = try ConfigurationJournalFixture(name: "legacy-rollback")
    defer { fixture.cleanUp() }
    fixture.settings.clipboardEnabled = true
    fixture.settings.quickPasteAllowsSensitiveContent = true
    fixture.settings.prefixesEnabled = false
    try fixture.writeJournal(
        schemaVersion: 1,
        state: nil,
        transactionID: UUID().uuidString.lowercased(),
        originalSettings: [
            "search.prefixesEnabled": .bool(true),
            "clipboard.enabled": .bool(false),
            "clipboard.quickPaste.allowsSensitiveContent": .bool(false),
        ],
        importedSettings: [
            "search.prefixesEnabled": .bool(false),
            "clipboard.enabled": .bool(true),
            "clipboard.quickPaste.allowsSensitiveContent": .bool(true),
        ]
    )

    let coordinator = ConfigurationImportCoordinator(
        service: fixture.service,
        settings: fixture.settings,
        defaults: fixture.defaults
    )
    #expect(try await coordinator.recoverIfNeeded())
    #expect(!fixture.settings.clipboardEnabled)
    #expect(!fixture.settings.quickPasteAllowsSensitiveContent)
    #expect(fixture.settings.prefixesEnabled)
}

@Test @MainActor func malformedJournalIsQuarantinedAndDoesNotBlockFutureRecovery() async throws {
    let fixture = try ConfigurationJournalFixture(name: "invalid")
    defer { fixture.cleanUp() }
    let journalURL = try await fixture.service.importJournalURL()
    try Data("not a transaction journal".utf8).write(to: journalURL, options: .atomic)
    let coordinator = ConfigurationImportCoordinator(
        service: fixture.service,
        settings: fixture.settings,
        defaults: fixture.defaults
    )

    await #expect(throws: ConfigurationImportTransactionError.invalidJournal) {
        try await coordinator.recoverIfNeeded()
    }
    #expect(!FileManager.default.fileExists(atPath: journalURL.path))
    let backups = try FileManager.default.contentsOfDirectory(
        at: journalURL.deletingLastPathComponent(),
        includingPropertiesForKeys: nil
    )
    #expect(backups.contains { $0.lastPathComponent.hasPrefix("ConfigurationImportTransaction.invalid-") })
    #expect(try await coordinator.recoverIfNeeded() == false)
}

@Test @MainActor func symlinkedJournalIsRemovedWithoutTouchingItsTarget() async throws {
    let fixture = try ConfigurationJournalFixture(name: "symlink")
    defer { fixture.cleanUp() }
    let journalURL = try await fixture.service.importJournalURL()
    let externalURL = fixture.root.appendingPathComponent("external-journal-target.json")
    let externalData = Data("preserve me".utf8)
    try externalData.write(to: externalURL, options: .atomic)
    try FileManager.default.createSymbolicLink(at: journalURL, withDestinationURL: externalURL)
    let coordinator = ConfigurationImportCoordinator(
        service: fixture.service,
        settings: fixture.settings,
        defaults: fixture.defaults
    )

    await #expect(throws: ConfigurationImportTransactionError.invalidJournal) {
        try await coordinator.recoverIfNeeded()
    }
    #expect(!FileManager.default.fileExists(atPath: journalURL.path))
    #expect(try Data(contentsOf: externalURL) == externalData)
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
    let firstCoordinator = ConfigurationImportCoordinator(service: target, settings: settings, defaults: defaults)
    let secondCoordinator = ConfigurationImportCoordinator(service: target, settings: settings, defaults: defaults)

    let firstTask = Task { @MainActor in try await firstCoordinator.apply(firstImport) }
    for _ in 0..<1_000 {
        if await targetStore.firstMergeIsWaiting { break }
        await Task.yield()
    }
    #expect(await targetStore.firstMergeIsWaiting)
    #expect(settings.prefixesEnabled)

    let secondTask = Task { @MainActor in try await secondCoordinator.apply(secondImport) }
    for _ in 0..<100 { await Task.yield() }
    #expect(settings.prefixesEnabled)
    #expect(await targetStore.mergeCount == 1)

    await targetStore.releaseFirstMerge()
    _ = try await firstTask.value
    _ = try await secondTask.value
    #expect(settings.prefixesEnabled)
    #expect(await targetStore.mergeCount == 2)
}

@Test @MainActor func settingsApplyOnlyAfterCommitAndFailedMergePreservesLiveLocalChoices() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyestro-import-side-effect-order-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        bundleIdentifier: "com.keyestro.import-side-effect-order-tests",
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
    let data = try await source.export(settings: [
        "clipboard.retentionPreset": .string("1-day"),
        "clipboard.excludedApplications": .string("com.example.private"),
    ])
    let targetStore = SuspendedConfigurationQuicklinkStore(failFirstMerge: true)
    let target = ConfigurationService(
        quicklinks: targetStore,
        scripts: InMemoryScriptStore(),
        extensions: InMemoryExtensionStore(),
        paths: paths,
        appVersion: "1.0.0"
    )
    let validated = try await target.inspectImport(data)
    let suiteName = "com.keyestro.import-side-effect-order-tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let settings = SettingsStore(defaults: defaults)
    let coordinator = ConfigurationImportCoordinator(service: target, settings: settings, defaults: defaults)

    let importTask = Task { @MainActor in try await coordinator.apply(validated) }
    for _ in 0..<1_000 {
        if await targetStore.firstMergeIsWaiting { break }
        await Task.yield()
    }
    #expect(await targetStore.firstMergeIsWaiting)
    #expect(settings.clipboardRetentionPreset == "30-days")
    #expect(settings.clipboardExcludedApplications.isEmpty)

    settings.clipboardPaused = true
    settings.fileSearchEnabled = true
    settings.clipboardRetentionPreset = "90-days"
    await targetStore.releaseFirstMerge()

    await #expect(throws: ConfigurationImportTransactionError.self) {
        try await importTask.value
    }
    #expect(settings.clipboardPaused)
    #expect(settings.fileSearchEnabled)
    #expect(settings.clipboardRetentionPreset == "90-days")
    #expect(settings.clipboardExcludedApplications.isEmpty)
}

private struct RetainedJournalFailure: Error {}

@MainActor
private struct ConfigurationJournalFixture {
    let root: URL
    let paths: AppPaths
    let suiteName: String
    let defaults: UserDefaults
    let quicklinks: InMemoryQuicklinkStore
    let service: ConfigurationService
    let settings: SettingsStore
    let pending: PendingConfigurationImportStore

    init(name: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyestro-import-journal-\(name)-\(UUID().uuidString)", isDirectory: true)
        paths = try AppPaths(
            bundleIdentifier: "com.keyestro.import-journal-\(name)-tests",
            applicationSupportRoot: root.appendingPathComponent("Support", isDirectory: true),
            cachesRoot: root.appendingPathComponent("Caches", isDirectory: true)
        )
        suiteName = "com.keyestro.import-journal-\(name)-tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw ConfigurationJournalFixtureError.defaultsUnavailable
        }
        self.defaults = defaults
        defaults.removePersistentDomain(forName: suiteName)
        quicklinks = InMemoryQuicklinkStore()
        service = ConfigurationService(
            quicklinks: quicklinks,
            scripts: InMemoryScriptStore(),
            extensions: InMemoryExtensionStore(),
            paths: paths,
            appVersion: "1.0.0"
        )
        settings = SettingsStore(defaults: defaults)
        pending = PendingConfigurationImportStore(defaults: defaults)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    func writeJournal(
        schemaVersion: Int,
        state: String?,
        transactionID: String,
        originalSettings: [String: JSONValue],
        importedSettings: [String: JSONValue],
        importedScripts: [ExportedScriptRegistration] = []
    ) throws {
        try paths.prepare()
        let journalURL = paths.backups.appendingPathComponent(
            "ConfigurationImportTransaction.json",
            isDirectory: false
        )
        let journal = TestConfigurationImportJournal(
            schemaVersion: schemaVersion,
            state: state,
            transactionID: transactionID,
            backupURL: paths.backups.appendingPathComponent("Configuration-test-backup.json"),
            originalSettings: originalSettings,
            originalPending: PendingConfigurationImportSnapshot(scripts: [], extensions: []),
            importedSettings: importedSettings,
            importedScripts: importedScripts,
            importedExtensions: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(journal).write(to: journalURL, options: .atomic)
    }
}

private struct TestConfigurationImportJournal: Encodable {
    let schemaVersion: Int
    let state: String?
    let transactionID: String
    let backupURL: URL
    let originalSettings: [String: JSONValue]
    let originalPending: PendingConfigurationImportSnapshot
    let importedSettings: [String: JSONValue]
    let importedScripts: [ExportedScriptRegistration]
    let importedExtensions: [ExportedExtensionRegistration]
}

private enum ConfigurationJournalFixtureError: Error {
    case defaultsUnavailable
}

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

    func mergeQuicklinksAtomically(
        _ definitions: [QuicklinkDefinition],
        transactionID: String,
        expecting expectations: [QuicklinkMergeExpectation]
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
    private let failFirstMerge: Bool

    init(failFirstMerge: Bool = false) {
        self.failFirstMerge = failFirstMerge
    }

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

    func mergeQuicklinksAtomically(_ definitions: [QuicklinkDefinition]) async throws {
        try await merge(definitions, transactionID: nil)
    }

    func mergeQuicklinksAtomically(
        _ definitions: [QuicklinkDefinition],
        transactionID: String
    ) async throws {
        try await merge(definitions, transactionID: transactionID)
    }

    func mergeQuicklinksAtomically(
        _ definitions: [QuicklinkDefinition],
        transactionID: String,
        expecting expectations: [QuicklinkMergeExpectation]
    ) async throws {
        guard expectations.allSatisfy({ self.definitions[$0.id] == $0.existingDefinition }) else {
            throw ConfigurationError.conflictingChanges
        }
        try await merge(definitions, transactionID: transactionID)
    }

    func hasCommittedConfigurationTransaction(_ transactionID: String) -> Bool {
        committedTransactions.contains(transactionID)
    }

    func releaseFirstMerge() {
        firstMergeContinuation?.resume()
        firstMergeContinuation = nil
    }

    private func merge(_ incoming: [QuicklinkDefinition], transactionID: String?) async throws {
        mergeCount += 1
        if mergeCount == 1 {
            await withCheckedContinuation { firstMergeContinuation = $0 }
            if failFirstMerge { throw SuspendedMergeFailure() }
        }
        for definition in incoming { definitions[definition.id] = definition }
        if let transactionID { committedTransactions.insert(transactionID) }
    }
}

private struct SuspendedMergeFailure: Error {}
