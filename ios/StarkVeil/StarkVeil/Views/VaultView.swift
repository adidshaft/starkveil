import SwiftUI

struct VaultView: View {
    @EnvironmentObject private var syncEngine: SyncEngine
    @EnvironmentObject private var walletManager: WalletManager

    @State private var transferAmount: String = ""
    @State private var recipientAddress: String = ""
    @State private var errorMessage: String? = nil

    var body: some View {
        ZStack {
            // OLED True Black Background
            Color.black.edgesIgnoringSafeArea(.all)

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
        // Force overall preferred Dark Mode schema
        .preferredColorScheme(.dark)
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
        VaultView()
            .environmentObject(SyncEngine())
            .environmentObject(WalletManager())
    }
}
