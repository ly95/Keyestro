import Foundation
import KeyestroCore
import Testing
@testable import KeyestroApp

@Test @MainActor func pendingConfigurationImportsRemainInertUntilIndividuallyCleared() throws {
    let suiteName = "com.keyestro.pending-import-tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = PendingConfigurationImportStore(defaults: defaults)
    let scriptDefinition = try ScriptDefinition(
        id: "script",
        title: "Script",
        executablePath: "/private/source/script",
        contentHash: String(repeating: "a", count: 64)
    )
    let script = ExportedScriptRegistration(scriptDefinition)
    let manifest = ExtensionManifest(
        id: "com.example.pending",
        name: "Pending",
        version: "1.0.0",
        description: "Pending import",
        author: "Tests",
        license: "MIT",
        executable: "bin/extension",
        minimumHostVersion: "0.1.0"
    )
    let extensionRegistration = ExportedExtensionRegistration(
        ExtensionRegistration(
            manifest: manifest,
            installPath: "/private/source/Pending.extension",
            manifestJSON: Data(),
            contentHash: String(repeating: "b", count: 64),
            enabled: true
        )
    )

    try store.merge(scripts: [script], extensions: [extensionRegistration])
    #expect(try store.scripts() == [script])
    #expect(try store.extensions() == [extensionRegistration])

    try store.removeScript(script)
    #expect(try store.scripts().isEmpty)
    #expect(try store.extensions() == [extensionRegistration])

    try store.removeExtension(extensionRegistration)
    #expect(try store.extensions().isEmpty)
}

@Test @MainActor func pendingConfigurationImportMergePreservesUnresolvedRegistrations() throws {
    let suiteName = "com.keyestro.pending-import-merge-tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = PendingConfigurationImportStore(defaults: defaults)
    let first = ExportedScriptRegistration(
        try ScriptDefinition(
            id: "first",
            title: "First",
            executablePath: "/private/first",
            contentHash: String(repeating: "a", count: 64)
        )
    )
    let second = ExportedScriptRegistration(
        try ScriptDefinition(
            id: "second",
            title: "Second",
            executablePath: "/private/second",
            contentHash: String(repeating: "b", count: 64)
        )
    )
    try store.merge(scripts: [first], extensions: [])
    try store.merge(scripts: [second], extensions: [])
    #expect(try store.scripts().map(\.id) == ["first", "second"])
}

@Test @MainActor func pendingConfigurationImportStoreRejectsCorruptState() throws {
    let suiteName = "com.keyestro.pending-import-corrupt-tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(Data("not-json".utf8), forKey: PendingConfigurationImportStore.scriptsKey)
    let store = PendingConfigurationImportStore(defaults: defaults)
    #expect(throws: (any Error).self) { try store.scripts() }
}
