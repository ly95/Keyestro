import CryptoKit
import Foundation
import KeyestroDomain

public struct ExportedQuicklink: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let urlTemplate: String
    public let arguments: [ArgumentDefinition]
    public let keywords: [String]
    public let iconName: String?
    public let browserBundleIdentifier: String?
    public let createdAt: Date
    public let updatedAt: Date

    public init(_ definition: QuicklinkDefinition) {
        id = definition.id
        title = definition.title
        urlTemplate = definition.urlTemplate
        arguments = definition.arguments
        keywords = definition.keywords
        iconName = definition.iconName
        browserBundleIdentifier = definition.browserBundleIdentifier
        createdAt = definition.createdAt
        updatedAt = definition.updatedAt
    }

    public func validatedDefinition() throws -> QuicklinkDefinition {
        try QuicklinkDefinition(
            id: id,
            title: title,
            urlTemplate: urlTemplate,
            arguments: arguments,
            keywords: keywords,
            iconName: iconName ?? "link",
            browserBundleIdentifier: browserBundleIdentifier,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

public struct ExportedScriptRegistration: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let executableName: String
    public let arguments: [ArgumentDefinition]
    public let timeoutSeconds: Int
    public let contentHash: String
    public let requiresReconnection: Bool

    public init(_ definition: ScriptDefinition) {
        id = definition.id
        title = definition.title
        executableName = URL(fileURLWithPath: definition.executablePath).lastPathComponent
        arguments = definition.arguments
        timeoutSeconds = definition.timeoutSeconds
        contentHash = definition.contentHash
        requiresReconnection = true
    }

    public func validate() throws {
        guard !id.isEmpty, id.count <= 128,
            !title.isEmpty, title.unicodeScalars.count <= DomainLimits.titleUnicodeScalars,
            !executableName.isEmpty, !executableName.contains("/"), executableName.utf8.count <= 255,
            arguments.count <= 50,
            (1...300).contains(timeoutSeconds),
            contentHash.count == 64,
            contentHash.allSatisfy({ $0.isHexDigit }),
            requiresReconnection
        else { throw ConfigurationError.invalidPayload }
        do {
            _ = try ScriptDefinition(
                id: id,
                title: title,
                executablePath: "/reconnect/\(executableName)",
                arguments: arguments,
                timeoutSeconds: timeoutSeconds,
                contentHash: contentHash,
                enabled: false
            )
        } catch {
            throw ConfigurationError.invalidPayload
        }
    }
}

public struct ExportedExtensionRegistration: Codable, Equatable, Sendable {
    public let manifest: ExtensionManifest
    public let contentHash: String
    public let requiresReinstallation: Bool

    public init(_ registration: ExtensionRegistration) {
        manifest = registration.manifest
        contentHash = registration.contentHash
        requiresReinstallation = true
    }

    public func validate() throws {
        try manifest.validateMetadata()
        guard contentHash.count == 64,
            contentHash.unicodeScalars.allSatisfy({
                (48...57).contains($0.value) || (97...102).contains($0.value)
            }),
            requiresReinstallation
        else { throw ConfigurationError.invalidPayload }
    }
}

public struct ConfigurationPayload: Codable, Equatable, Sendable {
    public let settings: [String: JSONValue]
    public let quicklinks: [ExportedQuicklink]
    public let scripts: [ExportedScriptRegistration]
    public let extensions: [ExportedExtensionRegistration]

    public init(
        settings: [String: JSONValue],
        quicklinks: [ExportedQuicklink],
        scripts: [ExportedScriptRegistration],
        extensions: [ExportedExtensionRegistration]
    ) {
        self.settings = settings
        self.quicklinks = quicklinks
        self.scripts = scripts
        self.extensions = extensions
    }
}

public struct ConfigurationDocument: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let appVersion: String
    public let createdAt: Date
    public let payloadSHA256: String
    public let payload: ConfigurationPayload
}

public struct ConfigurationImportPreview: Equatable, Sendable {
    public let addedQuicklinks: Int
    public let replacedQuicklinks: Int
    public let settingsCount: Int
    public let ignoredSettingsCount: Int
    public let scriptsRequiringReconnection: Int
    public let extensionsRequiringReinstallation: Int

    public init(
        addedQuicklinks: Int,
        replacedQuicklinks: Int,
        settingsCount: Int,
        ignoredSettingsCount: Int = 0,
        scriptsRequiringReconnection: Int,
        extensionsRequiringReinstallation: Int
    ) {
        self.addedQuicklinks = addedQuicklinks
        self.replacedQuicklinks = replacedQuicklinks
        self.settingsCount = settingsCount
        self.ignoredSettingsCount = ignoredSettingsCount
        self.scriptsRequiringReconnection = scriptsRequiringReconnection
        self.extensionsRequiringReinstallation = extensionsRequiringReinstallation
    }
}

public struct ValidatedConfigurationImport: Sendable {
    public let document: ConfigurationDocument
    public let quicklinks: [QuicklinkDefinition]
    public let preview: ConfigurationImportPreview
}

public enum ConfigurationError: Error, Equatable, Sendable {
    case tooLarge
    case unsupportedSchema
    case invalidChecksum
    case invalidPayload
}

public actor ConfigurationService {
    public static let maximumDocumentBytes = 10 * 1_024 * 1_024
    public static let supportedSettingKeys: Set<String> = [
        "general.showDockIcon",
        "search.prefixesEnabled",
        "ranking.learningEnabled",
        "shortcuts.numberShortcutsEnabled",
        "shortcuts.launcher.keyCode",
        "shortcuts.launcher.modifiers",
        "clipboard.enabled",
        "clipboard.paused",
        "clipboard.retentionPreset",
        "clipboard.excludedApplications",
        "capture.ocrLanguagePreset",
        "files.contentSearchEnabled",
        "files.hiddenFilesEnabled",
        "files.systemLocationsEnabled",
        "files.trashEnabled",
        "system.confirmSleepEveryTime",
    ]
    private let quicklinks: any QuicklinkBatchStoring
    private let scripts: any ScriptStoring
    private let extensions: any ExtensionStoring
    private let paths: AppPaths
    private let appVersion: String

    public init(
        quicklinks: any QuicklinkBatchStoring,
        scripts: any ScriptStoring,
        extensions: any ExtensionStoring,
        paths: AppPaths,
        appVersion: String
    ) {
        self.quicklinks = quicklinks
        self.scripts = scripts
        self.extensions = extensions
        self.paths = paths
        self.appVersion = appVersion
    }

    public func export(settings: [String: JSONValue]) async throws -> Data {
        try Self.validateSettings(settings)
        let payload = ConfigurationPayload(
            settings: settings,
            quicklinks: try await quicklinks.allQuicklinks().map(ExportedQuicklink.init),
            scripts: try await scripts.allScripts().map(ExportedScriptRegistration.init),
            extensions: try await extensions.allExtensions().map(ExportedExtensionRegistration.init)
        )
        let document = ConfigurationDocument(
            schemaVersion: 1,
            appVersion: appVersion,
            createdAt: Date(),
            payloadSHA256: Self.sha256(try Self.encoder.encode(payload)),
            payload: payload
        )
        let data = try Self.encoder.encode(document)
        guard data.count <= Self.maximumDocumentBytes else { throw ConfigurationError.tooLarge }
        return data
    }

    public func inspectImport(_ data: Data) async throws -> ValidatedConfigurationImport {
        guard data.count <= Self.maximumDocumentBytes else { throw ConfigurationError.tooLarge }
        let document: ConfigurationDocument
        do { document = try Self.decoder.decode(ConfigurationDocument.self, from: data) } catch { throw ConfigurationError.invalidPayload }
        guard document.schemaVersion == 1 else { throw ConfigurationError.unsupportedSchema }
        guard !document.appVersion.isEmpty,
            document.appVersion.utf8.count <= 64,
            document.createdAt.timeIntervalSince1970.isFinite
        else { throw ConfigurationError.invalidPayload }
        let actualHash = Self.sha256(try Self.encoder.encode(document.payload))
        guard actualHash == document.payloadSHA256 else { throw ConfigurationError.invalidChecksum }
        try Self.validateSettings(document.payload.settings)
        guard document.payload.quicklinks.count <= 1_000,
            document.payload.scripts.count <= 1_000,
            document.payload.extensions.count <= 100
        else { throw ConfigurationError.invalidPayload }
        let importedQuicklinks = try document.payload.quicklinks.map { try $0.validatedDefinition() }
        guard Set(importedQuicklinks.map(\.id)).count == importedQuicklinks.count else {
            throw ConfigurationError.invalidPayload
        }
        try document.payload.scripts.forEach { try $0.validate() }
        try document.payload.extensions.forEach { try $0.validate() }
        guard Set(document.payload.scripts.map(\.id)).count == document.payload.scripts.count,
            Set(document.payload.extensions.map(\.manifest.id)).count == document.payload.extensions.count
        else { throw ConfigurationError.invalidPayload }
        let currentIDs = Set(try await quicklinks.allQuicklinks().map(\.id))
        let importedIDs = Set(importedQuicklinks.map(\.id))
        let preview = ConfigurationImportPreview(
            addedQuicklinks: importedIDs.subtracting(currentIDs).count,
            replacedQuicklinks: importedIDs.intersection(currentIDs).count,
            settingsCount: document.payload.settings.keys.filter(Self.supportedSettingKeys.contains).count,
            ignoredSettingsCount: document.payload.settings.keys.filter { !Self.supportedSettingKeys.contains($0) }.count,
            scriptsRequiringReconnection: document.payload.scripts.count,
            extensionsRequiringReinstallation: document.payload.extensions.count
        )
        return ValidatedConfigurationImport(document: document, quicklinks: importedQuicklinks, preview: preview)
    }

    @discardableResult
    public func createBackup(currentSettings: [String: JSONValue]) async throws -> URL {
        try paths.prepare()
        let backup = try await export(settings: currentSettings)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backupURL = paths.backups.appendingPathComponent(
            "Configuration-\(formatter.string(from: Date()))-\(UUID().uuidString.lowercased()).json",
            isDirectory: false
        )
        try backup.write(to: backupURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
        return backupURL
    }

    public func merge(_ validated: ValidatedConfigurationImport) async throws {
        try await quicklinks.mergeQuicklinksAtomically(validated.quicklinks)
    }

    public func merge(_ validated: ValidatedConfigurationImport, transactionID: String) async throws {
        guard UUID(uuidString: transactionID) != nil else { throw ConfigurationError.invalidPayload }
        try await quicklinks.mergeQuicklinksAtomically(validated.quicklinks, transactionID: transactionID)
    }

    public func hasCommittedTransaction(_ transactionID: String) async throws -> Bool {
        guard UUID(uuidString: transactionID) != nil else { return false }
        return try await quicklinks.hasCommittedConfigurationTransaction(transactionID)
    }

    public func importJournalURL() async throws -> URL {
        try paths.prepare()
        return paths.backups.appendingPathComponent("ConfigurationImportTransaction.json", isDirectory: false)
    }

    public func apply(_ validated: ValidatedConfigurationImport, currentSettings: [String: JSONValue]) async throws {
        _ = try await createBackup(currentSettings: currentSettings)
        try await merge(validated)
    }

    private static func validateSettings(_ settings: [String: JSONValue]) throws {
        guard settings.count <= 100 else { throw ConfigurationError.invalidPayload }
        for (key, value) in settings {
            guard !key.isEmpty, key.count <= 128,
                key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" })
            else { throw ConfigurationError.invalidPayload }
            try validateSettingValue(value, key: key)
        }
    }

    private static func validateSettingValue(_ value: JSONValue, key: String) throws {
        let booleanKeys: Set<String> = [
            "general.showDockIcon",
            "search.prefixesEnabled",
            "ranking.learningEnabled",
            "shortcuts.numberShortcutsEnabled",
            "clipboard.enabled",
            "clipboard.paused",
            "files.contentSearchEnabled",
            "files.hiddenFilesEnabled",
            "files.systemLocationsEnabled",
            "files.trashEnabled",
            "system.confirmSleepEveryTime",
        ]
        if booleanKeys.contains(key) {
            guard case .bool = value else { throw ConfigurationError.invalidPayload }
            return
        }
        if ["shortcuts.launcher.keyCode", "shortcuts.launcher.modifiers"].contains(key) {
            guard case let .integer(number) = value, UInt32(exactly: number) != nil else {
                throw ConfigurationError.invalidPayload
            }
            return
        }
        if key == "clipboard.retentionPreset" {
            guard case let .string(text) = value,
                ["1-day", "7-days", "30-days", "90-days", "unlimited"].contains(text)
            else { throw ConfigurationError.invalidPayload }
            return
        }
        if key == "clipboard.excludedApplications" {
            guard case let .string(text) = value, text.utf8.count <= 16_384 else {
                throw ConfigurationError.invalidPayload
            }
            return
        }
        if key == "capture.ocrLanguagePreset" {
            guard case let .string(text) = value,
                ["automatic", "en-zh", "en-US", "zh-Hans", "ja-JP"].contains(text)
            else { throw ConfigurationError.invalidPayload }
            return
        }
        // Unknown future keys are bounded and shown as ignored in the import preview.
        switch value {
        case .bool, .integer: break
        case let .string(text) where text.unicodeScalars.count <= 1_024: break
        default: throw ConfigurationError.invalidPayload
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
