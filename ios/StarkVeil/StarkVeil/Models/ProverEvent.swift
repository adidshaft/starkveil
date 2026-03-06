import Foundation
import SwiftData

// MARK: - ProverEvent Kind

enum ProverEventKind: String, Codable {
    case transfer = "transfer"
    case unshield = "unshield"
}

// MARK: - ProverEvent Model

/// A persistent record of every on-device Stwo STARK proof that was synthesised.
/// Shown in the Prove tab so the user can see the prover running natively on A-series silicon.
@Model
final class ProverEvent {
    @Attribute(.unique) var id: UUID
    var kindRaw: String             // ProverEventKind.rawValue
    var timestamp: Date
    var proofElementCount: Int      // number of felt252 elements in the serialised proof
    var noteCommitment: String      // the note commitment that was spent
    var historicRoot: String        // Merkle root the proof was built against
    var nullifier: String           // the revealed nullifier
    var durationMs: Double          // wall-clock time to generate proof (ms)
    var networkId: String
    var txHash: String?             // filled in after the tx is accepted on-chain

    init(kind: ProverEventKind,
         proofElementCount: Int,
         noteCommitment: String,
         historicRoot: String,
         nullifier: String,
         durationMs: Double,
         networkId: String,
         txHash: String? = nil) {
        self.id              = UUID()
        self.kindRaw         = kind.rawValue
        self.timestamp       = Date()
        self.proofElementCount = proofElementCount
        self.noteCommitment  = noteCommitment
        self.historicRoot    = historicRoot
        self.nullifier       = nullifier
        self.durationMs      = durationMs
        self.networkId       = networkId
        self.txHash          = txHash
    }

    var kind: ProverEventKind { ProverEventKind(rawValue: kindRaw) ?? .transfer }
}
