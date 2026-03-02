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

    // MARK: - Lifecycle

    init(networkManager: NetworkManager) {
        self.networkManager = networkManager
        
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
    /// Direct @Published mutations here are safe without DispatchQueue.main.async.
    private func tick() {
        currentBlockNumber += 1

        // Simulate discovering a new public deposit 1-in-5 blocks
        if Int.random(in: 1...5) == 5 {
            let incomingValue = Double.random(in: 0.1...5.0)
            let note = Note(
                value: String(format: "%.9f", incomingValue),
                asset_id: "0xETH",
                owner_ivk: "0xMockIVK",
                memo: "auto-shield"
            )
            noteDetected.send(note)
            print("[SyncEngine] Block \(currentBlockNumber) [\(networkManager.activeNetwork.rawValue)]: detected deposit, emitting note (\(note.value) ETH)")
        }
    }
}
