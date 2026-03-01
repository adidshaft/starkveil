import Foundation
import Combine

// MARK: - Domain Errors

enum ProverError: LocalizedError {
    case transferInProgress
    case invalidAmount
    case insufficientBalance

    var errorDescription: String? {
        switch self {
        case .transferInProgress:  return "A transfer is already in progress."
        case .invalidAmount:       return "Enter a valid amount greater than zero."
        case .insufficientBalance: return "Insufficient shielded balance."
        }
    }
}

// MARK: - Wallet State

/// All @Published mutations happen on the MainActor.
/// Callers from async Task contexts automatically hop back to the main actor
/// after each suspension point because the class is isolated to @MainActor.
@MainActor
class WalletManager: ObservableObject {

    // Single source of truth for the UTXO set
    @Published private(set) var notes: [Note] = []
    // Derived: sum of note values. Updated by recomputeBalance() after any note change.
    @Published private(set) var balance: Double = 0.0

    @Published private(set) var isProving: Bool = false
    @Published private(set) var lastProvedTxHash: String? = nil
    // Exposed so VaultView can display it without a separate @State errorMessage
    @Published var transferError: String? = nil

    // Synchronous re-entrancy flag. Only ever read/written on the main actor,
    // so no additional locking is needed.
    private var isTransferInFlight = false

    // MARK: - Note Management (called by AppCoordinator's SyncEngine pipeline)

    func addNote(_ note: Note) {
        notes.append(note)
        recomputeBalance()
    }

    private func recomputeBalance() {
        balance = notes.compactMap { Double($0.value) }.reduce(0, +)
    }

    // MARK: - Transfer

    func executePrivateTransfer(recipient: String, amount: Double) async throws {
        // --- Synchronous guards (run on main actor before first suspension) ---
        guard !isTransferInFlight else { throw ProverError.transferInProgress }
        guard amount > 0, amount.isFinite else { throw ProverError.invalidAmount }
        guard amount <= balance else { throw ProverError.insufficientBalance }

        isTransferInFlight = true
        isProving = true
        lastProvedTxHash = nil
        transferError = nil

        // defer runs on main actor (same isolation as the enclosing function)
        defer {
            isTransferInFlight = false
            isProving = false
        }

        // Greedy note selection — Phase 5 can replace with optimal coin selection
        let inputNotes = selectNotes(for: amount)

        // --- Suspension point: proof runs on global queue in StarkVeilProver ---
        // The main actor is released here and resumes automatically after await.
        let result = try await StarkVeilProver.generateTransferProof(notes: inputNotes)

        // --- Back on main actor ---
        print("STARK Proof generated: \(result.proof)")

        // Remove spent notes from UTXO set
        let spentValues = Set(inputNotes.map { $0.value })
        notes.removeAll { spentValues.contains($0.value) }

        // Add a change note if the selected notes exceed the transfer amount
        let totalIn = inputNotes.compactMap { Double($0.value) }.reduce(0, +)
        let change = totalIn - amount
        if change > 1e-9 {
            notes.append(Note(
                value: String(format: "%.9f", change),
                asset_id: inputNotes.first?.asset_id ?? "0xETH",
                owner_ivk: inputNotes.first?.owner_ivk ?? "0xMockIVK",
                memo: "change"
            ))
        }

        recomputeBalance()

        // Use the first returned nullifier as a proxy tx-hash until real RPC is wired
        lastProvedTxHash = result.nullifiers.first.map { "0x" + String($0.prefix(40)) }
            ?? "0x" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(40)
    }

    // MARK: - Private Helpers

    /// Simple greedy UTXO selection. Picks notes in insertion order until the
    /// accumulated value covers `amount`. Phase 5 should replace with
    /// privacy-optimal selection (fewest notes, smallest change).
    private func selectNotes(for amount: Double) -> [Note] {
        var selected: [Note] = []
        var accumulated = 0.0
        for note in notes {
            guard let v = Double(note.value) else { continue }
            selected.append(note)
            accumulated += v
            if accumulated >= amount { break }
        }
        return selected
    }
}
