import CryptoKit
import Foundation

/// Stable, sendable metadata used instead of leaking `FileManager` dictionaries across boundaries.
public struct FileSystemItemMetadata: Equatable, Sendable {
    public let isRegularFile: Bool
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    public let isExecutable: Bool
    public let byteCount: Int
    public let posixPermissions: Int?
    /// Stable identity for the current file object. A replacement at the same path gets a new value.
    public let fileIdentity: String?

    public init(
        isRegularFile: Bool,
        isDirectory: Bool,
        isSymbolicLink: Bool,
        isExecutable: Bool,
        byteCount: Int,
        posixPermissions: Int?,
        fileIdentity: String? = nil
    ) {
        self.isRegularFile = isRegularFile
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.isExecutable = isExecutable
        self.byteCount = max(0, byteCount)
        self.posixPermissions = posixPermissions
        self.fileIdentity = fileIdentity
    }
}

public enum FileSystemServiceError: Error, Equatable, Sendable {
    case invalidURL
    case itemMissing
    case itemTooLarge(maximumBytes: Int)
}

/// Minimal file-system boundary for validation, managed installation, hashing, and cleanup.
public protocol FileSystemServicing: Sendable {
    func canonicalURL(for url: URL) async throws -> URL
    func metadata(at url: URL) async throws -> FileSystemItemMetadata?
    func createDirectory(at url: URL, permissions: Int) async throws
    func copyItem(at source: URL, to destination: URL) async throws
    func moveItem(at source: URL, to destination: URL) async throws
    func removeItem(at url: URL) async throws
    func setPermissions(_ permissions: Int, at url: URL) async throws
    func sha256Digest(at url: URL, maximumBytes: Int) async throws -> String
}

/// Serialized production file-system implementation. Blocking calls never execute on MainActor.
public actor LocalFileSystemService: FileSystemServicing {
    private let manager: FileManager

    public init(manager: FileManager = .default) {
        self.manager = manager
    }

    public func canonicalURL(for url: URL) throws -> URL {
        guard url.isFileURL else { throw FileSystemServiceError.invalidURL }
        return url.resolvingSymlinksInPath().standardizedFileURL
    }

    public func metadata(at url: URL) throws -> FileSystemItemMetadata? {
        guard url.isFileURL else { throw FileSystemServiceError.invalidURL }
        guard manager.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        let attributes = try manager.attributesOfItem(atPath: url.path)
        let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value
        let file = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        return FileSystemItemMetadata(
            isRegularFile: values.isRegularFile == true,
            isDirectory: values.isDirectory == true,
            isSymbolicLink: values.isSymbolicLink == true,
            isExecutable: manager.isExecutableFile(atPath: url.path),
            byteCount: values.fileSize ?? 0,
            posixPermissions: (attributes[.posixPermissions] as? NSNumber)?.intValue,
            fileIdentity: device.flatMap { device in file.map { "\(device):\($0)" } }
        )
    }

    public func createDirectory(at url: URL, permissions: Int) throws {
        guard url.isFileURL else { throw FileSystemServiceError.invalidURL }
        try manager.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: permissions]
        )
    }

    public func copyItem(at source: URL, to destination: URL) throws {
        guard source.isFileURL, destination.isFileURL else { throw FileSystemServiceError.invalidURL }
        try manager.copyItem(at: source, to: destination)
    }

    public func moveItem(at source: URL, to destination: URL) throws {
        guard source.isFileURL, destination.isFileURL else { throw FileSystemServiceError.invalidURL }
        try manager.moveItem(at: source, to: destination)
    }

    public func removeItem(at url: URL) throws {
        guard url.isFileURL else { throw FileSystemServiceError.invalidURL }
        guard manager.fileExists(atPath: url.path) else { return }
        try manager.removeItem(at: url)
    }

    public func setPermissions(_ permissions: Int, at url: URL) throws {
        guard url.isFileURL else { throw FileSystemServiceError.invalidURL }
        try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    public func sha256Digest(at url: URL, maximumBytes: Int) throws -> String {
        guard url.isFileURL, maximumBytes > 0 else { throw FileSystemServiceError.invalidURL }
        guard let metadata = try metadata(at: url) else { throw FileSystemServiceError.itemMissing }
        guard metadata.isRegularFile else { throw FileSystemServiceError.itemMissing }
        guard metadata.byteCount <= maximumBytes else {
            throw FileSystemServiceError.itemTooLarge(maximumBytes: maximumBytes)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var bytesRead = 0
        while true {
            let data = try handle.read(upToCount: 64 * 1_024) ?? Data()
            if data.isEmpty { break }
            bytesRead += data.count
            guard bytesRead <= maximumBytes else {
                throw FileSystemServiceError.itemTooLarge(maximumBytes: maximumBytes)
            }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
