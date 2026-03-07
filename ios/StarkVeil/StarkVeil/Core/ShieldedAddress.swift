import Foundation

struct ShieldedAddressParts {
    let ivk: String
    let pubkey: String
}

enum ShieldedAddress {
    private static let prefix = "svk:"

    static func format(ivk: String, pubkey: String) -> String {
        "\(prefix)\(ivk):\(pubkey)"
    }

    static func parse(_ raw: String) -> ShieldedAddressParts? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let body: String
        if trimmed.lowercased().hasPrefix(prefix) {
            body = String(trimmed.dropFirst(prefix.count))
        } else {
            body = trimmed
        }

        let parts = body.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 2,
           parts[0].hasPrefix("0x"),
           parts[1].hasPrefix("0x") {
            return ShieldedAddressParts(ivk: parts[0], pubkey: parts[1])
        }

        // Legacy fallback for old `svk:0x...` addresses.
        if parts.count == 1, parts[0].hasPrefix("0x") {
            return ShieldedAddressParts(ivk: parts[0], pubkey: parts[0])
        }

        return nil
    }
}
