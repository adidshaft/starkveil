import CryptoKit
import Foundation

// MARK: - NoteEncryption
//
// Implements the StarkVeil cryptographic note encryption scheme:
//
//   IVK  = stark_derive_ivk(spending_key)          — Poseidon(sk, domain), via Rust FFI
//   EK   = HKDF-SHA256(ikm=IVK_bytes, salt="StarkVeil-NoteEnc-v1", info="note-enc-v1")
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
    ///
    /// M-2 fix: Uses a fixed domain salt ("StarkVeil-NoteEnc-v1") for proper
    /// domain separation per RFC 5869 §3.1.
    static func encryptionKey(from ivkHex: String) throws -> SymmetricKey {
        try encryptionKeyInternal(from: ivkHex, useLegacySalt: false)
    }

    /// Legacy key derivation with empty salt — used for decrypting memos encrypted
    /// before the M-2 fix. New encryptions always use the domain salt.
    static func legacyEncryptionKey(from ivkHex: String) throws -> SymmetricKey {
        try encryptionKeyInternal(from: ivkHex, useLegacySalt: true)
    }

    private static func encryptionKeyInternal(from ivkHex: String, useLegacySalt: Bool) throws -> SymmetricKey {
        let raw = ivkHex.hasPrefix("0x") ? String(ivkHex.dropFirst(2)) : ivkHex
        // !! CANONICAL ENCODING: always produce exactly 32 bytes (64 hex chars),
        // left-padding with zeros. Without this, '0x1234' (2 bytes) and '0x001234'
        // (3 bytes) produce DIFFERENT HKDF keys even though they are the same number.
        // clampToFelt252 zero-pads to 64 chars; deriveIVK may return shorter hex —
        // normalising here makes both produce identical key material.
        let normalized = String(repeating: "0", count: max(0, 64 - raw.count)) + raw
        guard let ikm = Data(hexString: normalized), ikm.count == 32 else {
            throw NoteEncryptionError.invalidKey
        }
        let info = Data("note-enc-v1".utf8)
        // M-2 fix: fixed domain salt for proper domain separation per RFC 5869 §3.1
        let salt = useLegacySalt ? Data() : Data("StarkVeil-NoteEnc-v1".utf8)
        let prk  = HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt)
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
    ///
    /// M-2 fix: tries new domain salt first, falls back to legacy empty salt
    /// for memos encrypted before the audit fix.
    static func decryptMemo(_ encryptedHex: String, ivkHex: String) throws -> String? {
        guard let combined = Data(hexString: encryptedHex) else {
            throw NoteEncryptionError.invalidCiphertext
        }
        // Try new key (with domain salt) first
        let key = try encryptionKey(from: ivkHex)
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: combined)
            let plaintext = try AES.GCM.open(sealedBox, using: key)
            return String(data: plaintext, encoding: .utf8) ?? plaintext.hexString
        } catch {
            // M-2 legacy fallback: try old key derivation (empty salt) for pre-fix memos
            let legacyKey = try legacyEncryptionKey(from: ivkHex)
            do {
                let sealedBox = try AES.GCM.SealedBox(combined: combined)
                let plaintext = try AES.GCM.open(sealedBox, using: legacyKey)
                return String(data: plaintext, encoding: .utf8) ?? plaintext.hexString
            } catch {
                // GCM authentication failure = not addressed to us; return nil (not an error)
                return nil
            }
        }
    }

    // MARK: - Compact felt252 Encryption (for on-chain Transfer events)
    //
    // AES-GCM is not usable for on-chain memos: its minimum overhead is
    // 12 (nonce) + 16 (tag) = 28 bytes, leaving only 3 bytes for plaintext
    // in a 31-byte felt252. Instead we use:
    //
    //   keystream = HKDF-SHA256(ikm=EK, info=commitment_bytes, length=23)
    //   payload   = [value_8bytes || memo_up_to_15bytes]
    //   cipherPayload = XOR(payload, keystream)
    //   auth      = HMAC-SHA256(EK, cipherPayload)[0..<8]   (M-4: Encrypt-then-MAC)
    //   ciphertext = auth(8) || cipherPayload(23)
    //
    // Total = 8 + 23 = 31 bytes = exactly one felt252.
    // The commitment is unique per note, so keystream is unique (no nonce needed).
    // Auth failure → returns nil, identical to AES-GCM for SyncEngine trial-decrypt.
    //
    // H-5 fix: auth tag increased from 4 → 8 bytes (64-bit security)
    // M-4 fix: HMAC computed on ciphertext, not plaintext (Encrypt-then-MAC)

    static let compactPayloadSize = 23   // 31 - 8 (auth tag) — H-5 fix
    static let compactValueSize   = 8    // 8 bytes = u64, supports up to ~1.8e19 wei
    static let authTagSize        = 8    // H-5 fix: 64-bit security (was 4)

    /// Encrypts `(valueWei, memo)` into a 31-byte felt252-safe compact ciphertext.
    /// - `valueWei`: raw integer string e.g. "100000000000000000"
    /// - `commitment`: the output note commitment, used as a unique nonce
    static func encryptCompact(valueWei: String, memo: String, ivkHex: String, commitment: String) throws -> String {
        let aesKey = try encryptionKey(from: ivkHex)

        // Build plaintext: 8-byte big-endian value + memo bytes (truncated to fit)
        let valueInt = UInt64(valueWei) ?? 0
        let valueBytes = (0..<8).map { i -> UInt8 in
            let shift = (7 - i) * 8
            return UInt8((valueInt >> shift) & 0xFF)
        }
        let memoBytes = Array(memo.utf8.prefix(compactPayloadSize - compactValueSize))
        // Pad to FULL compactPayloadSize (23) bytes BEFORE XOR.
        var payload: [UInt8] = valueBytes + memoBytes
        while payload.count < compactPayloadSize { payload.append(0) }

        // Derive keystream from EK + commitment (unique per note → no replay)
        let commitRaw = commitment.hasPrefix("0x") ? String(commitment.dropFirst(2)) : commitment
        let commitEven = commitRaw.count % 2 == 1 ? "0" + commitRaw : commitRaw
        guard let commitData = Data(hexString: commitEven) else {
            throw NoteEncryptionError.invalidCiphertext
        }
        let keystreamKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: aesKey,
            info: commitData,
            outputByteCount: compactPayloadSize
        )
        let keystreamBytes = keystreamKey.withUnsafeBytes { Array($0) }

        // XOR encrypt the full padded payload
        let cipherPayload = zip(payload, keystreamBytes).map { $0 ^ $1 }

        // M-4 fix: Encrypt-then-MAC — HMAC on ciphertext, not plaintext
        // H-5 fix: 8-byte auth tag (64-bit security, was 4 bytes / 32-bit)
        let authFull = HMAC<SHA256>.authenticationCode(for: Data(cipherPayload), using: aesKey)
        let auth = Array(authFull.prefix(authTagSize))

        // Concatenate: auth(8) || cipherPayload(23) = exactly 31 bytes
        let result = auth + cipherPayload
        let hex = result.map { String(format: "%02x", $0) }.joined()
        return "0x" + hex
    }

    /// Decrypts a compact felt252 ciphertext. Returns `(valueWei, memo)` or nil if auth fails.
    ///
    /// M-2 fix: tries new key first, falls back to legacy key.
    /// H-5/M-4 fix: handles both new (8-byte auth, Encrypt-then-MAC) and
    /// legacy (4-byte auth, MAC-then-Encrypt) formats.
    static func decryptCompact(_ encryptedHex: String, ivkHex: String, commitment: String) throws -> (valueWei: String, memo: String)? {
        // Try new format first (8-byte auth, Encrypt-then-MAC, domain salt)
        if let result = try decryptCompactInternal(encryptedHex, ivkHex: ivkHex, commitment: commitment, legacyFormat: false, useLegacySalt: false) {
            return result
        }
        // Legacy fallback 1: new salt, old format (4-byte auth, MAC-then-Encrypt)
        if let result = try decryptCompactInternal(encryptedHex, ivkHex: ivkHex, commitment: commitment, legacyFormat: true, useLegacySalt: false) {
            return result
        }
        // Legacy fallback 2: old salt, old format
        if let result = try decryptCompactInternal(encryptedHex, ivkHex: ivkHex, commitment: commitment, legacyFormat: true, useLegacySalt: true) {
            return result
        }
        return nil
    }

    private static func decryptCompactInternal(
        _ encryptedHex: String,
        ivkHex: String,
        commitment: String,
        legacyFormat: Bool,
        useLegacySalt: Bool
    ) throws -> (valueWei: String, memo: String)? {
        let clean = encryptedHex.hasPrefix("0x") ? String(encryptedHex.dropFirst(2)) : encryptedHex

        let currentAuthSize = legacyFormat ? 4 : authTagSize
        let currentPayloadSize = legacyFormat ? 27 : compactPayloadSize
        let expectedBytes = currentAuthSize + currentPayloadSize  // 31 either way
        let expectedHexLen = expectedBytes * 2  // 62

        guard clean.count <= expectedHexLen else { return nil }
        let padded = String(repeating: "0", count: max(0, expectedHexLen - clean.count)) + clean
        guard let data = Data(hexString: padded), data.count == expectedBytes else {
            return nil
        }
        let bytes = Array(data)
        let auth = Array(bytes[0..<currentAuthSize])
        let cipherPayload = Array(bytes[currentAuthSize..<expectedBytes])

        // Derive keystream
        let aesKey = useLegacySalt ? try legacyEncryptionKey(from: ivkHex) : try encryptionKey(from: ivkHex)
        let commitRaw = commitment.hasPrefix("0x") ? String(commitment.dropFirst(2)) : commitment
        let commitEven = commitRaw.count % 2 == 1 ? "0" + commitRaw : commitRaw
        guard let commitData = Data(hexString: commitEven) else { return nil }

        let keystreamKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: aesKey,
            info: commitData,
            outputByteCount: currentPayloadSize
        )
        let keystreamBytes = keystreamKey.withUnsafeBytes { Array($0) }

        if legacyFormat {
            // Legacy MAC-then-Encrypt: decrypt first, then verify HMAC on plaintext
            let payload = zip(cipherPayload, keystreamBytes).map { $0 ^ $1 }
            let authFull = HMAC<SHA256>.authenticationCode(for: Data(payload), using: aesKey)
            let expectedAuth = Array(authFull.prefix(currentAuthSize))
            guard auth == expectedAuth else { return nil }

            let valueInt = payload.prefix(compactValueSize).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let memoBytes = Array(payload.dropFirst(compactValueSize)).prefix(while: { $0 != 0 })
            let memo = String(bytes: Array(memoBytes), encoding: .utf8) ?? ""
            return (valueWei: String(valueInt), memo: memo)
        } else {
            // New Encrypt-then-MAC: verify HMAC on ciphertext first, then decrypt
            let authFull = HMAC<SHA256>.authenticationCode(for: Data(cipherPayload), using: aesKey)
            let expectedAuth = Array(authFull.prefix(currentAuthSize))
            guard auth == expectedAuth else { return nil }

            let payload = zip(cipherPayload, keystreamBytes).map { $0 ^ $1 }
            let valueInt = payload.prefix(compactValueSize).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let memoBytes = Array(payload.dropFirst(compactValueSize)).prefix(while: { $0 != 0 })
            let memo = String(bytes: Array(memoBytes), encoding: .utf8) ?? ""
            return (valueWei: String(valueInt), memo: memo)
        }
    }



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
