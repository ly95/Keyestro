import CryptoKit
import Foundation
import KeyestroDomain

public struct EncryptedClipboardPayload: Equatable, Sendable {
    public let ciphertext: Data
    public let nonce: Data
    public let tag: Data
    public let fingerprint: String

    public init(ciphertext: Data, nonce: Data, tag: Data, fingerprint: String) {
        self.ciphertext = ciphertext
        self.nonce = nonce
        self.tag = tag
        self.fingerprint = fingerprint
    }
}

public enum ClipboardCryptoError: Error, Equatable, Sendable {
    case invalidNonce
    case authenticationFailed

    public var descriptor: ErrorDescriptor {
        switch self {
        case .invalidNonce:
            ErrorDescriptor(code: "clipboard.invalidNonce", message: "The encrypted clipboard nonce is invalid.")
        case .authenticationFailed:
            ErrorDescriptor(code: "clipboard.authenticationFailed", message: "The clipboard item failed authentication.")
        }
    }
}

public struct ClipboardCrypto: Sendable {
    public init() {}

    public func seal(
        _ plaintext: Data,
        itemID: String,
        contentType: String,
        keys: ClipboardDerivedKeys
    ) throws -> EncryptedClipboardPayload {
        let aad = Self.additionalAuthenticatedData(itemID: itemID, contentType: contentType)
        let sealed = try AES.GCM.seal(plaintext, using: keys.encryption, authenticating: aad)
        return EncryptedClipboardPayload(
            ciphertext: sealed.ciphertext,
            nonce: sealed.nonce.withUnsafeBytes { Data($0) },
            tag: sealed.tag,
            fingerprint: PrivacyKeyHasher.fingerprint(for: plaintext, key: keys.fingerprint)
        )
    }

    public func open(
        _ payload: EncryptedClipboardPayload,
        itemID: String,
        contentType: String,
        keys: ClipboardDerivedKeys
    ) throws -> Data {
        do {
            let nonce = try AES.GCM.Nonce(data: payload.nonce)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: payload.ciphertext, tag: payload.tag)
            return try AES.GCM.open(
                box,
                using: keys.encryption,
                authenticating: Self.additionalAuthenticatedData(itemID: itemID, contentType: contentType)
            )
        } catch let error as ClipboardCryptoError {
            throw error
        } catch {
            if payload.nonce.count != 12 { throw ClipboardCryptoError.invalidNonce }
            throw ClipboardCryptoError.authenticationFailed
        }
    }

    private static func additionalAuthenticatedData(itemID: String, contentType: String) -> Data {
        var data = Data(itemID.utf8)
        data.append(0)
        data.append(Data(contentType.utf8))
        return data
    }
}
