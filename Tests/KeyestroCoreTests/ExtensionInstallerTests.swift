import Foundation
import KeyestroDomain
import Testing
@testable import KeyestroCore

@Test func extensionUpgradeSwitchesOnlyAfterValidationAndPreservesTheOldVersionOnStoreFailure() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyestro-extension-upgrade-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        bundleIdentifier: "com.keyestro.extension-upgrade-tests",
        applicationSupportRoot: root.appendingPathComponent("support", isDirectory: true),
        cachesRoot: root.appendingPathComponent("cache", isDirectory: true)
    )
    let versionOne = try makeExtensionPackage(root: root, version: "1.0.0", output: "one")
    let versionTwo = try makeExtensionPackage(root: root, version: "2.0.0", output: "two")
    let store = ControllableExtensionStore()
    let installer = ExtensionInstaller(paths: paths, store: store)

    let inspectedOriginal = try await installer.inspect(sourceRoot: versionOne)
    let copiedProbe = root.appendingPathComponent("copied-probe", isDirectory: true)
    try FileManager.default.copyItem(at: versionOne, to: copiedProbe)
    let inspectedCopy = try await installer.inspect(sourceRoot: copiedProbe)
    #expect(inspectedCopy.contentHash == inspectedOriginal.contentHash)
    let installedOne = try await installer.install(sourceRoot: versionOne, enable: true)
    #expect(await store.extensionRegistration(id: installedOne.id) == installedOne)
    #expect(FileManager.default.fileExists(atPath: installedOne.installPath))
    #expect(
        installedOne.manifestJSON
            == (try Data(
                contentsOf: URL(fileURLWithPath: installedOne.installPath)
                    .appendingPathComponent("extension.json", isDirectory: false)
            ))
    )

    await store.setRejectSaves(true)
    await #expect(throws: ControllableExtensionStore.Failure.rejected) {
        try await installer.install(sourceRoot: versionTwo, enable: true)
    }
    let versionTwoDestination = paths.extensions
        .appendingPathComponent(installedOne.id, isDirectory: true)
        .appendingPathComponent("2.0.0", isDirectory: true)
    #expect(await store.extensionRegistration(id: installedOne.id) == installedOne)
    #expect(FileManager.default.fileExists(atPath: installedOne.installPath))
    #expect(!FileManager.default.fileExists(atPath: versionTwoDestination.path))

    await store.setRejectSaves(false)
    let installedTwo = try await installer.install(sourceRoot: versionTwo, enable: true)
    #expect(await store.extensionRegistration(id: installedOne.id) == installedTwo)
    #expect(FileManager.default.fileExists(atPath: installedOne.installPath))
    #expect(FileManager.default.fileExists(atPath: installedTwo.installPath))

    do {
        try await installer.remove(installedOne)
        Issue.record("Expected the stale version snapshot to be rejected")
    } catch let descriptor as ErrorDescriptor {
        #expect(descriptor.code == "extensions.staleRegistration")
    }
    #expect(await store.extensionRegistration(id: installedOne.id) == installedTwo)
    #expect(FileManager.default.fileExists(atPath: installedOne.installPath))
    #expect(FileManager.default.fileExists(atPath: installedTwo.installPath))

    await store.setRejectDeletes(true)
    await #expect(throws: ControllableExtensionStore.Failure.rejected) {
        try await installer.remove(installedTwo)
    }
    #expect(await store.extensionRegistration(id: installedOne.id) == installedTwo)
    #expect(FileManager.default.fileExists(atPath: installedOne.installPath))
    #expect(FileManager.default.fileExists(atPath: installedTwo.installPath))

    await store.setRejectDeletes(false)
    try await installer.remove(installedTwo)
    #expect(await store.extensionRegistration(id: installedOne.id) == nil)
    #expect(!FileManager.default.fileExists(atPath: installedOne.installPath))
    #expect(!FileManager.default.fileExists(atPath: installedTwo.installPath))
}

private func makeExtensionPackage(root: URL, version: String, output: String) throws -> URL {
    let package = root.appendingPathComponent("source-\(version).extension", isDirectory: true)
    let bin = package.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let executable = bin.appendingPathComponent("extension", isDirectory: false)
    try Data("#!/bin/sh\nprintf '%s\\n' '\(output)'\n".utf8).write(to: executable, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let manifest = ExtensionManifest(
        id: "com.example.atomic-upgrade",
        name: "Atomic Upgrade",
        version: version,
        description: "Upgrade fixture",
        author: "Keyestro",
        license: "MIT",
        executable: "bin/extension",
        minimumHostVersion: "0.1.0"
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(manifest).write(
        to: package.appendingPathComponent("extension.json", isDirectory: false),
        options: .atomic
    )
    return package
}

private actor ControllableExtensionStore: ExtensionStoring {
    enum Failure: Error { case rejected }

    private var registrations: [String: ExtensionRegistration] = [:]
    private var rejectSaves = false
    private var rejectDeletes = false

    func setRejectSaves(_ reject: Bool) { rejectSaves = reject }
    func setRejectDeletes(_ reject: Bool) { rejectDeletes = reject }
    func allExtensions() -> [ExtensionRegistration] { Array(registrations.values) }
    func extensionRegistration(id: String) -> ExtensionRegistration? { registrations[id] }

    func saveExtension(_ registration: ExtensionRegistration) throws {
        if rejectSaves { throw Failure.rejected }
        registrations[registration.id] = registration
    }

    func deleteExtension(id: String) throws {
        if rejectDeletes { throw Failure.rejected }
        registrations[id] = nil
    }
    func deleteExtension(ifCurrentMatches registration: ExtensionRegistration) throws -> Bool {
        if rejectDeletes { throw Failure.rejected }
        guard registrations[registration.id]?.sameInstalledPayload(as: registration) == true else { return false }
        registrations[registration.id] = nil
        return true
    }
    func extensionPreference(extensionID: String, name: String) -> ExtensionPreferenceRecord? { nil }
    func extensionPreferences(extensionID: String?) -> [ExtensionPreferenceRecord] { [] }
    func saveExtensionPreference(_ preference: ExtensionPreferenceRecord) {}
    func deleteExtensionPreference(extensionID: String, name: String) {}
}
