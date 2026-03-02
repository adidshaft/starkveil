import Foundation
import SwiftData

/// Persisted UTXO note stored in SwiftData, surviving across app launches.
/// Mirrors the in-memory `Note` struct but adds created-at and network scope.
@Model
final class StoredNote {
    @Attribute(.unique) var id: UUID
    var value: String
    var asset_id: String
    var owner_ivk: String
    var memo: String
    var createdAt: Date
    var networkId: String // "Mainnet" or "Sepolia Testnet"

    init(from note: Note, networkId: String) {
        self.id = UUID()
        self.value = note.value
        self.asset_id = note.asset_id
        self.owner_ivk = note.owner_ivk
        self.memo = note.memo
        self.createdAt = Date()
        self.networkId = networkId
    }

    func toNote() -> Note {
        Note(value: value, asset_id: asset_id, owner_ivk: owner_ivk, memo: memo)
    }
}
