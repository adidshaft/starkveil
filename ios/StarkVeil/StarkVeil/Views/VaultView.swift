import SwiftUI

struct VaultView: View {
    // Owned by AppCoordinator and injected at the app root via .environmentObject(...)
    @EnvironmentObject private var syncEngine: SyncEngine
    @EnvironmentObject private var walletManager: WalletManager

    @State private var isBalanceRevealed = false
    @State private var transferAmount: String = ""
    @State private var recipientAddress: String = ""
    @State private var errorMessage: String? = nil

    // MARK: - Derived State

    /// Returns the parsed amount only if it is a finite, positive Double
    /// that does not exceed the current shielded balance.
    private var parsedAmount: Double? {
        guard let v = Double(transferAmount), v > 0, v.isFinite, v <= walletManager.balance else {
            return nil
        }
        return v
    }

    private var canSend: Bool {
        !walletManager.isProving && !recipientAddress.isEmpty && parsedAmount != nil
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)

            VStack(spacing: 30) {

                // MARK: Header
                HStack {
                    Text("StarkVeil")
                        .font(.custom("SpaceGrotesk-Bold", size: 28, relativeTo: .title))
                        .foregroundColor(.white)
                    Spacer()
                    HStack(spacing: 8) {
                        Circle()
                            .fill(syncEngine.isSyncing ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                            .shadow(color: syncEngine.isSyncing ? Color.green : Color.clear, radius: 4)
                        Text(syncEngine.isSyncing ? "Syncing…" : "Offline")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
                .padding(.horizontal)

                // MARK: Vault Card
                VStack(spacing: 15) {
                    Text("Shielded Balance")
                        .font(.subheadline)
                        .foregroundColor(.gray)

                    ZStack {
                        if isBalanceRevealed {
                            // Single source of truth: walletManager.balance (derived from UTXO notes)
                            Text("$\(walletManager.balance, specifier: "%.2f")")
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
                            isBalanceRevealed = isPressing
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

                // MARK: Action Area
                VStack(spacing: 20) {
                    TextField("Recipient (0x…)", text: $recipientAddress)
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

                    // Error display — shows WalletManager errors (balance, re-entrancy)
                    // and local validation errors (non-positive amount)
                    let displayError = walletManager.transferError ?? errorMessage
                    if let msg = displayError {
                        Text(msg)
                            .font(.caption)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    Button(action: sendAction) {
                        HStack {
                            if walletManager.isProving {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .black))
                                Text("Synthesizing STARK Proof…")
                            } else {
                                Image(systemName: "paperplane.fill")
                                Text("Private Send")
                            }
                        }
                        .font(.headline)
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(canSend ? Color.white : Color.gray)
                        .cornerRadius(16)
                    }
                    .disabled(!canSend)

                    if let hash = walletManager.lastProvedTxHash {
                        Text("Sent! TxHash: \(hash.prefix(10))…")
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
        .onDisappear {
            // Stops the background timer to prevent battery drain and stale mutations
            syncEngine.stopSyncing()
        }
    }

    // MARK: - Actions

    private func sendAction() {
        errorMessage = nil

        guard let amount = parsedAmount else {
            // parsedAmount returns nil for two distinct reasons; inspect the raw string to pick the right message.
            if let v = Double(transferAmount), v > 0, v.isFinite {
                errorMessage = "Amount exceeds your shielded balance."
            } else {
                errorMessage = "Enter a valid amount greater than zero."
            }
            return
        }

        Task {
            do {
                try await walletManager.executePrivateTransfer(
                    recipient: recipientAddress,
                    amount: amount
                )
            } catch {
                // Surface error to the user — never swallow with try?
                errorMessage = error.localizedDescription
            }
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
