import CryptoKit
import Foundation
import KeyestroDomain
import Testing
@testable import KeyestroCore

@Test func installationKeysArePersistentAndSeparated() async throws {
    let keychain = InMemoryKeychainService()
    let manager = InstallationKeyManager(keychain: keychain, service: "com.keyestro.tests")
    let privacyA = try await manager.installPrivacyKey().withUnsafeBytes { Data($0) }
    let privacyB = try await manager.installPrivacyKey().withUnsafeBytes { Data($0) }
    let clipboard = try await manager.clipboardKeys(createIfMissing: true)
    let encryption = clipboard.encryption.withUnsafeBytes { Data($0) }
    let fingerprint = clipboard.fingerprint.withUnsafeBytes { Data($0) }
    #expect(privacyA == privacyB)
    #expect(privacyA != encryption)
    #expect(encryption != fingerprint)
}

@Test func concurrentFirstUseReturnsOneClipboardMasterKeyToEveryCaller() async throws {
    let keychain = SuspendedFirstReadKeychain()
    let manager = InstallationKeyManager(keychain: keychain, service: "com.keyestro.concurrent-key-tests")
    let first = Task { try await clipboardKeyBytes(from: manager) }
    await keychain.waitForFirstRead()
    let second = Task { try await clipboardKeyBytes(from: manager) }

    for _ in 0..<100 { await Task.yield() }
    #expect(await keychain.readCount == 1)
    await keychain.releaseFirstRead()

    let firstValue = try await first.value
    let secondValue = try await second.value
    #expect(firstValue == secondValue)
    #expect(await keychain.writeCount == 1)
    #expect(await keychain.readCount == 2)
}

@Test func clipboardEncryptionBindsItemAndContentType() async throws {
    let manager = InstallationKeyManager(keychain: InMemoryKeychainService(), service: "com.keyestro.tests")
    let keys = try await manager.clipboardKeys(createIfMissing: true)
    let crypto = ClipboardCrypto()
    let plaintext = Data("private clipboard text".utf8)
    let encrypted = try crypto.seal(plaintext, itemID: "one", contentType: "text", keys: keys)
    let independentlyEncrypted = try crypto.seal(plaintext, itemID: "one", contentType: "text", keys: keys)
    #expect(encrypted.ciphertext != plaintext)
    #expect(encrypted.nonce.count == 12)
    #expect(encrypted.nonce != independentlyEncrypted.nonce)
    #expect(try crypto.open(encrypted, itemID: "one", contentType: "text", keys: keys) == plaintext)
    #expect(throws: ClipboardCryptoError.authenticationFailed) {
        try crypto.open(encrypted, itemID: "two", contentType: "text", keys: keys)
    }

    var changedCiphertext = encrypted.ciphertext
    changedCiphertext[changedCiphertext.startIndex] ^= 1
    let tampered = EncryptedClipboardPayload(
        ciphertext: changedCiphertext,
        nonce: encrypted.nonce,
        tag: encrypted.tag,
        fingerprint: encrypted.fingerprint
    )
    #expect(throws: ClipboardCryptoError.authenticationFailed) {
        try crypto.open(tampered, itemID: "one", contentType: "text", keys: keys)
    }
}

@Test func keyedItemIdentifiersDoNotContainRawResource() {
    let key = SymmetricKey(size: .bits256)
    let itemID = ItemID(providerID: "files", providerStableID: "/Users/example/secret.txt")
    let hashed = PrivacyKeyHasher.itemKey(for: itemID, key: key)
    #expect(hashed.count == 64)
    #expect(!hashed.contains("secret"))
    #expect(PrivacyKeyHasher.itemKey(for: itemID, key: key) == hashed)
}

private func clipboardKeyBytes(from manager: InstallationKeyManager) async throws -> [Data] {
    let keys = try await manager.clipboardKeys(createIfMissing: true)
    return [
        keys.encryption.withUnsafeBytes { Data($0) },
        keys.fingerprint.withUnsafeBytes { Data($0) },
    ]
}

private actor SuspendedFirstReadKeychain: KeychainServicing {
    private var values: [String: Data] = [:]
    private var firstReadContinuation: CheckedContinuation<Void, Never>?
    private(set) var readCount = 0
    private(set) var writeCount = 0

    func data(service: String, account: String) async -> Data? {
        readCount += 1
        if readCount == 1 {
            await withCheckedContinuation { firstReadContinuation = $0 }
        }
        return values["\(service)\u{0}\(account)"]
    }

    func setData(_ data: Data, service: String, account: String) {
        writeCount += 1
        values["\(service)\u{0}\(account)"] = data
    }

    func delete(service: String, account: String) {
        values["\(service)\u{0}\(account)"] = nil
    }

    func waitForFirstRead() async {
        while readCount == 0 { await Task.yield() }
    }

    func releaseFirstRead() {
        firstReadContinuation?.resume()
        firstReadContinuation = nil
    }
}
