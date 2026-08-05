import Foundation
import Testing
@testable import KeyestroCore

@Test func extensionPreferencesKeepSecretsOutOfSQLiteAndRemoveTheirKeychainValues() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyestro-extension-preferences-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        bundleIdentifier: "com.keyestro.extension-preference-tests",
        applicationSupportRoot: root.appendingPathComponent("support", isDirectory: true),
        cachesRoot: root.appendingPathComponent("cache", isDirectory: true)
    )
    let database = LauncherDatabase(paths: paths)
    let manifest = ExtensionManifest(
        id: "com.example.preferences",
        name: "Preferences",
        version: "1.0.0",
        description: "Preference test",
        author: "Keyestro",
        license: "MIT",
        executable: "bin/extension",
        minimumHostVersion: "0.1.0",
        preferences: [
            ExtensionPreferenceManifest(name: "label", title: "Label", type: .text, required: true),
            ExtensionPreferenceManifest(name: "token", title: "Token", type: .password, required: true),
            ExtensionPreferenceManifest(
                name: "color",
                title: "Color",
                type: .choice,
                required: true,
                choices: ["blue", "green"]
            ),
        ]
    )
    try manifest.validateMetadata()
    try await database.saveExtension(
        ExtensionRegistration(
            manifest: manifest,
            installPath: "/tmp/com.example.preferences/1.0.0",
            manifestJSON: try JSONEncoder().encode(manifest),
            contentHash: String(repeating: "a", count: 64),
            enabled: true
        )
    )
    let keychain = InMemoryKeychainService()
    let service = ExtensionPreferenceService(
        store: database,
        keychain: keychain,
        bundleIdentifier: paths.bundleIdentifier
    )

    try await service.set(.string("visible"), extensionID: manifest.id, name: "label")
    try await service.set(.string("top-secret"), extensionID: manifest.id, name: "token")
    #expect(try await service.read(extensionID: manifest.id, name: "label") == .string("visible"))
    #expect(try await service.read(extensionID: manifest.id, name: "token") == .string("top-secret"))

    let records = try await database.extensionPreferences(extensionID: manifest.id)
    let secretRecord = try #require(records.first(where: { $0.name == "token" }))
    #expect(secretRecord.isSecret)
    #expect(secretRecord.valueJSON == nil)
    let labelRecord = try #require(records.first(where: { $0.name == "label" }))
    #expect(!labelRecord.isSecret)
    #expect(labelRecord.valueJSON != nil)
    let states = try await service.states(extensionID: manifest.id)
    #expect(states["token"] == ExtensionPreferenceState(value: nil, isSet: true, isSecret: true))

    await #expect(throws: PreferenceRemovalFailure.rejected) {
        try await service.removeAll(
            extensionID: manifest.id,
            whilePerforming: {
                throw PreferenceRemovalFailure.rejected
            })
    }
    #expect(try await service.read(extensionID: manifest.id, name: "label") == .string("visible"))
    #expect(try await service.read(extensionID: manifest.id, name: "token") == .string("top-secret"))

    let keychainService = paths.bundleIdentifier + ExtensionPreferenceService.keychainServiceSuffix
    let keychainAccount = ExtensionPreferenceService.keychainAccount(extensionID: manifest.id, name: "token")
    await keychain.delete(service: keychainService, account: keychainAccount)
    let missingSecretStates = try await service.states(extensionID: manifest.id)
    #expect(missingSecretStates["token"] == ExtensionPreferenceState(value: nil, isSet: false, isSecret: true))
    await #expect(throws: ExtensionPreferenceError.secretUnavailable) {
        try await service.read(extensionID: manifest.id, name: "token")
    }
    try await service.set(.string("replacement-secret"), extensionID: manifest.id, name: "token")

    await #expect(throws: ExtensionPreferenceError.invalidValue) {
        try await service.set(.string("red"), extensionID: manifest.id, name: "color")
    }
    await #expect(throws: ExtensionPreferenceError.undeclaredPreference) {
        try await service.set(.string("value"), extensionID: manifest.id, name: "undeclared")
    }

    try await service.removeAll(extensionID: manifest.id)
    #expect(try await database.extensionPreferences(extensionID: manifest.id).isEmpty)
    #expect(
        await keychain.data(
            service: keychainService,
            account: keychainAccount
        ) == nil
    )
}

@Test func extensionManifestValidatesPreferenceIdentifiersAndChoices() {
    let invalidName = ExtensionManifest(
        id: "com.example.invalid-name",
        name: "Invalid",
        version: "1.0.0",
        description: "test",
        author: "test",
        license: "MIT",
        executable: "bin/extension",
        minimumHostVersion: "0.1.0",
        preferences: [
            ExtensionPreferenceManifest(name: "bad:name", title: "Bad", type: .text, required: false)
        ]
    )
    #expect(throws: ExtensionValidationError.invalidManifest) { try invalidName.validateMetadata() }

    let missingChoices = ExtensionManifest(
        id: "com.example.missing-choices",
        name: "Invalid",
        version: "1.0.0",
        description: "test",
        author: "test",
        license: "MIT",
        executable: "bin/extension",
        minimumHostVersion: "0.1.0",
        preferences: [
            ExtensionPreferenceManifest(name: "mode", title: "Mode", type: .choice, required: false)
        ]
    )
    #expect(throws: ExtensionValidationError.invalidManifest) { try missingChoices.validateMetadata() }
}

@Test func concurrentExtensionSecretWritesCannotBeClobberedByAnEarlierRollback() async throws {
    let registration = try preferenceTestRegistration()
    let store = CoordinatedPreferenceStore(registration: registration, behavior: .suspendFirstThenReject)
    let service = ExtensionPreferenceService(
        store: store,
        keychain: InMemoryKeychainService(),
        bundleIdentifier: "com.keyestro.preference-concurrency-tests"
    )

    let first = Task {
        try await service.set(.string("first"), extensionID: registration.id, name: "token")
    }
    await store.waitForFirstSave()
    let second = Task {
        try await service.set(.string("second"), extensionID: registration.id, name: "token")
    }

    for _ in 0..<100 { await Task.yield() }
    #expect(await store.preferenceSaveCount == 1)
    await store.releaseFirstSave()

    await #expect(throws: CoordinatedPreferenceStore.Failure.rejected) {
        try await first.value
    }
    try await second.value
    #expect(try await service.read(extensionID: registration.id, name: "token") == .string("second"))
    #expect(await store.preferenceSaveCount == 2)
}

@Test func extensionPreferenceReportsWhenStorageRollbackCannotRestoreKeychain() async throws {
    let registration = try preferenceTestRegistration()
    let store = CoordinatedPreferenceStore(registration: registration, behavior: .reject)
    let service = ExtensionPreferenceService(
        store: store,
        keychain: RollbackRejectingKeychain(),
        bundleIdentifier: "com.keyestro.preference-rollback-tests"
    )

    await #expect(throws: ExtensionPreferenceError.rollbackFailed) {
        try await service.set(.string("secret"), extensionID: registration.id, name: "token")
    }
    #expect(ExtensionPreferenceError.rollbackFailed.descriptor.code == "extension.preference.rollbackFailed")
}

@Test func stalePreferenceConfirmationCannotClearAValueAfterExtensionUpgrade() async throws {
    let reviewed = try preferenceTestRegistration()
    let store = InMemoryExtensionStore(registrations: [reviewed])
    let keychain = InMemoryKeychainService()
    let service = ExtensionPreferenceService(
        store: store,
        keychain: keychain,
        bundleIdentifier: "com.keyestro.preference-stale-tests"
    )
    try await service.set(.string("keep-me"), extensionID: reviewed.id, name: "token")

    let replacementManifest = ExtensionManifest(
        id: reviewed.id,
        name: "Preference Concurrency",
        version: "2.0.0",
        description: "Upgraded preference fixture",
        author: "Keyestro",
        license: "MIT",
        executable: "bin/extension",
        minimumHostVersion: "0.1.0",
        preferences: [
            ExtensionPreferenceManifest(name: "token", title: "Replacement Token", type: .password, required: true)
        ]
    )
    try replacementManifest.validateMetadata()
    let replacement = ExtensionRegistration(
        manifest: replacementManifest,
        installPath: "/tmp/com.example.preference-concurrency/2.0.0",
        manifestJSON: try JSONEncoder().encode(replacementManifest),
        contentHash: String(repeating: "c", count: 64),
        enabled: true
    )
    await store.saveExtension(replacement)

    await #expect(throws: ExtensionPreferenceError.staleRegistration) {
        try await service.remove(ifCurrentMatches: reviewed, name: "token")
    }
    #expect(try await service.read(extensionID: replacement.id, name: "token") == .string("keep-me"))
}

private func preferenceTestRegistration() throws -> ExtensionRegistration {
    let manifest = ExtensionManifest(
        id: "com.example.preference-concurrency",
        name: "Preference Concurrency",
        version: "1.0.0",
        description: "Preference consistency fixture",
        author: "Keyestro",
        license: "MIT",
        executable: "bin/extension",
        minimumHostVersion: "0.1.0",
        preferences: [
            ExtensionPreferenceManifest(name: "token", title: "Token", type: .password, required: true)
        ]
    )
    try manifest.validateMetadata()
    return ExtensionRegistration(
        manifest: manifest,
        installPath: "/tmp/com.example.preference-concurrency/1.0.0",
        manifestJSON: try JSONEncoder().encode(manifest),
        contentHash: String(repeating: "b", count: 64),
        enabled: true
    )
}

private actor CoordinatedPreferenceStore: ExtensionStoring {
    enum Failure: Error { case rejected }
    enum SaveBehavior: Sendable { case normal, reject, suspendFirstThenReject }

    private var registration: ExtensionRegistration?
    private var record: ExtensionPreferenceRecord?
    private let behavior: SaveBehavior
    private var firstSaveContinuation: CheckedContinuation<Void, Never>?
    private(set) var preferenceSaveCount = 0

    init(registration: ExtensionRegistration, behavior: SaveBehavior) {
        self.registration = registration
        self.behavior = behavior
    }

    func allExtensions() -> [ExtensionRegistration] { registration.map { [$0] } ?? [] }
    func extensionRegistration(id: String) -> ExtensionRegistration? {
        registration?.id == id ? registration : nil
    }
    func saveExtension(_ registration: ExtensionRegistration) { self.registration = registration }
    func deleteExtension(id: String) {
        guard registration?.id == id else { return }
        registration = nil
        record = nil
    }
    func deleteExtension(ifCurrentMatches candidate: ExtensionRegistration) -> Bool {
        guard registration?.sameInstalledPayload(as: candidate) == true else { return false }
        registration = nil
        record = nil
        return true
    }
    func extensionPreference(extensionID: String, name: String) -> ExtensionPreferenceRecord? {
        guard record?.extensionID == extensionID, record?.name == name else { return nil }
        return record
    }
    func extensionPreferences(extensionID: String?) -> [ExtensionPreferenceRecord] {
        guard let record, extensionID == nil || record.extensionID == extensionID else { return [] }
        return [record]
    }
    func saveExtensionPreference(_ preference: ExtensionPreferenceRecord) async throws {
        preferenceSaveCount += 1
        switch behavior {
        case .normal:
            record = preference
        case .reject:
            throw Failure.rejected
        case .suspendFirstThenReject where preferenceSaveCount == 1:
            await withCheckedContinuation { firstSaveContinuation = $0 }
            throw Failure.rejected
        case .suspendFirstThenReject:
            record = preference
        }
    }
    func deleteExtensionPreference(extensionID: String, name: String) {
        guard record?.extensionID == extensionID, record?.name == name else { return }
        record = nil
    }
    func waitForFirstSave() async {
        while preferenceSaveCount == 0 { await Task.yield() }
    }
    func releaseFirstSave() {
        firstSaveContinuation?.resume()
        firstSaveContinuation = nil
    }
}

private actor RollbackRejectingKeychain: KeychainServicing {
    enum Failure: Error { case rejected }

    private var values: [String: Data] = [:]

    func data(service: String, account: String) -> Data? {
        values["\(service)\u{0}\(account)"]
    }
    func setData(_ data: Data, service: String, account: String) {
        values["\(service)\u{0}\(account)"] = data
    }
    func delete(service: String, account: String) throws {
        throw Failure.rejected
    }
}

private enum PreferenceRemovalFailure: Error {
    case rejected
}
