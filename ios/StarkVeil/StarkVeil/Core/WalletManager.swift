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
        // Persist the ACTUAL on-chain commitment so executeUnshield/executePrivateTransfer
        // can use it directly for nullifier derivation without reconstruction.
        ctx.insert(StoredNote(from: note, networkId: activeNetworkId, commitment: commitment))
        do {
            try ctx.save()
        } catch {
            print("[WalletManager] CRITICAL: SwiftData save failed in addNote: \(error)")
        }
        // Log a deposit event so it appears in the Activity tab.
        // Convert raw wei string → STRK for human-readable display.
        let strkDisplay: String = {
            if let wei = Double(note.value) {
                return String(format: "%.6f", wei / 1e18)
            }
            return note.value
        }()
        logEvent(kind: .deposit, amount: strkDisplay, assetId: note.asset_id, counterparty: "Shielded Deposit")
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

        let proofInputNote = Note(
            value: inputNote.value,
            asset_id: safeAssetId,
            owner_ivk: inputNote.owner_ivk,
            owner_pubkey: storedNote.owner_pubkey.isEmpty ? keys.publicKey.hexString : storedNote.owner_pubkey,
            nonce: storedNote.nonce.isEmpty ? keys.publicKey.hexString : storedNote.nonce,
            spending_key: spendingKeyHex,
            memo: inputNote.memo
        )
        // Generate proof off the main actor (Rust FFI blocks the thread)
        let result = try await StarkVeilProver.generateTransferProof(notes: [proofInputNote])

        // Use the note's stored raw wei value directly as the calldata amount.
        // inputNote.value is already the canonical wei integer (e.g. "100000000000000000"),
        // re-deriving from the Double `amount` causes floating-point precision loss.
        let amountU256Low: String
        if let weiInt = Int(inputNote.value) {
            amountU256Low = "0x" + String(weiInt, radix: 16)
        } else if inputNote.value.hasPrefix("0x") {
            amountU256Low = inputNote.value  // already hex
        } else {
            amountU256Low = "0x0"
        }
        let amountU256High = "0x0"

        let proofCalldata = result.proof.flatMap { [$0] }

        // Starknet Keccak-250 selector for PrivacyPool.unshield()
        // Computed: starknet_keccak("unshield")
        let unshieldSelector = "0x3079978d9c0e08ca0a86356d70a7eea2408b5d3882425b2f30a60818eac5b1b"

        // Build the complete flat payload first, then derive calldata_len from it.
        // Encoding: [proof_len, ...proof_items, nullifier, recipient, amount_low, amount_high, asset_id]
        // NOTE: asset here must be the STRK ERC-20 ContractAddress (safeAssetId), NOT the short string.
        var callPayload: [String] = [String(format: "0x%x", proofCalldata.count)] + proofCalldata
        callPayload += [nullifier, recipient, amountU256Low, amountU256High, safeAssetId]

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

        // Derive IVK for the note commitment
        guard let ivkData = KeychainManager.ownerIVK() else {
            throw NSError(domain: "StarkVeil", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Wallet not initialised — no IVK found."])
        }
        let ivkHex = "0x" + ivkData.map { String(format: "%02x", $0) }.joined()

        // C-COMMITMENT-MISMATCH fix: derive STARK keypair to get owner_pubkey,
        // then use the 4-field Poseidon commitment that matches what execute
        // PrivateTransfer / executeUnshield reconstructs when spending the note.
        // The nonce is persisted in StoredNote so we never need to re-derive it.
        guard let seed = KeychainManager.masterSeed() else {
            throw NSError(domain: "StarkVeil", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "Master seed not found in Keychain."])
        }
        let keys = try StarknetAccount.deriveAccountKeys(fromSeed: seed)
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
            memo: memo.isEmpty ? "shielded deposit" : memo
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
            addNote(note, commitment: commitmentKey)
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
        // note.value is raw wei; amount is STRK — convert before matching
        guard let inputNote = notes.first(where: {
            guard let weiDouble = Double($0.value) else { return false }
            let strk = weiDouble / 1e18
            return abs(strk - amount) < 1e-9
        }) ?? selectNotes(for: amount).first
        else { throw ProverError.noMatchingNote }

        isTransferInFlight = true
        defer { isTransferInFlight = false }

        // M-TRANSFER-NO-PENDING Fix: Mark note as pending
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
        // Clamp the recipient IVK to felt252 range before ANY Rust FFI call.
        // SVK is 32 bytes (256 bits); felt252 max is ~252 bits. Passing a raw
        // 256-bit value to Rust throws "Invalid felt252 hex: number out of range".
        let recipientIVKClamped = WalletManager.clampToFelt252(recipientIVK)

        let outputCommitment = try StarkVeilProver.noteCommitment(
            value: inputNote.value,
            assetId: safeAssetId,
            ownerPubkey: recipientIVKClamped,
            nonce: outputNonce
        )

        // M-2 fix: make encryption throwing — abort if memo can't be encrypted.
        let encryptedMemo = try NoteEncryption.encryptMemo(
            memo.isEmpty ? "private transfer" : memo,
            ivkHex: recipientIVKClamped
        )

        // C-6 fix: Cairo private_transfer() expects:
        //   proof: Array<felt252>, nullifiers: Array<felt252>,
        //   new_commitments: Array<felt252>, fee: u256
        // Array<felt252> ABI encoding = [len, ...elements]
        let transferSelector = "0x2605e7681cf37ab3a81d1732a9c8a75f2544c5967628a4d6999f276c6ba513c"

        // Generate the proof payload (mock proof + real nullifiers/commitments)
        let proofInputNote = Note(
            value: inputNote.value,
            asset_id: safeAssetId,
            owner_ivk: ivkHex,
            owner_pubkey: storedNote.owner_pubkey.isEmpty ? keys.publicKey.hexString : storedNote.owner_pubkey,
            nonce: storedNote.nonce.isEmpty ? keys.publicKey.hexString : storedNote.nonce,
            spending_key: spendingKeyHex,
            memo: inputNote.memo
        )
        let proofPayload = try await StarkVeilProver.generateTransferProof(notes: [proofInputNote])

        // fee: u256 = (low=0x0, high=0x0) — mock verifier doesn't enforce fees
        var callPayload: [String] = []
        callPayload += [String(format: "0x%x", proofPayload.proof.count)] + proofPayload.proof  // proof array
        callPayload += ["0x1", nullifier]                                        // nullifiers array
        callPayload += ["0x1", outputCommitment]                                 // new_commitments array
        callPayload += ["0x0", "0x0"]                                          // fee: u256

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

        // 7. Optimistically remove spent note and recompute balance
        didSuccessfullySubmit = true
        removeNote(inputNote)
        recomputeBalance()   // uses /1e18 division — keeps balance display in STRK not wei
        
        // 8. Log the transfer event
        logEvent(
            kind: .transfer,
            amount: String(format: "%.6f", amount),
            assetId: "0x5354524b", // STRK
            counterparty: recipientIVK.isEmpty ? "Anonymous" : recipientIVK,
            txHash: broadcastedHash
        )
        
        return broadcastedHash
    }

    // MARK: - Private Helpers

    /// Removes a note from the in-memory array and deletes its persisted SwiftData counterpart.
    private func removeNote(_ note: Note) {
        if let idx = notes.firstIndex(where: {
            $0.value == note.value && $0.asset_id == note.asset_id && $0.owner_ivk == note.owner_ivk && $0.nonce == note.nonce
        }) {
            notes.remove(at: idx)
        }
        // Also remove from SwiftData
        let ctx = persistence.context
        let netId = activeNetworkId
        let descriptor = FetchDescriptor<StoredNote>(predicate: #Predicate { $0.networkId == netId })
        if let allStored = try? ctx.fetch(descriptor),
           let match = allStored.first(where: { $0.value == note.value && $0.asset_id == note.asset_id }) {
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

    /// Clamps an arbitrary 32-byte hex private key to a valid felt252 value.
    /// The STARK field prime is slightly less than 2^252, so we clear the top
    /// 3 bits of the most-significant byte to guarantee the result is in-range.
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
            bytes[0] &= 0x07  // clear top 3 bits → value < 2^253, safely < STARK prime
        }
        return "0x" + bytes.map { String(format: "%02x", $0) }.joined()
    }
}
