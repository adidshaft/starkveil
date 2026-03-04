import Foundation
import CryptoKit

// MARK: - Starknet Transaction Builder  (V3 — exact spec from docs.starknet.io)
//
// Source: https://docs.starknet.io/learn/cheatsheets/transactions-reference
//
// INVOKE v3 hash:
//   h( "invoke", version, sender_address,
//      h(tip, l1_gas_bounds, l2_gas_bounds, l1_data_gas_bounds),
//      h(paymaster_data), chain_id, nonce, data_availability_modes,
//      h(account_deployment_data), h(calldata) )
//
// DEPLOY_ACCOUNT v3 hash:
//   h( "deploy_account", version, contract_address,
//      h(tip, l1_gas_bounds, l2_gas_bounds, l1_data_gas_bounds),
//      h(paymaster_data), chain_id, nonce, data_availability_modes,
//      h(constructor_calldata), class_hash, contract_address_salt )
//
// Resource bound encoding:
//   resource_name(60 bits) | max_amount(64 bits) | max_price_per_unit(128 bits)
//   Resource names (ASCII felt252):
//     L1_GAS  = 0x4c315f474153     (60-bit)
//     L2_GAS  = 0x4c325f474153     (60-bit)
//     L1_DATA = 0x4c315f44415441   (60-bit)
//
// DA modes: 0(188 bits) | nonce_da_mode(32 bits) | fee_da_mode(32 bits)
//   L1=0, so both L1/L1 => 0x0
//
// h = Poseidon hash

enum StarknetTransactionBuilder {

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Chain IDs (felt252-encoded ASCII)
    // ─────────────────────────────────────────────────────────────────────────

    enum ChainID {
        static let sepolia = "0x534e5f5345504f4c4941"  // felt252("SN_SEPOLIA")
        static let mainnet = "0x534e5f4d41494e"         // felt252("SN_MAIN")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Resource name constants (ASCII → felt252, 60-bit prefix slot)
    // ─────────────────────────────────────────────────────────────────────────

    /// felt252("L1_GAS") = 0x4c315f474153
    private static let L1_GAS_NAME:  UInt64 = 0x4c315f474153
    /// felt252("L2_GAS") = 0x4c325f474153
    private static let L2_GAS_NAME:  UInt64 = 0x4c325f474153
    /// felt252("L1_DATA") = 0x4c315f44415441
    private static let L1_DATA_NAME: UInt64 = 0x4c315f44415441

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - INVOKE v3: build, hash, sign
    // ─────────────────────────────────────────────────────────────────────────

    static func buildAndSign(
        senderAddress: String,
        calldata: [String],
        resourceBounds: ResourceBoundsMapping,
        nonce: String,
        chainID: String = ChainID.sepolia,
        privateKey: String
    ) throws -> (txHash: String, signature: [String]) {
        let txHash = try invokeV3Hash(
            senderAddress: senderAddress,
            calldata: calldata,
            resourceBounds: resourceBounds,
            nonce: nonce,
            chainID: chainID
        )
        let sig = try StarkVeilProver.signTransaction(txHash: txHash, privateKey: privateKey)
        return (txHash: txHash, signature: [sig.r, sig.s])
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - INVOKE v3 hash
    // ─────────────────────────────────────────────────────────────────────────

    static func invokeV3Hash(
        senderAddress: String,
        calldata: [String],
        resourceBounds: ResourceBoundsMapping,
        nonce: String,
        chainID: String = ChainID.sepolia
    ) throws -> String {
        // Per spec:
        // h("invoke", version, sender_address,
        //   h(tip, l1_gas_bounds, l2_gas_bounds, l1_data_gas_bounds),
        //   h(paymaster_data), chain_id, nonce, da_modes,
        //   h(account_deployment_data), h(calldata))
        let invokePrefix = "0x696e766f6b65"  // felt252("invoke")
        let version      = "0x3"
        let tip          = "0x0"

        // Gas bounds inner hash: h(tip, l1_gas_bounds, l2_gas_bounds, l1_data_gas_bounds)
        let l1Bound  = encodeResourceBound(name: L1_GAS_NAME,  bound: resourceBounds.l1_gas)
        let l2Bound  = encodeResourceBound(name: L2_GAS_NAME,  bound: resourceBounds.l2_gas)
        let l1dBound = encodeResourceBound(name: L1_DATA_NAME, bound: resourceBounds.l1_data_gas)
        let gasHash  = try StarkVeilProver.poseidonHash(elements: [tip, l1Bound, l2Bound, l1dBound])

        let paymasterHash       = try StarkVeilProver.poseidonHash(elements: [])  // empty array
        let acctDeployDataHash  = try StarkVeilProver.poseidonHash(elements: [])  // empty array
        let calldataHash        = try StarkVeilProver.poseidonHash(elements: calldata)

        // DA modes: L1/L1 → 0x0
        let daModes = "0x0"

        let elements = [
            invokePrefix,
            version,
            senderAddress,
            gasHash,
            paymasterHash,
            chainID,
            nonce,
            daModes,
            acctDeployDataHash,
            calldataHash
        ]
        return try StarkVeilProver.poseidonHash(elements: elements)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - DEPLOY_ACCOUNT v3 hash
    // ─────────────────────────────────────────────────────────────────────────

    static func deployAccountHash(
        contractAddress: String,
        constructorCalldata: [String],
        classHash: String,
        salt: String,
        resourceBounds: ResourceBoundsMapping,
        nonce: String = "0x0",
        chainID: String = ChainID.sepolia
    ) throws -> String {
        // Per spec:
        // h("deploy_account", version, contract_address,
        //   h(tip, l1_gas_bounds, l2_gas_bounds, l1_data_gas_bounds),
        //   h(paymaster_data), chain_id, nonce, da_modes,
        //   h(constructor_calldata), class_hash, contract_address_salt)
        let deployPrefix = "0x6465706c6f795f6163636f756e74"  // felt252("deploy_account")
        let version      = "0x3"
        let tip          = "0x0"

        let l1Bound  = encodeResourceBound(name: L1_GAS_NAME,  bound: resourceBounds.l1_gas)
        let l2Bound  = encodeResourceBound(name: L2_GAS_NAME,  bound: resourceBounds.l2_gas)
        let l1dBound = encodeResourceBound(name: L1_DATA_NAME, bound: resourceBounds.l1_data_gas)
        let gasHash  = try StarkVeilProver.poseidonHash(elements: [tip, l1Bound, l2Bound, l1dBound])

        let paymasterHash       = try StarkVeilProver.poseidonHash(elements: [])
        let constructorHash     = try StarkVeilProver.poseidonHash(elements: constructorCalldata)
        let daModes             = "0x0"

        let elements = [
            deployPrefix,
            version,
            contractAddress,
            gasHash,
            paymasterHash,
            chainID,
            nonce,
            daModes,
            constructorHash,
            classHash,
            salt
        ]
        return try StarkVeilProver.poseidonHash(elements: elements)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Resource bound encoding
    //
    // Spec: resource_name(60 bits) | max_amount(64 bits) | max_price_per_unit(128 bits)
    // Total: 252 bits = fits in one felt252
    //
    // Packed as a single big integer:
    //   value = (name << 192) | (max_amount << 128) | max_price_per_unit
    // ─────────────────────────────────────────────────────────────────────────

    static func encodeResourceBound(name: UInt64, bound: ResourceBound) -> String {
        // Parse max_amount (u64) and max_price_per_unit (u128)
        let amountHex = bound.max_amount.hasPrefix("0x")
            ? String(bound.max_amount.dropFirst(2)) : bound.max_amount
        let priceHex = bound.max_price_per_unit.hasPrefix("0x")
            ? String(bound.max_price_per_unit.dropFirst(2)) : bound.max_price_per_unit

        // Pad to exact widths: amount=16 hex chars (64 bits), price=32 hex chars (128 bits)
        let amountPadded = String(repeating: "0", count: max(0, 16 - amountHex.count)) + amountHex
        let pricePadded  = String(repeating: "0", count: max(0, 32 - priceHex.count))  + priceHex

        // Resource name in hex, no leading 0x — already a 60-bit value, fits in 15 hex chars
        let nameHex = String(name, radix: 16)

        // Concatenate: name(15 hex) | amount(16 hex) | price(32 hex) = 63 hex = 252 bits
        return "0x" + nameHex + amountPadded + pricePadded
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Legacy (Pedersen) helper — kept for internal note commitments
    // ─────────────────────────────────────────────────────────────────────────

    static func hashOnElements(_ elements: [String]) throws -> String {
        var h = "0x0"
        for element in elements {
            h = try StarkVeilProver.pedersenHash(a: h, b: element)
        }
        h = try StarkVeilProver.pedersenHash(a: h, b: "0x\(String(elements.count, radix: 16))")
        return h
    }
}
