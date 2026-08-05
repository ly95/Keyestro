import Foundation

public struct LocalDataDeletionReport: Equatable, Sendable {
    public let deletedTargets: [String]
    public let failedTargets: [String]

    public init(deletedTargets: [String], failedTargets: [String]) {
        self.deletedTargets = deletedTargets
        self.failedTargets = failedTargets
    }

    public var succeeded: Bool { failedTargets.isEmpty }
}

public actor LocalDataDeletionService {
    private let paths: AppPaths
    private let keys: InstallationKeyManager

    public init(paths: AppPaths, keys: InstallationKeyManager) {
        self.paths = paths
        self.keys = keys
    }

    public func deleteAllOwnedData() async -> LocalDataDeletionReport {
        var deleted: [String] = []
        var failed: [String] = []
        do {
            try await keys.deleteAllInstallationKeys()
            deleted.append("Keychain installation and clipboard keys")
        } catch {
            failed.append("Keychain installation and clipboard keys")
        }
        for (label, url) in [
            ("Application Support data", paths.applicationSupport),
            ("Caches", paths.caches),
        ] {
            guard Self.isExactOwnedRoot(url, bundleIdentifier: paths.bundleIdentifier) else {
                failed.append(label)
                continue
            }
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                deleted.append(label)
            } catch {
                failed.append(label)
            }
        }
        return LocalDataDeletionReport(deletedTargets: deleted, failedTargets: failed)
    }

    public static func isExactOwnedRoot(_ url: URL, bundleIdentifier: String) -> Bool {
        let standardized = url.standardizedFileURL
        guard standardized.isFileURL,
            standardized.path != "/",
            standardized.lastPathComponent == bundleIdentifier,
            standardized.deletingLastPathComponent().path != "/"
        else { return false }
        return true
    }
}
