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
    // Phase 18 (C-6 fix): spending_key for nullifier derivation in generate_transfer_proof.
    // Optional so existing Note construction sites (addNote, SyncEngine) don't break.
    let spending_key: String?
    let memo: String
    // Phase 20 (Stwo integration): Merkle witness fields for real STARK proof generation
    let leaf_position: UInt32?
    let merkle_path: [String]?
    // Commitment override: if non-nil, the Rust prover uses this as the Merkle leaf
    // directly instead of recomputing Poseidon(value, asset, owner, nonce).
    // Required because SyncEngine stores value as decimal and nonce = on-chain commitment.
    let commitment: String?

    init(value: String, asset_id: String, owner_ivk: String, owner_pubkey: String,
         nonce: String, spending_key: String?, memo: String,
         leaf_position: UInt32?, merkle_path: [String]?, commitment: String? = nil) {
        self.value = value
        self.asset_id = asset_id
        self.owner_ivk = owner_ivk
        self.owner_pubkey = owner_pubkey
        self.nonce = nonce
        self.spending_key = spending_key
        self.memo = memo
        self.leaf_position = leaf_position
        self.merkle_path = merkle_path
        self.commitment = commitment
    }
}

struct Nullifier: Codable {
    let nullifier_hash: String
}

struct TransferPayload: Codable {
    let proof: [String]
    let nullifiers: [String]
    let new_commitments: [String]
    let fee: String
    // Phase 20: Merkle root the proof was generated against
    let historic_root: String
}

// Phase 20: Unshield proof types matching Rust FFI
struct UnshieldInput: Codable {
    let note: Note
    let amount_low: String
    let amount_high: String
    let recipient: String
    let asset: String
    let historic_root: String
}

struct UnshieldPayload: Codable {
    let proof: [String]
    let nullifier: String
    let historic_root: String
}

enum UnshieldFFIResult: Decodable, Sendable {
    case success(UnshieldPayload)
    case error(String)

    enum CodingKeys: String, CodingKey {
        case Success
        case Error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.Success) {
            let payload = try container.decode(UnshieldPayload.self, forKey: .Success)
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
                debugDescription: "UnshieldFFIResult must contain either a 'Success' or 'Error' key"
            )
        )
    }
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
    // The FFI functions return UnsafePointer<CChar>? (const *c_char in Rust).
    // ─────────────────────────────────────────────────────────────────────────
    private static func callSingleArg(
        _ fn: @Sendable (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?,
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
            free_rust_string(UnsafeMutablePointer(mutating: rawPtr))
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

    /// Phase 18 (H-2 fix): k is now derived deterministically inside Rust via RFC-6979.
    /// The Swift side simply passes txHash + privateKey. No nonce logic needed here.
    static func signTransaction(txHash: String, privateKey: String) throws -> ECDSASignature {
        let txBuf = txHash.utf8CString
        let pkBuf = privateKey.utf8CString
        let result = try txBuf.withUnsafeBufferPointer { txPtr in
            try pkBuf.withUnsafeBufferPointer { pkPtr in
                guard let tx = txPtr.baseAddress, let pk = pkPtr.baseAddress else {
                    throw NSError(domain: "FFIError", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Null C string buffer"])
                }
                guard let rawPtr = stark_sign_transaction(tx, pk) else {
                    throw NSError(domain: "FFIError", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "Rust returned null"])
                }
                let json = String(cString: rawPtr)
                free_rust_string(UnsafeMutablePointer(mutating: rawPtr))
                return json
            }
        }
        guard let data = result.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "FFIError", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot parse sign result: \(result)"])
        }
        if let ok = dict["Ok"] as? [String: String],
           let r = ok["r"], let s = ok["s"] {
            return ECDSASignature(r: r, s: s)
        }
        let errMsg = dict["Error"] as? String ?? dict["Err"] as? String ?? result
        throw NSError(domain: "CryptoFFI", code: 4,
                      userInfo: [NSLocalizedDescriptionKey: "Sign error: \(errMsg)"])
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Phase 20: Unshield STARK Proof Generation
    // ─────────────────────────────────────────────────────────────────────────

    /// Generates a Stwo STARK proof for an unshield operation.
    /// - Parameters:
    ///   - note: The input note being unshielded (must include Merkle witness data)
    ///   - amountLow: u256 low part of the withdrawal amount (hex)
    ///   - amountHigh: u256 high part of the withdrawal amount (hex)
    ///   - recipient: Recipient ContractAddress (hex)
    ///   - asset: Asset ContractAddress (hex)
    ///   - historicRoot: Merkle root to verify against (hex)
    /// - Returns: UnshieldPayload with proof, nullifier, and historic_root
    static func generateUnshieldProof(
        note: Note,
        amountLow: String,
        amountHigh: String,
        recipient: String,
        asset: String,
        historicRoot: String
    ) async throws -> UnshieldPayload {
        let input = UnshieldInput(
            note: note,
            amount_low: amountLow,
            amount_high: amountHigh,
            recipient: recipient,
            asset: asset,
            historic_root: historicRoot
        )

        let inputData = try JSONEncoder().encode(input)
        guard let inputString = String(data: inputData, encoding: .utf8) else {
            throw NSError(domain: "StarkVeilProver", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Unshield input could not be UTF-8 encoded"])
        }

        let cStringBuffer = inputString.utf8CString

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                cStringBuffer.withUnsafeBufferPointer { buffer in
                    guard let baseAddress = buffer.baseAddress else {
                        continuation.resume(throwing: NSError(
                            domain: "FFIError", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "C string buffer has no base address"]))
                        return
                    }

                    let resultPtr = generate_unshield_proof(baseAddress)
                    guard let resultPtr = resultPtr else {
                        continuation.resume(throwing: NSError(
                            domain: "FFIError", code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "Rust returned null for unshield proof"]))
                        return
                    }

                    let resultString = String(cString: resultPtr)
                    free_rust_string(UnsafeMutablePointer(mutating: resultPtr))

                    guard let resultData = resultString.data(using: .utf8) else {
                        continuation.resume(throwing: NSError(
                            domain: "FFIError", code: 3,
                            userInfo: [NSLocalizedDescriptionKey: "FFI response is not valid UTF-8"]))
                        return
                    }

                    do {
                        let ffiResult = try JSONDecoder().decode(UnshieldFFIResult.self, from: resultData)
                        switch ffiResult {
                        case .success(let payload):
                            continuation.resume(returning: payload)
                        case .error(let message):
                            continuation.resume(throwing: NSError(
                                domain: "ProverError", code: 4,
                                userInfo: [NSLocalizedDescriptionKey: message]))
                        }
                    } catch {
                        continuation.resume(throwing: NSError(
                            domain: "FFIError", code: 5,
                            userInfo: [
                                NSLocalizedDescriptionKey: "UnshieldFFIResult decode failed: \(error.localizedDescription)",
                                NSUnderlyingErrorKey: error
                            ]))
                    }
                }
            }
        }
    }
}
