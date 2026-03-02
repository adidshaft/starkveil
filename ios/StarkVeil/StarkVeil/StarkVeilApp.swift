import SwiftUI
import Combine
import LocalAuthentication

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
    let appSettings = AppSettings()

    private var notePipeline: AnyCancellable?
    private var networkPipeline: AnyCancellable?

    init() {
        // Initialize SyncEngine with the shared NetworkManager
        self.syncEngine = SyncEngine(networkManager: networkManager)

        // Set the initial networkId so SwiftData queries target the right network on cold start
        walletManager.activeNetworkId = networkManager.activeNetwork.rawValue
        // Bootstrap from SwiftData (notes from previous session)
        Task { @MainActor in
            self.walletManager.loadNotes(for: self.networkManager.activeNetwork.rawValue)
        }
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
                guard let self else { return }
                MainActor.assumeIsolated {
                    // clearStore() queries SwiftData using activeNetworkId. It MUST run before
                    // activeNetworkId is updated so it targets the OLD network's records.
                    // Inverting this order would delete the new network's records instead.
                    self.walletManager.clearStore()
                    self.walletManager.activeNetworkId = self.networkManager.activeNetwork.rawValue
                    // Reload persisted notes for the new network immediately
                    self.walletManager.loadNotes(for: self.networkManager.activeNetwork.rawValue)
                }
            }
    }
}

// MARK: - App Entry Point

@main
struct StarkVeilApp: App {
    @StateObject private var coordinator = AppCoordinator()
    @State private var isWalletSetUp = KeychainManager.hasWallet

    var body: some Scene {
        WindowGroup {
            if isWalletSetUp {
                BiometricGateView(
                    appSettings: coordinator.appSettings,
                    onWalletDeleted: {
                        withAnimation(.easeInOut(duration: 0.4)) {
                            isWalletSetUp = false
                        }
                    }
                )
                .environmentObject(coordinator.themeManager)
                .environmentObject(coordinator.networkManager)
                .environmentObject(coordinator.walletManager)
                .environmentObject(coordinator.syncEngine)
                .environmentObject(coordinator.appSettings)
                .transition(.opacity)
            } else {
                WalletOnboardingView {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        isWalletSetUp = true
                    }
                }
                .environmentObject(coordinator.themeManager)
                .transition(.opacity)
            }
        }
    }
}

// MARK: - Biometric Gate

/// Blocks access to the wallet until local authentication passes.
/// Only shown when the user has enabled Biometric Lock in Settings.
/// H2 fix: Previously the toggle was purely decorative — now it actually gates the UI.
private struct BiometricGateView: View {
    @EnvironmentObject private var themeManager: AppThemeManager
    let appSettings: AppSettings
    let onWalletDeleted: () -> Void

    @State private var isAuthenticated = false
    @State private var authError: String? = nil

    var body: some View {
        if !appSettings.isBiometricLockEnabled || isAuthenticated {
            VaultView(onWalletDeleted: onWalletDeleted)
        } else {
            lockScreen
                .onAppear(perform: authenticate)
        }
    }

    private var lockScreen: some View {
        ZStack {
            themeManager.bgColor.ignoresSafeArea()
            VStack(spacing: 28) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(themeManager.textPrimary)
                Text("StarkVeil Locked")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(themeManager.textPrimary)
                if let err = authError {
                    Text(err)
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                Button(action: authenticate) {
                    HStack(spacing: 8) {
                        Image(systemName: "faceid")
                        Text("Unlock with Biometrics")
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(themeManager.bgColor)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 14)
                    .background(themeManager.textPrimary)
                    .clipShape(Capsule())
                }
            }
        }
    }

    private func authenticate() {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // Device has no biometrics/passcode — let through
            isAuthenticated = true
            return
        }
        context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: "Unlock StarkVeil to access your shielded wallet."
        ) { success, err in
            DispatchQueue.main.async {
                if success {
                    withAnimation { isAuthenticated = true }
                } else {
                    authError = err?.localizedDescription ?? "Authentication failed."
                }
            }
        }
    }
}
