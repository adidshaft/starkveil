import Foundation
import SwiftData

/// Persisted UTXO note stored in SwiftData, surviving across app launches.
/// Mirrors the in-memory `Note` struct but adds created-at and network scope.
///
/// C-COMMITMENT-MISMATCH fix: `nonce` and `owner_pubkey` are now persisted so that
/// `executePrivateTransfer` and `executeUnshield` can reconstruct the canonical
/// Poseidon(value, asset_id, owner_pubkey, nonce) commitment that was submitted
/// to the chain during `executeShield`. Without these two fields the client was
/// forced to re-derive the nonce deterministically, producing a different value
/// and therefore an unspendable commitment.
@Model
final class StoredNote {
    @Attribute(.unique) var id: UUID
    var value: String
    var asset_id: String
    var owner_ivk: String
    var owner_pubkey: String   // STARK public key used in the Poseidon commitment
    var nonce: String          // felt252 hex nonce used in the Poseidon commitment
    var memo: String
    var createdAt: Date
    var networkId: String // "Mainnet" or "Sepolia Testnet"
    var isPendingSpend: Bool = false

    init(from note: Note, networkId: String) {
        self.id          = UUID()
        self.value       = note.value
        self.asset_id    = note.asset_id
        self.owner_ivk   = note.owner_ivk
        self.owner_pubkey = note.owner_pubkey
        self.nonce       = note.nonce
        self.memo        = note.memo
        self.createdAt   = Date()
        self.networkId   = networkId
    }

    func toNote() -> Note {
        Note(value: value, asset_id: asset_id, owner_ivk: owner_ivk,
             owner_pubkey: owner_pubkey, nonce: nonce, spending_key: nil, memo: memo)
    }
}
