import Foundation
import CryptoKit
import CommonCrypto

/// The cryptographic building blocks of Private Space. Only Apple's CryptoKit and CommonCrypto are used.
public enum VaultCrypto {
    /// OWASP Password Storage Cheat Sheet: PBKDF2-HMAC-SHA256, 600,000 iterations.
    public static let defaultIterations = 600_000

    /// Password → 256-bit key-encryption key (PBKDF2-HMAC-SHA256). The password is Unicode-normalised so the
    /// same passphrase typed on different keyboards derives the same key.
    public static func deriveKey(password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        let pw = Data(password.precomposedStringWithCanonicalMapping.utf8)
        var out = Data(count: 32)
        let status = out.withUnsafeMutableBytes { outPtr in
            pw.withUnsafeBytes { pwPtr in
                salt.withUnsafeBytes { saltPtr in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         pwPtr.baseAddress?.assumingMemoryBound(to: CChar.self), pw.count,
                                         saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                         outPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), 32)
                }
            }
        }
        guard status == kCCSuccess else { throw VaultError.crypto("Key derivation failed (\(status)).") }
        return SymmetricKey(data: out)
    }

    public static func randomBytes(_ count: Int) -> Data {
        var d = Data(count: count)
        _ = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return d
    }

    /// Authenticated encryption of a small secret (AES-256-GCM, random nonce). A wrong key fails the tag check.
    public static func wrap(_ secret: Data, with key: SymmetricKey) throws -> Data {
        guard let combined = try AES.GCM.seal(secret, using: key).combined else { throw VaultError.crypto("Seal failed.") }
        return combined
    }

    public static func unwrap(_ blob: Data, with key: SymmetricKey) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: blob), using: key)
    }

    /// Encrypt to the vault's public key (X25519 key agreement → HKDF-SHA256 → AES-256-GCM). Anyone with the
    /// public key can add items; only the holder of the private key can read them. Output: ephemeral key ‖ box.
    public static func seal(_ data: Data, to publicKey: Curve25519.KeyAgreement.PublicKey) throws -> Data {
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let key = try sharedKey(ephemeral.sharedSecretFromKeyAgreement(with: publicKey),
                                ephemeral: ephemeral.publicKey.rawRepresentation, recipient: publicKey.rawRepresentation)
        guard let box = try AES.GCM.seal(data, using: key).combined else { throw VaultError.crypto("Seal failed.") }
        return ephemeral.publicKey.rawRepresentation + box
    }

    public static func open(_ blob: Data, with privateKey: Curve25519.KeyAgreement.PrivateKey) throws -> Data {
        guard blob.count > 32 + 28 else { throw VaultError.crypto("Encrypted item is truncated.") }
        let eph = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: blob.prefix(32))
        let key = try sharedKey(privateKey.sharedSecretFromKeyAgreement(with: eph),
                                ephemeral: eph.rawRepresentation, recipient: privateKey.publicKey.rawRepresentation)
        return try AES.GCM.open(AES.GCM.SealedBox(combined: blob.dropFirst(32)), using: key)
    }

    private static func sharedKey(_ secret: SharedSecret, ephemeral: Data, recipient: Data) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: ephemeral + recipient,
                                       sharedInfo: Data("pixora-private-space-v1".utf8), outputByteCount: 32)
    }
}

public enum VaultError: Error, LocalizedError, Equatable {
    case notSetUp, alreadySetUp, locked, wrongPassword, tooManyAttempts(retryAfter: Int), weakPassword(String)
    case crypto(String), corrupt(String)

    public var errorDescription: String? {
        switch self {
        case .notSetUp: "Private Space hasn’t been set up yet."
        case .alreadySetUp: "Private Space is already set up."
        case .locked: "Unlock Private Space first."
        case .wrongPassword: "That password isn’t right."
        case let .tooManyAttempts(s): "Too many attempts. Try again in \(s < 60 ? "\(s) seconds" : "\(s / 60) minutes")."
        case let .weakPassword(why): why
        case let .crypto(m): m
        case let .corrupt(m): "Private Space data is damaged: \(m)"
        }
    }
}
