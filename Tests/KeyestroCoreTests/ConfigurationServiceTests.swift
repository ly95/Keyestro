import CryptoKit
import Foundation
import KeyestroDomain
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

@Test func configurationExportStripsLocalCapabilityGrantsAndLegacyImportsIgnoreThem() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        bundleIdentifier: "com.keyestro.configuration-quick-paste-tests",
        applicationSupportRoot: root.appendingPathComponent("Support"),
        cachesRoot: root.appendingPathComponent("Caches")
    )
    let service = ConfigurationService(
        quicklinks: InMemoryQuicklinkStore(),
        scripts: InMemoryScriptStore(),
        extensions: InMemoryExtensionStore(),
        paths: paths,
        appVersion: "1.0.0"
    )
    let settings: [String: JSONValue] = [
        "shortcuts.clipboardHistory.keyCode": .integer(9),
        "shortcuts.clipboardHistory.modifiers": .integer(2_048),
        "shortcuts.quickPaste.combined": .string("35:2304"),
        "clipboard.quickPaste.enabled": .bool(true),
        "clipboard.quickPaste.allowsSensitiveContent": .bool(false),
    ]

    let data = try await service.export(settings: settings)
    let validated = try await service.inspectImport(data)
    let portableSettings: [String: JSONValue] = [
        "shortcuts.clipboardHistory.keyCode": .integer(9),
        "shortcuts.clipboardHistory.modifiers": .integer(2_048),
        "shortcuts.quickPaste.combined": .string("35:2304"),
    ]
    #expect(validated.document.payload.settings == portableSettings)
    #expect(validated.preview.settingsCount == portableSettings.count)
    #expect(validated.preview.ignoredSettingsCount == 0)

    // Schema-v1 backups written by older Keyestro versions remain readable. The
    // capability keys stay in the validated document for checksum compatibility,
    // but the preview classifies them as ignored rather than importable settings.
    let legacyPayload = ConfigurationPayload(
        settings: settings,
        quicklinks: [],
        scripts: [],
        extensions: []
    )
    let legacy = try await service.inspectImport(
        try configurationDocumentData(payload: legacyPayload, appVersion: "0.1.0")
    )
    #expect(legacy.document.payload.settings == settings)
    #expect(legacy.preview.settingsCount == portableSettings.count)
    #expect(legacy.preview.ignoredSettingsCount == 2)

    let invalidSettings: [[String: JSONValue]] = [
        ["shortcuts.clipboardHistory.keyCode": .integer(-1)],
        ["shortcuts.clipboardHistory.modifiers": .string("option")],
        ["shortcuts.quickPaste.combined": .bool(true)],
        ["shortcuts.quickPaste.combined": .string("35")],
        ["shortcuts.quickPaste.combined": .string("35:not-a-modifier")],
        ["clipboard.quickPaste.enabled": .string("true")],
        ["clipboard.quickPaste.allowsSensitiveContent": .integer(1)],
    ]
    for invalid in invalidSettings {
        await #expect(throws: ConfigurationError.invalidPayload) {
            try await service.export(settings: invalid)
        }
    }
}

@Test func everyLocallyAuthorizedSettingHasAReasonAndIsRemovedAtTheExportBoundary() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = ConfigurationService(
        quicklinks: InMemoryQuicklinkStore(),
        scripts: InMemoryScriptStore(),
        extensions: InMemoryExtensionStore(),
        paths: try AppPaths(
            bundleIdentifier: "com.keyestro.configuration-consent-coverage-tests",
            applicationSupportRoot: root.appendingPathComponent("Support"),
            cachesRoot: root.appendingPathComponent("Caches")
        ),
        appVersion: "1.0.0"
    )
    #expect(!ConfigurationService.locallyAuthorizedSettingReasons.isEmpty)
    #expect(ConfigurationService.locallyAuthorizedSettingReasons.values.allSatisfy { !$0.isEmpty })
    #expect(
        ConfigurationService.supportedSettingKeys
            .isDisjoint(with: ConfigurationService.locallyAuthorizedSettingKeys)
    )

    let capabilityValues = Dictionary(
        uniqueKeysWithValues: ConfigurationService.locallyAuthorizedSettingKeys.map { ($0, JSONValue.bool(true)) }
    )
    let data = try await service.export(settings: capabilityValues)
    let validated = try await service.inspectImport(data)
    #expect(validated.document.payload.settings.isEmpty)
    #expect(validated.preview.settingsCount == 0)
    #expect(validated.preview.ignoredSettingsCount == 0)

    let legacyPayload = ConfigurationPayload(
        settings: capabilityValues,
        quicklinks: [],
        scripts: [],
        extensions: []
    )
    let legacy = try await service.inspectImport(
        try configurationDocumentData(payload: legacyPayload, appVersion: "0.1.0")
    )
    #expect(legacy.document.payload.settings == capabilityValues)
    #expect(legacy.preview.settingsCount == 0)
    #expect(legacy.preview.ignoredSettingsCount == capabilityValues.count)
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

@Test func configurationImportRejectsQuicklinkChangedAfterPreview() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        bundleIdentifier: "com.keyestro.configuration-conflict-tests",
        applicationSupportRoot: root.appendingPathComponent("Support"),
        cachesRoot: root.appendingPathComponent("Caches")
    )
    let imported = try QuicklinkDefinition.inferred(
        id: "shared",
        title: "Imported",
        urlTemplate: "https://imported.example"
    )
    let source = ConfigurationService(
        quicklinks: InMemoryQuicklinkStore(definitions: [imported]),
        scripts: InMemoryScriptStore(),
        extensions: InMemoryExtensionStore(),
        paths: paths,
        appVersion: "1.0.0"
    )
    let data = try await source.export(settings: [:])
    let original = try QuicklinkDefinition.inferred(
        id: "shared",
        title: "Original",
        urlTemplate: "https://original.example"
    )
    let targetStore = InMemoryQuicklinkStore(definitions: [original])
    let target = ConfigurationService(
        quicklinks: targetStore,
        scripts: InMemoryScriptStore(),
        extensions: InMemoryExtensionStore(),
        paths: paths,
        appVersion: "1.0.0"
    )
    let validated = try await target.inspectImport(data)
    #expect(validated.preview.replacedQuicklinks == 1)

    let userEdit = try QuicklinkDefinition.inferred(
        id: "shared",
        title: "Edited After Preview",
        urlTemplate: "https://edited.example"
    )
    await targetStore.saveQuicklink(userEdit)
    await #expect(throws: ConfigurationError.conflictingChanges) {
        try await target.merge(validated, transactionID: UUID().uuidString.lowercased())
    }
    #expect(await targetStore.quicklink(id: "shared") == userEdit)
}

@Test func configurationImportRejectsMalformedDocumentsAndDuplicateQuicklinks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        bundleIdentifier: "com.keyestro.configuration-coverage-tests",
        applicationSupportRoot: root.appendingPathComponent("Support"),
        cachesRoot: root.appendingPathComponent("Caches")
    )
    let service = ConfigurationService(
        quicklinks: InMemoryQuicklinkStore(),
        scripts: InMemoryScriptStore(),
        extensions: InMemoryExtensionStore(),
        paths: paths,
        appVersion: "1.0.0"
    )

    await #expect(throws: ConfigurationError.invalidPayload) {
        try await service.inspectImport(Data("not json".utf8))
    }
    await #expect(throws: ConfigurationError.invalidPayload) {
        try await service.export(settings: ["shortcuts.launcher.keyCode": .integer(-1)])
    }
    await #expect(throws: ConfigurationError.invalidPayload) {
        try await service.export(
            settings: ["clipboard.excludedApplications": .string(String(repeating: "x", count: 16_385))]
        )
    }

    let definition = try QuicklinkDefinition.inferred(
        id: "duplicate",
        title: "Duplicate",
        urlTemplate: "https://example.com"
    )
    let duplicate = ExportedQuicklink(definition)
    let payload = ConfigurationPayload(
        settings: [:],
        quicklinks: [duplicate, duplicate],
        scripts: [],
        extensions: []
    )
    let data = try configurationDocumentData(payload: payload, appVersion: "1.0.0")
    await #expect(throws: ConfigurationError.invalidPayload) {
        try await service.inspectImport(data)
    }

    let validScript = try ScriptDefinition(
        id: "script",
        title: "Script",
        executablePath: "/private/script",
        arguments: [ArgumentDefinition(id: "query", title: "Query", kind: .text, required: true)],
        contentHash: String(repeating: "a", count: 64)
    )
    let exportedScript = ExportedScriptRegistration(validScript)
    let invalidScript: ExportedScriptRegistration = try mutatedCodable(exportedScript) { object in
        object["id"] = ""
    }
    #expect(throws: ConfigurationError.invalidPayload) { try invalidScript.validate() }

    let invalidScriptArguments: ExportedScriptRegistration = try mutatedCodable(exportedScript) { object in
        let argument = try #require((object["arguments"] as? [[String: Any]])?.first)
        object["arguments"] = [argument, argument]
    }
    #expect(throws: ConfigurationError.invalidPayload) { try invalidScriptArguments.validate() }

    let manifest = ExtensionManifest(
        id: "com.keyestro.coverage",
        name: "Coverage",
        version: "1.0.0",
        description: "Coverage fixture",
        author: "Keyestro",
        license: "Apache-2.0",
        executable: "bin/extension",
        minimumHostVersion: "0.1.0"
    )
    let exportedExtension = ExportedExtensionRegistration(
        ExtensionRegistration(
            manifest: manifest,
            installPath: "/private/Coverage.extension",
            manifestJSON: Data(),
            contentHash: String(repeating: "b", count: 64),
            enabled: true
        )
    )
    let invalidExtension: ExportedExtensionRegistration = try mutatedCodable(exportedExtension) { object in
        object["contentHash"] = "not-a-hash"
    }
    #expect(throws: ConfigurationError.invalidPayload) { try invalidExtension.validate() }

    let emptyPayload = ConfigurationPayload(settings: [:], quicklinks: [], scripts: [], extensions: [])
    await #expect(throws: ConfigurationError.unsupportedSchema) {
        try await service.inspectImport(
            try configurationDocumentData(payload: emptyPayload, appVersion: "1.0.0", schemaVersion: 2)
        )
    }
    await #expect(throws: ConfigurationError.invalidPayload) {
        try await service.inspectImport(try configurationDocumentData(payload: emptyPayload, appVersion: ""))
    }
    await #expect(throws: ConfigurationError.tooLarge) {
        try await service.inspectImport(Data(repeating: 0, count: ConfigurationService.maximumDocumentBytes + 1))
    }

    let oversizedPayload = ConfigurationPayload(
        settings: [:],
        quicklinks: Array(repeating: duplicate, count: 1_001),
        scripts: [],
        extensions: []
    )
    await #expect(throws: ConfigurationError.invalidPayload) {
        try await service.inspectImport(try configurationDocumentData(payload: oversizedPayload, appVersion: "1.0.0"))
    }

    let invalidSettings: [[String: JSONValue]] = [
        Dictionary(uniqueKeysWithValues: (0...100).map { ("future.\($0)", .bool(true)) }),
        ["": .bool(true)],
        ["general.showDockIcon": .string("yes")],
        ["appearance.launcher": .string("sepia")],
        ["clipboard.retentionPreset": .string("forever")],
        ["capture.ocrLanguagePreset": .string("invalid")],
        ["future.value": .string(String(repeating: "x", count: 1_025))],
    ]
    for settings in invalidSettings {
        await #expect(throws: ConfigurationError.invalidPayload) {
            try await service.export(settings: settings)
        }
    }

    let validData = try await service.export(settings: [:])
    let validated = try await service.inspectImport(validData)
    await #expect(throws: ConfigurationError.invalidPayload) {
        try await service.merge(validated, transactionID: "not-a-uuid")
    }
    #expect(try await service.hasCommittedTransaction("not-a-uuid") == false)
    #expect(try await service.importJournalURL().lastPathComponent == "ConfigurationImportTransaction.json")
}

@Test func configurationExportRejectsADocumentBeyondTheHardByteLimit() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repeatedPath = String(repeating: "x", count: 8_000)
    var definitions: [QuicklinkDefinition] = []
    definitions.reserveCapacity(1_500)
    for index in 0..<1_500 {
        definitions.append(
            try QuicklinkDefinition.inferred(
                id: "large-\(index)",
                title: "Large \(index)",
                urlTemplate: "https://example.com/\(repeatedPath)/\(index)"
            )
        )
    }
    let paths = try AppPaths(
        bundleIdentifier: "com.keyestro.configuration-size-tests",
        applicationSupportRoot: root.appendingPathComponent("Support"),
        cachesRoot: root.appendingPathComponent("Caches")
    )
    let service = ConfigurationService(
        quicklinks: InMemoryQuicklinkStore(definitions: definitions),
        scripts: InMemoryScriptStore(),
        extensions: InMemoryExtensionStore(),
        paths: paths,
        appVersion: "1.0.0"
    )
    await #expect(throws: ConfigurationError.tooLarge) {
        try await service.export(settings: [:])
    }
}

private func configurationDocumentData(
    payload: ConfigurationPayload,
    appVersion: String,
    schemaVersion: Int = 1
) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .millisecondsSince1970
    let payloadData = try encoder.encode(payload)
    let checksum = SHA256.hash(data: payloadData).map { String(format: "%02x", $0) }.joined()
    return try encoder.encode(
        ConfigurationDocument(
            schemaVersion: schemaVersion,
            appVersion: appVersion,
            createdAt: Date(),
            payloadSHA256: checksum,
            payload: payload
        )
    )
}

private func mutatedCodable<Value: Codable>(
    _ value: Value,
    mutation: (inout [String: Any]) throws -> Void
) throws -> Value {
    let data = try JSONEncoder().encode(value)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    try mutation(&object)
    return try JSONDecoder().decode(Value.self, from: JSONSerialization.data(withJSONObject: object))
}
