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

enum FFIResult: Codable {
    case success(TransferPayload)
    case error(String)
    
    // Custom decoding to match Rust's Enum memory layout
    enum CodingKeys: String, CodingKey {
        case Success
        case Error
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let payload = try? container.decode(TransferPayload.self, forKey: .Success) {
            self = .success(payload)
            return
        }
        if let errorString = try? container.decode(String.self, forKey: .Error) {
            self = .error(errorString)
            return
        }
        throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Invalid FFIResult shape"))
    }
}

// MARK: - ZK Prover Service

class StarkVeilProver {
    
    /// Generates a Zero-Knowledge proof natively using the Rust FFI framework.
    /// - Parameter notes: Array of input notes constraints.
    /// - Returns: The signed payload ready to be sent to the StarkVeil Cairo Contract.
    static func generateTransferProof(notes: [Note]) async throws -> TransferPayload {
        let encoder = JSONEncoder()
        let notesData = try encoder.encode(notes)
        guard let notesString = String(data: notesData, encoding: .utf8) else {
            throw NSError(domain: "StarkVeilProver", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid Notes JSON String"])
        }
        
        // Ensure bridging thread-safety if the C function is heavily blocking
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                
                // 1. Cross the FFI boundary
                // Note: generate_transfer_proof is the C function mapped from the Rust bridging header
                notesString.withCString { cString in
                    let resultPtr = generate_transfer_proof(cString)
                    guard let resultPtr = resultPtr else {
                        continuation.resume(throwing: NSError(domain: "FFIError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Rust returned a null pointer"]))
                        return
                    }
                    
                    // 2. Read string back into Swift ARC memory space safely
                    let resultString = String(cString: resultPtr)
                    
                    // 3. Immediately ask Rust to free its memory allocation to prevent memory leaks!
                    free_rust_string(resultPtr)
                    
                    // 4. Decode the result into Swift Type
                    guard let resultData = resultString.data(using: .utf8) else {
                        continuation.resume(throwing: NSError(domain: "FFIError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid UTF8 boundary crossover"]))
                        return
                    }
                    
                    do {
                        let decoder = JSONDecoder()
                        let ffiResult = try decoder.decode(FFIResult.self, from: resultData)
                        
                        switch ffiResult {
                        case .success(let payload):
                            continuation.resume(returning: payload)
                        case .error(let message):
                            continuation.resume(throwing: NSError(domain: "ProverError", code: 3, userInfo: [NSLocalizedDescriptionKey: message]))
                        }
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
}
