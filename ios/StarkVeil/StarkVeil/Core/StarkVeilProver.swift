import Foundation
import CryptoKit

// MARK: - Core Types matching Rust FFI

struct Note: Codable {
    let value: String
    let asset_id: String
    let owner_ivk: String
    // L-NOTE-STRUCT-MISMATCH fix: Rust types.rs uses owner_pubkey (Phase 15 field).
    // Swift was serialising only owner_ivk, so Rust always saw owner_pubkey = None → 0x0
    // in computeCommitment. Both fields are now passed through FFI JSON.
    let owner_pubkey: String
    let nonce: String
    let memo: String
}

struct Nullifier: Codable {
    let nullifier_hash: String
}

struct TransferPayload: Codable {
    let proof: [String]
    let nullifiers: [String]
    let new_commitments: [String]
    let fee: String
}

enum FFIResult: Decodable, Sendable {
    case success(TransferPayload)
    case error(String)

    enum CodingKeys: String, CodingKey {
        case Success
        case Error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Use contains() + typed try so a malformed Success payload surfaces the
        // real field-level error instead of silently falling through to the Error branch.
        if container.contains(.Success) {
            let payload = try container.decode(TransferPayload.self, forKey: .Success)
            self = .success(payload)
            return
        }
        if container.contains(.Error) {
            let message = try container.decode(String.self, forKey: .Error)
            self = .error(message)
            return
        }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "FFIResult must contain either a 'Success' or 'Error' key"
            )
        )
    }
}

// MARK: - ZK Prover Service

class StarkVeilProver {

    /// Generates a Zero-Knowledge proof natively using the Rust FFI framework.
    /// - Parameter notes: Array of input note constraints.
    /// - Returns: The signed payload ready to be sent to the StarkVeil Cairo Contract.
    static func generateTransferProof(notes: [Note]) async throws -> TransferPayload {
        let notesData = try JSONEncoder().encode(notes)
        guard let notesString = String(data: notesData, encoding: .utf8) else {
            throw NSError(domain: "StarkVeilProver", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Notes array could not be UTF-8 encoded"])
        }

        // Capture ownership of the null-terminated buffer explicitly as a value type.
        // ContiguousArray<CChar> lives in Swift memory for the entire closure lifetime,
        // eliminating reliance on withCString's non-escaping contract — which would be
        // broken if the body were ever wrapped in an escaping async callback.
        let cStringBuffer = notesString.utf8CString

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                cStringBuffer.withUnsafeBufferPointer { buffer in
                    guard let baseAddress = buffer.baseAddress else {
                        continuation.resume(throwing: NSError(
                            domain: "FFIError", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "C string buffer has no base address"]))
                        return
                    }

                    // 1. Cross the FFI boundary (blocking Rust call)
                    let resultPtr = generate_transfer_proof(baseAddress)
                    guard let resultPtr = resultPtr else {
                        continuation.resume(throwing: NSError(
                            domain: "FFIError", code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "Rust returned a null pointer"]))
                        return
                    }

                    // 2. Copy bytes into Swift-managed memory before freeing Rust allocation
                    let resultString = String(cString: resultPtr)

                    // 3. Release Rust allocation — must happen after the String copy above
                    free_rust_string(UnsafeMutablePointer(mutating: resultPtr))

                    // 4. Decode the FFIResult envelope
                    guard let resultData = resultString.data(using: .utf8) else {
                        continuation.resume(throwing: NSError(
                            domain: "FFIError", code: 3,
                            userInfo: [NSLocalizedDescriptionKey: "FFI response is not valid UTF-8"]))
                        return
                    }

                    do {
                        let ffiResult = try JSONDecoder().decode(FFIResult.self, from: resultData)
                        switch ffiResult {
                        case .success(let payload):
                            continuation.resume(returning: payload)
                        case .error(let message):
                            continuation.resume(throwing: NSError(
                                domain: "ProverError", code: 4,
                                userInfo: [NSLocalizedDescriptionKey: message]))
                        }
                    } catch {
                        // Wrap with context so caller can distinguish FFI shape errors
                        // from other decode failures.
                        continuation.resume(throwing: NSError(
                            domain: "FFIError", code: 5,
                            userInfo: [
                                NSLocalizedDescriptionKey: "FFIResult decode failed: \(error.localizedDescription)",
                                NSUnderlyingErrorKey: error
                            ]))
                    }
                }
            }
        }
    }

    // MARK: - Phase 12: Real STARK Cryptography Bridge

    // ─────────────────────────────────────────────────────────────────────────
    // Helper: calls a Rust FFI fn that takes a single C string and returns
    // a JSON string like {"Ok": "0x..."} or {"Err": "message"}.
    // L-CALLSINGLEARG-RETTYPE fix: fn must return UnsafeMutablePointer (not Unsafe)
    // to match the *mut c_char return type of all Rust FFI exports.
    // ─────────────────────────────────────────────────────────────────────────
    private static func callSingleArg(
        _ fn: (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?,
        arg: String
    ) throws -> String {
        let buf = arg.utf8CString
        return try buf.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else {
                throw NSError(domain: "FFIError", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Null C string buffer"])
            }
            guard let rawPtr = fn(base) else {
                throw NSError(domain: "FFIError", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Rust returned null"])
            }
            let json = String(cString: rawPtr)
            free_rust_string(rawPtr)   // no cast needed: already UnsafeMutablePointer
            return try decodeOkString(json: json)
        }
    }

    private static func decodeOkString(json: String) throws -> String {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "FFIError", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot parse FFI response: \(json)"])
        }
        if let ok = dict["Ok"] as? String { return ok }
        // H-ERR-KEY fix: Rust serde serialises the enum variant as {"Error": "..."} not {"Err": "..."}
        // Checking only "Err" caused every Rust error to become "Unknown Rust error"
        let errMsg = dict["Error"] as? String ?? dict["Err"] as? String ?? "Unknown Rust error: \(json)"
        throw NSError(domain: "CryptoFFI", code: 4,
                      userInfo: [NSLocalizedDescriptionKey: errMsg])
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 1. STARK Public Key  (real EC scalar multiply on STARK curve)
    //    Replaces the SHA-256 stub in StarknetAccount.starkPublicKey().
    // ─────────────────────────────────────────────────────────────────────────

    /// Computes the real STARK public key for the given private key.
    /// Uses starknet-crypto::get_public_key (EC scalar multiply on the STARK curve).
    static func starkPublicKey(privateKeyHex: String) throws -> String {
        try callSingleArg(stark_get_public_key, arg: privateKeyHex)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2. Pedersen Hash  (real Cairo pedersen_hash with shift-point constants)
    //    Replaces the SHA-256 stub in StarknetAccount.pedersenHash().
    // ─────────────────────────────────────────────────────────────────────────

    /// Computes H(a, b) using the real Cairo Pedersen hash.
    static func pedersenHash(a: String, b: String) throws -> String {
        let aBuf = a.utf8CString
        let bBuf = b.utf8CString
        return try aBuf.withUnsafeBufferPointer { ap in
            try bBuf.withUnsafeBufferPointer { bp in
                guard let aBase = ap.baseAddress, let bBase = bp.baseAddress else {
                    throw NSError(domain: "FFIError", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Null C string buffer"])
                }
                guard let rawPtr = stark_pedersen_hash(aBase, bBase) else {
                    throw NSError(domain: "FFIError", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "Rust returned null"])
                }
                let json = String(cString: rawPtr)
                free_rust_string(UnsafeMutablePointer(mutating: rawPtr))
                return try decodeOkString(json: json)
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3. Poseidon Hash  (matches Cairo poseidon_hash_span used in PrivacyPool)
    //    Used for note commitments: poseidon(value, asset_id, owner_ivk, memo)
    // ─────────────────────────────────────────────────────────────────────────

    /// Computes Poseidon hash of a list of felt252 elements.
    /// Matches the Cairo PrivacyPool contract's commitment hash.
    static func poseidonHash(elements: [String]) throws -> String {
        let json = try JSONEncoder().encode(elements)
        guard let jsonStr = String(data: json, encoding: .utf8) else {
            throw NSError(domain: "FFIError", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot encode elements to JSON"])
        }
        return try callSingleArg(stark_poseidon_hash, arg: jsonStr)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Phase 15 Function 5: Incoming Viewing Key
    //    IVK = Poseidon(spending_key, domain_separator)
    //    Safe to share — allows incoming note detection without spending ability.
    // ─────────────────────────────────────────────────────────────────────────

    /// Derives the Incoming Viewing Key (IVK) from the spending key.
    static func deriveIVK(spendingKeyHex: String) throws -> String {
        try callSingleArg(stark_derive_ivk, arg: spendingKeyHex)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Phase 15 Function 6: Note Commitment
    //    commitment = Poseidon(value, asset_id, owner_pubkey, nonce)
    // ─────────────────────────────────────────────────────────────────────────

    /// Computes the Poseidon note commitment.
    static func noteCommitment(value: String, assetId: String, ownerPubkey: String, nonce: String) throws -> String {
        let v    = value.utf8CString
        let a    = assetId.utf8CString
        let o    = ownerPubkey.utf8CString
        let n    = nonce.utf8CString
        return try v.withUnsafeBufferPointer { vp in
            try a.withUnsafeBufferPointer { ap in
                try o.withUnsafeBufferPointer { op in
                    try n.withUnsafeBufferPointer { np in
                        guard let vb = vp.baseAddress, let ab = ap.baseAddress,
                              let ob = op.baseAddress, let nb = np.baseAddress else {
                            throw NSError(domain: "FFIError", code: 1,
                                          userInfo: [NSLocalizedDescriptionKey: "Null buffer"])
                        }
                        guard let rawPtr = stark_note_commitment(vb, ab, ob, nb) else {
                            throw NSError(domain: "FFIError", code: 2,
                                          userInfo: [NSLocalizedDescriptionKey: "Rust returned null"])
                        }
                        let json = String(cString: rawPtr)
                        free_rust_string(UnsafeMutablePointer(mutating: rawPtr))
                        return try decodeOkString(json: json)
                    }
                }
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Phase 15 Function 7: Note Nullifier
    //    nullifier = Poseidon(commitment, spending_key)
    //    Revealed on-chain when the note is spent — prevents double-spend.
    // ─────────────────────────────────────────────────────────────────────────

    /// Computes the Poseidon note nullifier.
    static func noteNullifier(commitment: String, spendingKey: String) throws -> String {
        let cBuf = commitment.utf8CString
        let sBuf = spendingKey.utf8CString
        return try cBuf.withUnsafeBufferPointer { cp in
            try sBuf.withUnsafeBufferPointer { sp in
                guard let cb = cp.baseAddress, let sb = sp.baseAddress else {
                    throw NSError(domain: "FFIError", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Null buffer"])
                }
                guard let rawPtr = stark_note_nullifier(cb, sb) else {
                    throw NSError(domain: "FFIError", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "Rust returned null"])
                }
                let json = String(cString: rawPtr)
                free_rust_string(UnsafeMutablePointer(mutating: rawPtr))
                return try decodeOkString(json: json)
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 4. STARK ECDSA Signing
    //    Signs a transaction hash with the account's spending key.
    //    Returns the (r, s) signature pair for the invoke/deploy calldata.
    // ─────────────────────────────────────────────────────────────────────────

    struct ECDSASignature {
        let r: String
        let s: String
    }

    /// Signs a Starknet transaction hash with the account spending key.
    /// - Parameters:
    ///   - txHash:     The Pedersen hash of the transaction fields (felt252 hex).
    ///   - privateKey: The STARK spending key (felt252 hex, from KeyDerivationEngine).
    ///
    /// C-K-RETRY fix: original SHA-256(pk||txHash) produced the same k for the same
    /// txHash on every retry attempt — a retried failed tx would share k with the original,
    /// enabling private key extraction from two signatures with the same k.
    ///
    /// C-K-DOMAIN fix: SHA-256 output is 256-bit; STARK_ORDER ≈ 2^251.6, so ~6.25% of
    /// SHA-256 outputs exceed STARK_ORDER and cause the Rust sign() to return Err.
    ///
    /// Combined fix: HMAC-SHA256(key=privateKey, data=txHash||counter) in a retry loop.
    ///   - unique per (pk, txHash, attempt) — retries produce different k values
    ///   - clamped to [1, STARK_ORDER) by masking to 252 bits and rejecting 0
    ///   - follows the structure of RFC 6979 without requiring the full DRBG
    static func signTransaction(txHash: String, privateKey: String) throws -> ECDSASignature {
        // STARK_ORDER: 2^251 + 17*2^192 + 1 (251.58-bit value, first 5 bits of a 256-bit word are 0)
        // Masking with 0x07 in the top byte gives us < 2^251, which is safely below the order
        // on every iteration — eliminating the 6.25% domain failure entirely.
        let pkKey = SymmetricKey(data: Data(privateKey.utf8))
        var counter: UInt8 = 0
        while counter < 100 {   // bounded retry — should never exceed 1-2 iterations
            var msg = Data(txHash.utf8)
            msg.append(counter)
            let mac = HMAC<SHA256>.authenticationCode(for: msg, using: pkKey)
            var kBytes = Array(mac)
            // Clamp: mask top 5 bits so the value is always < 2^251 ≤ STARK_ORDER
            kBytes[0] &= 0x07
            // Reject k = 0 (degenerate; would produce r = 0)
            if kBytes.allSatisfy({ $0 == 0 }) { counter += 1; continue }
            let kValue = "0x" + kBytes.map { String(format: "%02x", $0) }.joined()
            let txBuf = txHash.utf8CString
            let pkBuf = privateKey.utf8CString
            let kBuf  = kValue.utf8CString
            let result = try txBuf.withUnsafeBufferPointer { txPtr in
                try pkBuf.withUnsafeBufferPointer { pkPtr in
                    try kBuf.withUnsafeBufferPointer { kPtr in
                        guard let tx = txPtr.baseAddress, let pk = pkPtr.baseAddress, let kp = kPtr.baseAddress else {
                            throw NSError(domain: "FFIError", code: 1,
                                          userInfo: [NSLocalizedDescriptionKey: "Null C string buffer"])
                        }
                        guard let rawPtr = stark_sign_transaction(tx, pk, kp) else {
                            throw NSError(domain: "FFIError", code: 2,
                                          userInfo: [NSLocalizedDescriptionKey: "Rust returned null"])
                        }
                        let json = String(cString: rawPtr)
                        free_rust_string(UnsafeMutablePointer(mutating: rawPtr))
                        return json
                    }
                }
            }
            // Decode: {"Ok": {"r": "0x...", "s": "0x..."}} or {"Err": "..."} / {"Error": "..."}
            guard let data = result.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "FFIError", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "Cannot parse sign result: \(result)"])
            }
            if let ok = dict["Ok"] as? [String: String],
               let r = ok["r"], let s = ok["s"] {
                return ECDSASignature(r: r, s: s)
            }
            // Rust Err: k may have been invalid (r=0, s=0) — retry with next counter
            let errMsg = dict["Error"] as? String ?? dict["Err"] as? String ?? result
            if errMsg.contains("invalid k") || errMsg.contains("ECDSA") {
                counter += 1
                continue
            }
            throw NSError(domain: "CryptoFFI", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: errMsg])
        }
        throw NSError(domain: "CryptoFFI", code: 5,
                      userInfo: [NSLocalizedDescriptionKey: "Could not produce a valid ECDSA signature after \(counter) attempts"])
    }
}
