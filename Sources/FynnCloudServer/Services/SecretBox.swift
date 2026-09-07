import Crypto
import Foundation
import Vapor

/// Authenticated symmetric encryption for secrets stored at rest (currently TOTP seeds).
/// Uses AES-GCM with a key derived from the configured `ENCRYPTION_KEY`, so a raw database
/// dump alone cannot recover the plaintext without the application key.
struct SecretBox: Sendable {
    private let key: SymmetricKey

    init(key: SymmetricKey) {
        self.key = key
    }

    /// Encrypts `plaintext` into a self-describing `v1.<base64>` token.
    func encrypt(_ plaintext: String) throws -> String {
        let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: key)
        guard let combined = sealed.combined else {
            throw Abort(.internalServerError, reason: "Failed to encrypt secret")
        }
        return "v1." + combined.base64EncodedString()
    }

    /// Decrypts a `v1.` token. Values without the prefix are treated as legacy plaintext
    /// so pre-encryption rows keep working until they are next re-saved.
    func decrypt(_ token: String) throws -> String {
        guard token.hasPrefix("v1.") else { return token }
        let encoded = String(token.dropFirst(3))
        guard let data = Data(base64Encoded: encoded) else {
            throw Abort(.internalServerError, reason: "Malformed encrypted secret")
        }
        let box = try AES.GCM.SealedBox(combined: data)
        let opened = try AES.GCM.open(box, using: key)
        return String(decoding: opened, as: UTF8.self)
    }
}

extension Application {
    /// Application-scoped `SecretBox`. The key is derived from `ENCRYPTION_KEY` via HKDF with a
    /// domain-separated label, giving key separation from JWT signing. `ENCRYPTION_KEY` is
    /// required at startup (the server refuses to boot without it) and must be permanent: a
    /// changed key makes previously encrypted seeds undecryptable.
    var secretBox: SecretBox {
        let ikm = SymmetricKey(data: Data(config.encryptionKey.utf8))
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            info: Data("fynncloud.secretbox.v1".utf8),
            outputByteCount: 32
        )
        return SecretBox(key: key)
    }
}

extension Request {
    var secretBox: SecretBox { application.secretBox }
}
