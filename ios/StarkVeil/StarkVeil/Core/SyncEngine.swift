import Combine
import Foundation

class SyncEngine: ObservableObject {
    @Published var isSyncing = false
    @Published var currentBlockNumber: Int = 0

    /// Emits a Note each time the light client detects a new shielded deposit.
    /// AppCoordinator subscribes and forwards these into WalletManager.addNote(_:).
    let noteDetected = PassthroughSubject<Note, Never>()

    private var timer: Timer?

    // MARK: - Lifecycle

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
            print("[SyncEngine] Block \(currentBlockNumber): detected deposit, emitting note (\(note.value) ETH)")
        }
    }
}
