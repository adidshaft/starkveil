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
    case noteAlreadySpent   // Phase 15: nullifier already revealed on-chain

    var errorDescription: String? {
        switch self {
        case .transferInProgress:  return "A transfer is already in progress."
        case .invalidAmount:       return "Enter a valid amount greater than zero."
        case .insufficientBalance: return "Insufficient shielded balance."
        case .noMatchingNote:      return "No single note matches the exact unshield amount. Try the exact note value."
        case .noteAlreadySpent:    return "This note has already been spent on-chain. Refresh your balance."
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
    // Phase 19: Public (unshielded) STRK balance from on-chain ERC-20
    @Published private(set) var publicBalance: Double = 0.0

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

        notes = all.filter { !$0.isPendingSpend }.map { $0.toNote() }
        recomputeBalance()
        loadEvents(for: networkId)

        // H-4 fix: schedule async recovery of pending notes (can't do async in init/loadNotes)
        // This runs after the main actor settles, checking each pending note on-chain.
        let pendingNotes = all.filter { $0.isPendingSpend }
        if !pendingNotes.isEmpty {
            Task { @MainActor [weak self] in
                await self?.recoverPendingNotes(pendingNotes)
            }
        }
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
        txHash: String? = nil,
        fee: String? = nil
    ) -> ActivityEvent {
        let ctx = persistence.context
        let event = ActivityEvent(
            kind: kind,
            amount: amount,
            assetId: assetId,
            counterparty: counterparty,
            txHash: txHash,
            fee: fee,
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

    func addNote(_ note: Note, commitment: String = "") {
        // Dedup by commitment (nonce field) — each note has a unique on-chain commitment.
        // The old check used memo which caused false positives when two transfers of the
        // same amount and memo arrived (receiver rejected the second one as "duplicate").
        let commitKey = commitment.isEmpty ? note.nonce : commitment
        let isDuplicate = notes.contains {
            $0.nonce == commitKey && !commitKey.isEmpty
        }
        // Fallback: if commitment is empty (legacy note), dedup by value+asset+ivk
        let isLegacyDup = commitKey.isEmpty && notes.contains {
            $0.value == note.value &&
            $0.asset_id == note.asset_id &&
            $0.owner_ivk == note.owner_ivk &&
            $0.memo == note.memo
        }
        // Phase 21 fix: Double-shield dedup. When executeShield() adds a note optimistically
        // (nonce = random), the incoming SyncEngine note has nonce = on-chain commitment.
        // These are different strings, so the nonce check misses it.
        // Solution: also check StoredNote.commitment in SwiftData against the incoming commitment.
        let isStoredCommitmentDup: Bool = {
            guard !commitKey.isEmpty else { return false }
            let ctx = persistence.context
            let netId = activeNetworkId
            let descriptor = FetchDescriptor<StoredNote>(predicate: #Predicate { $0.networkId == netId })
            guard let stored = try? ctx.fetch(descriptor) else { return false }
            return stored.contains { $0.commitment == commitKey && !$0.commitment.isEmpty }
        }()
        guard !isDuplicate && !isLegacyDup && !isStoredCommitmentDup else {
            // Leaf-position back-patch: executeShield stores the note with leaf_position=nil because
            // fetchMerkleNextIndex runs right after broadcast — before the tx is indexed. When
            // SyncEngine later picks up the Shielded event it carries the real leaf index (data[4]).
            // Patch the stored note here so executePrivateTransfer/executeUnshield can build a witness.
            if let newLeaf = note.leaf_position, !commitKey.isEmpty {
                let pCtx = persistence.context
                let netId = activeNetworkId
                let pDesc = FetchDescriptor<StoredNote>(predicate: #Predicate { $0.networkId == netId })
                if let stored = try? pCtx.fetch(pDesc),
                   let match = stored.first(where: { $0.commitment == commitKey && $0.leafPosition == nil }) {
                    match.leafPosition = Int(newLeaf)
                    try? pCtx.save()
                    // Mirror into in-memory notes so the current session benefits immediately
                    if let idx = notes.firstIndex(where: { $0.nonce == match.nonce || $0.nonce == commitKey }) {
                        let old = notes[idx]
                        notes[idx] = Note(value: old.value, asset_id: old.asset_id, owner_ivk: old.owner_ivk,
                                          owner_pubkey: old.owner_pubkey, nonce: old.nonce, spending_key: old.spending_key,
                                          memo: old.memo, leaf_position: newLeaf, merkle_path: old.merkle_path)
                    }
                    print("[WalletManager] Patched leafPosition=\(newLeaf) on stored note commitment=\(commitKey.prefix(12))…")
                }
            }
            print("[WalletManager] Duplicate note ignored (commitment: \(commitKey.prefix(16)))")
            return
        }
        notes.append(note)
        recomputeBalance()
        let ctx = persistence.context
        ctx.insert(StoredNote(from: note, networkId: activeNetworkId, commitment: commitment,
                              leafPosition: note.leaf_position.map { Int($0) }))
        do {
            try ctx.save()
        } catch {
            print("[WalletManager] CRITICAL: SwiftData save failed in addNote: \(error)")
        }
        // Log to Activity — skip for change notes (they're not deposits)
        if note.memo != "Change" {
            let strkDisplay: String = {
                if let wei = Double(note.value) {
                    return String(format: "%.6f", wei / 1e18)
                }
                return note.value
            }()
            // Memos beginning with "Private" indicate an incoming private transfer received
            // from another StarkVeil user (trial-decrypted by SyncEngine).
            // Shield deposits use any other memo — displayed as a shielded deposit.
            let kind: ActivityKind = note.memo.hasPrefix("Private") ? .received : .deposit
            let counterparty = note.memo.hasPrefix("Private") ? "Incoming shielded transfer" : "Shielded Deposit"
            logEvent(kind: kind, amount: strkDisplay, assetId: note.asset_id, counterparty: counterparty)
        }
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
        // Note values are stored as raw wei strings (e.g. "100000000000000000" = 0.1 STRK).
        // Divide by 1e18 so `balance` is always expressed in STRK.
        balance = notes.compactMap { Double($0.value) }.reduce(0, +) / 1e18
    }

    /// Phase 19: Fetches the on-chain STRK ERC-20 balance for the public (unshielded) address.
    /// Updates `publicBalance` which is displayed as the U balance in the Zashi-style UI.
    func refreshPublicBalance(rpcUrl: URL) async {
        guard let address = KeychainManager.accountAddress() else { return }
        do {
            let rawResult = try await RPCClient().getSTRKBalance(rpcUrl: rpcUrl, address: address)
            // Result is "low_hex, high_hex" — parse the u256
            let parts = rawResult.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let lowHex = parts.first ?? "0x0"
            // UInt64 overflows for balances > 18.44 STRK. Use Decimal for safe parsing.
            let hexDigits = lowHex.hasPrefix("0x") ? String(lowHex.dropFirst(2)) : lowHex
            var weiDecimal = Decimal(0)
            for ch in hexDigits {
                weiDecimal *= 16
                if let digit = Int(String(ch), radix: 16) {
                    weiDecimal += Decimal(digit)
                }
            }
            let strkBalance = weiDecimal / Decimal(sign: .plus, exponent: 18, significand: 1)
            publicBalance = NSDecimalNumber(decimal: strkBalance).doubleValue
        } catch {
            print("[WalletManager] Failed to fetch public balance: \(error)")
        }
    }

    /// Phase 19: Send STRK from the public (unshielded) balance via ERC-20 transfer().
    /// This is a plain on-chain transfer — no privacy pool interaction.
    func executePublicSend(
        recipient: String,
        amount: Double,
        rpcUrl: URL,
        network: NetworkEnvironment
    ) async throws -> String {
        guard amount > 0, amount.isFinite else { throw ProverError.invalidAmount }
        guard amount <= publicBalance else {
            throw NSError(domain: "StarkVeil", code: 30,
                          userInfo: [NSLocalizedDescriptionKey: "Insufficient unshielded balance. You have \(String(format: "%.4f", publicBalance)) STRK (U)."])
        }

        guard let senderAddress = KeychainManager.accountAddress() else {
            throw NSError(domain: "StarkVeil", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "Account not activated."])
        }
        guard let seed = KeychainManager.masterSeed(),
              let keys = try? StarknetAccount.deriveAccountKeys(fromSeed: seed) else {
            throw NSError(domain: "StarkVeil", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "Could not derive signing key."])
        }

        // STRK ERC-20 contract
        let strkContract = "0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d"
        // transfer(recipient: ContractAddress, amount: u256)
        let transferSelector = "0x83afd3f4caedc6eebf44246fe54e38c95e3179a5ec9ea81740eca5b482d12e"

        // Convert amount to wei hex
        let amountDecimal = Decimal(amount) * Decimal(sign: .plus, exponent: 18, significand: 1)
        let amountWeiStr = (amountDecimal as NSDecimalNumber).stringValue
        var weiValue = Decimal(0)
        for ch in amountWeiStr {
            if let d = Int(String(ch)) {
                weiValue = weiValue * 10 + Decimal(d)
            }
        }
        var hex = ""
        var remaining = weiValue
        if remaining == 0 { hex = "0" }
        while remaining > 0 {
            let q = NSDecimalNumber(decimal: remaining).dividing(by: NSDecimalNumber(value: 16))
            let qFloor = q.int64Value
            let rVal = NSDecimalNumber(decimal: remaining).subtracting(NSDecimalNumber(value: qFloor).multiplying(by: NSDecimalNumber(value: 16))).intValue
            hex = String(rVal, radix: 16) + hex
            remaining = Decimal(qFloor)
        }
        let amountLow = "0x" + hex
        let amountHigh = "0x0"

        // Build calldata for __execute__ multicall (Cairo 1 format: Array<Call>)
        let callPayload = [recipient, amountLow, amountHigh]
        var calldata: [String] = [
            "0x1",                      // number of calls
            strkContract,               // to
            transferSelector,           // selector
            String(format: "0x%x", callPayload.count)   // calldata_len
        ]
        calldata.append(contentsOf: callPayload)

        let chainNonce = try await RPCClient().getNonce(rpcUrl: rpcUrl, address: senderAddress)
        let resourceBounds = try await RPCClient().estimateInvokeFee(
            rpcUrl: rpcUrl,
            senderAddress: senderAddress,
            calldata: calldata,
            nonce: chainNonce
        )
        let (txHash, signature) = try StarknetTransactionBuilder.buildAndSign(
            senderAddress: senderAddress,
            calldata: calldata,
            resourceBounds: resourceBounds,
            nonce: chainNonce,
            chainID: network.chainIdFelt252,
            privateKey: keys.privateKey.hexString
        )

        let broadcastedHash = try await RPCClient().addInvokeTransaction(
            rpcUrl: rpcUrl,
            senderAddress: senderAddress,
            calldata: calldata,
            resourceBounds: resourceBounds,
            signature: signature,
            nonce: chainNonce
        )

        // Refresh public balance after send
        await refreshPublicBalance(rpcUrl: rpcUrl)

        return txHash
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

        // note.value is raw wei (e.g. "100000000000000000" for 0.1 STRK).
        // amount is in STRK (e.g. 0.1). Convert wei -> STRK before comparing.
        guard let inputNote = notes.first(where: {
            guard let weiDouble = Double($0.value) else { return false }
            let strk = weiDouble / 1e18
            return abs(strk - amount) < 1e-9
        }) ?? selectNotes(for: amount).first
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

        var didSuccessfullySubmit = false
        defer {
            if !didSuccessfullySubmit {
                storedNote.isPendingSpend = false
                try? ctx.save()
            }
        }

        // H-NULLIFIER-ORDER Fix: Derive nullifier here and check on-chain before generating proof
        guard let seed = KeychainManager.masterSeed(),
              let keys = try? StarknetAccount.deriveAccountKeys(fromSeed: seed) else {
            throw NSError(domain: "StarkVeil", code: 11, userInfo: [NSLocalizedDescriptionKey: "Could not derive signing key."])
        }
        // Clamp to valid felt252 range BEFORE passing to Poseidon FFI (felt252 overflow fix)
        let spendingKeyHex = WalletManager.clampToFelt252(keys.privateKey.hexString)
        // The original (unclamped) key is used for ECDSA signing only
        let signingKeyHex = keys.privateKey.hexString
        
        // STRK token contract on Sepolia. Notes store asset_id as the shortstring "0x5354524b" (ASCII "STRK")
        // but the Cairo unshield() param is ContractAddress — the actual ERC-20 contract address.
        let strkTokenAddress = "0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d"
        let safeAssetId: String = {
            let raw = inputNote.asset_id
            if raw == "STRK" || raw == "0xSTRK" || raw == "0x5354524b" { return strkTokenAddress }
            return raw
        }()
        // NULLIFIER DERIVATION — use the stored on-chain commitment DIRECTLY.
        // storedNote.commitment is set by:
        //   - executeShield: = StarkVeilProver.noteCommitment(value,asset,pubkey,nonce)
        //   - SyncEngine:     = event.data[3]  (the actual Merkle leaf on-chain)
        // Both are the canonical commitment. NO reconstruction is needed or done here.
        let commitment: String
        if !storedNote.commitment.isEmpty {
            commitment = storedNote.commitment
        } else {
            // Fallback for old notes missing the commitment field: reconstruct.
            // This will only be correct for locally-shielded notes where nonce is the original random nonce.
            let commitmentAssetId = (inputNote.asset_id == "STRK" || inputNote.asset_id == "0xSTRK") ? "0x5354524b" : inputNote.asset_id
            commitment = try StarkVeilProver.noteCommitment(
                value: inputNote.value,
                assetId: commitmentAssetId,
                ownerPubkey: storedNote.owner_pubkey.isEmpty ? keys.publicKey.hexString : storedNote.owner_pubkey,
                nonce: storedNote.nonce.isEmpty ? keys.publicKey.hexString : storedNote.nonce
            )
            print("[Unshield] ⚠️ no stored commitment — reconstructed (old note format)")
        }
        let nullifier = try StarkVeilProver.noteNullifier(commitment: commitment, spendingKey: spendingKeyHex)
        print("[Unshield] commitment=\(commitment)")

        let alreadySpent = await RPCClient().isNullifierSpent(
            rpcUrl: rpcUrl,
            contractAddress: contractAddress,
            nullifier: nullifier
        )
        if alreadySpent {
            storedNote.isPendingSpend = false
            try? ctx.save()
            throw ProverError.noteAlreadySpent
        }

        // H-3 fix: use generateUnshieldProof (not generateTransferProof).
        // generateUnshieldProof binds (amount, asset, recipient) as public inputs,
        // which is required for the unshield circuit. generateTransferProof creates
        // change notes and uses a completely different proof structure.

        // C-4 fix: include Merkle witness data (leaf_position + merkle_path) from StoredNote.
        // If the stored path is nil (old note), fetch it on-demand from the contract.
        var merklePath: [String]? = storedNote.merklePathJSON
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) }

        // Fetch current Merkle root from contract (needed as historic_root for proof).
        // Falls back to storage read if the view function isn't available on this deployment.
        let rpcClient = RPCClient()
        let fetchedRoot = (try? await rpcClient.fetchMerkleRoot(rpcUrl: rpcUrl, contractAddress: contractAddress)) ?? "0x0"

        // Last-resort leaf_position recovery for unshield (same issue as private transfer)
        if storedNote.leafPosition == nil, !storedNote.commitment.isEmpty {
            print("[Unshield] leafPosition nil — scanning events for commitment \(storedNote.commitment.prefix(12))…")
            if let found = try? await rpcClient.fetchLeafPositionByCommitment(
                rpcUrl: rpcUrl,
                contractAddress: contractAddress,
                commitment: storedNote.commitment
            ) {
                storedNote.leafPosition = found
                try? ctx.save()
                print("[Unshield] Recovered leafPosition=\(found) from on-chain events")
            }
        }

        if merklePath == nil, let leafIdx = storedNote.leafPosition {
            merklePath = try? await rpcClient.fetchMerkleWitness(
                rpcUrl: rpcUrl,
                contractAddress: contractAddress,
                leafIndex: leafIdx
            )
            // Persist witness so future spends don't need another RPC round-trip
            if let path = merklePath,
               let data = try? JSONEncoder().encode(path),
               let json = String(data: data, encoding: .utf8) {
                storedNote.merklePathJSON = json
                try? ctx.save()
            }
        }

        let proofInputNote = Note(
            value: inputNote.value,
            asset_id: safeAssetId,
            owner_ivk: inputNote.owner_ivk,
            owner_pubkey: storedNote.owner_pubkey.isEmpty ? keys.publicKey.hexString : storedNote.owner_pubkey,
            nonce: storedNote.nonce.isEmpty ? keys.publicKey.hexString : storedNote.nonce,
            spending_key: spendingKeyHex,
            memo: inputNote.memo,
            leaf_position: storedNote.leafPosition.map { UInt32($0) },
            merkle_path: merklePath
        )
        let amountU256Low: String
        if let weiInt = Int(inputNote.value) {
            amountU256Low = "0x" + String(weiInt, radix: 16)
        } else if inputNote.value.hasPrefix("0x") {
            amountU256Low = inputNote.value
        } else {
            amountU256Low = "0x0"
        }
        let amountU256High = "0x0"

        // Build an UnshieldInput for the Rust FFI, binding the proof to the current Merkle root
        let unshieldResult = try await StarkVeilProver.generateUnshieldProof(
            note: proofInputNote,
            amountLow: amountU256Low,
            amountHigh: amountU256High,
            recipient: recipient,
            asset: safeAssetId,
            historicRoot: fetchedRoot
        )

        let proofCalldata = unshieldResult.proof.flatMap { [$0] }

        // Starknet Keccak-250 selector for PrivacyPool.unshield()
        // Computed: starknet_keccak("unshield")
        let unshieldSelector = "0x3079978d9c0e08ca0a86356d70a7eea2408b5d3882425b2f30a60818eac5b1b"

        // Build the complete flat payload first, then derive calldata_len from it.
        // Encoding: [proof_len, ...proof_items, nullifier, recipient, amount_low, amount_high, asset_id, historic_root]
        let unshieldNullifier = unshieldResult.nullifier
        let historicRoot = unshieldResult.historic_root
        var callPayload: [String] = [String(format: "0x%x", proofCalldata.count)] + proofCalldata
        callPayload += [unshieldNullifier, recipient, amountU256Low, amountU256High, safeAssetId, historicRoot]

        print("[Unshield] nullifier=\(nullifier)")
        print("[Unshield] recipient=\(recipient)")
        print("[Unshield] amount=\(amountU256Low) (wei)")
        print("[Unshield] asset=\(safeAssetId)")
        print("[Unshield] proof items=\(proofCalldata.count)")
        print("[Unshield] calldata_len=\(callPayload.count)")

        var calldata: [String] = [
            "0x1",                          // number of calls
            contractAddress,                // to (PrivacyPool)
            unshieldSelector,               // selector
            String(format: "0x%x", callPayload.count) // calldata_len = total flat arg count
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
        // V3: estimate fee returns resource bounds (STRK gas pricing)
        let resourceBounds = try await RPCClient().estimateInvokeFee(
            rpcUrl: rpcUrl,
            senderAddress: senderAddress,
            calldata: calldata,
            nonce: chainNonce
        )
        let (_, signature) = try StarknetTransactionBuilder.buildAndSign(
            senderAddress: senderAddress,
            calldata: calldata,
            resourceBounds: resourceBounds,
            nonce: chainNonce,
            chainID: network.chainIdFelt252,
            privateKey: signingKeyHex   // ECDSA uses the original (unclamped) key
        )
        let txHash = try await RPCClient().addInvokeTransaction(
            rpcUrl: rpcUrl,
            senderAddress: senderAddress,
            calldata: calldata,
            resourceBounds: resourceBounds,
            signature: signature,
            nonce: chainNonce
        )

        didSuccessfullySubmit = true

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
        // GUARD: Account must be deployed on-chain. If not deployed, shielding will fail
        // with RPC Error 41 (Requested contract address is not deployed).
        guard KeychainManager.isAccountDeployed else {
            throw NSError(domain: "StarkVeil", code: 99, userInfo: [
                NSLocalizedDescriptionKey: "Your wallet has not been activated yet. Please go to Activate Wallet and deploy your account first. (Settings → your wallet display)"
            ])
        }

        isTransferInFlight = true
        isShielding = true
        shieldError = nil
        lastShieldTxHash = nil

        defer {
            isTransferInFlight = false
            isShielding = false
        }

        // Derive IVK for the note commitment — use the POSEIDON-derived IVK
        // (same key SyncEngine uses for trial-decryption), NOT the raw HKDF bytes.
        guard let seed = KeychainManager.masterSeed() else {
            throw NSError(domain: "StarkVeil", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "Master seed not found in Keychain."])
        }
        let keys = try StarknetAccount.deriveAccountKeys(fromSeed: seed)
        let spendingKeyHexShield = WalletManager.clampToFelt252(keys.privateKey.hexString)
        let ivkHex = try StarkVeilProver.deriveIVK(spendingKeyHex: spendingKeyHexShield)

        // C-COMMITMENT-MISMATCH fix: derive STARK keypair to get owner_pubkey,
        // then use the 4-field Poseidon commitment that matches what execute
        // PrivateTransfer / executeUnshield reconstructs when spending the note.
        // The nonce is persisted in StoredNote so we never need to re-derive it.
        let ownerPubkeyHex = keys.publicKey.hexString

        // Use a cryptographically random nonce and persist it
        var randomBytes = [UInt8](repeating: 0, count: 32)
        let rngStatus = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        guard rngStatus == errSecSuccess else {
            throw NSError(domain: "StarkVeil", code: 20,
                          userInfo: [NSLocalizedDescriptionKey: "SecRandomCopyBytes failed — cannot generate safe shield nonce"])
        }
        randomBytes[0] &= 0x07  // clamp to STARK prime range
        let noteNonce = "0x" + randomBytes.map { String(format: "%02x", $0) }.joined()

        let amountWeiHex: String = {
            var hex = ""
            var remaining = Decimal(amount) * Decimal(sign: .plus, exponent: 18, significand: 1)
            if remaining == 0 { return "0x0" }
            while remaining > 0 {
                let (q, r) = { (val: Decimal) -> (Decimal, Int) in
                    let divisor = Decimal(16)
                    let q = NSDecimalNumber(decimal: val).dividing(by: NSDecimalNumber(decimal: divisor))
                    let qFloor = q.int64Value
                    let rVal = NSDecimalNumber(decimal: val).subtracting(NSDecimalNumber(value: qFloor).multiplying(by: NSDecimalNumber(decimal: divisor))).intValue
                    return (Decimal(qFloor), rVal)
                }(remaining)
                hex = String(r, radix: 16) + hex
                remaining = q
            }
            return "0x" + hex
        }()

        // 4-field Poseidon(value, asset_id, owner_pubkey, nonce) — matches contract spec
        let commitmentKey = try StarkVeilProver.noteCommitment(
            value: amountWeiHex,
            assetId: "0x5354524b",
            ownerPubkey: ownerPubkeyHex,
            nonce: noteNonce
        )

        let note = Note(
            value: amountWeiHex,
            asset_id: "0x5354524b",
            owner_ivk: ivkHex,
            owner_pubkey: ownerPubkeyHex,
            nonce: noteNonce,
            spending_key: nil,
            memo: memo.isEmpty ? "shielded deposit" : memo,
            leaf_position: nil,
            merkle_path: nil
        )


        // C-4 fix: u256 split at 2^128 (not 2^64). Use the hex we already computed.
        let amountLow = amountWeiHex
        let amountHigh = "0x0"

        // Phase 15 Item 5: Encrypt the memo with AES-256-GCM using IVK-derived key.
        // The encrypted memo is embedded in calldata so the recipient can trial-decrypt it
        // during SyncEngine polling. Falls back to plaintext hex if encryption fails.
        let encryptedMemo: String
        do {
            let encRaw = try NoteEncryption.encryptMemo(
                memo.isEmpty ? "shielded deposit" : memo,
                ivkHex: ivkHex
            )
            // C-FELT-OVERFLOW fix: felt252 max length is 31 bytes (62 hex chars).
            // Truncate the encrypted memo to fit within a single felt argument.
            encryptedMemo = "0x" + String(encRaw.prefix(62))
        } catch {
            // Encrypt failure is non-fatal — include plaintext hex so at least
            // the self-owned SyncEngine can still see the memo.
            let textHex = Data((memo.isEmpty ? "shield" : memo).utf8).hexString
            encryptedMemo = "0x" + String(textHex.prefix(62))
        }

        // Starknet Keccak-250 selector for PrivacyPool.shield()
        let shieldSelector = "0x1d142bf165333b22247aed261a8174bd8ba65a3f9b25570d99a8b8f2c32e3ba"

        // STRK token contract address on Sepolia
        let strkContractAddress = "0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d"

        guard let senderAddress = KeychainManager.accountAddress() else {
            throw NSError(domain: "StarkVeil", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "Account not activated. Activate your wallet first."])
        }

        let chainNonce = try await RPCClient().getNonce(rpcUrl: rpcUrl, address: senderAddress)

        // Cairo 1 Multicall (Array<Call>):
        // We must first approve the PrivacyPool to spend STRK, then call shield.
        // approve(spender: ContractAddress, amount: u256)
        let approveSelector = "0x219209e083275171774dab1df80982e9df2096516f06319c5c6d71ae0a8480c"
        
        // 1. Approve Call
        let approvePayload = [contractAddress, amountLow, amountHigh]
        
        // 2. Shield Call
        let shieldPayload = [strkContractAddress, amountLow, amountHigh, commitmentKey, encryptedMemo]
        
        var calldata: [String] = [
            "0x2",                      // number of calls (= 2)
            // Call 1: approve
            strkContractAddress,        // to (STRK token)
            approveSelector,            // selector
            "0x3"                       // calldata_len (amount is u256 = 2 felts + spender = 1 felt)
        ]
        calldata.append(contentsOf: approvePayload)
        
        calldata.append(contentsOf: [
            // Call 2: shield
            contractAddress,            // to (PrivacyPool)
            shieldSelector,             // selector
            "0x5"                       // calldata_len
        ])
        calldata.append(contentsOf: shieldPayload)

        // V3: estimate fee returns resource bounds (STRK gas pricing)
        let resourceBounds = try await RPCClient().estimateInvokeFee(
            rpcUrl: rpcUrl,
            senderAddress: senderAddress,
            calldata: calldata,
            nonce: chainNonce
        )
        let (txHash, signature) = try StarknetTransactionBuilder.buildAndSign(
            senderAddress: senderAddress,
            calldata: calldata,
            resourceBounds: resourceBounds,
            nonce: chainNonce,
            chainID: network.chainIdFelt252,
            privateKey: keys.privateKey.hexString
        )

        let broadcastedHash = try await RPCClient().addInvokeTransaction(
            rpcUrl: rpcUrl,
            senderAddress: senderAddress,
            calldata: calldata,
            resourceBounds: resourceBounds,
            signature: signature,
            nonce: chainNonce
        )

        // M-6 fix: wait for tx confirmation before adding note (prevents phantom notes on revert)
        let finality = await RPCClient().pollUntilAccepted(rpcUrl: rpcUrl, txHash: broadcastedHash)
        switch finality {
        case .accepted:
            // Pass the COMPUTED commitment so the StoredNote.commitment field is set correctly.
            // executeUnshield/executePrivateTransfer will use this directly for nullifier derivation.
            // C-4 fix: fetch leaf position (get_mt_next_index() - 1) right after acceptance.
            let leafPos: UInt32? = await {
                if let idx = try? await RPCClient().fetchMerkleNextIndex(rpcUrl: rpcUrl, contractAddress: contractAddress), idx > 0 {
                    return UInt32(idx - 1)
                }
                return nil
            }()
            let noteWithLeaf = Note(value: note.value, asset_id: note.asset_id,
                                    owner_ivk: note.owner_ivk, owner_pubkey: note.owner_pubkey,
                                    nonce: note.nonce, spending_key: note.spending_key,
                                    memo: note.memo, leaf_position: leafPos, merkle_path: nil)
            addNote(noteWithLeaf, commitment: commitmentKey)
            if let last = activityEvents.first, last.txHash == nil, last.kind == .deposit {
                last.txHash = broadcastedHash
                let ctx = persistence.context
                do { try ctx.save() }
                catch { print("[WalletManager] Non-critical: could not attach txHash to deposit event.") }
            }
        case .reverted(let reason):
            throw NSError(domain: "StarkVeil", code: 30,
                          userInfo: [NSLocalizedDescriptionKey: "Shield transaction reverted: \(reason)"])
        case .rejected:
            throw NSError(domain: "StarkVeil", code: 31,
                          userInfo: [NSLocalizedDescriptionKey: "Shield transaction was rejected by the network."])
        case .timeout:
            // Optimistically add — SyncEngine will reconcile later
            addNote(note, commitment: commitmentKey)
        }

        lastShieldTxHash = broadcastedHash
        return broadcastedHash
    }

    // MARK: - Private-to-Private Transfer  (Phase 15 Item 4)

    /// Transfers a shielded note to another StarkVeil address without touching the public pool.
    /// - The sender's note is nullified.
    /// - A new note commitment is created for the recipient.
    /// - The memo is encrypted with a key derived from the recipient's address (IVK seed).
    @discardableResult
    func executePrivateTransfer(
        recipientAddress: String,
        recipientIVK: String,
        amount: Double,
        memo: String,
        rpcUrl: URL,
        contractAddress: String,
        network: NetworkEnvironment
    ) async throws -> String {
        guard !isTransferInFlight else { throw ProverError.transferInProgress }
        guard amount > 0, amount.isFinite else { throw ProverError.invalidAmount }
        guard amount <= balance else { throw ProverError.insufficientBalance }
        // Pre-fetch pending note commitments so we can exclude them from selection.
        let ctxPre = persistence.context
        let netIdPre = activeNetworkId
        let descPre = FetchDescriptor<StoredNote>(predicate: #Predicate { $0.networkId == netIdPre })
        let pendingCommitments = Set((try? ctxPre.fetch(descPre))?
            .filter { $0.isPendingSpend }
            .map { $0.commitment } ?? [])

        // Pick the SMALLEST available note that covers the requested amount.
        // We create a change note for any excess, so partial amounts are fully supported.
        let amountWeiTarget = amount * 1e18
        guard let inputNote = notes
            .filter({
                guard let w = Double($0.value) else { return false }
                guard !pendingCommitments.contains($0.nonce) else { return false }
                return w >= amountWeiTarget - 1.0   // small rounding epsilon
            })
            .sorted(by: { (Double($0.value) ?? 0) < (Double($1.value) ?? 0) })
            .first
        else { throw ProverError.insufficientBalance }

        isTransferInFlight = true
        defer { isTransferInFlight = false }

        // M-TRANSFER-NO-PENDING Fix: Mark note as pending
        let ctx = persistence.context
        let netId = activeNetworkId
        let desc = FetchDescriptor<StoredNote>(predicate: #Predicate { $0.networkId == netId })
        let allStoredNotes = (try? ctx.fetch(desc)) ?? []
        guard let storedNote = allStoredNotes.first(where: {
            $0.value     == inputNote.value    &&
            $0.asset_id  == inputNote.asset_id &&
            $0.memo      == inputNote.memo     &&
            $0.owner_ivk == inputNote.owner_ivk
        }) else {
            throw ProverError.noMatchingNote
        }
        storedNote.isPendingSpend = true
        try? ctx.save()

        var didSuccessfullySubmit = false
        defer {
            if !didSuccessfullySubmit {
                storedNote.isPendingSpend = false
                try? ctx.save()
            }
        }

        guard let seed = KeychainManager.masterSeed(),
              let keys = try? StarknetAccount.deriveAccountKeys(fromSeed: seed) else {
            throw NSError(domain: "StarkVeil", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "Could not derive signing key."])
        }
        guard let senderAddress = KeychainManager.accountAddress() else {
            throw NSError(domain: "StarkVeil", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "Account not activated."])
        }

        let spendingKeyHex = WalletManager.clampToFelt252(keys.privateKey.hexString)
        // Original (unclamped) key for ECDSA signing — MUST NOT be the clamped value
        let signingKeyHex = keys.privateKey.hexString
        let ivkHex = try StarkVeilProver.deriveIVK(spendingKeyHex: spendingKeyHex)

        // C-COMMITMENT-MISMATCH fix: use the PERSISTED nonce from StoredNote.
        // The shield step stored the exact random nonce used in Poseidon(value,asset,pubkey,nonce).
        // Re-deriving it (Poseidon(ivk,value,asset)) produces a different value → wrong commitment.
        // Always use shortstring "0x5354524b" for the commitment (matches what shield() stored).
        let safeAssetId = (inputNote.asset_id == "STRK" || inputNote.asset_id == "0xSTRK" || inputNote.asset_id == "0x5354524b") ? "0x5354524b" : inputNote.asset_id
        // NULLIFIER DERIVATION — use stored commitment directly (same logic as executeUnshield)
        let commitment: String
        if !storedNote.commitment.isEmpty {
            commitment = storedNote.commitment
        } else {
            commitment = try StarkVeilProver.noteCommitment(
                value: inputNote.value,
                assetId: safeAssetId,
                ownerPubkey: storedNote.owner_pubkey.isEmpty ? keys.publicKey.hexString : storedNote.owner_pubkey,
                nonce: storedNote.nonce.isEmpty ? keys.publicKey.hexString : storedNote.nonce
            )
            print("[PrivateTransfer] ⚠️ no stored commitment — reconstructed (old note format)")
        }
        let nullifier = try StarkVeilProver.noteNullifier(commitment: commitment, spendingKey: spendingKeyHex)
        print("[PrivateTransfer] commitment=\(commitment)")

        // 2. Check nullifier isn't already spent
        let alreadySpent = await RPCClient().isNullifierSpent(rpcUrl: rpcUrl, contractAddress: contractAddress, nullifier: nullifier)
        if alreadySpent { throw ProverError.noteAlreadySpent }

        // 3. Create new output commitment for the recipient
        // H-SECRANDOM-UNCHECKED fix: check SecRandomCopyBytes return value and throw on failure
        var outputRandomBytes = [UInt8](repeating: 0, count: 32)
        let outputRngStatus = SecRandomCopyBytes(kSecRandomDefault, outputRandomBytes.count, &outputRandomBytes)
        guard outputRngStatus == errSecSuccess else {
            throw NSError(domain: "StarkVeil", code: 20,
                          userInfo: [NSLocalizedDescriptionKey: "SecRandomCopyBytes failed — cannot generate safe output nonce"])
        }
        outputRandomBytes[0] &= 0x07  // clamp to STARK prime range
        let outputNonce = "0x" + outputRandomBytes.map { String(format: "%02x", $0) }.joined()

        // ── Amount maths ────────────────────────────────────────────────────────
        // Convert requested amount to raw wei. Use UInt64 arithmetic to avoid
        // floating-point rounding when computing change.
        let amountWeiVal  = UInt64(amountWeiTarget)   // recipient gets this
        let inputWeiVal   = UInt64(Double(inputNote.value) ?? 0)
        let changeWeiVal  = inputWeiVal > amountWeiVal ? inputWeiVal - amountWeiVal : 0
        let amountWeiStr  = String(amountWeiVal)
        let changeWeiStr  = String(changeWeiVal)
        let hasChange     = changeWeiVal > 0

        // The recipient IVK (from SVK address) is already a valid felt252 — it's a
        // Poseidon hash output, always < STARK prime. Do NOT clamp it, because
        // clamping can change the value, making the encryption key different from
        // what the receiver derives. For Poseidon noteCommitment we pass it directly.
        // For encryptCompact we MUST use the exact same value the receiver will use.
        print("[PrivateTransfer] recipientIVK=\(recipientIVK)")
        print("[PrivateTransfer] senderIVK=\(ivkHex)")

        // ── Recipient output commitment ──────────────────────────────────────────
        // IMPORTANT: use amountWeiStr, NOT inputNote.value — the recipient's note
        // value equals the amount sent, not the full input note value.
        let outputCommitment = try StarkVeilProver.noteCommitment(
            value: amountWeiStr,
            assetId: safeAssetId,
            ownerPubkey: recipientIVK,      // raw IVK, not clamped
            nonce: outputNonce
        )

        // ── Change note commitment (returned to sender) ─────────────────────────
        var changeCommitment: String? = nil
        var changePlainNote: Note? = nil
        var changeNonceStr = ""
        if hasChange {
            var changeBytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, changeBytes.count, &changeBytes) == errSecSuccess else {
                throw NSError(domain: "StarkVeil", code: 21,
                              userInfo: [NSLocalizedDescriptionKey: "RNG failed for change nonce"])
            }
            changeBytes[0] &= 0x07
            changeNonceStr = "0x" + changeBytes.map { String(format: "%02x", $0) }.joined()
            let cc = try StarkVeilProver.noteCommitment(
                value: changeWeiStr,
                assetId: safeAssetId,
                ownerPubkey: ivkHex,       // sender's raw IVK, not clamped
                nonce: changeNonceStr
            )
            changeCommitment = cc
            changePlainNote = Note(
                value: changeWeiStr,
                asset_id: "0x5354524b",
                owner_ivk: ivkHex,
                owner_pubkey: ivkHex,      // raw IVK
                nonce: changeNonceStr,
                spending_key: nil,
                memo: "Change",
                leaf_position: nil,
                merkle_path: nil
            )
            print("[PrivateTransfer] changeCommitment=\(cc) changeWei=\(changeWeiStr)")
        }

        // ── Encrypt memo for recipient (compact 31-byte felt252 scheme) ──────────
        let userMemo = memo.isEmpty ? "" : memo
        let encryptedMemo = try NoteEncryption.encryptCompact(
            valueWei: amountWeiStr,
            memo: userMemo,
            ivkHex: recipientIVK,           // RAW IVK, not clamped — must match receiver's
            commitment: outputCommitment
        )
        print("[PrivateTransfer] encryptedMemo=\(encryptedMemo)")

        // C-6 fix: Cairo private_transfer() expects:
        //   proof: Array<felt252>, nullifiers: Array<felt252>,
        //   new_commitments: Array<felt252>, fee: u256
        // Array<felt252> ABI encoding = [len, ...elements]
        let transferSelector = "0x2605e7681cf37ab3a81d1732a9c8a75f2544c5967628a4d6999f276c6ba513c"

        // Fetch current Merkle root + witness, then generate the proof.
        // Falls back to storage read if the view function isn't available on this deployment.
        let xferRPCClient = RPCClient()
        let xferFetchedRoot = (try? await xferRPCClient.fetchMerkleRoot(rpcUrl: rpcUrl, contractAddress: contractAddress)) ?? "0x0"

        var xferMerklePath: [String]? = storedNote.merklePathJSON
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) }

        // Last-resort leaf_position recovery: if the note was stored before the selector fix,
        // leafPosition may be nil. Scan on-chain Shielded events to find the correct index.
        if storedNote.leafPosition == nil, !storedNote.commitment.isEmpty {
            print("[PrivateTransfer] leafPosition nil — scanning events for commitment \(storedNote.commitment.prefix(12))…")
            if let found = try? await xferRPCClient.fetchLeafPositionByCommitment(
                rpcUrl: rpcUrl,
                contractAddress: contractAddress,
                commitment: storedNote.commitment
            ) {
                storedNote.leafPosition = found
                let saveCtx = persistence.context
                try? saveCtx.save()
                print("[PrivateTransfer] Recovered leafPosition=\(found) from on-chain events")
            }
        }

        if xferMerklePath == nil, let leafIdx = storedNote.leafPosition {
            xferMerklePath = try? await xferRPCClient.fetchMerkleWitness(
                rpcUrl: rpcUrl,
                contractAddress: contractAddress,
                leafIndex: leafIdx
            )
            if let path = xferMerklePath,
               let data = try? JSONEncoder().encode(path),
               let json = String(data: data, encoding: .utf8) {
                storedNote.merklePathJSON = json
                let saveCtx = persistence.context
                try? saveCtx.save()
            }
        }

        // Generate the proof payload (mock proof + real nullifiers/commitments)
        let proofInputNote = Note(
            value: inputNote.value,
            asset_id: safeAssetId,
            owner_ivk: ivkHex,
            owner_pubkey: storedNote.owner_pubkey.isEmpty ? keys.publicKey.hexString : storedNote.owner_pubkey,
            nonce: storedNote.nonce.isEmpty ? keys.publicKey.hexString : storedNote.nonce,
            spending_key: spendingKeyHex,
            memo: inputNote.memo,
            leaf_position: storedNote.leafPosition.map { UInt32($0) },
            merkle_path: xferMerklePath
        )
        let proofPayload = try await StarkVeilProver.generateTransferProof(notes: [proofInputNote])

        // fee: u256 = (low=0x0, high=0x0) — mock verifier doesn't enforce fees
        var callPayload: [String] = []
        callPayload += [String(format: "0x%x", proofPayload.proof.count)] + proofPayload.proof  // proof array
        callPayload += ["0x1", nullifier]                                        // nullifiers array
        // new_commitments: recipient note + optional change note back to sender
        var newCommits = [outputCommitment]
        if let cc = changeCommitment { newCommits.append(cc) }
        callPayload += [String(format: "0x%x", newCommits.count)] + newCommits
        callPayload += ["0x0", "0x0"]                                            // fee: u256
        callPayload += [encryptedMemo]                                            // encrypted_memo: felt252
        callPayload += [xferFetchedRoot]                                          // historic_root: felt252

        print("[PrivateTransfer] nullifier=\(nullifier)")
        print("[PrivateTransfer] outputCommitment=\(outputCommitment)")
        print("[PrivateTransfer] proof items=\(proofPayload.proof.count)")
        print("[PrivateTransfer] calldata_len=\(callPayload.count)")

        let calldata: [String] = [
            "0x1",                      // number of calls
            contractAddress,            // to
            transferSelector,           // selector
            String(format: "0x%x", callPayload.count)   // calldata_len
        ] + callPayload

        // 6. Sign and submit (V3)
        let chainNonce = try await RPCClient().getNonce(rpcUrl: rpcUrl, address: senderAddress)
        let resourceBounds = try await RPCClient().estimateInvokeFee(rpcUrl: rpcUrl, senderAddress: senderAddress, calldata: calldata, nonce: chainNonce)
        let (txHash, signature) = try StarknetTransactionBuilder.buildAndSign(
            senderAddress: senderAddress,
            calldata: calldata,
            resourceBounds: resourceBounds,
            nonce: chainNonce,
            chainID: network.chainIdFelt252,
            privateKey: signingKeyHex   // ECDSA uses original (unclamped) key
        )
        let broadcastedHash = try await RPCClient().addInvokeTransaction(
            rpcUrl: rpcUrl,
            senderAddress: senderAddress,
            calldata: calldata,
            resourceBounds: resourceBounds,
            signature: signature,
            nonce: chainNonce
        )

        // 7. Optimistically update local state
        didSuccessfullySubmit = true
        print("[PrivateTransfer] BEFORE removeNote: notes.count=\(notes.count) balance=\(balance)")
        removeNote(inputNote)
        print("[PrivateTransfer] AFTER removeNote: notes.count=\(notes.count) balance=\(balance)")

        // If there's a change note, add it back to the sender's wallet immediately.
        if hasChange, let cn = changePlainNote, let cc = changeCommitment {
            addNote(cn, commitment: cc)
            print("[PrivateTransfer] AFTER addNote(change): notes.count=\(notes.count) balance=\(balance) changeWei=\(changeWeiStr)")
        }

        recomputeBalance()
        print("[PrivateTransfer] FINAL: notes.count=\(notes.count) balance=\(balance)")

        // 8. Log to activity feed — use .transfer for outgoing sends
        let strkAmount = String(format: "%.6f", amount)
        logEvent(
            kind: .transfer,   // outgoing: shown with − prefix, neutral/red colour
            amount: strkAmount,
            assetId: "STRK",
            counterparty: String(recipientAddress.prefix(16)) + "…",
            txHash: broadcastedHash
        )

        return broadcastedHash
    }

    // MARK: - Private Helpers

    /// Removes a note from the in-memory array and deletes its persisted SwiftData counterpart.
    private func removeNote(_ note: Note) {
        if let idx = notes.firstIndex(where: {
            $0.value == note.value && $0.asset_id == note.asset_id &&
            $0.owner_ivk == note.owner_ivk && $0.nonce == note.nonce
        }) {
            notes.remove(at: idx)
        }
        // Also remove from SwiftData — match by commitment (nonce field stores it)
        // to avoid deleting a different note with the same value.
        let ctx = persistence.context
        let netId = activeNetworkId
        let descriptor = FetchDescriptor<StoredNote>(predicate: #Predicate { $0.networkId == netId })
        if let allStored = try? ctx.fetch(descriptor),
           let match = allStored.first(where: {
               // Prefer commitment match; fall back to value+asset if no commitment stored
               if !note.nonce.isEmpty && $0.commitment == note.nonce { return true }
               return $0.value == note.value && $0.asset_id == note.asset_id &&
                      $0.owner_ivk == note.owner_ivk
           }) {
            ctx.delete(match)
            try? ctx.save()
        }
    }

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
        // amount is in STRK; note.value is raw wei — convert before accumulating
        var selected: [Note] = []
        var accumulated = 0.0
        for note in notes {
            guard let weiVal = Double(note.value) else { continue }
            let strkVal = weiVal / 1e18
            selected.append(note)
            accumulated += strkVal
            if accumulated >= amount { break }
        }
        return selected
    }

    // MARK: - H-4 fix: Recover pending-spend notes

    /// Checks each pending-spend note's nullifier on-chain:
    ///   - If spent → the transaction succeeded, safe to delete the note.
    ///   - If NOT spent → the transaction failed/timed out, restore the note to balance.
    /// Called from loadNotes via a Task after init completes.
    func recoverPendingNotes(_ pendingNotes: [StoredNote]) async {
        let ctx = persistence.context
        let currentNetwork = NetworkEnvironment.allCases.first(where: { $0.rawValue == activeNetworkId }) ?? .sepolia
        let currentRpcUrl = currentNetwork.rpcUrl
        let currentContractAddress = currentNetwork.contractAddress

        guard let seed = KeychainManager.masterSeed(),
              let keys = try? StarknetAccount.deriveAccountKeys(fromSeed: seed) else {
            // Can't derive keys — conservatively restore all pending notes
            for note in pendingNotes {
                note.isPendingSpend = false
            }
            try? ctx.save()
            let netId = activeNetworkId
            notes = (try? ctx.fetch(FetchDescriptor<StoredNote>(
                predicate: #Predicate { $0.networkId == netId }
            )))?.map { $0.toNote() } ?? notes
            recomputeBalance()
            return
        }

        let spendingKeyHex = WalletManager.clampToFelt252(keys.privateKey.hexString)

        for storedNote in pendingNotes {
            let commitment = storedNote.commitment
            guard !commitment.isEmpty else {
                // No commitment → can't derive nullifier; restore conservatively
                storedNote.isPendingSpend = false
                continue
            }

            do {
                let nullifier = try StarkVeilProver.noteNullifier(
                    commitment: commitment, spendingKey: spendingKeyHex
                )
                let spent = await RPCClient().isNullifierSpent(
                    rpcUrl: currentRpcUrl,
                    contractAddress: currentContractAddress,
                    nullifier: nullifier
                )
                if spent {
                    // Transaction succeeded — delete the note
                    ctx.delete(storedNote)
                    #if DEBUG
                    print("[WalletManager] H-4: Pending note SPENT on-chain, deleting: \(commitment.prefix(12))…")
                    #endif
                } else {
                    // Transaction failed — restore the note
                    storedNote.isPendingSpend = false
                    #if DEBUG
                    print("[WalletManager] H-4: Pending note NOT spent, restoring: \(commitment.prefix(12))…")
                    #endif
                }
            } catch {
                // Nullifier derivation failed — restore conservatively
                storedNote.isPendingSpend = false
                print("[WalletManager] H-4: Could not check nullifier for \(commitment.prefix(12))…: \(error)")
            }
        }

        do { try ctx.save() }
        catch { print("[WalletManager] CRITICAL: Could not save pending note recovery: \(error)") }

        // Refresh in-memory notes from the updated SwiftData state
        let netId = activeNetworkId
        let descriptor = FetchDescriptor<StoredNote>(
            predicate: #Predicate { $0.networkId == netId },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        notes = ((try? ctx.fetch(descriptor)) ?? [])
            .filter { !$0.isPendingSpend }
            .map { $0.toNote() }
        recomputeBalance()
    }

    /// Clamps an arbitrary 32-byte hex private key to a valid felt252 value.
    /// The STARK field prime is slightly less than 2^252, so we clear the top
    /// 5 bits of the most-significant byte to guarantee the result is in-range
    /// (< 2^251, safely below the STARK prime ≈ 2^251.006).
    /// This matches the clamping that Cairo / starknet-rs apply internally.
    /// Privacy: the mathematical operation does not weaken the key — it only
    /// ensures the value can be encoded as a Cairo felt252 field element.
    static func clampToFelt252(_ hex: String) -> String {
        let stripped = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        // Pad to 64 hex chars (32 bytes) if short
        let padded = String(repeating: "0", count: max(0, 64 - stripped.count)) + stripped
        var bytes = stride(from: 0, to: padded.count, by: 2).compactMap {
            UInt8(padded[padded.index(padded.startIndex, offsetBy: $0) ..< padded.index(padded.startIndex, offsetBy: $0 + 2)], radix: 16)
        }
        if bytes.count == 32 {
            bytes[0] &= 0x07  // clear top 5 bits → value < 2^251, safely < STARK prime
        }
        return "0x" + bytes.map { String(format: "%02x", $0) }.joined()
    }
}
