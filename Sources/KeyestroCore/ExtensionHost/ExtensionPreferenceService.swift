import Foundation
import KeyestroDomain

/// Stable validation and persistence failures for extension preferences.
public enum ExtensionPreferenceError: Error, Equatable, Sendable {
    case extensionUnavailable
    case undeclaredPreference
    case invalidValue
    case corruptStoredValue
    case secretUnavailable
    case staleRegistration
    case rollbackFailed

    public var descriptor: ErrorDescriptor {
        switch self {
        case .extensionUnavailable:
            ErrorDescriptor(code: "extension.preference.extensionUnavailable", message: "The extension is unavailable.")
        case .undeclaredPreference:
            ErrorDescriptor(code: "extension.preference.undeclared", message: "The extension did not declare this preference.")
        case .invalidValue:
            ErrorDescriptor(code: "extension.preference.invalidValue", message: "The preference value is invalid.")
        case .corruptStoredValue:
            ErrorDescriptor(
                code: "extension.preference.corrupt",
                message: "A stored extension preference is invalid.",
                recoverySuggestion: "Clear the preference and set it again."
            )
        case .secretUnavailable:
            ErrorDescriptor(
                code: "extension.preference.secretUnavailable",
                message: "The extension secret is no longer available in Keychain.",
                recoverySuggestion: "Clear the preference and set it again."
            )
        case .staleRegistration:
            ErrorDescriptor(
                code: "extension.preference.staleRegistration",
                message: "The extension changed after this preference was reviewed.",
                recoverySuggestion: "Review the current extension preferences and try again."
            )
        case .rollbackFailed:
            ErrorDescriptor(
                code: "extension.preference.rollbackFailed",
                message: "The extension preference could not be restored after a storage failure.",
                recoverySuggestion: "Review the preference and set it again."
            )
        }
    }
}

/// A host-visible preference state that never exposes a stored password in settings UI.
public struct ExtensionPreferenceState: Equatable, Sendable {
    public let value: JSONValue?
    public let isSet: Bool
    public let isSecret: Bool

    public init(value: JSONValue?, isSet: Bool, isSecret: Bool) {
        self.value = value
        self.isSet = isSet
        self.isSecret = isSecret
    }
}

/// Owns extension preference validation and keeps secret values out of SQLite.
public actor ExtensionPreferenceService {
    public static let keychainServiceSuffix = ".extension-preferences"

    private let store: any ExtensionStoring
    private let keychain: any KeychainServicing
    private let keychainService: String
    private var operationInProgress = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    private struct PreferenceSnapshot: Sendable {
        let record: ExtensionPreferenceRecord
        let secretData: Data?
    }

    public init(store: any ExtensionStoring, keychain: any KeychainServicing, bundleIdentifier: String) {
        self.store = store
        self.keychain = keychain
        keychainService = bundleIdentifier + Self.keychainServiceSuffix
    }

    public func states(extensionID: String) async throws -> [String: ExtensionPreferenceState] {
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()

        let registration = try await registration(extensionID: extensionID)
        let records = try await store.extensionPreferences(extensionID: extensionID)
        let recordsByName = Dictionary(uniqueKeysWithValues: records.map { ($0.name, $0) })
        var output: [String: ExtensionPreferenceState] = [:]
        for declaration in registration.manifest.preferences {
            guard let record = recordsByName[declaration.name] else {
                output[declaration.name] = ExtensionPreferenceState(
                    value: nil,
                    isSet: false,
                    isSecret: declaration.type == .password
                )
                continue
            }
            if declaration.type == .password {
                guard record.isSecret, record.valueJSON == nil else {
                    throw ExtensionPreferenceError.corruptStoredValue
                }
                let secret = try await keychain.data(
                    service: keychainService,
                    account: Self.keychainAccount(extensionID: extensionID, name: declaration.name)
                )
                output[declaration.name] = ExtensionPreferenceState(
                    value: nil,
                    isSet: secret != nil,
                    isSecret: true
                )
            } else {
                guard !record.isSecret, let valueJSON = record.valueJSON,
                    let value = try? JSONDecoder().decode(JSONValue.self, from: valueJSON),
                    Self.isValid(value, for: declaration)
                else { throw ExtensionPreferenceError.corruptStoredValue }
                output[declaration.name] = ExtensionPreferenceState(value: value, isSet: true, isSecret: false)
            }
        }
        return output
    }

    public func read(extensionID: String, name: String) async throws -> JSONValue? {
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()

        let declaration = try await declaration(extensionID: extensionID, name: name)
        guard let record = try await store.extensionPreference(extensionID: extensionID, name: name) else {
            return nil
        }
        if declaration.type == .password {
            guard record.isSecret, record.valueJSON == nil else {
                throw ExtensionPreferenceError.corruptStoredValue
            }
            guard
                let secret = try await keychain.data(
                    service: keychainService,
                    account: Self.keychainAccount(extensionID: extensionID, name: name)
                ), let value = String(data: secret, encoding: .utf8)
            else { throw ExtensionPreferenceError.secretUnavailable }
            return .string(value)
        }
        guard !record.isSecret, let valueJSON = record.valueJSON,
            let value = try? JSONDecoder().decode(JSONValue.self, from: valueJSON),
            Self.isValid(value, for: declaration)
        else { throw ExtensionPreferenceError.corruptStoredValue }
        return value
    }

    public func set(_ value: JSONValue, extensionID: String, name: String) async throws {
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()

        let declaration = try await declaration(extensionID: extensionID, name: name)
        guard Self.isValid(value, for: declaration) else { throw ExtensionPreferenceError.invalidValue }
        let account = Self.keychainAccount(extensionID: extensionID, name: name)
        let existingSecret = try await keychain.data(service: keychainService, account: account)

        if declaration.type == .password {
            guard case let .string(secret) = value else { throw ExtensionPreferenceError.invalidValue }
            try await keychain.setData(Data(secret.utf8), service: keychainService, account: account)
            do {
                try await store.saveExtensionPreference(
                    ExtensionPreferenceRecord(extensionID: extensionID, name: name, valueJSON: nil, isSecret: true)
                )
            } catch {
                do {
                    try await restoreKeychain(existingSecret, account: account)
                } catch {
                    throw ExtensionPreferenceError.rollbackFailed
                }
                throw error
            }
        } else {
            let encoded = try JSONEncoder().encode(value)
            guard encoded.count <= 16 * 1_024 else { throw ExtensionPreferenceError.invalidValue }
            if existingSecret != nil {
                try await keychain.delete(service: keychainService, account: account)
            }
            do {
                try await store.saveExtensionPreference(
                    ExtensionPreferenceRecord(extensionID: extensionID, name: name, valueJSON: encoded, isSecret: false)
                )
            } catch {
                do {
                    try await restoreKeychain(existingSecret, account: account)
                } catch {
                    throw ExtensionPreferenceError.rollbackFailed
                }
                throw error
            }
        }
    }

    public func remove(extensionID: String, name: String) async throws {
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()

        _ = try await declaration(extensionID: extensionID, name: name)
        guard let record = try await store.extensionPreference(extensionID: extensionID, name: name) else { return }
        try await remove(record)
    }

    /// Removes a value only while the installed payload is still the one shown in
    /// the destructive confirmation. This prevents an old settings window from
    /// clearing a same-named preference after an extension upgrade.
    public func remove(ifCurrentMatches registration: ExtensionRegistration, name: String) async throws {
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()

        guard
            let current = try await store.extensionRegistration(id: registration.id),
            current.sameInstalledPayload(as: registration)
        else { throw ExtensionPreferenceError.staleRegistration }
        guard current.manifest.preferences.contains(where: { $0.name == name }) else {
            throw ExtensionPreferenceError.undeclaredPreference
        }
        guard let record = try await store.extensionPreference(extensionID: registration.id, name: name) else {
            return
        }
        try await remove(record)
    }

    public func removeAll(extensionID: String) async throws {
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()

        let snapshots = try await preferenceSnapshots(extensionID: extensionID)
        do {
            try await remove(snapshots)
        } catch let removalError {
            do {
                try await restore(snapshots)
            } catch {
                throw ExtensionPreferenceError.rollbackFailed
            }
            throw removalError
        }
    }

    /// Keeps preference removal compensating if a later extension-unregistration step fails.
    public func removeAll(
        extensionID: String,
        whilePerforming operation: @Sendable () async throws -> Void
    ) async throws {
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()

        let snapshots = try await preferenceSnapshots(extensionID: extensionID)
        do {
            try await remove(snapshots)
            try await operation()
        } catch let operationError {
            // A cleanup error after authoritative unregistration must not resurrect orphaned
            // preference rows. Only compensate while the extension still exists.
            let extensionStillRegistered: Bool
            do {
                extensionStillRegistered = try await store.extensionRegistration(id: extensionID) != nil
            } catch {
                // If registration state cannot be read, prefer an explicit failed compensation
                // over silently discarding preferences that may still belong to an installed extension.
                do {
                    try await restore(snapshots)
                } catch {
                    throw ExtensionPreferenceError.rollbackFailed
                }
                throw operationError
            }
            guard extensionStillRegistered else { throw operationError }
            do {
                try await restore(snapshots)
            } catch {
                throw ExtensionPreferenceError.rollbackFailed
            }
            throw operationError
        }
    }

    /// Deletes secrets before the bundle-owned database is removed by the all-data workflow.
    public func deleteAllKnownSecrets() async throws {
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()

        var firstError: (any Error)?
        for record in try await store.extensionPreferences(extensionID: nil) where record.isSecret {
            do {
                try Task.checkCancellation()
                try await keychain.delete(
                    service: keychainService,
                    account: Self.keychainAccount(extensionID: record.extensionID, name: record.name)
                )
            } catch {
                if error is CancellationError { throw error }
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    public static func keychainAccount(extensionID: String, name: String) -> String {
        "\(extensionID):\(name)"
    }

    private func registration(extensionID: String) async throws -> ExtensionRegistration {
        guard let registration = try await store.extensionRegistration(id: extensionID) else {
            throw ExtensionPreferenceError.extensionUnavailable
        }
        return registration
    }

    private func declaration(extensionID: String, name: String) async throws -> ExtensionPreferenceManifest {
        let registration = try await registration(extensionID: extensionID)
        guard let declaration = registration.manifest.preferences.first(where: { $0.name == name }) else {
            throw ExtensionPreferenceError.undeclaredPreference
        }
        return declaration
    }

    private func remove(_ record: ExtensionPreferenceRecord) async throws {
        let account = Self.keychainAccount(extensionID: record.extensionID, name: record.name)
        let existingSecret =
            record.isSecret
            ? try await keychain.data(service: keychainService, account: account)
            : nil
        if record.isSecret {
            try await keychain.delete(service: keychainService, account: account)
        }
        do {
            try await store.deleteExtensionPreference(extensionID: record.extensionID, name: record.name)
        } catch {
            do {
                try await restoreKeychain(existingSecret, account: account)
            } catch {
                throw ExtensionPreferenceError.rollbackFailed
            }
            throw error
        }
    }

    private func preferenceSnapshots(extensionID: String) async throws -> [PreferenceSnapshot] {
        var snapshots: [PreferenceSnapshot] = []
        for record in try await store.extensionPreferences(extensionID: extensionID) {
            let secretData =
                record.isSecret
                ? try await keychain.data(
                    service: keychainService,
                    account: Self.keychainAccount(extensionID: record.extensionID, name: record.name)
                )
                : nil
            snapshots.append(PreferenceSnapshot(record: record, secretData: secretData))
        }
        return snapshots
    }

    private func remove(_ snapshots: [PreferenceSnapshot]) async throws {
        for snapshot in snapshots {
            try Task.checkCancellation()
            try await remove(snapshot.record)
        }
    }

    private func restore(_ snapshots: [PreferenceSnapshot]) async throws {
        var firstError: (any Error)?
        for snapshot in snapshots {
            do {
                if snapshot.record.isSecret {
                    try await restoreKeychain(
                        snapshot.secretData,
                        account: Self.keychainAccount(
                            extensionID: snapshot.record.extensionID,
                            name: snapshot.record.name
                        )
                    )
                }
                try await store.saveExtensionPreference(snapshot.record)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    private func restoreKeychain(_ data: Data?, account: String) async throws {
        if let data {
            try await keychain.setData(data, service: keychainService, account: account)
        } else {
            try await keychain.delete(service: keychainService, account: account)
        }
    }

    private func acquireOperation() async {
        guard operationInProgress else {
            operationInProgress = true
            return
        }
        await withCheckedContinuation { operationWaiters.append($0) }
    }

    private func releaseOperation() {
        guard !operationWaiters.isEmpty else {
            operationInProgress = false
            return
        }
        operationWaiters.removeFirst().resume()
    }

    private static func isValid(_ value: JSONValue, for declaration: ExtensionPreferenceManifest) -> Bool {
        switch (declaration.type, value) {
        case let (.text, .string(text)), let (.password, .string(text)):
            return text.unicodeScalars.count <= 8_192 && (!declaration.required || !text.isEmpty)
        case let (.choice, .string(choice)):
            return declaration.choices.contains(choice)
        case let (.file, .string(path)), let (.directory, .string(path)):
            return !path.contains("\u{0}") && path.utf8.count <= 4_096
                && path.hasPrefix("/") && (!declaration.required || path.count > 1)
        case (.toggle, .bool):
            return true
        default:
            return false
        }
    }
}
