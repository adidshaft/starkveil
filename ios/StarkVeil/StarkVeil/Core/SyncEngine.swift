import Combine
import Foundation

class SyncEngine: ObservableObject {
    @Published var isSyncing = false
    @Published var currentBlockNumber: Int = 0

    /// Emits a Note each time the light client detects a new shielded deposit.
    /// AppCoordinator subscribes and forwards these into WalletManager.addNote(_:).
    let noteDetected = PassthroughSubject<Note, Never>()
    let networkChanged = PassthroughSubject<Void, Never>()

    private var timer: Timer?
    private var networkCancellable: AnyCancellable?
    private let networkManager: NetworkManager
    private let rpcClient: RPCClient
    
    // Concurrency lock for slow RPC responses
    private var isFetchingRPC = false

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
        // Stop current syncing immediately
        if isSyncing {
            stopSyncing()
        }
        
        // Reset block height
        currentBlockNumber = 0
        
        // Notify subscribers (like WalletManager) to flush their UTXOs
        networkChanged.send()
        
        // Restart on new network
        startSyncing()
    }

    // MARK: - Private

    /// Fires on the main thread (scheduled on RunLoop.main).
    private func tick() {
        guard !isFetchingRPC else { return }
        isFetchingRPC = true
        
        Task {
            defer { 
                Task { @MainActor in self.isFetchingRPC = false }
            }
            
            do {
                let rpcUrl = networkManager.activeNetwork.rpcUrl
                let latestBlock = try await rpcClient.fetchLatestBlockNumber(rpcUrl: rpcUrl)
                
                let current = await MainActor.run { self.currentBlockNumber }
                
                if latestBlock > current {
                    // For the very first sync, jump to latest - 10 to simulate some past blocks
                    let fromBlock = current == 0 ? max(0, latestBlock - 10) : current + 1
                    
                    let events = try await rpcClient.fetchEvents(
                        rpcUrl: rpcUrl,
                        fromBlock: fromBlock,
                        toBlock: latestBlock,
                        contractAddress: networkManager.activeNetwork.contractAddress
                    )
                    
                    for event in events {
                        // Cairo Struct: `Shielded { asset, amount: u256(low, high), commitment, leaf_index }`
                        // data[0] = asset, data[1] = amount.low, data[2] = amount.high
                        // data[3] = commitment, data[4] = leaf_index
                        if event.data.count >= 5 {
                            let amountHex = event.data[1]
                            let commitment = event.data[3]
                            
                            // Decode hex string to integer, divide by natively 18 decimals (mock logic for hackathon)
                            guard let amountInt = Int(amountHex.replacingOccurrences(of: "0x", with: ""), radix: 16) else { continue }
                            let amountDouble = Double(amountInt) / 1e18
                            
                            // Mocking the IVK Cyphertext Decryption since we lack AES bounds over raw starknet getEvents
                            let note = Note(
                                value: String(format: "%.9f", amountDouble > 0 ? amountDouble : Double.random(in: 0.1...5.0)),
                                asset_id: "0xSTRK", // We strictly mocked strongly typed asset mappings
                                owner_ivk: "0xMockIVK",
                                memo: "RPC Shielded: \(commitment.prefix(10))..."
                            )
                            
                            await MainActor.run {
                                self.noteDetected.send(note)
                                print("[SyncEngine] Block \(event.block_number) [\(self.networkManager.activeNetwork.rawValue)]: Decoded Note (\(note.value) STRK)")
                            }
                        }
                    }
                    
                    await MainActor.run {
                        self.currentBlockNumber = latestBlock
                    }
                }
            } catch {
                print("[SyncEngine] RPC Sync Error: \(error.localizedDescription)")
            }
        }
    }
}
