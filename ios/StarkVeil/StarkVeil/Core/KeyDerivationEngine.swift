import Foundation
import CryptoKit

// MARK: - StarkNet Key Derivation Engine
//
// Derivation chain:
//   BIP-39 mnemonic
//     → PBKDF2-HMAC-SHA512 (2048 rounds) → 64-byte master seed
//     → HMAC-SHA256("Starknet seed v0", master_seed) → 32-byte chain root
//     → IVK  = HKDF-SHA256(chain_root, info: "starkveil-ivk-v1",  length: 32)
//     → SK   = HKDF-SHA256(chain_root, info: "starkveil-sk-v1",   length: 32)
//
// Both IVK and SK are derived from the same seed so both are fully recoverable
// from the 12-word mnemonic phrase on any new device.
//
// Security properties:
// - IVK ≠ SK: different HKDF info strings guarantee key separation.
// - IVK compromise does not reveal SK (one-way HKDF).
// - SK is re-derived on demand alongside IVK, prior to Secure Enclave migration.
// - The mnemonic itself is NEVER stored; only the 64-byte seed reaches Keychain.

enum KeyDerivationEngine {

    // MARK: - Public API

    struct DerivedKeys {
        /// Incoming Viewing Key (32 bytes) — for AES-GCM memo decryption only.
        let ivk: Data
        /// Spending Key material (32 bytes) — authorises nullifier generation.
        let spendingKey: Data
        /// Raw 64-byte master seed for Keychain storage.
        let masterSeed: Data
    }

    /// Full derivation from a validated BIP-39 mnemonic.
    static func deriveKeys(from mnemonic: [String], passphrase: String = "") throws -> DerivedKeys {
        // Step 1: BIP-39 PBKDF2 → 64-byte master seed
        let masterSeed = try BIP39.deriveSeed(from: mnemonic, passphrase: passphrase)

        // Step 2: HMAC-SHA256 with a StarkVeil domain tag → 32-byte chain root
        let chainRoot = starknetChainRoot(from: masterSeed)

        // Step 3: Derive IVK and SK via HKDF-SHA256 with distinct info strings
        let ivk = deriveSubkey(from: chainRoot, info: "starkveil-ivk-v1")
        let sk  = deriveSubkey(from: chainRoot, info: "starkveil-sk-v1")

        return DerivedKeys(ivk: ivk, spendingKey: sk, masterSeed: masterSeed)
    }

    /// Re-derive only the IVK from a stored master seed (used on hot path after unlock).
    static func ivk(fromMasterSeed seed: Data) -> Data {
        let chainRoot = starknetChainRoot(from: seed)
        return deriveSubkey(from: chainRoot, info: "starkveil-ivk-v1")
    }

    /// Re-derive only the spending key from a stored master seed.
    static func spendingKey(fromMasterSeed seed: Data) -> Data {
        let chainRoot = starknetChainRoot(from: seed)
        return deriveSubkey(from: chainRoot, info: "starkveil-sk-v1")
    }

    // MARK: - Private Helpers

    /// HMAC-SHA256("Starknet seed v0", masterSeed) → 32-byte output.
    /// Provides domain separation: IVK/SK from StarkVeil cannot be confused with
    /// keys from other BIP-32 wallets sharing the same mnemonic.
    private static func starknetChainRoot(from masterSeed: Data) -> Data {
        let domainTag = Data("Starknet seed v0".utf8)
        let hmac = HMAC<SHA256>.authenticationCode(for: masterSeed, using: SymmetricKey(data: domainTag))
        return Data(hmac)
    }

    /// HKDF-SHA256 expansion from a 32-byte input key material.
    private static func deriveSubkey(from ikm: Data, info: String) -> Data {
        let infoData = Data(info.utf8)
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            info: infoData,
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }
}
