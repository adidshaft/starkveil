import Foundation
import CryptoKit

// MARK: - Starknet Transaction Builder  (Phase 13)
//
// Computes the real INVOKE_V1 transaction hash per the Starknet spec:
//   https://docs.starknet.io/documentation/architecture_and_concepts/Network_Architecture/transactions/#v1_hash_calculation
//
// Hash formula (Pedersen chained):
//   tx_hash = H(
//     "invoke",          // prefix
//     version,           // 0x1
//     sender_address,
//     entry_point_selector, // always 0x0 for INVOKE_V1
//     calldata_hash,     // compute_hash_on_elements(calldata)
//     max_fee,
//     chain_id,
//     nonce
//   )
//
// After Phase 12, pedersenHash uses the real Cairo hash via Rust FFI.

enum StarknetTransactionBuilder {

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Chain IDs (felt252-encoded ASCII)
    // ─────────────────────────────────────────────────────────────────────────

    enum ChainID {
        /// Starknet Sepolia testnet:  felt252("SN_SEPOLIA")
        static let sepolia  = "0x534e5f5345504f4c4941"
        /// Starknet Mainnet:         felt252("SN_MAIN")
        static let mainnet  = "0x534e5f4d41494e"
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Main entry point
    // ─────────────────────────────────────────────────────────────────────────

    /// Builds, hashes, and signs an INVOKE_V1 transaction.
    ///
    /// - Parameters:
    ///   - senderAddress: The deployed account address (hex felt252).
    ///   - calldata: Array of felt252 calldata elements.
    ///   - maxFee: Max fee in wei (hex felt252).
    ///   - nonce: Account nonce from starknet_getNonce (hex felt252).
    ///   - chainID: Chain ID (use `ChainID.sepolia` or `ChainID.mainnet`).
    ///   - privateKey: STARK spending key (hex felt252).
    ///
    /// - Returns: `(txHash, signature)` ready to pass to RPCClient.addInvokeTransaction.
    static func buildAndSign(
        senderAddress: String,
        calldata: [String],
        maxFee: String,
        nonce: String,
        chainID: String = ChainID.sepolia,
        privateKey: String
    ) throws -> (txHash: String, signature: [String]) {

        // 1. Compute calldata hash: compute_hash_on_elements(calldata)
        //    = pedersenHash( pedersenHash( ... pedersenHash(0, c[0]), c[1] ... ), len )
        let calldataHash = try hashOnElements(calldata)

        // 2. Compute tx hash per INVOKE_V1 spec
        let invokePrefix = "0x696e766f6b65" // felt252("invoke")
        let version     = "0x1"
        let epSelector  = "0x0"  // INVOKE_V1 always uses 0x0 entry point

        let elements = [
            invokePrefix,
            version,
            senderAddress,
            epSelector,
            calldataHash,
            maxFee,
            chainID,
            nonce
        ]
        let txHash = try hashOnElements(elements)

        // 3. Sign the tx hash with the spending key
        let sig = try StarkVeilProver.signTransaction(txHash: txHash, privateKey: privateKey)

        return (txHash: txHash, signature: [sig.r, sig.s])
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - compute_hash_on_elements
    //
    // Cairo spec: hash = pedersenHash( pedersenHash( ... H(0, e[0]), e[1] ... ), length )
    // This is equivalent to hashing a vector with a length-suffix.
    // ─────────────────────────────────────────────────────────────────────────

    static func hashOnElements(_ elements: [String]) throws -> String {
        var h = "0x0"
        for element in elements {
            h = try StarkVeilProver.pedersenHash(a: h, b: element)
        }
        // Append length
        h = try StarkVeilProver.pedersenHash(a: h, b: "0x\(String(elements.count, radix: 16))")
        return h
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - DEPLOY_ACCOUNT_V1 hash  (Phase 13)
    //
    // https://docs.starknet.io/documentation/architecture_and_concepts/Network_Architecture/transactions/#deploy_account_hash_calculation
    // tx_hash = H(
    //   "deploy_account",
    //   version,
    //   contract_address,
    //   entry_point_selector, // 0x0
    //   constructor_calldata_hash,
    //   max_fee,
    //   chain_id,
    //   nonce,
    //   class_hash,
    //   contract_address_salt
    // )
    // ─────────────────────────────────────────────────────────────────────────

    static func deployAccountHash(
        contractAddress: String,
        constructorCalldata: [String],
        classHash: String,
        salt: String,
        maxFee: String,
        nonce: String = "0x0",
        chainID: String = ChainID.sepolia
    ) throws -> String {
        let deployPrefix  = "0x6465706c6f795f6163636f756e74" // felt252("deploy_account")
        let version       = "0x1"
        let epSelector    = "0x0"
        let cdHash        = try hashOnElements(constructorCalldata)

        let elements = [
            deployPrefix,
            version,
            contractAddress,
            epSelector,
            cdHash,
            maxFee,
            chainID,
            nonce,
            classHash,
            salt
        ]
        return try hashOnElements(elements)
    }
}
