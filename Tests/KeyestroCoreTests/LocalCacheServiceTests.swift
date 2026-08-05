import Foundation
import Testing
@testable import KeyestroCore

@Test func localCacheClearingRemovesOnlyTheExactBundleOwnedCacheRoot() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyestro-cache-clear-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let cacheParent = root.appendingPathComponent("Caches", isDirectory: true)
    let paths = try AppPaths(
        bundleIdentifier: "com.keyestro.cache-tests",
        applicationSupportRoot: root.appendingPathComponent("Support", isDirectory: true),
        cachesRoot: cacheParent
    )
    try paths.prepare()
    let marker = paths.derivedData.appendingPathComponent("marker")
    try Data("cache".utf8).write(to: marker)
    let sibling = cacheParent.appendingPathComponent("com.example.sibling", isDirectory: true)
    try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
    let siblingMarker = sibling.appendingPathComponent("keep")
    try Data("owned elsewhere".utf8).write(to: siblingMarker)

    try LocalCacheService(paths: paths).clear()

    #expect(!FileManager.default.fileExists(atPath: marker.path))
    #expect(FileManager.default.fileExists(atPath: paths.icons.path))
    #expect(FileManager.default.fileExists(atPath: paths.derivedData.path))
    #expect(FileManager.default.fileExists(atPath: siblingMarker.path))
}
