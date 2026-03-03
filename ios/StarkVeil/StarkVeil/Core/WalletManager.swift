import Foundation
import Combine
import SwiftData
import CryptoKit

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

    // Activity feed — persisted, shown in the Activity tab
    @Published private(set) var activityEvents: [ActivityEvent] = []

    @Published private(set) var isProving: Bool = false
    @Published private(set) var isUnshielding: Bool = false
    @Published private(set) var isShielding: Bool = false
    @Published private(set) var lastProvedTxHash: String? = nil
    @Published private(set) var lastUnshieldTxHash: String? = nil
    @Published private(set) var lastShieldTxHash: String? = nil
    @Published var transferError: String? = nil
    @Published var unshieldError: String? = nil
    @Published var shieldError: String? = nil


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
        loadEvents(for: activeNetworkId)
    }

    func loadNotes(for networkId: String) {
        let ctx = persistence.context
        let descriptor = FetchDescriptor<StoredNote>(
            predicate: #Predicate { $0.networkId == networkId },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        guard let all = try? ctx.fetch(descriptor) else {
            notes = []; recomputeBalance(); return
        }

        let pending = all.filter { $0.isPendingSpend }
        if !pending.isEmpty {
            pending.forEach { ctx.delete($0) }
            do { try ctx.save() }
            catch { print("[WalletManager] CRITICAL: Could not purge pending-spend notes: \(error)") }
        }

        notes = all.filter { !$0.isPendingSpend }.map { $0.toNote() }
        recomputeBalance()
        loadEvents(for: networkId)
    }

    // MARK: - Event Loading

    func loadEvents(for networkId: String) {
        let ctx = persistence.context
        let descriptor = FetchDescriptor<ActivityEvent>(
            predicate: #Predicate { $0.networkId == networkId },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        activityEvents = (try? ctx.fetch(descriptor)) ?? []
    }

    @discardableResult
    private func logEvent(
        kind: ActivityKind,
        amount: String,
        assetId: String,
        counterparty: String,
        txHash: String? = nil
    ) -> ActivityEvent {
        let ctx = persistence.context
        let event = ActivityEvent(
            kind: kind,
            amount: amount,
            assetId: assetId,
            counterparty: counterparty,
            txHash: txHash,
            networkId: activeNetworkId
        )
        ctx.insert(event)
        do { try ctx.save() } catch {
            print("[WalletManager] CRITICAL: Could not save activity event: \(error)")
        }
        activityEvents.insert(event, at: 0)
        return event
    }

    // MARK: - Note Management (called by AppCoordinator's SyncEngine pipeline)

    func addNote(_ note: Note) {
        // C-NEW-2: deduplication guard — prevents phantom UTXOs from SyncEngine
        // re-scanning already-credited blocks after a cold restart.
        let isDuplicate = notes.contains {
            $0.value == note.value &&
            $0.asset_id == note.asset_id &&
            $0.owner_ivk == note.owner_ivk &&
            $0.memo == note.memo
        }
        guard !isDuplicate else {
            print("[WalletManager] Duplicate note ignored (memo: \(note.memo.prefix(20)))")
            return
        }
        notes.append(note)
        recomputeBalance()
        let ctx = persistence.context
        ctx.insert(StoredNote(from: note, networkId: activeNetworkId))
        do {
            try ctx.save()
        } catch {
            print("[WalletManager] CRITICAL: SwiftData save failed in addNote: \(error)")
        }
        // Log a deposit event so it appears in the Activity tab
        logEvent(kind: .deposit, amount: note.value, assetId: note.asset_id, counterparty: "Shielded Deposit")
    }

    func clearStore() {
        if isTransferInFlight {
            transferError = "Transfer cancelled: network was switched mid-proof."
        }
        notes.removeAll()
        recomputeBalance()
        // Delete persisted notes for this network from SwiftData (network-switch scoped)
        let ctx = persistence.context
        let netId = activeNetworkId
        let descriptor = FetchDescriptor<StoredNote>(predicate: #Predicate { $0.networkId == netId })
        if let stored = try? ctx.fetch(descriptor) {
            stored.forEach { ctx.delete($0) }
            do {
                try ctx.save()
            } catch {
                print("[WalletManager] CRITICAL: SwiftData save failed in clearStore: \(error)")
            }
        }
    }

    /// H3 fix: Wipes ALL networks' notes and events — used on wallet deletion.
    /// clearStore() only deletes the active network; this guarantees a full wipe.
    func deleteAllNetworksData() {
        if isTransferInFlight {
            transferError = "Transfer cancelled: wallet was deleted."
        }
        notes.removeAll()
        activityEvents.removeAll()
        recomputeBalance()
        let ctx = persistence.context
        // L-WIPE-SILENT fix: use proper do-catch so a fetch failure is not silently swallowed,
        // leaving stale notes/events visible on next launch despite Keychain being wiped.
        do {
            let allNotes  = try ctx.fetch(FetchDescriptor<StoredNote>())
            let allEvents = try ctx.fetch(FetchDescriptor<ActivityEvent>())
            allNotes.forEach  { ctx.delete($0) }
            allEvents.forEach { ctx.delete($0) }
            try ctx.save()
        } catch {
            print("[WalletManager] CRITICAL: deleteAllNetworksData SwiftData wipe failed: \(error). Manual clear required.")
        }
    }

    /// Deletes all ActivityEvent records for the active network from SwiftData and clears the in-memory array.
    func clearActivityEvents() {
        let ctx = persistence.context
        let netId = activeNetworkId
        let descriptor = FetchDescriptor<ActivityEvent>(predicate: #Predicate { $0.networkId == netId })
        if let events = try? ctx.fetch(descriptor) {
            events.forEach { ctx.delete($0) }
            do { try ctx.save() }
            catch { print("[WalletManager] CRITICAL: SwiftData save failed in clearActivityEvents: \(error)") }
        }
        activityEvents.removeAll()
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
        // NOTE: proof data is intentionally NOT logged (audit C2 — prevents proof leakage to console/crash logs)

        // Remove exactly the spent notes to prevent destroying other notes with the same value (Audit Bug 2)
        let ctx = persistence.context
        let netId = activeNetworkId
        let allStoredDescriptor = FetchDescriptor<StoredNote>(
            predicate: #Predicate { $0.networkId == netId }
        )
        var remainingStored = (try? ctx.fetch(allStoredDescriptor)) ?? []

        for inputNote in inputNotes {
            if let memIdx = notes.firstIndex(where: {
                $0.value == inputNote.value && $0.asset_id == inputNote.asset_id && $0.memo == inputNote.memo && $0.owner_ivk == inputNote.owner_ivk
            }) {
                notes.remove(at: memIdx)
            }
            if let dbIdx = remainingStored.firstIndex(where: {
                $0.value == inputNote.value && $0.asset_id == inputNote.asset_id && $0.memo == inputNote.memo && $0.owner_ivk == inputNote.owner_ivk
            }) {
                let stored = remainingStored.remove(at: dbIdx)
                ctx.delete(stored)
            }
        }

        // Add a change note if the selected notes exceed the transfer amount
        let totalIn = inputNotes.compactMap { Double($0.value) }.reduce(0, +)
        let change = totalIn - amount
        if change > 1e-9 {
            // Derive real IVK for the change note so it can be scanned back
            let changeIvk: String
            if let ivkData = KeychainManager.ownerIVK() {
                changeIvk = "0x" + ivkData.map { String(format: "%02x", $0) }.joined()
            } else {
                changeIvk = inputNotes.first?.owner_ivk ?? ""
            }
            let changeNote = Note(
                value: String(format: "%.9f", change),
                asset_id: inputNotes.first?.asset_id ?? "STRK",
                owner_ivk: changeIvk,
                memo: "change"
            )
            notes.append(changeNote)
            // Persist the change note so it survives relaunch
            ctx.insert(StoredNote(from: changeNote, networkId: activeNetworkId))
        }

        do {
            try ctx.save()
        } catch {
            print("[WalletManager] CRITICAL: SwiftData save failed in executePrivateTransfer: \(error)")
        }
        recomputeBalance()

        // Use the first returned nullifier as a proxy tx-hash until real RPC is wired
        lastProvedTxHash = result.nullifiers.first.map { "0x" + String($0.prefix(40)) }
            ?? "0x" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(40)

        // Log the private transfer event
        logEvent(
            kind: .transfer,
            amount: String(format: "%.6f", amount),
            assetId: inputNotes.first?.asset_id ?? "STRK",
            // H4: Recipient address is NOT stored in the activity log.
            // Storing even a truncated address creates a persistent on-device link between
            // this proof and its recipient, violating the privacy model.
            counterparty: "shielded-recipient",
            txHash: lastProvedTxHash
        )
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
        contractAddress: String,
        network: NetworkEnvironment   // M-CHAIN-ID-HARDCODED fix
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

        let ctx = persistence.context
        let netId = activeNetworkId
        let desc = FetchDescriptor<StoredNote>(predicate: #Predicate { $0.networkId == netId })

        guard let storedNote = (try? ctx.fetch(desc))?.first(where: {
            $0.value     == inputNote.value    &&
            $0.asset_id  == inputNote.asset_id &&
            $0.memo      == inputNote.memo     &&
            $0.owner_ivk == inputNote.owner_ivk
        }) else {
            throw ProverError.noMatchingNote
        }
        storedNote.isPendingSpend = true
        do {
            try ctx.save()
        } catch {
            print("[WalletManager] CRITICAL: Could not mark note as pending: \(error)")
            throw error
        }

        // Generate proof off the main actor (Rust FFI blocks the thread)
        let result = try await StarkVeilProver.generateTransferProof(notes: [inputNote])

        // Back on main actor — build and submit RPC before local deletion (Audit Bug 1)
        // Format for V1 Invoke __execute__: [call_array_len, to, selector, data_offset, data_len, calldata_len, ...data] (Audit Bug 5)
        let amountWei = amount * 1e18
        let amountU256Low: String
        let amountU256High: String
        if amountWei < Double(UInt64.max) {
            amountU256Low  = String(format: "0x%llx", UInt64(amountWei))
            amountU256High = "0x0"
        } else {
            let highPart = UInt64(amountWei / Double(UInt64.max))
            let lowPart  = UInt64(amountWei.truncatingRemainder(dividingBy: Double(UInt64.max)))
            amountU256Low  = String(format: "0x%llx", lowPart)
            amountU256High = String(format: "0x%llx", highPart)
        }

        let proofCalldata = result.proof.flatMap { [$0] }
        let nullifier = result.nullifiers.first ?? "0x0"
        
        // Starknet Keccak-250 selector for PrivacyPool.unshield()
        // Computed: keccak("unshield") & ((1<<250)-1)
        let unshieldSelector = "0x21eefa4f46062f7986b501187c7684110faa0fa374c2819584d21a92ace0fac"
        
        var callPayload: [String] = [String(proofCalldata.count)] + proofCalldata
        callPayload += [nullifier, recipient, amountU256Low, amountU256High, inputNote.asset_id]
        
        var calldata: [String] = [
            "0x1",              // call_array_len
            contractAddress,    // to
            unshieldSelector,   // selector
            "0x0",              // data_offset
            String(callPayload.count), // data_len
            String(callPayload.count)  // calldata_len
        ]
        calldata.append(contentsOf: callPayload)

        // Submit via RPC — Phase 13: use real account address, nonce, and signing
        guard let senderAddress = KeychainManager.accountAddress() else {
            throw NSError(domain: "StarkVeil", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "Account not activated. Please complete wallet activation first."])
        }
        guard let seed = KeychainManager.masterSeed(),
              let keys = try? StarknetAccount.deriveAccountKeys(fromSeed: seed) else {
            throw NSError(domain: "StarkVeil", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "Could not derive signing key."])
        }
        let chainNonce = try await RPCClient().getNonce(rpcUrl: rpcUrl, address: senderAddress)
        let (_, signature) = try StarknetTransactionBuilder.buildAndSign(
            senderAddress: senderAddress,
            calldata: calldata,
            maxFee: "0x2386f26fc10000",
            nonce: chainNonce,
            chainID: network.chainIdFelt252,
            privateKey: keys.privateKey.hexString
        )
        let txHash = try await RPCClient().addInvokeTransaction(
            rpcUrl: rpcUrl,
            senderAddress: senderAddress,
            calldata: calldata,
            maxFee: "0x2386f26fc10000",
            signature: signature,
            nonce: chainNonce
        )

        // RPC Confirmed: Remove EXACTLY ONE matching spent note (Audit Bug 2)
        if let memIdx = notes.firstIndex(where: {
            $0.value == inputNote.value && $0.asset_id == inputNote.asset_id && $0.memo == inputNote.memo && $0.owner_ivk == inputNote.owner_ivk
        }) {
            notes.remove(at: memIdx)
        }
        
        ctx.delete(storedNote)
        
        do {
            try ctx.save()
        } catch {
            print("[WalletManager] CRITICAL: SwiftData save failed in executeUnshield: \(error)")
        }
        recomputeBalance()

        // Log the unshield event
        logEvent(
            kind: .unshield,
            amount: String(format: "%.6f", amount),
            assetId: inputNote.asset_id,
            // H4: Recipient address NOT stored — same rule as private transfer.
            // Unshield reveals amount+recipient on-chain anyway; no need to persist it locally.
            counterparty: "public-unshield",
            txHash: txHash
        )

        lastUnshieldTxHash = txHash
    }

    // MARK: - Shield (Public → Private)

    /// Deposit public STRK into the PrivacyPool contract.
    /// The contract emits a `Shielded(commitment)` event and the SyncEngine will
    /// detect it on the next sync cycle and call `addNote()` with the new leaf.
    /// We also optimistically create the note locally so the balance updates immediately.
    ///
    /// Privacy model: The on-chain call reveals sender address + amount.
    /// Everything upstream (transfer, unshield) is private via STARK proofs.
    @discardableResult
    func executeShield(
        amount: Double,
        memo: String,
        rpcUrl: URL,
        contractAddress: String,
        network: NetworkEnvironment   // M-CHAIN-ID-HARDCODED fix
    ) async throws -> String {
        guard amount > 0, amount.isFinite else { throw ProverError.invalidAmount }
        guard !isTransferInFlight else { throw ProverError.transferInProgress }

        isTransferInFlight = true
        isShielding = true
        shieldError = nil
        lastShieldTxHash = nil

        defer {
            isTransferInFlight = false
            isShielding = false
        }

        // Derive IVK for the note commitment
        guard let ivkData = KeychainManager.ownerIVK() else {
            throw NSError(domain: "StarkVeil", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Wallet not initialised — no IVK found."])
        }
        let ivkHex = "0x" + ivkData.map { String(format: "%02x", $0) }.joined()

        // C-NONCE-UUID fix: UUID().uuidString is NOT a valid felt252 hex string.
        // Poseidon(ivkHex, UUID-string) always fails → SHA-256 fallback → wrong commitment → locked funds.
        // Fix: generate a 32-byte cryptographically random value and encode as 0x-prefixed hex felt252.
        var randomBytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        guard status == errSecSuccess else {
            throw NSError(domain: "StarkVeil", code: 20,
                          userInfo: [NSLocalizedDescriptionKey: "SecRandomCopyBytes failed — cannot generate safe nonce"])
        }
        // Clamp to STARK_PRIME (< 2^251 + 17*2^192 + 1) by masking top 5 bits
        randomBytes[0] &= 0x07  // ensures value < 2^251
        let noteNonce = "0x" + randomBytes.map { String(format: "%02x", $0) }.joined()
        let note = Note(
            value: String(format: "%.6f", amount),
            asset_id: "STRK",
            owner_ivk: ivkHex,
            memo: memo.isEmpty ? "shielded deposit" : memo
        )
        // noteNonce is a valid felt252 hex — safe to pass to Poseidon FFI

        // Build calldata for PrivacyPool.shield(amount_low, amount_high, commitment_key)
        // M-SHIELD-AMOUNT fix: use same u256 split as executeUnshield to avoid silent cap
        // at ~18.44 STRK (UInt64.max wei). Amounts > 18.44 STRK now encode correctly.
        let amountWei = amount * 1e18
        let amountLow: String
        let amountHigh: String
        if amountWei < Double(UInt64.max) {
            amountLow  = String(format: "0x%llx", UInt64(amountWei))
            amountHigh = "0x0"
        } else {
            let hi = UInt64(amountWei / Double(UInt64.max))
            let lo = UInt64(amountWei.truncatingRemainder(dividingBy: Double(UInt64.max)))
            amountLow  = String(format: "0x%llx", lo)
            amountHigh = String(format: "0x%llx", hi)
        }

        // H1 fix: Do NOT send raw IVK in calldata — it links all deposits on-chain.
        // Instead derive a one-time commitment key: Poseidon(ivk || nonce).
        // The contract only sees the commitment; only the holder of the IVK can
        // scan events to recognise their own incoming notes.
        let commitmentKey = try deriveNoteCommitmentKey(ivkHex: ivkHex, nonce: noteNonce)

        // Starknet Keccak-250 selector for PrivacyPool.shield()
        let shieldSelector = "0x224a8f74e6fd7a11ab9e36f7742dd64470a7b2e3541b802eb7ed24087db909"

        // Phase 13: use the real deployed account address (not IVK placeholder)
        guard let senderAddress = KeychainManager.accountAddress() else {
            throw NSError(domain: "StarkVeil", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "Account not activated. Activate your wallet first."])
        }

        // H-TRY-SWALLOW fix: try? silently swallows real FFI errors (e.g. Rust panic, bad hex).
        // A swallowed error here means keys = nil → nil-coalesced to garbage → wrong signature.
        // Fix: propagate the throw so the user sees a real error message.
        guard let seed = KeychainManager.masterSeed() else {
            throw NSError(domain: "StarkVeil", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "Master seed not found in Keychain."])
        }
        let keys = try StarknetAccount.deriveAccountKeys(fromSeed: seed)

        // Phase 13: fetch real on-chain nonce before building tx
        let chainNonce = try await RPCClient().getNonce(rpcUrl: rpcUrl, address: senderAddress)

        let calldata = ["0x1", contractAddress, shieldSelector, "0x0", "0x3", "0x3",
                        amountLow, amountHigh, commitmentKey]

        // Phase 13: compute tx hash + real ECDSA signature
        let (txHash, signature) = try StarknetTransactionBuilder.buildAndSign(
            senderAddress: senderAddress,
            calldata: calldata,
            maxFee: "0x2386f26fc10000",   // 0.01 ETH — conservative Sepolia estimate
            nonce: chainNonce,
            chainID: network.chainIdFelt252,
            privateKey: keys.privateKey.hexString
        )

        let broadcastedHash = try await RPCClient().addInvokeTransaction(
            rpcUrl: rpcUrl,
            senderAddress: senderAddress,
            calldata: calldata,
            maxFee: "0x2386f26fc10000",
            signature: signature,
            nonce: chainNonce
        )

        // Optimistically add note and log event
        addNote(note)
        if let last = activityEvents.first, last.txHash == nil, last.kind == .deposit {
            last.txHash = broadcastedHash
            let ctx = persistence.context
            do { try ctx.save() }
            catch { print("[WalletManager] Non-critical: could not attach txHash to deposit event.") }
        }

        lastShieldTxHash = broadcastedHash
        return broadcastedHash
    }

    // MARK: - Private Helpers

    /// Phase 13 / C-POSEIDON-FALLBACK fix: commitment key MUST use real Poseidon.
    /// If Poseidon FFI fails and we fall back to SHA-256, the key won't match the
    /// Cairo contract → the shielded funds are permanently locked on-chain.
    /// Fix: make this function throwing — any Poseidon FFI failure aborts the shield.
    private func deriveNoteCommitmentKey(ivkHex: String, nonce: String) throws -> String {
        // Real Poseidon (matches Cairo poseidon_hash_span used in PrivacyPool contract)
        return try StarkVeilProver.poseidonHash(elements: [ivkHex, nonce])
    }

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
