import Foundation
import SwiftData

/// Persisted UTXO note stored in SwiftData, surviving across app launches.
/// Mirrors the in-memory `Note` struct but adds created-at and network scope.
///
/// KEY INVARIANT: `commitment` stores the ACTUAL Poseidon Merkle leaf that was
/// submitted to the on-chain PrivacyPool contract. This is the ground truth used
/// for nullifier derivation: nullifier = Poseidon(commitment, spendingKey).
///
/// Two code paths populate StoredNote:
///   1. executeShield: commitment = StarkVeilProver.noteCommitment(value, asset, pubkey, nonce)
///   2. SyncEngine:    commitment = event.data[3]  (already on-chain — no reconstruction needed)
///
/// C-4 fix: Added `leafPosition` and `merklePathJSON` for Merkle witness persistence.
/// Without these fields, notes loaded from SwiftData after app restart would fail
/// at the Rust FFI boundary with "missing required field: leaf_position".
@Model
final class StoredNote {
    @Attribute(.unique) var id: UUID
    var value: String          // raw wei string, e.g. "100000000000000000"
    var asset_id: String
    var owner_ivk: String
    var owner_pubkey: String   // STARK public key used in Poseidon commitment
    var nonce: String          // felt252 hex nonce used in Poseidon commitment
    var commitment: String     // THE actual on-chain Merkle leaf — set by both shield and sync paths
    var memo: String
    var createdAt: Date
    var networkId: String
    var isPendingSpend: Bool = false
    var leafPosition: Int?          // C-4 fix: u32 Merkle leaf index from the Shielded event
    var merklePathJSON: String?     // C-4 fix: JSON array of 20 sibling hashes, stored as String

    init(from note: Note, networkId: String, commitment: String = "",
         leafPosition: Int? = nil, merklePath: [String]? = nil) {
        self.id           = UUID()
        self.value        = note.value
        self.asset_id     = note.asset_id
        self.owner_ivk    = note.owner_ivk
        self.owner_pubkey = note.owner_pubkey
        self.nonce        = note.nonce
        self.commitment   = commitment
        self.memo         = note.memo
        self.createdAt    = Date()
        self.networkId    = networkId
        self.leafPosition   = leafPosition
        self.merklePathJSON = merklePath.flatMap { try? JSONEncoder().encode($0) }
                                        .flatMap { String(data: $0, encoding: .utf8) }
    }

    func toNote() -> Note {
        let path = merklePathJSON
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) }
        return Note(value: value, asset_id: asset_id, owner_ivk: owner_ivk,
                    owner_pubkey: owner_pubkey, nonce: nonce, spending_key: nil,
                    memo: memo, leaf_position: leafPosition.map { UInt32($0) },
                    merkle_path: path, commitment: commitment.isEmpty ? nil : commitment)
    }
}
