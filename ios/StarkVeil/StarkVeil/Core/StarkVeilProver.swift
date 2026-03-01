import Foundation

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

enum FFIResult: Decodable {
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
}
