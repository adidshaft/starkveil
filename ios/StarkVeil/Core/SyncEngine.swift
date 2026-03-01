import Combine
import Foundation

class SyncEngine: ObservableObject {
    @Published var isSyncing = false
    @Published var currentBlockNumber: Int = 0
    @Published var shieldedBalance: Double = 0.0
    
    private var timer: Timer?
    
    func startSyncing() {
        isSyncing = true
        // Mock a light client syncing engine parsing RPC events
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            // Simulating parsing new blocks containing Merkle Tree updates
            self.currentBlockNumber += 1
            
            // Randomly simulate an incoming public auto-shield event
            if Int.random(in: 1...5) == 5 {
                let incomingValue = Double.random(in: 0.1...5.0)
                DispatchQueue.main.async {
                    self.shieldedBalance += incomingValue
                    print("Detected new public fund. Auto-Shield completed. New Balance: \(self.shieldedBalance)")
                }
            }
        }
    }
    
    func stopSyncing() {
        timer?.invalidate()
        timer = nil
        isSyncing = false
    }
}
