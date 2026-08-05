import Foundation
import KeyestroDomain

public struct AppPaths: Sendable, Equatable {
    public let bundleIdentifier: String
    public let applicationSupport: URL
    public let database: URL
    public let encryptedBlobs: URL
    public let extensions: URL
    public let managedScripts: URL
    public let backups: URL
    public let diagnostics: URL
    public let caches: URL
    public let icons: URL
    public let derivedData: URL

    public init(
        bundleIdentifier: String,
        applicationSupportRoot: URL? = nil,
        cachesRoot: URL? = nil
    ) throws {
        guard Self.isValidBundleIdentifier(bundleIdentifier) else {
            throw ErrorDescriptor(code: "paths.invalidBundleIdentifier", message: "The bundle identifier is invalid.")
        }
        let manager = FileManager.default
        let supportRoot =
            applicationSupportRoot
            ?? manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let cacheRoot = cachesRoot ?? manager.urls(for: .cachesDirectory, in: .userDomainMask).first
        guard let supportRoot, let cacheRoot else {
            throw ErrorDescriptor(
                code: "paths.systemDirectoryUnavailable",
                message: "The macOS application data directories are unavailable."
            )
        }

        self.bundleIdentifier = bundleIdentifier
        applicationSupport = supportRoot.appendingPathComponent(bundleIdentifier, isDirectory: true).standardizedFileURL
        database = applicationSupport.appendingPathComponent("launcher.sqlite", isDirectory: false)
        encryptedBlobs = applicationSupport.appendingPathComponent("EncryptedBlobs", isDirectory: true)
        extensions = applicationSupport.appendingPathComponent("Extensions", isDirectory: true)
        managedScripts = applicationSupport.appendingPathComponent("Scripts", isDirectory: true)
        backups = applicationSupport.appendingPathComponent("Backups", isDirectory: true)
        diagnostics = applicationSupport.appendingPathComponent("Diagnostics", isDirectory: true)
        caches = cacheRoot.appendingPathComponent(bundleIdentifier, isDirectory: true).standardizedFileURL
        icons = caches.appendingPathComponent("Icons", isDirectory: true)
        derivedData = caches.appendingPathComponent("DerivedData", isDirectory: true)

        guard applicationSupport.path.hasPrefix(supportRoot.standardizedFileURL.path + "/"),
            caches.path.hasPrefix(cacheRoot.standardizedFileURL.path + "/")
        else {
            throw ErrorDescriptor(code: "paths.escape", message: "An application data path escaped its owned directory.")
        }
    }

    public func prepare() throws {
        let manager = FileManager.default
        for directory in [
            applicationSupport, encryptedBlobs, extensions, managedScripts, backups, diagnostics,
            caches, icons, derivedData,
        ] {
            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }

    private static func isValidBundleIdentifier(_ value: String) -> Bool {
        guard value.count <= 255, value.contains("."), !value.hasPrefix("."), !value.hasSuffix(".") else {
            return false
        }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-"
        }
    }
}
