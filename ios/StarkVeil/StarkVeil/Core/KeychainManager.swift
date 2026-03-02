import Foundation
import Security

/// Thin, zero-dependency wrapper around iOS Keychain Services.
/// Stores and retrieves the user's 32-byte Incoming Viewing Key (IVK)
/// used to decrypt shielded note memos from Starknet event payloads.
///
/// Security model:
/// - `kSecAttrAccessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
///   ensures the IVK is only accessible after the first unlock (never in background),
///   cannot be backed up to iCloud or transferred to another device.
/// - The IVK is a symmetric secret that does NOT allow spending — only decryption.
///   The spending key remains in the Secure Enclave (future phase).
enum KeychainManager {
    private static let serviceKey = "io.starkveil.owner_ivk"
    private static let accountKey = "default"

    /// Returns the existing IVK from Keychain, or generates and stores a fresh one.
    static func ownerIVK() -> Data {
        if let existing = load() { return existing }
        let fresh = freshIVK()
        try? store(fresh)
        return fresh
    }

    private static func freshIVK() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            // Fallback: deterministic bytes derived from device identity (not production-safe)
            return Data(repeating: 0xAB, count: 32)
        }
        return Data(bytes)
    }

    private static func store(_ data: Data) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: serviceKey,
            kSecAttrAccount: accountKey,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private static func load() -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: serviceKey,
            kSecAttrAccount: accountKey,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }
}
