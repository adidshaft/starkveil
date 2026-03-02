import SwiftUI
import Combine

// MARK: - App Coordinator
//
// Owns both long-lived service objects and wires the Combine pipeline
// that routes SyncEngine-detected notes into the WalletManager UTXO store.
// Keeping this wiring here (rather than in the View) means:
//   • Neither service object knows about the other — they stay decoupled.
//   • The pipeline lives for the app lifetime without needing @State tricks.
//   • Child views get both objects via environmentObject injection.

class AppCoordinator: ObservableObject {
    let themeManager = AppThemeManager()
    let networkManager = NetworkManager()
    let walletManager = WalletManager()
    let syncEngine: SyncEngine

    private var notePipeline: AnyCancellable?
    private var networkPipeline: AnyCancellable?

    init() {
        // Initialize SyncEngine with the shared NetworkManager
        self.syncEngine = SyncEngine(networkManager: networkManager)
        // SyncEngine fires noteDetected on the main thread (RunLoop.main timer).
        // We receive on RunLoop.main to make that guarantee explicit, then forward
        // into walletManager.addNote which is isolated to @MainActor.
        notePipeline = syncEngine.noteDetected
            .receive(on: RunLoop.main)
            .sink { [weak self] (note: Note) in
                guard let self else { return }
                Task { @MainActor in
                    self.walletManager.addNote(note)
                }
            }
            
        // When the network changes, we must flush the WalletManager so balances from
        // Mainnet don't show up on Sepolia, etc.
        //
        // ORDERING CONTRACT: networkChanged is fired by SyncEngine.handleNetworkChange()
        // synchronously, between stopSyncing() and startSyncing(). clearStore() must
        // complete before startSyncing() arms the timer so no new-network notes can
        // land in the old UTXO set. Task { @MainActor in } is async and breaks this
        // ordering. MainActor.assumeIsolated is safe here because .receive(on: RunLoop.main)
        // guarantees we are already executing on the main actor.
        networkPipeline = syncEngine.networkChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                MainActor.assumeIsolated {
                    self?.walletManager.clearStore()
                }
            }
    }
}

// MARK: - App Entry Point

@main
struct StarkVeilApp: App {
    @StateObject private var coordinator = AppCoordinator()

    var body: some Scene {
        WindowGroup {
            VaultView()
                .environmentObject(coordinator.themeManager)
                .environmentObject(coordinator.networkManager)
                .environmentObject(coordinator.walletManager)
                .environmentObject(coordinator.syncEngine)
            // NOTE: .preferredColorScheme is NOT applied here.
            // StarkVeilApp observes coordinator (AppCoordinator), which has no @Published
            // properties — so this body never re-evaluates on theme changes. Applying
            // .preferredColorScheme here would read .dark once at launch and freeze it.
            // The modifier lives in VaultView instead, where @EnvironmentObject themeManager
            // IS observed and triggers correct re-evaluation on every toggle.
        }
    }
}
