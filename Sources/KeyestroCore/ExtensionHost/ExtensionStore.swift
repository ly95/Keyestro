import CryptoKit
import Foundation
import KeyestroDomain
import SQLite3

/// An installed extension version and its host-owned enablement and failure metadata.
public struct ExtensionRegistration: Equatable, Identifiable, Sendable {
    public let manifest: ExtensionManifest
    public let installPath: String
    public let manifestJSON: Data
    public let contentHash: String
    public let enabled: Bool
    public let lastErrorCode: String?
    public let installedAt: Date
    public let updatedAt: Date

    public var id: String { manifest.id }

    /// Identity of the installed payload affected by destructive removal.
    /// Runtime enablement and failure metadata do not change that target.
    public func sameInstalledPayload(as other: ExtensionRegistration) -> Bool {
        id == other.id
            && manifest == other.manifest
            && installPath == other.installPath
            && manifestJSON == other.manifestJSON
            && contentHash == other.contentHash
    }

    public init(
        manifest: ExtensionManifest,
        installPath: String,
        manifestJSON: Data,
        contentHash: String,
        enabled: Bool,
        lastErrorCode: String? = nil,
        installedAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.manifest = manifest
        self.installPath = installPath
        self.manifestJSON = manifestJSON
        self.contentHash = contentHash
        self.enabled = enabled
        self.lastErrorCode = lastErrorCode
        self.installedAt = installedAt
        self.updatedAt = updatedAt
    }

    public func replacing(enabled: Bool, lastErrorCode: String? = nil) -> Self {
        Self(
            manifest: manifest,
            installPath: installPath,
            manifestJSON: manifestJSON,
            contentHash: contentHash,
            enabled: enabled,
            lastErrorCode: lastErrorCode,
            installedAt: installedAt,
            updatedAt: Date()
        )
    }
}

/// The SQLite representation of a non-secret preference value or a secret-set marker.
public struct ExtensionPreferenceRecord: Equatable, Sendable {
    public let extensionID: String
    public let name: String
    public let valueJSON: Data?
    public let isSecret: Bool

    public init(extensionID: String, name: String, valueJSON: Data?, isSecret: Bool) {
        self.extensionID = extensionID
        self.name = name
        self.valueJSON = valueJSON
        self.isSecret = isSecret
    }
}

/// Persistence operations for extension preference records.
public protocol ExtensionPreferenceStoring: Sendable {
    func extensionPreference(extensionID: String, name: String) async throws -> ExtensionPreferenceRecord?
    func extensionPreferences(extensionID: String?) async throws -> [ExtensionPreferenceRecord]
    func saveExtensionPreference(_ preference: ExtensionPreferenceRecord) async throws
    func deleteExtensionPreference(extensionID: String, name: String) async throws
}

/// Persistence operations required by extension installation and supervision.
public protocol ExtensionStoring: ExtensionPreferenceStoring, Sendable {
    func allExtensions() async throws -> [ExtensionRegistration]
    func extensionRegistration(id: String) async throws -> ExtensionRegistration?
    /// Atomically replaces the authoritative current-version pointer for this extension ID.
    func saveExtension(_ registration: ExtensionRegistration) async throws
    func deleteExtension(id: String) async throws
    /// Removes only if the current installed payload is the one the user reviewed.
    func deleteExtension(ifCurrentMatches registration: ExtensionRegistration) async throws -> Bool
}

/// A deterministic in-memory extension store for previews, tools, and tests.
public actor InMemoryExtensionStore: ExtensionStoring {
    private var registrations: [String: ExtensionRegistration] = [:]
    private var preferences: [String: ExtensionPreferenceRecord] = [:]

    public init(registrations: [ExtensionRegistration] = []) {
        self.registrations = Dictionary(uniqueKeysWithValues: registrations.map { ($0.id, $0) })
    }

    public func allExtensions() -> [ExtensionRegistration] {
        registrations.values.sorted { $0.manifest.name.localizedStandardCompare($1.manifest.name) == .orderedAscending }
    }

    public func extensionRegistration(id: String) -> ExtensionRegistration? { registrations[id] }
    public func saveExtension(_ registration: ExtensionRegistration) { registrations[registration.id] = registration }
    public func deleteExtension(id: String) {
        registrations[id] = nil
        preferences = preferences.filter { $0.value.extensionID != id }
    }

    public func deleteExtension(ifCurrentMatches registration: ExtensionRegistration) -> Bool {
        guard registrations[registration.id]?.sameInstalledPayload(as: registration) == true else { return false }
        registrations[registration.id] = nil
        preferences = preferences.filter { $0.value.extensionID != registration.id }
        return true
    }

    public func extensionPreference(extensionID: String, name: String) -> ExtensionPreferenceRecord? {
        preferences[Self.preferenceKey(extensionID: extensionID, name: name)]
    }

    public func extensionPreferences(extensionID: String?) -> [ExtensionPreferenceRecord] {
        preferences.values
            .filter { extensionID == nil || $0.extensionID == extensionID }
            .sorted {
                ($0.extensionID, $0.name) < ($1.extensionID, $1.name)
            }
    }

    public func saveExtensionPreference(_ preference: ExtensionPreferenceRecord) {
        preferences[Self.preferenceKey(extensionID: preference.extensionID, name: preference.name)] = preference
    }

    public func deleteExtensionPreference(extensionID: String, name: String) {
        preferences[Self.preferenceKey(extensionID: extensionID, name: name)] = nil
    }

    private static func preferenceKey(extensionID: String, name: String) -> String {
        "\(extensionID)\u{0}\(name)"
    }
}

extension LauncherDatabase: ExtensionStoring {
    public func allExtensions() throws -> [ExtensionRegistration] {
        let database = try databaseHandle()
        return try withStatement(
            database: database,
            sql: """
                SELECT id,version,install_path,manifest_json,content_hash,enabled,last_error_code,installed_at,updated_at
                FROM extensions ORDER BY id;
                """
        ) { statement in
            var output: [ExtensionRegistration] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW,
                    let id = string(at: 0, in: statement),
                    let version = string(at: 1, in: statement),
                    let installPath = string(at: 2, in: statement),
                    let manifestData = data(at: 3, in: statement),
                    let contentHash = string(at: 4, in: statement),
                    let manifest = try? JSONDecoder().decode(ExtensionManifest.self, from: manifestData),
                    manifest.id == id,
                    manifest.version == version
                else { throw DatabaseError.corruptData(table: "extensions") }
                output.append(
                    ExtensionRegistration(
                        manifest: manifest,
                        installPath: installPath,
                        manifestJSON: manifestData,
                        contentHash: contentHash,
                        enabled: sqlite3_column_int64(statement, 5) != 0,
                        lastErrorCode: string(at: 6, in: statement),
                        installedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
                        updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8))
                    )
                )
            }
            return output
        }
    }

    public func extensionRegistration(id: String) throws -> ExtensionRegistration? {
        try allExtensions().first(where: { $0.id == id })
    }

    public func saveExtension(_ registration: ExtensionRegistration) throws {
        let database = try databaseHandle()
        try withStatement(
            database: database,
            sql: """
                INSERT INTO extensions(id,version,install_path,manifest_json,content_hash,enabled,last_error_code,installed_at,updated_at)
                VALUES(?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET
                  version=excluded.version,install_path=excluded.install_path,
                  manifest_json=excluded.manifest_json,content_hash=excluded.content_hash,
                  enabled=excluded.enabled,last_error_code=excluded.last_error_code,
                  updated_at=excluded.updated_at;
                """
        ) { statement in
            try bind(registration.id, to: 1, in: statement)
            try bind(registration.manifest.version, to: 2, in: statement)
            try bind(registration.installPath, to: 3, in: statement)
            try bind(registration.manifestJSON, to: 4, in: statement)
            try bind(registration.contentHash, to: 5, in: statement)
            try bind(Int64(registration.enabled ? 1 : 0), to: 6, in: statement)
            if let error = registration.lastErrorCode {
                try bind(error, to: 7, in: statement)
            } else {
                sqlite3_bind_null(statement, 7)
            }
            try bind(registration.installedAt.timeIntervalSince1970, to: 8, in: statement)
            try bind(registration.updatedAt.timeIntervalSince1970, to: 9, in: statement)
            try requireDone(statement)
        }
    }

    public func deleteExtension(id: String) throws {
        let database = try databaseHandle()
        try withStatement(database: database, sql: "DELETE FROM extensions WHERE id=?;") { statement in
            try bind(id, to: 1, in: statement)
            try requireDone(statement)
        }
    }

    public func deleteExtension(ifCurrentMatches registration: ExtensionRegistration) throws -> Bool {
        guard try extensionRegistration(id: registration.id)?.sameInstalledPayload(as: registration) == true else {
            return false
        }
        try deleteExtension(id: registration.id)
        return true
    }

    public func extensionPreference(extensionID: String, name: String) throws -> ExtensionPreferenceRecord? {
        let database = try databaseHandle()
        return try withStatement(
            database: database,
            sql: """
                SELECT value_json,is_secret FROM extension_preferences
                WHERE extension_id=? AND name=? LIMIT 1;
                """
        ) { statement in
            try bind(extensionID, to: 1, in: statement)
            try bind(name, to: 2, in: statement)
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW else { throw DatabaseError.statementFailed(code: status) }
            return ExtensionPreferenceRecord(
                extensionID: extensionID,
                name: name,
                valueJSON: data(at: 0, in: statement),
                isSecret: sqlite3_column_int64(statement, 1) != 0
            )
        }
    }

    public func extensionPreferences(extensionID: String?) throws -> [ExtensionPreferenceRecord] {
        let database = try databaseHandle()
        let sql: String
        if extensionID == nil {
            sql = """
                SELECT extension_id,name,value_json,is_secret
                FROM extension_preferences ORDER BY extension_id,name;
                """
        } else {
            sql = """
                SELECT extension_id,name,value_json,is_secret
                FROM extension_preferences WHERE extension_id=? ORDER BY name;
                """
        }
        return try withStatement(database: database, sql: sql) { statement in
            if let extensionID { try bind(extensionID, to: 1, in: statement) }
            var output: [ExtensionPreferenceRecord] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW,
                    let recordExtensionID = string(at: 0, in: statement),
                    let name = string(at: 1, in: statement)
                else { throw DatabaseError.corruptData(table: "extension_preferences") }
                output.append(
                    ExtensionPreferenceRecord(
                        extensionID: recordExtensionID,
                        name: name,
                        valueJSON: data(at: 2, in: statement),
                        isSecret: sqlite3_column_int64(statement, 3) != 0
                    )
                )
            }
            return output
        }
    }

    public func saveExtensionPreference(_ preference: ExtensionPreferenceRecord) throws {
        let database = try databaseHandle()
        try withStatement(
            database: database,
            sql: """
                INSERT INTO extension_preferences(extension_id,name,value_json,is_secret)
                VALUES(?,?,?,?)
                ON CONFLICT(extension_id,name) DO UPDATE SET
                  value_json=excluded.value_json,is_secret=excluded.is_secret;
                """
        ) { statement in
            try bind(preference.extensionID, to: 1, in: statement)
            try bind(preference.name, to: 2, in: statement)
            if let valueJSON = preference.valueJSON {
                try bind(valueJSON, to: 3, in: statement)
            } else {
                sqlite3_bind_null(statement, 3)
            }
            try bind(Int64(preference.isSecret ? 1 : 0), to: 4, in: statement)
            try requireDone(statement)
        }
    }

    public func deleteExtensionPreference(extensionID: String, name: String) throws {
        let database = try databaseHandle()
        try withStatement(
            database: database,
            sql: "DELETE FROM extension_preferences WHERE extension_id=? AND name=?;"
        ) { statement in
            try bind(extensionID, to: 1, in: statement)
            try bind(name, to: 2, in: statement)
            try requireDone(statement)
        }
    }
}

/// Inspects, hashes, hardens, and atomically installs versioned extension packages.
///
/// A fully validated version directory is materialized before `ExtensionStoring.saveExtension`
/// atomically switches the authoritative current-version row. If that switch fails, the new
/// directory is removed while the previous registration and version remain runnable.
public actor ExtensionInstaller {
    private let paths: AppPaths
    private let store: any ExtensionStoring
    private let maximumPackageBytes = 100 * 1_024 * 1_024
    private let maximumFiles = 1_000
    private var operationInProgress = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(paths: AppPaths, store: any ExtensionStoring) {
        self.paths = paths
        self.store = store
    }

    public func inspect(sourceRoot: URL) throws -> ExtensionRegistration {
        let source = sourceRoot.resolvingSymlinksInPath().standardizedFileURL
        let manifest = try ExtensionManifest.load(from: source)
        let inventory = try validateInventory(root: source)
        let manifestJSON = try Data(contentsOf: source.appendingPathComponent("extension.json"))
        return ExtensionRegistration(
            manifest: manifest,
            installPath: source.path,
            manifestJSON: manifestJSON,
            contentHash: inventory.hash,
            enabled: false
        )
    }

    public func install(sourceRoot: URL, enable: Bool) async throws -> ExtensionRegistration {
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()

        try paths.prepare()
        let inspected = try inspect(sourceRoot: sourceRoot)
        let canonicalSource = URL(fileURLWithPath: inspected.installPath, isDirectory: true)
        let idRoot = paths.extensions.appendingPathComponent(inspected.id, isDirectory: true)
        try FileManager.default.createDirectory(
            at: idRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let destination = idRoot.appendingPathComponent(inspected.manifest.version, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ExtensionValidationError.alreadyInstalled
        }
        let staging = idRoot.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        var movedToDestination = false
        do {
            try FileManager.default.copyItem(at: canonicalSource, to: staging)
            try hardenPermissions(root: staging)
            let copiedManifest = try ExtensionManifest.load(from: staging)
            guard copiedManifest == inspected.manifest else {
                throw ExtensionValidationError.manifestChangedDuringInstall
            }
            let copiedInventory = try validateInventory(root: staging)
            guard copiedInventory.hash == inspected.contentHash else {
                throw ExtensionValidationError.contentChangedDuringInstall
            }
            let copiedManifestJSON = try Data(
                contentsOf: staging.appendingPathComponent("extension.json", isDirectory: false),
                options: .mappedIfSafe
            )
            guard copiedManifestJSON.count <= 256 * 1_024,
                try JSONDecoder().decode(ExtensionManifest.self, from: copiedManifestJSON) == copiedManifest,
                try validateInventory(root: staging).hash == copiedInventory.hash
            else { throw ExtensionValidationError.contentChangedDuringInstall }
            try FileManager.default.moveItem(at: staging, to: destination)
            movedToDestination = true
            let registration = ExtensionRegistration(
                manifest: copiedManifest,
                installPath: destination.path,
                manifestJSON: copiedManifestJSON,
                contentHash: copiedInventory.hash,
                enabled: enable
            )
            try await store.saveExtension(registration)
            return registration
        } catch {
            try? FileManager.default.removeItem(at: staging)
            if movedToDestination { try? FileManager.default.removeItem(at: destination) }
            throw error
        }
    }

    public func remove(_ registration: ExtensionRegistration) async throws {
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()

        let installURL = URL(fileURLWithPath: registration.installPath).standardizedFileURL
        let ownedRoot = paths.extensions.standardizedFileURL
        let extensionIDRoot = ownedRoot.appendingPathComponent(registration.id, isDirectory: true).standardizedFileURL
        guard extensionIDRoot.deletingLastPathComponent() == ownedRoot,
            installURL.deletingLastPathComponent() == extensionIDRoot
        else { throw ExtensionValidationError.pathEscape }
        guard try await store.deleteExtension(ifCurrentMatches: registration) else {
            throw ErrorDescriptor(
                code: "extensions.staleRegistration",
                message: "The extension changed after the removal confirmation.",
                recoverySuggestion: "Review the current extension version and confirm removal again."
            )
        }
        if FileManager.default.fileExists(atPath: extensionIDRoot.path) {
            do {
                try FileManager.default.removeItem(at: extensionIDRoot)
            } catch {
                throw ErrorDescriptor(
                    code: "extensions.removalCleanupFailed",
                    message: "The extension was unregistered, but its installed files could not be deleted.",
                    recoverySuggestion: "Use Delete All Local Data to remove remaining extension files."
                )
            }
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

    private func validateInventory(root: URL) throws -> (hash: String, size: Int, count: Int) {
        let manager = FileManager.default
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        guard let enumerator = manager.enumerator(atPath: canonicalRoot.path) else {
            throw ExtensionValidationError.invalidManifest
        }
        var entries: [(String, URL, Int)] = []
        var totalSize = 0
        for case let relative as String in enumerator {
            guard !relative.isEmpty,
                relative.utf8.count <= 4_096,
                !relative.contains("\u{0}"),
                !relative.hasPrefix("/")
            else { throw ExtensionValidationError.pathEscape }
            let url = canonicalRoot.appendingPathComponent(relative, isDirectory: false)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if values.isSymbolicLink == true { throw ExtensionValidationError.symbolicLinkNotAllowed }
            guard values.isRegularFile == true else { continue }
            let size = values.fileSize ?? 0
            entries.append((relative, url, size))
            totalSize += size
            guard entries.count <= maximumFiles else { throw ExtensionValidationError.tooManyFiles }
            guard totalSize <= maximumPackageBytes else { throw ExtensionValidationError.packageTooLarge }
        }
        var hasher = SHA256()
        for (relative, url, size) in entries.sorted(by: { $0.0 < $1.0 }) {
            hasher.update(data: Data(relative.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: withUnsafeBytes(of: UInt64(size).bigEndian) { Data($0) })
            let handle = try FileHandle(forReadingFrom: url)
            do {
                while true {
                    let chunk = try handle.read(upToCount: 64 * 1_024) ?? Data()
                    if chunk.isEmpty { break }
                    hasher.update(data: chunk)
                }
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
        }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (hash, totalSize, entries.count)
    }

    private func hardenPermissions(root: URL) throws {
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        guard
            let enumerator = manager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: []
            )
        else { throw ExtensionValidationError.invalidManifest }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values.isDirectory == true {
                try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            } else if values.isRegularFile == true {
                let wasExecutable = manager.isExecutableFile(atPath: url.path)
                try manager.setAttributes(
                    [.posixPermissions: wasExecutable ? 0o700 : 0o600],
                    ofItemAtPath: url.path
                )
            }
        }
    }
}
