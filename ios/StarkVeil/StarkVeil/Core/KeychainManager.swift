import Foundation
import Security

/// Keychain wrapper for StarkVeil.
/// Stores two items:
///   - Master seed (64 bytes): the PBKDF2 output from the BIP-39 mnemonic. All other keys
///     are re-derived from this on demand. Never stored in plaintext anywhere else.
///   - IVK cache (32 bytes): cached derivation of the IVK, re-written after any seed change.
///
/// Security model:
/// - `kSecAttrAccessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
///   denies iCloud backup and cross-device transfer.
/// - The mnemonic itself is NEVER stored — only the 64-byte derived seed.
/// - IVK and spending key are re-derived on demand from the seed via KeyDerivationEngine.
enum KeychainManager {

    // MARK: - Keys

    private static let service = "io.starkveil"

    private enum Account: String {
        case masterSeed       = "master_seed"
        case accountAddress   = "account_address"    // Phase 11: computed Starknet address
        case accountDeployed  = "account_deployed"   // Phase 11: "1" once deploy tx confirmed
    }

    // MARK: - Public API

    /// True if a master seed is already stored (wallet has been set up).
    static var hasWallet: Bool {
        load(account: .masterSeed) != nil
    }

    /// Stores the master seed (64-byte PBKDF2 output) derived from the user's mnemonic.
    static func storeMasterSeed(_ seed: Data) throws {
        // Reset the deployed flag. If the user deleted the app, iOS doesn't wipe Keychain.
        // A new wallet or restored wallet must re-verify deployment state.
        try? store(Data([0]), account: .accountDeployed)
        try store(seed, account: .masterSeed)
    }

    /// Loads the stored master seed and derives the IVK on demand.
    /// Returns `nil` if no wallet has been set up yet.
    static func ownerIVK() -> Data? {
        guard let seed = load(account: .masterSeed) else { return nil }
        return KeyDerivationEngine.ivk(fromMasterSeed: seed)
    }

    /// Returns the raw master seed for key re-derivation (e.g. spending key).
    static func masterSeed() -> Data? {
        load(account: .masterSeed)
    }

    // MARK: - Phase 11: Account Abstraction

    /// Stores (or overwrites) the deterministic Starknet account address.
    static func storeAccountAddress(_ address: String) throws {
        guard let data = address.data(using: .utf8) else { return }
        try store(data, account: .accountAddress)
    }

    /// Returns the stored account address, or nil if not yet computed.
    static func accountAddress() -> String? {
        guard let data = load(account: .accountAddress) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Marks the account as deployed on-chain (called after deploy tx is confirmed).
    static func markAccountDeployed() throws {
        try store(Data([1]), account: .accountDeployed)
    }

    /// Resets the deployed flag without wiping the wallet seed.
    /// Used when on-chain verification shows the Keychain flag is stale.
    static func markAccountNotDeployed() throws {
        try store(Data([0]), account: .accountDeployed)
    }

    /// True once the user has broadcast (and confirmed) the deploy account transaction.
    static var isAccountDeployed: Bool {
        guard let data = load(account: .accountDeployed) else { return false }
        return data.first == 1
    }

    /// Wipes all StarkVeil Keychain items (used during wallet reset / re-import).
    static func deleteWallet() {
        let accounts: [Account] = [.masterSeed, .accountAddress, .accountDeployed]
        for account in accounts {
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account.rawValue
            ]
            SecItemDelete(query as CFDictionary)
        }
    }

    // MARK: - Private Helpers

    private static func store(_ data: Data, account: Account) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account.rawValue,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Keychain write failed for '\(account.rawValue)'. Status: \(status)."])
        }
    }

    private static func load(account: Account) -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account.rawValue,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }
}
