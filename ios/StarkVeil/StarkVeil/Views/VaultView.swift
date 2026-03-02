import SwiftUI

struct VaultView: View {
    @EnvironmentObject private var themeManager: AppThemeManager
    @EnvironmentObject private var syncEngine: SyncEngine
    @EnvironmentObject private var walletManager: WalletManager

    @State private var transferAmount: String = ""
    @State private var recipientAddress: String = ""
    @State private var errorMessage: String? = nil

    var body: some View {
        ZStack {
            // Semantic Dynamic Background
            // .ignoresSafeArea() replaces the deprecated .edgesIgnoringSafeArea(.all)
            // (deprecated since iOS 14; project minimum is iOS 16.0)
            themeManager.bgColor.ignoresSafeArea()

            VStack(spacing: 40) {
                VaultHeaderView()
                    .padding(.top, 20)

                ShieldedBalanceCard()

                PrivateSendForm(
                    recipientAddress: $recipientAddress,
                    transferAmount: $transferAmount,
                    errorMessage: $errorMessage
                )

                Spacer()
            }
        }
        // .preferredColorScheme lives here — NOT in StarkVeilApp — because VaultView
        // observes themeManager via @EnvironmentObject and re-evaluates body on every
        // isDarkMode toggle, keeping system chrome (status bar, keyboard, menus) in sync.
        .preferredColorScheme(themeManager.colorScheme)
        .onAppear {
            syncEngine.startSyncing()
        }
        .onDisappear {
            syncEngine.stopSyncing()
        }
    }
}

struct VaultView_Previews: PreviewProvider {
    static var previews: some View {
        // NetworkManager is shared so SyncEngine can observe $activeNetwork
        let networkManager = NetworkManager()
        VaultView()
            .environmentObject(AppThemeManager())
            .environmentObject(networkManager)
            .environmentObject(WalletManager())
            .environmentObject(SyncEngine(networkManager: networkManager))
    }
}
