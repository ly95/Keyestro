import Foundation
import KeyestroDomain

public struct LocalCacheService: Sendable {
    private let paths: AppPaths

    public init(paths: AppPaths) {
        self.paths = paths
    }

    /// Removes only the resolved bundle-owned cache root, then recreates its
    /// permission-hardened directory structure.
    public func clear() throws {
        let manager = FileManager.default
        let cacheRoot = paths.caches.standardizedFileURL
        guard cacheRoot.lastPathComponent == paths.bundleIdentifier,
            cacheRoot.path != "/",
            cacheRoot.pathComponents.count >= 3
        else {
            throw ErrorDescriptor(code: "cache.invalidRoot", message: "The application cache path is invalid.")
        }
        if manager.fileExists(atPath: cacheRoot.path) {
            try manager.removeItem(at: cacheRoot)
        }
        try paths.prepare()
    }
}
