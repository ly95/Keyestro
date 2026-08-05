import Foundation
import KeyestroDomain
import Security

public struct DiagnosticsPreview: Equatable, Sendable {
    public let files: [String]
    public let fields: [String]
    public let excluded: [String]

    public init(files: [String], fields: [String], excluded: [String]) {
        self.files = files
        self.fields = fields
        self.excluded = excluded
    }
}

public struct DiagnosticsSnapshot: Codable, Equatable, Sendable {
    public struct Signing: Codable, Equatable, Sendable {
        public let status: String
        public let identifier: String?
        public let teamIdentifier: String?
    }

    public let schemaVersion: Int
    public let generatedAt: Date
    public let appVersion: String
    public let buildVersion: String
    public let operatingSystem: String
    public let architecture: String
    public let permissions: [String: String]
    public let nonSecretSettings: [String: JSONValue]
    public let databaseIntegrity: String
    public let installedExtensionCount: Int
    public let enabledExtensionCount: Int
    public let applicationSupportBytes: Int64
    public let cacheBytes: Int64
    public let signing: Signing
    public let recentErrorCodes: [String]
}

public enum DiagnosticsError: Error, Equatable, Sendable {
    case unavailable
    case archiveFailed
    case writeFailed
}

public actor DiagnosticsService {
    private let paths: AppPaths
    private let extensions: any ExtensionStoring
    private let database: LauncherDatabase?
    private let processService: any ProcessServicing
    private let bundleURL: URL
    private let appVersion: String
    private let buildVersion: String

    public init(
        paths: AppPaths,
        extensions: any ExtensionStoring,
        database: LauncherDatabase?,
        processService: any ProcessServicing,
        bundleURL: URL = Bundle.main.bundleURL,
        appVersion: String,
        buildVersion: String
    ) {
        self.paths = paths
        self.extensions = extensions
        self.database = database
        self.processService = processService
        self.bundleURL = bundleURL
        self.appVersion = appVersion
        self.buildVersion = buildVersion
    }

    public nonisolated func preview() -> DiagnosticsPreview {
        DiagnosticsPreview(
            files: ["diagnostics.json", "README.txt"],
            fields: [
                "App/build and macOS versions",
                "CPU architecture and code-signing status",
                "Current permission states",
                "Non-secret settings",
                "Database integrity status",
                "Storage byte counts and extension counts",
                "Recent stable error codes",
            ],
            excluded: [
                "Queries, clipboard contents, screenshots, OCR text, and file contents",
                "Usernames and full home-directory paths",
                "Keychain values, API keys, script environment values, and extension secrets",
            ]
        )
    }

    public func snapshot(
        settings: [String: JSONValue],
        permissions: [String: String],
        recentErrorCodes: [String] = []
    ) async -> DiagnosticsSnapshot {
        let registrations = (try? await extensions.allExtensions()) ?? []
        let integrity: String
        if let database {
            do { integrity = try await database.integrityCheck() ? "ok" : "failed" } catch { integrity = "unavailable" }
        } else {
            integrity = "unavailable"
        }
        return DiagnosticsSnapshot(
            schemaVersion: 1,
            generatedAt: Date(),
            appVersion: appVersion,
            buildVersion: buildVersion,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: Self.architecture,
            permissions: permissions,
            nonSecretSettings: settings,
            databaseIntegrity: integrity,
            installedExtensionCount: registrations.count,
            enabledExtensionCount: registrations.filter(\.enabled).count,
            applicationSupportBytes: Self.directoryByteCount(paths.applicationSupport),
            cacheBytes: Self.directoryByteCount(paths.caches),
            signing: Self.signingStatus(bundleURL),
            recentErrorCodes: Array(recentErrorCodes.prefix(100)).filter { $0.count <= 256 }
        )
    }

    public func exportZIP(_ snapshot: DiagnosticsSnapshot, to destination: URL) async throws {
        let destination = destination.standardizedFileURL
        guard destination.isFileURL else { throw DiagnosticsError.writeFailed }
        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "keyestro-diagnostics-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        let package = temporaryRoot.appendingPathComponent("Keyestro Diagnostics", isDirectory: true)
        let archive = temporaryRoot.appendingPathComponent("diagnostics.zip", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        do {
            try FileManager.default.createDirectory(
                at: package,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            let jsonURL = package.appendingPathComponent("diagnostics.json")
            try data.write(to: jsonURL, options: [.atomic])
            let readme = """
                Keyestro diagnostics generated by explicit user action.

                This archive contains local system/app metadata and stable status codes only.
                It excludes query text, clipboard payloads, screenshots, OCR output, file contents,
                usernames, complete home paths, Keychain values, API keys, and secret preferences.
                Review diagnostics.json before sharing this archive.
                """
            try Data(readme.utf8).write(to: package.appendingPathComponent("README.txt"), options: [.atomic])
            let result = try await processService.run(
                ProcessExecutionRequest(
                    executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
                    arguments: ["-c", "-k", "--sequesterRsrc", "--keepParent", package.path, archive.path],
                    environment: [:],
                    workingDirectoryURL: temporaryRoot,
                    timeout: .seconds(30),
                    maximumOutputBytes: 64 * 1_024
                )
            )
            guard result.termination == .exited(0),
                let size = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                size <= 20 * 1_024 * 1_024
            else { throw DiagnosticsError.archiveFailed }
            try Data(contentsOf: archive, options: .mappedIfSafe).write(to: destination, options: [.atomic])
        } catch let error as DiagnosticsError {
            throw error
        } catch {
            throw DiagnosticsError.writeFailed
        }
    }

    private static var architecture: String {
        #if arch(arm64)
            "arm64"
        #elseif arch(x86_64)
            "x86_64"
        #else
            "unknown"
        #endif
    }

    private static func directoryByteCount(_ root: URL) -> Int64 {
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                values.isRegularFile == true
            else { continue }
            let size = Int64(values.fileSize ?? 0)
            if size > 0, total <= Int64.max - size { total += size }
        }
        return total
    }

    private static func signingStatus(_ url: URL) -> DiagnosticsSnapshot.Signing {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
            let staticCode
        else { return .init(status: "unavailable", identifier: nil, teamIdentifier: nil) }
        let validity = SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: kSecCSCheckAllArchitectures),
            nil
        )
        var information: CFDictionary?
        _ = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        let dictionary = information as? [String: Any]
        return .init(
            status: validity == errSecSuccess ? "valid" : "invalid",
            identifier: (dictionary?[kSecCodeInfoIdentifier as String] as? String)?.limitedToUnicodeScalars(256),
            teamIdentifier: (dictionary?[kSecCodeInfoTeamIdentifier as String] as? String)?.limitedToUnicodeScalars(64)
        )
    }
}
