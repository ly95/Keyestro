import Foundation
import KeyestroDomain
import Security

public enum KeychainServiceError: Error, Equatable, Sendable {
    case unexpectedStatus(OSStatus)
    case invalidData

    public var descriptor: ErrorDescriptor {
        switch self {
        case let .unexpectedStatus(status):
            ErrorDescriptor(
                code: "keychain.status.\(status)",
                message: "Keychain could not complete the request."
            )
        case .invalidData:
            ErrorDescriptor(code: "keychain.invalidData", message: "The Keychain item has an invalid format.")
        }
    }
}

public protocol KeychainServicing: Sendable {
    func data(service: String, account: String) async throws -> Data?
    func setData(_ data: Data, service: String, account: String) async throws
    func delete(service: String, account: String) async throws
}

public actor MacKeychainService: KeychainServicing {
    public init() {}

    public func data(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainServiceError.unexpectedStatus(status) }
        guard let data = result as? Data else { throw KeychainServiceError.invalidData }
        return data
    }

    public func setData(_ data: Data, service: String, account: String) throws {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(identity as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainServiceError.unexpectedStatus(updateStatus)
        }

        var newItem = identity
        newItem[kSecValueData as String] = data
        newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(newItem as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainServiceError.unexpectedStatus(addStatus) }
    }

    public func delete(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainServiceError.unexpectedStatus(status)
        }
    }
}

public actor InMemoryKeychainService: KeychainServicing {
    private var values: [String: Data] = [:]

    public init() {}

    public func data(service: String, account: String) -> Data? {
        values["\(service)\u{0}\(account)"]
    }

    public func setData(_ data: Data, service: String, account: String) {
        values["\(service)\u{0}\(account)"] = data
    }

    public func delete(service: String, account: String) {
        values["\(service)\u{0}\(account)"] = nil
    }
}
