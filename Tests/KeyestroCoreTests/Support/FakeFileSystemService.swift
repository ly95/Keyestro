import CryptoKit
import Foundation
@testable import KeyestroCore

actor FakeFileSystemService: FileSystemServicing {
    private enum Node: Sendable {
        case directory(permissions: Int)
        case file(data: Data, executable: Bool, permissions: Int, identity: String)
        case symbolicLink(URL)
    }

    private var nodes: [String: Node] = [:]

    func addFile(at url: URL, data: Data, executable: Bool, permissions: Int = 0o600) {
        nodes[path(url)] = .file(
            data: data,
            executable: executable,
            permissions: permissions,
            identity: UUID().uuidString
        )
    }

    func addSymbolicLink(at url: URL, destination: URL) {
        nodes[path(url)] = .symbolicLink(destination.standardizedFileURL)
    }

    func canonicalURL(for url: URL) throws -> URL {
        guard url.isFileURL else { throw FileSystemServiceError.invalidURL }
        var current = url.standardizedFileURL
        var visited = Set<String>()
        for _ in 0..<32 {
            guard visited.insert(path(current)).inserted else { throw FileSystemServiceError.invalidURL }
            guard case let .symbolicLink(destination)? = nodes[path(current)] else { return current }
            current = destination.standardizedFileURL
        }
        throw FileSystemServiceError.invalidURL
    }

    func metadata(at url: URL) -> FileSystemItemMetadata? {
        switch nodes[path(url)] {
        case let .directory(permissions):
            FileSystemItemMetadata(
                isRegularFile: false,
                isDirectory: true,
                isSymbolicLink: false,
                isExecutable: true,
                byteCount: 0,
                posixPermissions: permissions
            )
        case let .file(data, executable, permissions, identity):
            FileSystemItemMetadata(
                isRegularFile: true,
                isDirectory: false,
                isSymbolicLink: false,
                isExecutable: executable,
                byteCount: data.count,
                posixPermissions: permissions,
                fileIdentity: identity
            )
        case .symbolicLink:
            FileSystemItemMetadata(
                isRegularFile: false,
                isDirectory: false,
                isSymbolicLink: true,
                isExecutable: false,
                byteCount: 0,
                posixPermissions: nil
            )
        case nil:
            nil
        }
    }

    func createDirectory(at url: URL, permissions: Int) throws {
        guard nodes[path(url)] == nil else { throw CocoaError(.fileWriteFileExists) }
        nodes[path(url)] = .directory(permissions: permissions)
    }

    func copyItem(at source: URL, to destination: URL) throws {
        guard let node = nodes[path(source)], nodes[path(destination)] == nil else {
            throw FileSystemServiceError.itemMissing
        }
        switch node {
        case let .file(data, executable, permissions, _):
            nodes[path(destination)] = .file(
                data: data,
                executable: executable,
                permissions: permissions,
                identity: UUID().uuidString
            )
        default:
            nodes[path(destination)] = node
        }
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try copyItem(at: source, to: destination)
        nodes[path(source)] = nil
    }

    func removeItem(at url: URL) {
        let root = path(url)
        nodes = nodes.filter { key, _ in key != root && !key.hasPrefix(root + "/") }
    }

    func setPermissions(_ permissions: Int, at url: URL) throws {
        switch nodes[path(url)] {
        case .directory:
            nodes[path(url)] = .directory(permissions: permissions)
        case let .file(data, executable, _, identity):
            nodes[path(url)] = .file(
                data: data,
                executable: executable || permissions & 0o111 != 0,
                permissions: permissions,
                identity: identity
            )
        default:
            throw FileSystemServiceError.itemMissing
        }
    }

    func sha256Digest(at url: URL, maximumBytes: Int) throws -> String {
        guard case let .file(data, _, _, _) = nodes[path(url)] else {
            throw FileSystemServiceError.itemMissing
        }
        guard data.count <= maximumBytes else {
            throw FileSystemServiceError.itemTooLarge(maximumBytes: maximumBytes)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func path(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}
