import Foundation
import CryptoKit

// MARK: - Core Types matching Rust FFI

struct Note: Codable {
    let value: String
    let asset_id: String
    let owner_ivk: String
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
        let errMsg = dict["Err"] as? String ?? "Unknown Rust error"
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
    ///   - k:          RFC 6979 deterministic nonce; pass nil to auto-derive.
    ///
    /// - Warning: k MUST be unique per signature. Reusing k leaks the private key.
    static func signTransaction(txHash: String, privateKey: String, k: String? = nil) throws -> ECDSASignature {
        let kValue: String
        if let providedK = k {
            kValue = providedK
        } else {
            // Deterministic k via SHA-256(privkey || txhash) — not full RFC 6979 but
            // avoids nonce reuse since it is deterministic and unique per (key, txHash) pair.
            // Phase 13: replace with the Rust rfc6979 crate for a spec-compliant nonce.
            let combined = Data((privateKey + txHash).utf8)
            let hash = SHA256.hash(data: combined)
            kValue = "0x" + hash.map { String(format: "%02x", $0) }.joined()
        }
        let txBuf = txHash.utf8CString
        let pkBuf = privateKey.utf8CString
        let kBuf  = kValue.utf8CString
        return try txBuf.withUnsafeBufferPointer { txPtr in
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
                    guard let data = json.data(using: .utf8),
                          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let ok = dict["Ok"] as? [String: String],
                          let r = ok["r"], let s = ok["s"] else {
                        let errMsg = (try? JSONSerialization.jsonObject(with: json.data(using: .utf8) ?? Data()) as? [String: Any])?["Err"] as? String ?? json
                        throw NSError(domain: "CryptoFFI", code: 4,
                                      userInfo: [NSLocalizedDescriptionKey: errMsg])
                    }
                    return ECDSASignature(r: r, s: s)
                }
            }
        }
    }
}
