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
    let walletManager = WalletManager()
    let syncEngine = SyncEngine()

    private var notePipeline: AnyCancellable?

    init() {
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
    }
}

// MARK: - App Entry Point

@main
struct StarkVeilApp: App {
    @StateObject private var coordinator = AppCoordinator()

    var body: some Scene {
        WindowGroup {
            VaultView()
                .environmentObject(coordinator.walletManager)
                .environmentObject(coordinator.syncEngine)
        }
    }
}
