import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Seals a backup's secrets with a passphrase.
///
/// - PBKDF2-HMAC-SHA256 (`iterations`, a random 16-byte salt) derives 64 bytes: an AES-256 key and a check key.
/// - `key_check` = HMAC-SHA256(check key, "ccinnstarrocks-backup-key-check"), first 16 bytes. It is compared before
///   anything is decrypted, so a wrong passphrase is told apart from a modified file.
/// - AES-256-GCM with a random nonce authenticates `"ccinnstarrocks-backup/1:" + payload SHA-256`: changing the payload
///   changes its hash, and rewriting the hash in the header breaks the seal, so an encrypted backup is authenticated end
///   to end.
///
/// Key material lives in buffers that are zeroed after use; Swift strings (the passphrase, the secrets) cannot be.
enum BackupCrypto {
    static let kdfName = "pbkdf2-hmac-sha256"
    static let cipherName = "aes-256-gcm"
    /// OWASP 2023 for PBKDF2-HMAC-SHA256.
    static let defaultIterations = 600_000
    /// Counts outside are refused before deriving anything: a hostile file could otherwise ask for hours of work.
    static let acceptedIterations = 10_000...5_000_000
    static let saltLength = 16
    static let keyCheckLength = 16
    static let keyCheckLabel = "ccinnstarrocks-backup-key-check"
    static let associatedDataPrefix = "ccinnstarrocks-backup/1:"
    /// Nonce (12) and tag (16).
    static let minimumSealedLength = 28

    static func seal(_ plaintext: Data, passphrase: String, payloadSHA256: String, iterations: Int) throws -> BackupSecretsEnvelope {
        guard acceptedIterations.contains(iterations) else { throw BackupError.unsupportedEncryption("\(kdfName) × \(iterations)") }
        let salt = try randomBytes(saltLength)
        let keys = try DerivedKeys(passphrase: passphrase, salt: salt, iterations: iterations)
        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.seal(plaintext, using: keys.encryption, nonce: AES.GCM.Nonce(), authenticating: associatedData(payloadSHA256))
        } catch {
            throw BackupError.cryptographyUnavailable
        }
        guard let combined = sealedBox.combined else { throw BackupError.cryptographyUnavailable }
        return BackupSecretsEnvelope(kdf: kdfName, iterations: iterations, salt: Data(salt).base64EncodedString(),
                                     keyCheck: Data(keys.check).base64EncodedString(), cipher: cipherName,
                                     sealed: combined.base64EncodedString())
    }

    /// The plaintext, after the key check (`wrongPassphrase`) and the seal (`modified`) both pass.
    static func open(_ envelope: BackupSecretsEnvelope, passphrase: String, payloadSHA256: String) throws -> Data {
        guard envelope.kdf == kdfName else { throw BackupError.unsupportedEncryption(envelope.kdf) }
        guard envelope.cipher == cipherName else { throw BackupError.unsupportedEncryption(envelope.cipher) }
        guard acceptedIterations.contains(envelope.iterations) else { throw BackupError.unsupportedEncryption("\(kdfName) × \(envelope.iterations)") }
        guard let salt = Data(base64Encoded: envelope.salt), salt.count == saltLength,
              let expectedCheck = Data(base64Encoded: envelope.keyCheck), expectedCheck.count == keyCheckLength,
              let sealed = Data(base64Encoded: envelope.sealed), sealed.count >= minimumSealedLength
        else { throw BackupError.invalid("the encrypted passwords are damaged") }

        let keys = try DerivedKeys(passphrase: passphrase, salt: Array(salt), iterations: envelope.iterations)
        guard constantTimeEqual(keys.check, Array(expectedCheck)) else { throw BackupError.wrongPassphrase }
        do {
            let box = try AES.GCM.SealedBox(combined: sealed)
            return try AES.GCM.open(box, using: keys.encryption, authenticating: associatedData(payloadSHA256))
        } catch {
            throw BackupError.modified
        }
    }

    static func associatedData(_ payloadSHA256: String) -> Data {
        Data((associatedDataPrefix + payloadSHA256).utf8)
    }

    static func randomBytes(_ count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status: OSStatus = bytes.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) -> OSStatus in
            guard let base = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        guard status == errSecSuccess else { throw BackupError.cryptographyUnavailable }
        return bytes
    }

    static func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }

    static func wipe(_ bytes: inout [UInt8]) {
        bytes.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) -> Void in
            guard let base = buffer.baseAddress else { return }
            _ = memset_s(base, buffer.count, 0, buffer.count)
        }
    }

    /// The AES key and the 16-byte key check derived from a passphrase.
    struct DerivedKeys {
        let encryption: SymmetricKey
        let check: [UInt8]

        init(passphrase: String, salt: [UInt8], iterations: Int) throws {
            // NFC: the same passphrase typed on another Mac or keyboard derives the same key.
            var password = Array(passphrase.precomposedStringWithCanonicalMapping.utf8)
            defer { BackupCrypto.wipe(&password) }
            guard !password.isEmpty else { throw BackupError.wrongPassphrase }
            guard let rounds = UInt32(exactly: iterations) else { throw BackupError.unsupportedEncryption("\(BackupCrypto.kdfName) × \(iterations)") }
            var material = [UInt8](repeating: 0, count: 64)
            defer { BackupCrypto.wipe(&material) }
            let status = Self.derive(password: password, salt: salt, rounds: rounds, into: &material)
            guard status == Int32(kCCSuccess) else { throw BackupError.cryptographyUnavailable }
            encryption = SymmetricKey(data: material[0..<32])
            let checkKey = SymmetricKey(data: material[32..<64])
            let code = HMAC<SHA256>.authenticationCode(for: Data(BackupCrypto.keyCheckLabel.utf8), using: checkKey)
            check = Array(Array(code).prefix(BackupCrypto.keyCheckLength))
        }

        private static func derive(password: [UInt8], salt: [UInt8], rounds: UInt32, into material: inout [UInt8]) -> Int32 {
            let outputLength = material.count
            return password.withUnsafeBytes { (passwordBuffer: UnsafeRawBufferPointer) -> Int32 in
                salt.withUnsafeBytes { (saltBuffer: UnsafeRawBufferPointer) -> Int32 in
                    material.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) -> Int32 in
                        guard let passwordBase = passwordBuffer.baseAddress, let saltBase = saltBuffer.baseAddress,
                              let outputBase = output.baseAddress else { return Int32(kCCParamError) }
                        return CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                                    passwordBase.assumingMemoryBound(to: CChar.self), passwordBuffer.count,
                                                    saltBase.assumingMemoryBound(to: UInt8.self), saltBuffer.count,
                                                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds,
                                                    outputBase.assumingMemoryBound(to: UInt8.self), outputLength)
                    }
                }
            }
        }
    }
}
