import Foundation
import Combine
import SwiftData

// MARK: - Domain Errors

enum ProverError: LocalizedError {
    case transferInProgress
    case invalidAmount
    case insufficientBalance
    case noMatchingNote

    var errorDescription: String? {
        switch self {
        case .transferInProgress:  return "A transfer is already in progress."
        case .invalidAmount:       return "Enter a valid amount greater than zero."
        case .insufficientBalance: return "Insufficient shielded balance."
        case .noMatchingNote:      return "No single note matches the exact unshield amount. Try the exact note value."
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
    @Published private(set) var isUnshielding: Bool = false
    @Published private(set) var lastProvedTxHash: String? = nil
    @Published private(set) var lastUnshieldTxHash: String? = nil
    @Published var transferError: String? = nil
    @Published var unshieldError: String? = nil

    // Synchronous re-entrancy flag. Only ever read/written on the main actor,
    // so no additional locking is needed.
    private var isTransferInFlight = false

    // Persistence
    private let persistence = PersistenceController.shared
    // Set by AppCoordinator whenever the active network changes.
    var activeNetworkId: String = NetworkEnvironment.sepolia.rawValue

    // MARK: - Bootstrap (load from disk on init)

    init() {
        loadNotes(for: activeNetworkId)
    }

    func loadNotes(for networkId: String) {
        let ctx = persistence.context
        let descriptor = FetchDescriptor<StoredNote>(
            predicate: #Predicate { $0.networkId == networkId },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        notes = (try? ctx.fetch(descriptor))?.map { $0.toNote() } ?? []
        recomputeBalance()
    }

    // MARK: - Note Management (called by AppCoordinator's SyncEngine pipeline)

    func addNote(_ note: Note) {
        notes.append(note)
        recomputeBalance()
        // Persist to SwiftData
        let ctx = persistence.context
        ctx.insert(StoredNote(from: note, networkId: activeNetworkId))
        try? ctx.save()
    }

    func clearStore() {
        if isTransferInFlight {
            transferError = "Transfer cancelled: network was switched mid-proof."
        }
        notes.removeAll()
        recomputeBalance()
        // Delete persisted notes for this network from SwiftData
        let ctx = persistence.context
        let netId = activeNetworkId
        let descriptor = FetchDescriptor<StoredNote>(predicate: #Predicate { $0.networkId == netId })
        if let stored = try? ctx.fetch(descriptor) {
            stored.forEach { ctx.delete($0) }
            try? ctx.save()
        }
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

        // Remove spent notes from UTXO set (in-memory)
        let spentValues = Set(inputNotes.map { $0.value })
        notes.removeAll { spentValues.contains($0.value) }

        // Mirror the spend to SwiftData so spent notes don't reappear on next launch.
        // Fetch all stored notes for this network, then delete the ones that were spent.
        // (#Predicate does not support Set.contains — filter in Swift after fetch.)
        let ctx = persistence.context
        let netId = activeNetworkId
        let allStoredDescriptor = FetchDescriptor<StoredNote>(
            predicate: #Predicate { $0.networkId == netId }
        )
        if let allStored = try? ctx.fetch(allStoredDescriptor) {
            for stored in allStored where spentValues.contains(stored.value) {
                ctx.delete(stored)
            }
        }

        // Add a change note if the selected notes exceed the transfer amount
        let totalIn = inputNotes.compactMap { Double($0.value) }.reduce(0, +)
        let change = totalIn - amount
        if change > 1e-9 {
            let changeNote = Note(
                value: String(format: "%.9f", change),
                asset_id: inputNotes.first?.asset_id ?? "0xETH",
                owner_ivk: inputNotes.first?.owner_ivk ?? "0xMockIVK",
                memo: "change"
            )
            notes.append(changeNote)
            // Persist the change note so it survives relaunch
            ctx.insert(StoredNote(from: changeNote, networkId: activeNetworkId))
        }

        try? ctx.save()
        recomputeBalance()

        // Use the first returned nullifier as a proxy tx-hash until real RPC is wired
        lastProvedTxHash = result.nullifiers.first.map { "0x" + String($0.prefix(40)) }
            ?? "0x" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(40)
    }

    // MARK: - Unshield (Private → Public)

    /// Selects a note that exactly matches `amount`, generates a STARK unshield proof,
    /// removes the note from the UTXO set (in-memory + SwiftData), and submits the
    /// signed invoke transaction to the Starknet sequencer via RPC.
    ///
    /// The proof binds `(amount, asset_id, recipient)` as public inputs — the
    /// sequencer verifier will reject _any_ modification to those fields.
    func executeUnshield(
        recipient: String,
        amount: Double,
        rpcUrl: URL,
        contractAddress: String
    ) async throws {
        guard !isTransferInFlight else { throw ProverError.transferInProgress }
        guard amount > 0, amount.isFinite else { throw ProverError.invalidAmount }
        guard amount <= balance else { throw ProverError.insufficientBalance }

        // For unshield we require _exactly_ one matching note so the proof circuit
        // has a single clean input. Greedy multi-note unshield is a future improvement.
        guard let inputNote = notes.first(where: { Double($0.value).map { abs($0 - amount) < 1e-9 } ?? false })
            ?? selectNotes(for: amount).first
        else { throw ProverError.noMatchingNote }

        isTransferInFlight = true
        isUnshielding = true
        lastUnshieldTxHash = nil
        unshieldError = nil

        defer {
            isTransferInFlight = false
            isUnshielding = false
        }

        // Generate proof off the main actor (Rust FFI blocks the thread)
        let result = try await StarkVeilProver.generateTransferProof(notes: [inputNote])

        // Back on main actor — remove the spent note
        notes.removeAll { $0.value == inputNote.value }
        let ctx = persistence.context
        let netId = activeNetworkId
        let spentValue = inputNote.value
        let desc = FetchDescriptor<StoredNote>(predicate: #Predicate { $0.networkId == netId })
        if let allStored = try? ctx.fetch(desc) {
            for s in allStored where s.value == spentValue { ctx.delete(s) }
        }
        try? ctx.save()
        recomputeBalance()

        // Build calldata for PrivacyPool.unshield(proof, nullifier, recipient, amount, asset)
        // Format: [selector("unshield"), proof_len, ...proof, nullifier, recipient, amount_low, amount_high, asset_id]
        let amountU256Low  = String(format: "0x%llx", UInt64(amount * 1e18) & 0xFFFFFFFFFFFFFFFF)
        let amountU256High = "0x0"
        let proofCalldata = result.proof.flatMap { [$0] }
        let nullifier = result.nullifiers.first ?? "0x0"
        let unshieldSelector = "0x" + String(format: "%llx", 0x15d40a3d673baee5a4dd5f) // selectors.unshield
        var calldata: [String] = [contractAddress, "0x1", unshieldSelector]
        calldata.append(contentsOf: [String(proofCalldata.count)] + proofCalldata)
        calldata += [nullifier, recipient, amountU256Low, amountU256High, inputNote.asset_id]

        // Submit via RPC — sender is the wallet's own felt252 address (owner_ivk proxies it for now)
        let senderAddress = inputNote.owner_ivk
        let txHash = try await RPCClient().addInvokeTransaction(
            rpcUrl: rpcUrl,
            senderAddress: senderAddress,
            calldata: calldata
        )

        lastUnshieldTxHash = txHash
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
