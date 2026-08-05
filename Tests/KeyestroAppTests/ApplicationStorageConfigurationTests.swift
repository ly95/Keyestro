import Foundation
import KeyestroCore
import Testing
@testable import KeyestroApp

@Test func developerIDConfigurationUsesThePersistentMacKeychainProfile() throws {
    let configuration = ApplicationStorageConfiguration.resolve(
        infoDictionary: [
            "CFBundleIdentifier": ApplicationStorageConfiguration.productionBundleIdentifier,
            ApplicationStorageConfiguration.infoDictionaryKey: ApplicationCredentialStorage.keychain.rawValue,
        ],
        temporaryDirectory: FileManager.default.temporaryDirectory
    )

    #expect(configuration.bundleIdentifier == ApplicationStorageConfiguration.productionBundleIdentifier)
    #expect(configuration.credentialStorage == .keychain)
    #expect(!configuration.isEphemeral)
    #expect(configuration.makeCredentialStore() is MacKeychainService)
}

@Test func localConfigurationUsesIsolatedEphemeralDataAndNeverInstantiatesMacKeychain() throws {
    let fileManager = FileManager.default
    let testRoot = fileManager.temporaryDirectory
        .appendingPathComponent("KeyestroStorageConfigurationTests-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: testRoot, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: testRoot) }
    let runIdentifier = UUID()
    let configuration = ApplicationStorageConfiguration.resolve(
        infoDictionary: [
            "CFBundleIdentifier": ApplicationStorageConfiguration.localBundleIdentifier,
            ApplicationStorageConfiguration.infoDictionaryKey: ApplicationCredentialStorage.ephemeral.rawValue,
        ],
        temporaryDirectory: testRoot,
        runIdentifier: runIdentifier
    )

    #expect(configuration.bundleIdentifier == ApplicationStorageConfiguration.localBundleIdentifier)
    #expect(configuration.credentialStorage == .ephemeral)
    #expect(configuration.isEphemeral)
    #expect(configuration.makeCredentialStore() is InMemoryKeychainService)

    let paths = try configuration.makePaths()
    try paths.prepare()
    let marker = paths.applicationSupport.appendingPathComponent("marker", isDirectory: false)
    try Data("local-only".utf8).write(to: marker)
    #expect(marker.path.hasPrefix(testRoot.standardizedFileURL.path + "/"))

    try configuration.removeEphemeralData(fileManager: fileManager)
    #expect(!fileManager.fileExists(atPath: marker.path))
    #expect(fileManager.fileExists(atPath: testRoot.path))
}

@Test func missingOrInvalidProductionStorageMarkerFailsClosedToEphemeralStorage() {
    let temporaryDirectory = FileManager.default.temporaryDirectory
    let missingMarker = ApplicationStorageConfiguration.resolve(
        infoDictionary: [
            "CFBundleIdentifier": ApplicationStorageConfiguration.productionBundleIdentifier
        ],
        temporaryDirectory: temporaryDirectory
    )
    let invalidBundle = ApplicationStorageConfiguration.resolve(
        infoDictionary: [
            "CFBundleIdentifier": "../com.keyestro.launcher",
            ApplicationStorageConfiguration.infoDictionaryKey: ApplicationCredentialStorage.keychain.rawValue,
        ],
        temporaryDirectory: temporaryDirectory
    )

    #expect(missingMarker.credentialStorage == .ephemeral)
    #expect(missingMarker.makeCredentialStore() is InMemoryKeychainService)
    #expect(invalidBundle.bundleIdentifier == ApplicationStorageConfiguration.localBundleIdentifier)
    #expect(invalidBundle.credentialStorage == .ephemeral)
    #expect(invalidBundle.makeCredentialStore() is InMemoryKeychainService)
}
