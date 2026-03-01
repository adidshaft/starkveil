import SwiftUI

struct VaultView: View {
    @StateObject private var syncEngine = SyncEngine()
    @StateObject private var walletManager = WalletManager()
    
    @State private var isBalanceRevealed = false
    @State private var transferAmount: String = ""
    @State private var recipientAddress: String = ""
    
    var body: some View {
        ZStack {
            // Background
            Color.black.edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 30) {
                // Header
                HStack {
                    Text("StarkVeil")
                        .font(.custom("SpaceGrotesk-Bold", size: 28, relativeTo: .title))
                        .foregroundColor(.white)
                    Spacer()
                    
                    // Sync Status
                    HStack(spacing: 8) {
                        Circle()
                            .fill(syncEngine.isSyncing ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                            .shadow(color: syncEngine.isSyncing ? Color.green : Color.clear, radius: 4)
                        Text(syncEngine.isSyncing ? "Syncing..." : "Offline")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
                .padding(.horizontal)
                
                // Vault Card
                VStack(spacing: 15) {
                    Text("Shielded Balance")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                    
                    ZStack {
                        if isBalanceRevealed {
                            Text("$\(walletManager.decryptedBalance + syncEngine.shieldedBalance, specifier: "%.2f")")
                                .font(.system(size: 48, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                                .transition(.opacity)
                        } else {
                            Text("••••••")
                                .font(.system(size: 48, weight: .bold))
                                .foregroundColor(.white)
                                .transition(.opacity)
                        }
                    }
                    .onLongPressGesture(minimumDuration: 0.1, pressing: { isPressing in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            self.isBalanceRevealed = isPressing
                        }
                    }, perform: {})
                    
                    Text("Hold to reveal")
                        .font(.caption2)
                        .foregroundColor(Color.white.opacity(0.3))
                }
                .padding(.vertical, 40)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 24)
                        .fill(Color(white: 0.1))
                        .overlay(
                            RoundedRectangle(cornerRadius: 24)
                                .stroke(Color.white.opacity(0.1), lineWidth: 1)
                        )
                )
                .padding(.horizontal)
                
                // Action Area
                VStack(spacing: 20) {
                    TextField("Recipient (0x...)", text: $recipientAddress)
                        .padding()
                        .background(Color(white: 0.15))
                        .cornerRadius(12)
                        .foregroundColor(.white)
                    
                    TextField("Amount", text: $transferAmount)
                        .keyboardType(.decimalPad)
                        .padding()
                        .background(Color(white: 0.15))
                        .cornerRadius(12)
                        .foregroundColor(.white)
                    
                    Button(action: {
                        guard let amount = Double(transferAmount) else { return }
                        Task {
                            try? await walletManager.executePrivateTransfer(recipient: recipientAddress, amount: amount)
                        }
                    }) {
                        HStack {
                            if walletManager.isProving {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .black))
                                Text("Synthesizing STARK Proof...")
                            } else {
                                Image(systemName: "paperplane.fill")
                                Text("Private Send")
                            }
                        }
                        .font(.headline)
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(walletManager.isProving ? Color.gray : Color.white)
                        .cornerRadius(16)
                    }
                    .disabled(walletManager.isProving || transferAmount.isEmpty || recipientAddress.isEmpty)
                    
                    if let hash = walletManager.lastProvedTxHash {
                        Text("Sent! TxHash: \(hash.prefix(10))...")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
                .padding(.horizontal)
                
                Spacer()
            }
            .padding(.top)
        }
        .onAppear {
            syncEngine.startSyncing()
        }
    }
}

struct VaultView_Previews: PreviewProvider {
    static var previews: some View {
        VaultView()
    }
}
