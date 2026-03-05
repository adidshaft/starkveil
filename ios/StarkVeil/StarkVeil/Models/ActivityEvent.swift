import Foundation
import SwiftData

// MARK: - ActivityEvent Kind

enum ActivityKind: String, Codable {
    case deposit   = "deposit"   // Shielded: incoming from chain (shield op)
    case transfer  = "transfer"  // Private transfer — outgoing (sent)
    case received  = "received"  // Private transfer — incoming (received)
    case unshield  = "unshield"  // Unshield to a public recipient
    case publicSend = "publicSend" // Public ERC-20 send
}

// MARK: - ActivityEvent Model

/// A persistent record of every privacy-pool operation the user performed.
/// Stored independently of the live UTXO set so spent notes don't vanish from history.
@Model
final class ActivityEvent {
    @Attribute(.unique) var id: UUID
    var kindRaw: String           // ActivityKind.rawValue
    var amount: String            // human-readable STRK, e.g. "1.5"
    var assetId: String
    var counterparty: String      // recipient address (unshield) or shielded memo (transfer)
    var txHash: String?           // on-chain tx hash, nil until confirmed
    var fee: String?              // estimated fee in STRK, e.g. "0.000123", nil if unknown
    var timestamp: Date
    var networkId: String

    init(
        kind: ActivityKind,
        amount: String,
        assetId: String,
        counterparty: String,
        txHash: String? = nil,
        fee: String? = nil,
        networkId: String
    ) {
        self.id = UUID()
        self.kindRaw = kind.rawValue
        self.amount = amount
        self.assetId = assetId
        self.counterparty = counterparty
        self.txHash = txHash
        self.fee = fee
        self.timestamp = Date()
        self.networkId = networkId
    }

    var kind: ActivityKind { ActivityKind(rawValue: kindRaw) ?? .deposit }

    /// True if this event represents funds arriving into the shielded pool for this user.
    var isIncoming: Bool {
        switch kind {
        case .deposit, .received: return true
        case .transfer, .unshield, .publicSend: return false
        }
    }
}
