import Foundation
import KeyestroCore
import Testing

@Test func localDataDeletionUsesOnlyExactBundleOwnedRoots() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        bundleIdentifier: "com.keyestro.deletion-tests",
        applicationSupportRoot: root.appendingPathComponent("Support"),
        cachesRoot: root.appendingPathComponent("Caches")
    )
    try paths.prepare()
    let supportMarker = paths.applicationSupport.appendingPathComponent("marker")
    let cacheMarker = paths.caches.appendingPathComponent("marker")
    try Data("owned".utf8).write(to: supportMarker)
    try Data("owned".utf8).write(to: cacheMarker)
    let sibling = root.appendingPathComponent("Support/sibling", isDirectory: true)
    try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: sibling.appendingPathComponent("marker"))

    let keychain = InMemoryKeychainService()
    let keys = InstallationKeyManager(keychain: keychain, service: paths.bundleIdentifier)
    _ = try await keys.installPrivacyKey()
    _ = try await keys.clipboardKeys(createIfMissing: true)
    let report = await LocalDataDeletionService(paths: paths, keys: keys).deleteAllOwnedData()

    #expect(report.succeeded)
    #expect(!FileManager.default.fileExists(atPath: paths.applicationSupport.path))
    #expect(!FileManager.default.fileExists(atPath: paths.caches.path))
    #expect(FileManager.default.fileExists(atPath: sibling.path))
    #expect(await keychain.data(service: paths.bundleIdentifier, account: InstallationKeyManager.installPrivacyAccount) == nil)
    #expect(!LocalDataDeletionService.isExactOwnedRoot(URL(fileURLWithPath: "/"), bundleIdentifier: paths.bundleIdentifier))
}
