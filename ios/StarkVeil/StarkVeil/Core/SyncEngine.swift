import Combine
import Foundation
import SwiftData

class SyncEngine: ObservableObject {
    private let persistence = PersistenceController.shared
    @Published var isSyncing = false
    @Published var currentBlockNumber: Int = 0

    /// Emits a (Note, onChainCommitment) pair each time the light client detects a new shielded deposit.
    /// AppCoordinator subscribes and forwards these into WalletManager.addNote(_:commitment:).
    let noteDetected = PassthroughSubject<(note: Note, commitment: String), Never>()
    let networkChanged = PassthroughSubject<Void, Never>()

    private var timer: Timer?
    private var networkCancellable: AnyCancellable?
    private let networkManager: NetworkManager
    private let rpcClient: RPCClient
    
    // Concurrency guard: prevents overlapping HTTP requests when an RPC node
    // responds slower than the 5 s poll interval. Read and written exclusively
    // on the main thread (timer fires on RunLoop.main; reset via await MainActor.run).
    private var isFetchingRPC = false

    // Epoch counter: incremented on every network switch.
    // Each Task captures its epoch at launch and abandons its results if the epoch
    // no longer matches — preventing stale-network notes from landing in the
    // WalletManager after clearStore() has already been called for the new network.
    private var syncEpoch: Int = 0

    // MARK: - Lifecycle

    init(networkManager: NetworkManager) {
        self.networkManager = networkManager
        self.rpcClient = RPCClient()
        
        // Listen for network changes to reset sync state.
        // .receive(on: RunLoop.main) is required: @Published delivers on the mutating thread,
        // and handleNetworkChange() calls stopSyncing() which has a dispatchPrecondition(.onQueue(.main)).
        // Without this hop, any off-main mutation of activeNetwork would crash via that precondition.
        networkCancellable = networkManager.$activeNetwork
            .dropFirst() // Ignore the initial value on setup
            .receive(on: RunLoop.main)
            .sink { [weak self] newNetwork in
                print("[SyncEngine] Network switched to: \(newNetwork.rawValue)")
                self?.handleNetworkChange()
            }
    }

    func startSyncing() {
        // Document the calling-thread contract loudly so future refactors don't silently break it.
        dispatchPrecondition(condition: .onQueue(.main))

        isSyncing = true

        // Explicitly schedule on RunLoop.main so the timer fires on the main thread
        // regardless of where startSyncing() is called from in the future.
        // Using Timer(timeInterval:repeats:block:) + RunLoop.main.add ensures this,
        // unlike Timer.scheduledTimer which silently no-ops on threads without a RunLoop.
        let t = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopSyncing() {
        dispatchPrecondition(condition: .onQueue(.main))
        timer?.invalidate()
        timer = nil
        isSyncing = false
    }

    private func handleNetworkChange() {
        if isSyncing { stopSyncing() }

        // Reset the fetch guard immediately so the new network's first tick is not
        // blocked by the previous network's in-flight Task. Without this, the old
        // Task holds isFetchingRPC = true until it finishes (potentially tens of seconds),
        // suppressing the first poll on the newly selected network.
        isFetchingRPC = false

        // Advance the epoch. Any Task that was launched before this point captured
        // the old epoch value. Their MainActor.run blocks check syncEpoch == capturedEpoch
        // before emitting notes or updating currentBlockNumber, so stale results from
        // the old network are silently discarded after clearStore() has run.
        syncEpoch += 1

        currentBlockNumber = 0

        // Notify subscribers (AppCoordinator → WalletManager.clearStore()) to flush UTXOs.
        // This call is synchronous via MainActor.assumeIsolated in AppCoordinator — clearStore()
        // completes before networkChanged.send() returns, which is before startSyncing() runs.
        networkChanged.send()

        // Reload persisted notes for the new network
        startSyncing()
    }

    // MARK: - Checkpoint Persistence

    private func saveCheckpoint(networkId: String, block: Int) {
        let ctx = persistence.context
        let descriptor = FetchDescriptor<SyncCheckpoint>(predicate: #Predicate { $0.networkId == networkId })
        if let existing = try? ctx.fetch(descriptor).first {
            existing.lastBlockNumber = block
            existing.updatedAt = Date()
        } else {
            ctx.insert(SyncCheckpoint(networkId: networkId, lastBlockNumber: block))
        }
        try? ctx.save()
    }

    func loadCheckpoint(for networkId: String) -> Int {
        let ctx = persistence.context
        let descriptor = FetchDescriptor<SyncCheckpoint>(predicate: #Predicate { $0.networkId == networkId })
        return (try? ctx.fetch(descriptor).first?.lastBlockNumber) ?? 0
    }

    // MARK: - Private

    /// Fires on the main thread (scheduled on RunLoop.main).
    private func tick() {
        guard !isFetchingRPC else { return }
        isFetchingRPC = true

        // Capture all main-actor state before yielding to the cooperative thread pool.
        // networkManager.activeNetwork is @Published on a non-@MainActor class — reading
        // it from inside a plain Task body (which runs on the cooperative pool) is an
        // unsynchronized access. Capturing here, where tick() is guaranteed on the main
        // thread, eliminates that race entirely.
        let capturedEpoch    = syncEpoch
        let rpcUrl           = networkManager.activeNetwork.rpcUrl
        let networkName      = networkManager.activeNetwork.rawValue
        let contractAddress  = networkManager.activeNetwork.contractAddress
        // On cold start currentBlockNumber == 0. Consult the persisted checkpoint so
        // we resume from where the last session left off rather than always scanning
        // the last 10 blocks. When no checkpoint exists, loadCheckpoint returns 0
        // and the fromBlock calculation below falls back to latestBlock - 10 as before.
        let currentBlock = currentBlockNumber > 0
            ? currentBlockNumber
            : loadCheckpoint(for: networkName)

        Task {
            do {
                let latestBlock = try await rpcClient.fetchLatestBlockNumber(rpcUrl: rpcUrl)

                if latestBlock > currentBlock {
                    // For the very first sync, scan the last 10 blocks to catch recent events.
                    let fromBlock = currentBlock == 0 ? max(0, latestBlock - 10) : currentBlock + 1

                    let events = try await rpcClient.fetchEvents(
                        rpcUrl: rpcUrl,
                        fromBlock: fromBlock,
                        toBlock: latestBlock,
                        contractAddress: contractAddress
                    )

                    // Decode all notes off the main thread. O(events) work stays on the
                    // cooperative pool; a single MainActor hop delivers the full batch.
                    // The previous per-event await MainActor.run pattern caused O(N) context
                    // switches between the pool and the main thread for every page.
                    //
                    // Cairo Shielded event layout:
                    //   data[0] = asset (ContractAddress)
                    //   data[1] = amount.low  (u256 low 128 bits)
                    //   data[2] = amount.high (u256 high 128 bits)
                    //   data[3] = commitment  (felt252 hash)
                    //   data[4] = leaf_index  (u32)
                    //   data[5] = encrypted_memo (Phase 15 IVK-encrypted hex, optional)
                    // Phase 15 Item 2 & Audit Fixes (H-IVK-FAIL-DROPS-NOTES, M-IVK-LOOP-PERF):
                    // Derive IVK strictly ONCE outside the loop to avoid O(N) expensive operations.
                    // Fallback to keychain if derivation fails to prevent empty string breaking decryption.
                    let ivkHex: String
                    if let seed = KeychainManager.masterSeed(),
                       let keys = try? StarknetAccount.deriveAccountKeys(fromSeed: seed),
                       let derivedIVK = try? StarkVeilProver.deriveIVK(spendingKeyHex: keys.privateKey.hexString) {
                        ivkHex = derivedIVK
                    } else if let ivkData = KeychainManager.ownerIVK() {
                        ivkHex = "0x" + ivkData.map { String(format: "%02x", $0) }.joined()
                    } else {
                        // Impossible state post-onboarding, but safe escape.
                        return
                    }

                    var decodedNotes: [(note: Note, commitment: String, blockNumber: Int)] = []
                    for event in events {
                        // Shielded vs Transfer events
                        let isShielded = event.keys.contains("0x3905e8c1752e2e2f768e4ed493f6d4df0bcaaf86ad37ef5bc7c2bbf18fe8083")
                        let isTransfer = event.keys.contains("0x99cd8bde557814842a3121e8ddfd433a539b8c9f14bf31ebf108d12e6196e9")
                        
                        var singleEventCommitment: String? = nil
                        var singleEventEncMemo: String? = nil
                        // Transfer events do not emit amounts or asset_ids. The recipient receives
                        // full information ENCRYPTED in the memo payload (handled later in UI via query).
                        // For SyncEngine, we track the note's existence with 0.0 STRK until verified.
                        var singleEventAmountHex: String = "0x0" 
                        var singleEventAssetId: String = "0x5354524b" // default to STRK

                        if isShielded {
                            guard event.data.count >= 5 else { continue }
                            singleEventAmountHex = event.data[1]
                            singleEventCommitment = event.data[3]
                            if event.data.count >= 6 {
                                singleEventEncMemo = event.data[5]
                            }
                        } else if isTransfer {
                            // Transfer event data layout:
                            // data[0] = new_commitments_len
                            // data[1..len] = new_commitments elements
                            // data[...len+1] = encrypted_memos_len
                            // data[...(len+1)+enc_len] = encrypted_memo elements
                            // data[...] = fee u256
                            guard event.data.count >= 4 else { continue }
                            
                            guard let commitLenInt = Int(event.data[0].replacingOccurrences(of: "0x", with: ""), radix: 16) else { continue }
                            // For MVP we only look at the first commitment (index 1) which goes to recipient
                            // Index 2 is the change note (returns to sender)
                            if commitLenInt >= 2 {
                                // recipient commitment is usually the first element in the array after len
                                singleEventCommitment = event.data[1]
                            }
                            
                            let encMemoLenIndex = 1 + commitLenInt
                            if event.data.count > encMemoLenIndex {
                                guard let encMemoLenInt = Int(event.data[encMemoLenIndex].replacingOccurrences(of: "0x", with: ""), radix: 16) else { continue }
                                if encMemoLenInt >= 2 {
                                    // first encrypted memo matches first commitment
                                    let firstMemoIndex = encMemoLenIndex + 1
                                    if event.data.count > firstMemoIndex {
                                        singleEventEncMemo = event.data[firstMemoIndex]
                                    }
                                }
                            }
                        }
                        
                        guard let commitment = singleEventCommitment else { continue }

                        // If there's an encrypted memo field, trial-decrypt it.
                        // nil result means the note is not addressed to us — skip it.
                        var decryptedMemo: String? = "Shielded: \(commitment.prefix(10))…"
                        if let encHex = singleEventEncMemo, !encHex.isEmpty, encHex != "0x0" {
                            if let plain = try? NoteEncryption.decryptMemo(encHex, ivkHex: ivkHex) {
                                decryptedMemo = plain   // decrypts = note is ours
                            } else {
                                // Could not decrypt = note is not addressed to us; skip
                                continue
                            }
                        } else if isTransfer {
                            // If it's a transfer but has no memo, we can't be sure it's ours since it's anonymous
                            continue
                        }
                        // No encrypted memo = legacy/self-deposit Shielded event; accept it

                        // Use IVK clamped the same way executeShield does,
                        // so commitment reconstruction matches at spend time.
                        let clampedIVK = WalletManager.clampToFelt252(ivkHex)

                        // Store value as raw wei DECIMAL integer string format
                        let rawWei: String
                        if let weiInt = Int(singleEventAmountHex.replacingOccurrences(of: "0x", with: ""), radix: 16) {
                            rawWei = String(weiInt)
                        } else {
                            rawWei = singleEventAmountHex
                        }
                        // Skip zero value notes ONLY if they are Shielded deposits.
                        // Transfer events intentionally leave amount=0x0 because the real amount
                        // is hidden inside the encrypted memo itself (future integration).
                        if isShielded && rawWei == "0" {
                            continue
                        }

                        let note = Note(
                            value: rawWei,
                            asset_id: singleEventAssetId,
                            owner_ivk: ivkHex,
                            owner_pubkey: clampedIVK,
                            nonce: commitment,           // commitment acts as unique note ID
                            spending_key: nil,
                            memo: decryptedMemo ?? "Shielded deposit"
                        )
                        decodedNotes.append((note: note, commitment: commitment, blockNumber: event.block_number))
                    }

                    // Single MainActor hop for the entire batch.
                    // Epoch guard: if the network switched while we were fetching, syncEpoch
                    // no longer matches capturedEpoch. Returning here discards the stale
                    // Sepolia/Mainnet results without touching the now-cleared WalletManager.
                    await MainActor.run {
                        guard self.syncEpoch == capturedEpoch else { return }
                        for entry in decodedNotes {
                            self.noteDetected.send((note: entry.note, commitment: entry.commitment))
                            // Display in STRK for log readability; value is stored as raw wei
                            let weiDouble = Double(entry.note.value) ?? 0
                            let strkDisplay = String(format: "%.6f", weiDouble / 1e18)
                            print("[SyncEngine] Block \(entry.blockNumber) [\(networkName)]: Decoded Note (\(strkDisplay) STRK, commitment: \(entry.commitment.prefix(12))…)")
                        }
                        self.currentBlockNumber = latestBlock
                        // Persist the checkpoint so the next cold start resumes from here
                        // instead of re-scanning the last 10 blocks and re-emitting duplicates.
                        self.saveCheckpoint(networkId: networkName, block: latestBlock)
                    }
                }
            } catch {
                print("[SyncEngine] RPC Sync Error: \(error.localizedDescription)")
            }

            // Reset the fetch guard on the MainActor after all work is complete.
            // Using await MainActor.run (vs the previous defer + nested Task { @MainActor in })
            // eliminates the window where the outer Task had exited but isFetchingRPC was
            // still true, which was causing the very next 5 s tick to be skipped spuriously.
            // Epoch guard: a network switch already set isFetchingRPC = false and advanced
            // syncEpoch — do not overwrite that with a stale Task's reset.
            await MainActor.run {
                if self.syncEpoch == capturedEpoch {
                    self.isFetchingRPC = false
                }
            }
        }
    }
}
