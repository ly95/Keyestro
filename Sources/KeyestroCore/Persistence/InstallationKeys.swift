import CryptoKit
import Foundation
import KeyestroDomain

public enum InstallationKeyError: Error, Equatable, Sendable {
    case missingClipboardKey
    case invalidKeyLength(account: String)

    public var descriptor: ErrorDescriptor {
        switch self {
        case .missingClipboardKey:
            ErrorDescriptor(
                code: "keys.clipboardMissing",
                message: "The clipboard encryption key is missing.",
                recoverySuggestion: "Review the recovery screen before deleting or reinitializing clipboard history."
            )
        case .invalidKeyLength:
            ErrorDescriptor(code: "keys.invalidLength", message: "A Keychain item has an invalid length.")
        }
    }
}

public struct ClipboardDerivedKeys: Sendable {
    public let encryption: SymmetricKey
    public let fingerprint: SymmetricKey

    public init(encryption: SymmetricKey, fingerprint: SymmetricKey) {
        self.encryption = encryption
        self.fingerprint = fingerprint
    }
}

public actor InstallationKeyManager {
    public static let installPrivacyAccount = "installPrivacyKey.v1"
    public static let clipboardMasterAccount = "clipboardMasterKey.v1"

    private let keychain: any KeychainServicing
    private let service: String
    private var lockedAccounts = Set<String>()
    private var accountWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    public init(keychain: any KeychainServicing, service: String) {
        self.keychain = keychain
        self.service = service
    }

    public func installPrivacyKey() async throws -> SymmetricKey {
        try await loadOrCreate(account: Self.installPrivacyAccount)
    }

    public func clipboardKeys(createIfMissing: Bool) async throws -> ClipboardDerivedKeys {
        guard let master = try await load(account: Self.clipboardMasterAccount, createIfMissing: createIfMissing) else {
            throw InstallationKeyError.missingClipboardKey
        }

        let encryption = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: master,
            salt: Data(),
            info: Data("Keyestro Clipboard Encryption v1".utf8),
            outputByteCount: 32
        )
        let fingerprint = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: master,
            salt: Data(),
            info: Data("Keyestro Clipboard Fingerprint v1".utf8),
            outputByteCount: 32
        )
        return ClipboardDerivedKeys(encryption: encryption, fingerprint: fingerprint)
    }

    public func deleteClipboardKey() async throws {
        await acquire(account: Self.clipboardMasterAccount)
        defer { release(account: Self.clipboardMasterAccount) }
        try Task.checkCancellation()
        try await keychain.delete(service: service, account: Self.clipboardMasterAccount)
    }

    public func deleteAllInstallationKeys() async throws {
        var firstError: (any Error)?
        for account in [Self.installPrivacyAccount, Self.clipboardMasterAccount] {
            await acquire(account: account)
            var wasCancelled = false
            do {
                try Task.checkCancellation()
                try await keychain.delete(service: service, account: account)
            } catch is CancellationError {
                wasCancelled = true
                if firstError == nil { firstError = CancellationError() }
            } catch {
                if firstError == nil { firstError = error }
            }
            release(account: account)
            if wasCancelled { break }
        }
        if let firstError { throw firstError }
    }

    private func loadOrCreate(account: String) async throws -> SymmetricKey {
        guard let key = try await load(account: account, createIfMissing: true) else {
            throw InstallationKeyError.invalidKeyLength(account: account)
        }
        return key
    }

    private func load(account: String, createIfMissing: Bool) async throws -> SymmetricKey? {
        await acquire(account: account)
        defer { release(account: account) }
        try Task.checkCancellation()
        if let data = try await keychain.data(service: service, account: account) {
            guard data.count == 32 else { throw InstallationKeyError.invalidKeyLength(account: account) }
            return SymmetricKey(data: data)
        }
        guard createIfMissing else { return nil }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try await keychain.setData(data, service: service, account: account)
        return key
    }

    private func acquire(account: String) async {
        guard lockedAccounts.contains(account) else {
            lockedAccounts.insert(account)
            return
        }
        await withCheckedContinuation { continuation in
            accountWaiters[account, default: []].append(continuation)
        }
    }

    private func release(account: String) {
        guard var waiters = accountWaiters[account], !waiters.isEmpty else {
            accountWaiters[account] = nil
            lockedAccounts.remove(account)
            return
        }
        let next = waiters.removeFirst()
        accountWaiters[account] = waiters.isEmpty ? nil : waiters
        next.resume()
    }
}

public enum PrivacyKeyHasher {
    public static func itemKey(for itemID: ItemID, key: SymmetricKey) -> String {
        var data = Data(itemID.providerID.rawValue.utf8)
        data.append(0)
        data.append(Data(itemID.providerStableID.utf8))
        return hex(HMAC<SHA256>.authenticationCode(for: data, using: key))
    }

    public static func fingerprint(for plaintext: Data, key: SymmetricKey) -> String {
        hex(HMAC<SHA256>.authenticationCode(for: plaintext, using: key))
    }

    private static func hex<C: ContiguousBytes>(_ bytes: C) -> String {
        bytes.withUnsafeBytes { buffer in
            buffer.map { String(format: "%02x", $0) }.joined()
        }
    }
}
