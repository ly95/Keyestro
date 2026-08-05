import CryptoKit
import Foundation
import Testing
@testable import KeyestroCore

@Test func configurationExportExcludesSecretsAndAbsoluteScriptPaths() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let paths = try AppPaths(
        bundleIdentifier: "com.keyestro.configuration-tests",
        applicationSupportRoot: root.appendingPathComponent("Support"),
        cachesRoot: root.appendingPathComponent("Caches")
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let link = try QuicklinkDefinition.inferred(title: "Search", urlTemplate: "https://example.com/?q={query}")
    let quicklinks = InMemoryQuicklinkStore(definitions: [link])
    let script = try ScriptDefinition(
        id: "private-script",
        title: "Private Script",
        executablePath: "/Users/alice/Secret Folder/run.sh",
        environment: [:],
        contentHash: String(repeating: "a", count: 64)
    )
    let scripts = InMemoryScriptStore(scripts: [script])
    let manifest = ExtensionManifest(
        id: "com.example.export",
        name: "Export Example",
        version: "1.0.0",
        description: "test",
        author: "test",
        license: "MIT",
        executable: "bin/extension",
        minimumHostVersion: "0.1.0"
    )
    let extensionRegistration = ExtensionRegistration(
        manifest: manifest,
        installPath: "/Users/alice/Downloads/Export.extension",
        manifestJSON: Data(),
        contentHash: String(repeating: "b", count: 64),
        enabled: true
    )
    let extensions = InMemoryExtensionStore(registrations: [extensionRegistration])
    let service = ConfigurationService(
        quicklinks: quicklinks,
        scripts: scripts,
        extensions: extensions,
        paths: paths,
        appVersion: "1.0.0"
    )

    let data = try await service.export(settings: ["general.enabled": .bool(true)])
    let text = String(decoding: data, as: UTF8.self)
    #expect(!text.contains("API_TOKEN"))
    #expect(!text.contains("/Users/alice"))
    #expect(text.contains("run.sh"))
    #expect(!text.contains("Downloads/Export.extension"))

    let validated = try await service.inspectImport(data)
    #expect(validated.preview.replacedQuicklinks == 1)
    #expect(validated.preview.scriptsRequiringReconnection == 1)
    #expect(validated.preview.extensionsRequiringReinstallation == 1)
}

@Test func configurationImportReportsUnknownSettingsAsIgnoredAndRejectsDuplicateCodeRegistrations() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let paths = try AppPaths(
        bundleIdentifier: "com.keyestro.configuration-validation-tests",
        applicationSupportRoot: root.appendingPathComponent("Support"),
        cachesRoot: root.appendingPathComponent("Caches")
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let source = ConfigurationService(
        quicklinks: InMemoryQuicklinkStore(),
        scripts: InMemoryScriptStore(),
        extensions: InMemoryExtensionStore(),
        paths: paths,
        appVersion: "1.0.0"
    )
    let data = try await source.export(
        settings: [
            "general.showDockIcon": .bool(true),
            "future.unsupported": .string("bounded"),
        ]
    )
    let validated = try await source.inspectImport(data)
    #expect(validated.preview.settingsCount == 1)
    #expect(validated.preview.ignoredSettingsCount == 1)

    let script = try ScriptDefinition(
        id: "duplicate",
        title: "Duplicate",
        executablePath: "/private/duplicate",
        contentHash: String(repeating: "a", count: 64)
    )
    let registration = ExportedScriptRegistration(script)
    let payload = ConfigurationPayload(
        settings: [:],
        quicklinks: [],
        scripts: [registration, registration],
        extensions: []
    )
    let duplicated = try configurationDocumentData(payload: payload, appVersion: "1.0.0")
    await #expect(throws: ConfigurationError.invalidPayload) {
        try await source.inspectImport(duplicated)
    }
}

@Test func configurationImportChecksIntegrityAndCreatesBackupBeforeMerge() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let paths = try AppPaths(
        bundleIdentifier: "com.keyestro.configuration-merge-tests",
        applicationSupportRoot: root.appendingPathComponent("Support"),
        cachesRoot: root.appendingPathComponent("Caches")
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceLink = try QuicklinkDefinition.inferred(id: "source", title: "Source", urlTemplate: "https://example.com")
    let sourceStore = InMemoryQuicklinkStore(definitions: [sourceLink])
    let source = ConfigurationService(
        quicklinks: sourceStore,
        scripts: InMemoryScriptStore(),
        extensions: InMemoryExtensionStore(),
        paths: paths,
        appVersion: "1.0.0"
    )
    let data = try await source.export(settings: ["search.prefixesEnabled": .bool(true)])

    var tampered = data
    if let index = tampered.firstIndex(of: 0x53) { tampered[index] = 0x58 }
    await #expect(throws: (any Error).self) { try await source.inspectImport(tampered) }

    let targetStore = InMemoryQuicklinkStore()
    let target = ConfigurationService(
        quicklinks: targetStore,
        scripts: InMemoryScriptStore(),
        extensions: InMemoryExtensionStore(),
        paths: paths,
        appVersion: "1.0.0"
    )
    let validated = try await target.inspectImport(data)
    #expect(validated.preview.addedQuicklinks == 1)
    try await target.apply(validated, currentSettings: [:])
    #expect(await targetStore.quicklink(id: "source") != nil)
    let backups = try FileManager.default.contentsOfDirectory(at: paths.backups, includingPropertiesForKeys: nil)
    #expect(backups.contains(where: { $0.lastPathComponent.hasPrefix("Configuration-") }))
}

private func configurationDocumentData(payload: ConfigurationPayload, appVersion: String) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .millisecondsSince1970
    let payloadData = try encoder.encode(payload)
    let checksum = SHA256.hash(data: payloadData).map { String(format: "%02x", $0) }.joined()
    return try encoder.encode(
        ConfigurationDocument(
            schemaVersion: 1,
            appVersion: appVersion,
            createdAt: Date(),
            payloadSHA256: checksum,
            payload: payload
        )
    )
}
