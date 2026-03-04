import Foundation
import CryptoKit

/// Decrypts shielded Note memos using AES-256-GCM with the user's Incoming Viewing Key.
///
/// Privacy model:
/// - Notes whose memo ciphertext cannot be authenticated with the user's IVK are silently
///   SKIPPED — they belong to other users and must leave zero trace.
/// - The IVK is a read-only key — it proves ownership of the memo but cannot authorize
///   spending (that requires the separate spending key in Phase 9.x).
/// - We use HKDF to derive a per-epoch nonce so the raw IVK bytes are never directly
///   used as the cipher key, providing an extra layer of key separation.
enum NoteDecryptor {

    /// Attempt to decrypt the encrypted memo field from a Starknet event payload.
    /// Returns `nil` (not an error) if the ciphertext cannot be authenticated with `ivk`.
    ///
    /// - Parameters:
    ///   - ciphertext:  The hex-encoded AES-GCM ciphertext from the Cairo event's `memo` field.
    ///   - commitment:  The note's commitment felt252, used as the info parameter for HKDF
    ///                  so each note derives a unique subkey even with the same root IVK.
    ///   - ivk:         The user's 32-byte Incoming Viewing Key from Keychain.
    /// - Returns:       Decrypted plaintext string, or `nil` if decryption fails.
    static func decrypt(hexCiphertext: String, commitment: String, ivk: Data) -> String? {
        guard let ciphertextData = Data(hexString: hexCiphertext), ciphertextData.count > 12 + 16 else {
            return nil
        }

        // Derive a note-specific 256-bit subkey via HKDF-SHA256
        let info = Data((commitment + "starkveil-note-ivk").utf8)
        let symmetricKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ivk),
            info: info,
            outputByteCount: 32
        )

        // AES-GCM: first 12 bytes = nonce, rest = ciphertext+tag
        let nonce = ciphertextData.prefix(12)
        let ciphertextAndTag = ciphertextData.dropFirst(12)

        do {
            let sealedBox = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonce),
                ciphertext: ciphertextAndTag.dropLast(16),
                tag: ciphertextAndTag.suffix(16)
            )
            let decrypted = try AES.GCM.open(sealedBox, using: symmetricKey)
            return String(data: decrypted, encoding: .utf8)
        } catch {
            // Authentication tag mismatch — this is NOT our note. Return nil silently.
            return nil
        }
    }

    /// Encrypt a plaintext memo for a new shielded note (used during shielding).
    static func encrypt(plaintext: String, commitment: String, ivk: Data) -> String? {
        guard let plaintextData = plaintext.data(using: .utf8) else { return nil }

        let info = Data((commitment + "starkveil-note-ivk").utf8)
        let symmetricKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ivk),
            info: info,
            outputByteCount: 32
        )

        do {
            let sealedBox = try AES.GCM.seal(plaintextData, using: symmetricKey)
            // Concatenate nonce (12 bytes) + ciphertext + tag (16 bytes)
            let combined = sealedBox.nonce.withUnsafeBytes { Data($0) } + sealedBox.ciphertext + sealedBox.tag
            return combined.hexEncodedString()
        } catch {
            return nil
        }
    }
}

// MARK: - Data helpers

private extension Data {
    func hexEncodedString() -> String {
        map { String(format: "%02hhx", $0) }.joined()
    }
}

