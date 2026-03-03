import CryptoKit
import Foundation

// MARK: - NoteEncryption
//
// Implements the StarkVeil cryptographic note encryption scheme:
//
//   IVK  = stark_derive_ivk(spending_key)          — Poseidon(sk, domain), via Rust FFI
//   EK   = HKDF-SHA256(ikm=IVK_bytes, info="note-enc-v1")   — 256-bit AES key
//   CT   = AES-256-GCM(key=EK, plaintext=memo_utf8, nonce=random_96bit)
//
// The IVK is safe to share with watch-only wallets. Any party holding the IVK
// can detect and decrypt incoming notes. Only the holder of the spending key
// can compute the nullifier (spend the note).
//
// On-chain storage: the encrypted memo is included in the `shield` calldata
// as a hex-encoded string. The recipient's SyncEngine trial-decrypts every
// Shielded event using their IVK-derived EK.

enum NoteEncryptionError: Error, LocalizedError {
    case ivkDerivationFailed(String)
    case invalidKey
    case encryptionFailed
    case decryptionFailed
    case invalidCiphertext

    var errorDescription: String? {
        switch self {
        case .ivkDerivationFailed(let r): return "IVK derivation failed: \(r)"
        case .invalidKey:                 return "Invalid encryption key"
        case .encryptionFailed:           return "AES-256-GCM encryption failed"
        case .decryptionFailed:           return "AES-256-GCM decryption failed (wrong key or corrupted)"
        case .invalidCiphertext:          return "Invalid ciphertext format"
        }
    }
}

struct NoteEncryption {

    // MARK: - IVK Derivation

    /// Derives the Incoming Viewing Key (IVK) from the spending key via Rust FFI.
    /// IVK = Poseidon(spending_key, "StarkVeil IVK v1" as felt252)
    /// Safe to share with watch-only nodes for incoming note detection.
    static func deriveIVK(spendingKeyHex: String) throws -> String {
        try StarkVeilProver.deriveIVK(spendingKeyHex: spendingKeyHex)
    }

    // MARK: - Symmetric Encryption Key

    /// Derives a 256-bit AES encryption key from the IVK using HKDF-SHA256.
    /// Using HKDF instead of using the IVK directly ensures the key is properly
    /// domain-separated and uniform even if the IVK has low-entropy bit patterns.
    static func encryptionKey(from ivkHex: String) throws -> SymmetricKey {
        guard let ikm = Data(hexString: ivkHex.hasPrefix("0x") ? String(ivkHex.dropFirst(2)) : ivkHex) else {
            throw NoteEncryptionError.invalidKey
        }
        let info = Data("note-enc-v1".utf8)
        // HKDF-SHA256: extract + expand into 32 bytes (256-bit AES key)
        let prk  = HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: ikm), salt: nil)
        let okm  = HKDF<SHA256>.expand(pseudoRandomKey: prk, info: info, outputByteCount: 32)
        return okm
    }

    // MARK: - Encrypt

    /// Encrypts a memo string using AES-256-GCM with a random 96-bit nonce.
    ///
    /// Output format (hex-encoded): <12-byte nonce> || <ciphertext+tag>
    /// Total overhead: 12 (nonce) + 16 (GCM tag) = 28 bytes beyond plaintext.
    static func encryptMemo(_ memo: String, ivkHex: String) throws -> String {
        let key = try encryptionKey(from: ivkHex)
        let plaintext = Data(memo.utf8)
        // CryptoKit AES-256-GCM generates a random nonce internally
        let sealedBox = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealedBox.combined else {
            throw NoteEncryptionError.encryptionFailed
        }
        return combined.hexString
    }

    // MARK: - Decrypt

    /// Decrypts a hex-encoded AES-256-GCM ciphertext using the IVK.
    /// Returns nil if the ciphertext is not addressed to this IVK (authentication fails).
    /// Throws only on structural errors (invalid hex, wrong format).
    static func decryptMemo(_ encryptedHex: String, ivkHex: String) throws -> String? {
        guard let combined = Data(hexString: encryptedHex) else {
            throw NoteEncryptionError.invalidCiphertext
        }
        let key = try encryptionKey(from: ivkHex)
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: combined)
            let plaintext = try AES.GCM.open(sealedBox, using: key)
            return String(data: plaintext, encoding: .utf8)
        } catch {
            // GCM authentication failure = not addressed to us; return nil (not an error)
            return nil
        }
    }

    // MARK: - Note Commitment

    /// Computes the real Poseidon note commitment via Rust FFI.
    /// commitment = Poseidon(value, asset_id, owner_pubkey, nonce)
    static func computeCommitment(
        valueFelt: String,
        assetIdFelt: String,
        ownerPubkeyFelt: String,
        nonceFelt: String
    ) throws -> String {
        try StarkVeilProver.noteCommitment(
            value: valueFelt,
            assetId: assetIdFelt,
            ownerPubkey: ownerPubkeyFelt,
            nonce: nonceFelt
        )
    }

    /// Computes the real Poseidon nullifier via Rust FFI.
    /// nullifier = Poseidon(commitment, spending_key)
    static func computeNullifier(commitmentFelt: String, spendingKeyFelt: String) throws -> String {
        try StarkVeilProver.noteNullifier(commitment: commitmentFelt, spendingKey: spendingKeyFelt)
    }
}

// MARK: - Data Hex Extensions

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(hexString hex: String) {
        let clean = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        guard clean.count % 2 == 0 else { return nil }
        var data = Data(capacity: clean.count / 2)
        var idx = clean.startIndex
        while idx < clean.endIndex {
            let next = clean.index(idx, offsetBy: 2)
            guard let byte = UInt8(clean[idx..<next], radix: 16) else { return nil }
            data.append(byte)
            idx = next
        }
        self = data
    }
}
