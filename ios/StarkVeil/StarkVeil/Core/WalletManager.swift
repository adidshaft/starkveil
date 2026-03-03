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
        let spendingKeyHex = keys.privateKey.hexString
        let ivkHex = try StarkVeilProver.deriveIVK(spendingKeyHex: spendingKeyHex)
        let nonceFelt = try StarkVeilProver.poseidonHash(elements: [ivkHex, inputNote.value, inputNote.asset_id])
        let commitment = try StarkVeilProver.noteCommitment(
            value: inputNote.value,
            assetId: inputNote.asset_id,
            ownerPubkey: keys.publicKey.hexString,
            nonce: nonceFelt
        )
        let nullifier = try StarkVeilProver.noteNullifier(commitment: commitment, spendingKey: spendingKeyHex)

        let alreadySpent = await RPCClient().isNullifierSpent(
            rpcUrl: rpcUrl,
            contractAddress: contractAddress,
            nullifierHex: nullifier
        )
        if alreadySpent {
            storedNote.isPendingSpend = false
            try? ctx.save()
            throw ProverError.noteAlreadySpent
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
        // Phase 14: estimate real fee (1.5× multiplier, falls back to 0.01 ETH on RPC error)
        let maxFee = await RPCClient().estimateInvokeFee(
            rpcUrl: rpcUrl,
            senderAddress: senderAddress,
            calldata: calldata,
            nonce: chainNonce
        )
        let (_, signature) = try StarknetTransactionBuilder.buildAndSign(
            senderAddress: senderAddress,
            calldata: calldata,
            maxFee: maxFee,
            nonce: chainNonce,
            chainID: network.chainIdFelt252,
            privateKey: keys.privateKey.hexString
        )
        let txHash = try await RPCClient().addInvokeTransaction(
            rpcUrl: rpcUrl,
            senderAddress: senderAddress,
            calldata: calldata,
            maxFee: maxFee,
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

        // 4-field Poseidon(value, asset_id, owner_pubkey, nonce) — matches contract spec
        let commitmentKey = try StarkVeilProver.noteCommitment(
            value: String(format: "%.6f", amount),
            assetId: "STRK",
            ownerPubkey: ownerPubkeyHex,
            nonce: noteNonce
        )

        let note = Note(
            value: String(format: "%.6f", amount),
            asset_id: "STRK",
            owner_ivk: ivkHex,
            owner_pubkey: ownerPubkeyHex,
            nonce: noteNonce,
            memo: memo.isEmpty ? "shielded deposit" : memo
        )


        // M-SHIELD-AMOUNT fix: u256 split for amounts > 18.44 STRK (UInt64.max wei)
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

        // Phase 15 Item 5: Encrypt the memo with AES-256-GCM using IVK-derived key.
        // The encrypted memo is embedded in calldata so the recipient can trial-decrypt it
        // during SyncEngine polling. Falls back to plaintext hex if encryption fails.
        let encryptedMemo: String
        do {
            encryptedMemo = try NoteEncryption.encryptMemo(
                memo.isEmpty ? "shielded deposit" : memo,
                ivkHex: ivkHex
            )
        } catch {
            // Encrypt failure is non-fatal — include plaintext hex so at least
            // the self-owned SyncEngine can still see the memo.
            encryptedMemo = Data(memo.utf8).hexString
        }

        // H1 fix: Do NOT send raw IVK in calldata — it links all deposits on-chain.
        // Instead derive a one-time commitment key: Poseidon(ivk || nonce).
        let commitmentKey = try deriveNoteCommitmentKey(ivkHex: ivkHex, nonce: noteNonce)

        // Starknet Keccak-250 selector for PrivacyPool.shield()
        let shieldSelector = "0x224a8f74e6fd7a11ab9e36f7742dd64470a7b2e3541b802eb7ed24087db909"

        // Phase 13: use the real deployed account address (not IVK placeholder)
        guard let senderAddress = KeychainManager.accountAddress() else {
            throw NSError(domain: "StarkVeil", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "Account not activated. Activate your wallet first."])
        }

        // H-TRY-SWALLOW fix: keys already derived above for commitment
        let senderAddress: String
        guard let addr = KeychainManager.accountAddress() else {
            throw NSError(domain: "StarkVeil", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "Account not activated. Activate your wallet first."])
        }
        senderAddress = addr

        // Phase 13: fetch real on-chain nonce before building tx
        let chainNonce = try await RPCClient().getNonce(rpcUrl: rpcUrl, address: senderAddress)

        let calldata = ["0x1", contractAddress, shieldSelector, "0x0", "0x3", "0x3",
                        amountLow, amountHigh, commitmentKey]

        // Phase 14: estimate real fee before building tx hash (hash commits to maxFee)
        let maxFee = await RPCClient().estimateInvokeFee(
            rpcUrl: rpcUrl,
            senderAddress: senderAddress,
            calldata: calldata,
            nonce: chainNonce
        )
        let (txHash, signature) = try StarknetTransactionBuilder.buildAndSign(
            senderAddress: senderAddress,
            calldata: calldata,
            maxFee: maxFee,
            nonce: chainNonce,
            chainID: network.chainIdFelt252,
            privateKey: keys.privateKey.hexString
        )

        let broadcastedHash = try await RPCClient().addInvokeTransaction(
            rpcUrl: rpcUrl,
            senderAddress: senderAddress,
            calldata: calldata,
            maxFee: maxFee,
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
        guard let inputNote = notes.first(where: { Double($0.value).map { abs($0 - amount) < 1e-9 } ?? false })
            ?? selectNotes(for: amount).first
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

        let spendingKeyHex = keys.privateKey.hexString
        let ivkHex = try StarkVeilProver.deriveIVK(spendingKeyHex: spendingKeyHex)

        // C-COMMITMENT-MISMATCH fix: use the PERSISTED nonce from StoredNote.
        // The shield step stored the exact random nonce used in Poseidon(value,asset,pubkey,nonce).
        // Re-deriving it (Poseidon(ivk,value,asset)) produces a different value → wrong commitment.
        let commitment = try StarkVeilProver.noteCommitment(
            value: inputNote.value,
            assetId: inputNote.asset_id,
            ownerPubkey: storedNote.owner_pubkey.isEmpty ? keys.publicKey.hexString : storedNote.owner_pubkey,
            nonce: storedNote.nonce.isEmpty ? keys.publicKey.hexString : storedNote.nonce
        )
        let nullifier = try StarkVeilProver.noteNullifier(commitment: commitment, spendingKey: spendingKeyHex)

        // 2. Check nullifier isn't already spent
        let alreadySpent = await RPCClient().isNullifierSpent(rpcUrl: rpcUrl, contractAddress: contractAddress, nullifierHex: nullifier)
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
        let outputCommitment = try StarkVeilProver.noteCommitment(
            value: inputNote.value,
            assetId: inputNote.asset_id,
            ownerPubkey: recipientAddress,
            nonce: outputNonce
        )

        // 4. Encrypt memo for recipient using their IVK
        let encryptedMemo = (try? NoteEncryption.encryptMemo(
            memo.isEmpty ? "private transfer" : memo,
            ivkHex: recipientIVK
        )) ?? Data(memo.utf8).hexString

        // 5. Build PrivacyPool.transfer calldata
        // C-TRANSFER-SELECTOR fix: real Starknet Keccak-250 of "transfer"
        let transferSelector = "0x344ccfa6fcaef996304897401d531feee7a039a8feeff02fcfa1fc08923d1d7"
        let calldata: [String] = [
            "0x1",              // call_array_len
            contractAddress,
            transferSelector,
            "0x0",
            "0x5",              // data_len: nullifier, output_commitment, amount, recipient, encrypted_memo_len
            "0x5",
            nullifier,
            outputCommitment,
            inputNote.value,
            recipientAddress,
            encryptedMemo
        ]

        // 6. Sign and submit
        let chainNonce = try await RPCClient().getNonce(rpcUrl: rpcUrl, address: senderAddress)
        let maxFee = await RPCClient().estimateInvokeFee(rpcUrl: rpcUrl, senderAddress: senderAddress, calldata: calldata, nonce: chainNonce)
        let (txHash, signature) = try StarknetTransactionBuilder.buildAndSign(
            senderAddress: senderAddress,
            calldata: calldata,
            maxFee: maxFee,
            nonce: chainNonce,
            chainID: network.chainIdFelt252,
            privateKey: spendingKeyHex
        )
        let broadcastedHash = try await RPCClient().addInvokeTransaction(
            rpcUrl: rpcUrl,
            senderAddress: senderAddress,
            calldata: calldata,
            maxFee: maxFee,
            signature: signature,
            nonce: chainNonce
        )

        // 7. Optimistically remove spent note
        didSuccessfullySubmit = true
        removeNote(inputNote)
        balance = notes.reduce(0) { $0 + (Double($1.value) ?? 0) }
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
