import Foundation
import CryptoKit

// MARK: - Starknet Account Abstraction  (Phase 11)
//
// Derivation chain (building on KeyDerivationEngine):
//
//   BIP-39 mnemonic
//     → PBKDF2/HKDF → master seed (KeyDerivationEngine)
//     → STARK private key = HKDF(chainRoot, info: "starkveil-stark-pk-v1"), clamped to STARK_ORDER
//     → STARK public key  = stark_pubkey(private_key)   [Grumpkin/STARK curve Gx multiplication]
//     → Account address   = Pedersen(OZ_CLASS_HASH, pubkey)  [deterministic, matches OpenZeppelin v0.8]
//
// The user's Starknet account address is FULLY DETERMINISTIC from their 12-word seed.
// Deleting and reinstalling the app then entering the same mnemonic restores the same address.
//
// Deploy flow:
//   1. App computes address before any on-chain activity.
//   2. User funds the address with ETH (for gas) from any source.
//   3. User taps "Activate Wallet" → app broadcasts starknet_addDeployAccountTransaction.
//   4. Once confirmed, senderAddress is used for all future invokes (Shield, Transfer, Unshield).

// MARK: - Constants

enum StarknetCurve {
    /// STARK curve order (also the field prime for scalar arithmetic).
    /// P = 2^251 + 17*2^192 + 1  (from StarkWare spec)
    static let order = BigUInt(
        hex: "0800000000000011000000000000000000000000000000000000000000000001"
    )!

    /// OpenZeppelin Account v0.8.1 class hash on Starknet Mainnet & Sepolia.
    /// Used to compute the counterfactual deploy address before deployment.
    static let ozAccountClassHash = "0x061dac032f228abef9c6626f995015233097ae253a7f72d68552db02f2971b8f"

    /// Starknet Pedersen hash constants (Cairo felt252 arithmetic).
    /// These are the generator point x/y from the STARK-friendly curve.
    static let generatorX = BigUInt(
        hex: "01ef15c18599971b7beced415a40f0c7deacfd9b0d1819e03d723d8bc943cfca"
    )!
    static let generatorY = BigUInt(
        hex: "005668060aa49730b7be4801df46ec62de53ecd11abe43a32873000c36e8dc1f"
    )!
}

// MARK: - BigUInt (minimal, sufficient for 252-bit Starknet scalars)

/// Minimal arbitrary-precision unsigned integer sufficient for 252-bit Starknet scalars.
/// This avoids pulling in a third-party dependency (Attabit, BigInt, etc.).
struct BigUInt: Equatable, Comparable {
    var words: [UInt64]  // little-endian

    static let zero = BigUInt(words: [0])
    static let one  = BigUInt(words: [1])

    init(words: [UInt64]) {
        var w = words
        while w.count > 1 && w.last == 0 { w.removeLast() }
        self.words = w
    }

    init(_ value: UInt64) { self.init(words: [value]) }

    init?(hex: String) {
        let s = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        let padded = s.count % 16 == 0 ? s : String(repeating: "0", count: 16 - s.count % 16) + s
        var w: [UInt64] = []
        var i = padded.endIndex
        while i > padded.startIndex {
            let start = padded.index(i, offsetBy: -16, limitedBy: padded.startIndex) ?? padded.startIndex
            guard let v = UInt64(padded[start..<i], radix: 16) else { return nil }
            w.append(v)
            i = start
        }
        self.init(words: w)
    }

    var hexString: String {
        var s = words.reversed().map { String(format: "%016llx", $0) }.joined()
        s = String(s.drop(while: { $0 == "0" }))
        return s.isEmpty ? "0" : ("0x" + s)
    }

    static func < (lhs: BigUInt, rhs: BigUInt) -> Bool {
        let n = max(lhs.words.count, rhs.words.count)
        for i in stride(from: n - 1, through: 0, by: -1) {
            let l = i < lhs.words.count ? lhs.words[i] : 0
            let r = i < rhs.words.count ? rhs.words[i] : 0
            if l != r { return l < r }
        }
        return false
    }

    static func + (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        let n = max(lhs.words.count, rhs.words.count)
        var result = [UInt64]()
        var carry: UInt64 = 0
        for i in 0..<n {
            let l = i < lhs.words.count ? lhs.words[i] : 0
            let r = i < rhs.words.count ? rhs.words[i] : 0
            let (s1, o1) = l.addingReportingOverflow(r)
            let (s2, o2) = s1.addingReportingOverflow(carry)
            result.append(s2)
            carry = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        if carry > 0 { result.append(carry) }
        return BigUInt(words: result)
    }

    static func - (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        var result = [UInt64]()
        var borrow: UInt64 = 0
        for i in 0..<lhs.words.count {
            let l = lhs.words[i]
            let r = i < rhs.words.count ? rhs.words[i] : 0
            let (s1, o1) = l.subtractingReportingOverflow(r)
            let (s2, o2) = s1.subtractingReportingOverflow(borrow)
            result.append(s2)
            borrow = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        return BigUInt(words: result)
    }

    func mod(_ m: BigUInt) -> BigUInt {
        var r = self
        while r >= m { r = r - m }
        return r
    }
}

// MARK: - Starknet Account Engine

enum StarknetAccount {

    // MARK: - Public API

    struct AccountKeys {
        /// 252-bit STARK private key (clamped to STARK curve order).
        let privateKey: BigUInt
        /// 252-bit STARK public key (x-coordinate of private_key * G).
        let publicKey: BigUInt
        /// Deterministic counterfactual account address (OZ v0.8 compute_address).
        let address: String
    }

    /// Derives the complete STARK keypair and account address from the stored master seed.
    /// Returns nil if the wallet has not been set up yet.
    static func deriveAccountKeys() -> AccountKeys? {
        guard let seed = KeychainManager.masterSeed() else { return nil }
        return deriveAccountKeys(fromSeed: seed)
    }

    /// Derives the complete STARK keypair and address from raw seed bytes.
    static func deriveAccountKeys(fromSeed seed: Data) -> AccountKeys {
        // 1. Derive a 32-byte STARK-specific private key material via HKDF
        let chainRoot = hmacSHA256(key: Data("Starknet seed v0".utf8), data: seed)

        // 2. M-KEY-BIAS fix: use rejection-sampling (grindKey) instead of modular reduction.
        //    Modular reduction biases the key distribution toward the low range of [0, order).
        //    grindKey hashes with an incrementing counter until the result < order.
        let privateKey = grindKey(chainRoot: chainRoot)

        // 3. Compute STARK public key
        let publicKey = starkPublicKey(privateKey: privateKey)

        // 4. Compute OZ v0.8 counterfactual address
        let address = computeOZAccountAddress(publicKey: publicKey)

        return AccountKeys(privateKey: privateKey, publicKey: publicKey, address: address)
    }

    // MARK: - Address computation

    /// Computes the counterfactual OpenZeppelin v0.8 account address.
    /// Formula: contract_address = hash('STARKNET_CONTRACT_ADDRESS', deployer, salt, class_hash, calldata_hash, length)
    /// where salt = pubkey, deployer = 0, calldata = [pubkey]
    static func computeOZAccountAddress(publicKey: BigUInt) -> String {
        #if !DEBUG
        // C-STUB compile guard: stub address computation MUST NOT reach Release builds.
        // Replace starkPublicKey() and pedersenHash() with real FFI before switching to Release.
        #error("StarknetAccount uses stub cryptography. Wire real Pedersen + EC multiply from Rust FFI before Release.")
        #endif

        let classHash = BigUInt(hex: StarknetCurve.ozAccountClassHash)!
        let salt      = publicKey
        let deployer  = BigUInt.zero

        // H-CALLDATA-LEN fix: OZ compute_hash_on_elements hashes elements THEN appends the
        // length as a final element. Missing the length makes the hash structurally wrong.
        // calldata = [pubkey] → hash = pedersenHash(pedersenHash(0, pubkey), 1)
        var calldataHash = pedersenHash(a: BigUInt.zero, b: publicKey)
        calldataHash = pedersenHash(a: calldataHash, b: BigUInt(1)) // length = 1

        let prefix = BigUInt(hex: "535441524b4e45545f434f4e54524143545f41444452455353")!
        var h = pedersenHash(a: BigUInt.zero, b: prefix)
        h = pedersenHash(a: h, b: deployer)
        h = pedersenHash(a: h, b: salt)
        h = pedersenHash(a: h, b: classHash)
        h = pedersenHash(a: h, b: calldataHash)
        h = pedersenHash(a: h, b: BigUInt(5)) // H-CALLDATA-LEN: outer element count = 5

        // M-WRONG-MASK fix: mask to STARK curve order, not an ad-hoc 251-bit value.
        // Using order ensures the address is always a valid field element.
        return h.mod(StarknetCurve.order).hexString
    }

    // MARK: - Cryptographic primitives

    /// HMAC-SHA256 helper (wraps CryptoKit).
    static func hmacSHA256(key: Data, data: Data) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))
        return Data(mac)
    }

    /// HKDF-SHA256 helper reusing CryptoKit.
    static func hkdfSHA256(ikm: Data, info: String, length: Int) -> Data {
        let infoData = Data(info.utf8)
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            info: infoData,
            outputByteCount: length
        )
        return key.withUnsafeBytes { Data($0) }
    }

    /// M-KEY-BIAS fix: grindKey rejection-sampling.
    /// Derives a private key by repeatedly hashing with an incrementing counter until
    /// the result falls strictly within [1, STARK_ORDER). This produces a uniform distribution.
    static func grindKey(chainRoot: Data) -> BigUInt {
        let order = StarknetCurve.order
        var counter: UInt8 = 0
        while true {
            var data = chainRoot
            data.append(counter)
            let digest = SHA256.hash(data: data)
            let candidate = BigUInt(hex: digest.map { String(format: "%02x", $0) }.joined())!
            if candidate >= BigUInt(1) && candidate < order {
                return candidate
            }
            counter &+= 1  // wrapping add — loops at most ~2^6 times statistically
        }
    }

    /// Stub STARK public key derivation (SHA-256 approximation).
    /// MUST be replaced with StarkVeilProver.starkPublicKey() before Release.
    static func starkPublicKey(privateKey: BigUInt) -> BigUInt {
        #if !DEBUG
        #error("starkPublicKey() is a stub. Wire real EC multiply from Rust FFI before Release.")
        #endif
        var combined = Data(privateKey.hexString.utf8)
        combined.append(Data("stark-pubkey-v1".utf8))
        let digest = SHA256.hash(data: combined)
        let raw = BigUInt(hex: digest.map { String(format: "%02x", $0) }.joined())!
        return raw.mod(StarknetCurve.order)
    }

    /// Pedersen hash (simplified — one round of the STARK-friendly hash).
    /// Full Pedersen is defined over the STARK curve shift and constant points.
    /// This implementation follows CairoVM's compute_hash_on_elements ordering.
    ///
    /// Replace with the native Poseidon/Pedersen once the Rust SDK exposes pedersen().
    static func pedersenHash(a: BigUInt, b: BigUInt) -> BigUInt {
        // Hash(a, b) = SHA3-256(a_bytes || b_bytes) mod STARK_ORDER
        // This is NOT the real Pedersen but is structurally identical in how
        // address computation is chained — safe to substitute until FFI is wired.
        var data = Data()
        let aHex = a.hexString.replacingOccurrences(of: "0x", with: "")
        let bHex = b.hexString.replacingOccurrences(of: "0x", with: "")
        data.append(Data(aHex.utf8))
        data.append(Data(bHex.utf8))
        let digest = SHA256.hash(data: data)
        let raw = BigUInt(hex: digest.map { String(format: "%02x", $0) }.joined())!
        return raw.mod(StarknetCurve.order)
    }
}
