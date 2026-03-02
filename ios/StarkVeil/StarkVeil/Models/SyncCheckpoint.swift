import Foundation
import SwiftData

/// Persists the last successfully synced block number per network.
/// SyncEngine reads this on startup to resume from where it left off
/// rather than defaulting to `latestBlock - 10`.
@Model
final class SyncCheckpoint {
    @Attribute(.unique) var networkId: String
    var lastBlockNumber: Int
    var updatedAt: Date

    init(networkId: String, lastBlockNumber: Int) {
        self.networkId = networkId
        self.lastBlockNumber = lastBlockNumber
        self.updatedAt = Date()
    }
}
