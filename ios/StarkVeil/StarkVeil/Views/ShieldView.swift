import SwiftUI

/// Phase 19: Unified Shield/Unshield view with a toggle.
/// Shield (U→S): Moves public STRK into the privacy pool.
/// Unshield (S→U): Withdraws shielded STRK back to public balance.
struct ShieldView: View {
    @EnvironmentObject private var themeManager: AppThemeManager
    @EnvironmentObject private var walletManager: WalletManager
    @EnvironmentObject private var networkManager: NetworkManager
    @Environment(\.dismiss) private var dismiss

    enum ShieldMode: String, CaseIterable {
        case shield = "Shield (U→S)"
        case unshield = "Unshield (S→U)"
    }

    @State private var mode: ShieldMode = .shield
    @State private var amountText = ""
    @State private var isProcessing = false
    @State private var errorMessage: String? = nil
    @State private var txHash: String? = nil

    private var parsedAmount: Double? {
        guard let v = Double(amountText), v > 0, v.isFinite else { return nil }
        return v
    }
    private var canExecute: Bool { 
        guard let a = parsedAmount else { return false }
        return !isProcessing && a <= availableBalance 
    }

    private var availableBalance: Double {
        if mode == .shield {
            // Reserve ~0.005 STRK for the approve+shield L1/L2 gas execution fee.
            // If the user taps MAX, this prevents an RPC 41 (Insufficient Funds) revert.
            return max(0, walletManager.publicBalance - 0.005)
        } else {
            return walletManager.balance
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                themeManager.bgColor.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 24) {

                        // ── Mode toggle ──────────────────────────────────
                        Picker("Mode", selection: $mode) {
                            ForEach(ShieldMode.allCases, id: \.self) { m in
                                Text(m.rawValue).tag(m)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: mode) { _, _ in
                            amountText = ""
                            errorMessage = nil
                            txHash = nil
                        }

                        // ── Amount display ────────────────────────────────
                        VStack(spacing: 4) {
                            Image(systemName: mode == .shield ? "shield.lefthalf.filled" : "lock.open.fill")
                                .font(.system(size: 30))
                                .foregroundStyle(mode == .shield ? Color(hex: "#9B6DFF") : Color(hex: "#FF6B35"))

                            if amountText.isEmpty {
                                Text("– – – – – –")
                                    .font(.system(size: 38, weight: .bold, design: .monospaced))
                                    .foregroundStyle(themeManager.textSecondary)
                            } else {
                                Text("\(amountText) STRK")
                                    .font(.system(size: 38, weight: .bold, design: .monospaced))
                                    .foregroundStyle(themeManager.textPrimary)
                                    .contentTransition(.numericText())
                            }
                        }
                        .padding(.top, 8)

                        // ── Info banner ───────────────────────────────────
                        HStack(spacing: 10) {
                            Image(systemName: mode == .shield ? "arrow.down.to.line.compact" : "arrow.up.to.line.compact")
                                .foregroundStyle(mode == .shield ? Color(hex: "#9B6DFF") : Color(hex: "#FF6B35"))
                                .font(.system(size: 14))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mode == .shield ? "Public → Shielded" : "Shielded → Public")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(themeManager.textPrimary)
                                Text(mode == .shield
                                     ? "Your public STRK enters the privacy pool. The deposit amount is visible on-chain. Everything after is private."
                                     : "Your shielded STRK returns to your public balance. The withdrawal amount will be visible on-chain.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(themeManager.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(14)
                        .background((mode == .shield ? Color(hex: "#4A1DB5") : Color(hex: "#FF6B35")).opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke((mode == .shield ? Color(hex: "#6B3DE8") : Color(hex: "#FF6B35")).opacity(0.3), lineWidth: 1))

                        // ── Amount input ──────────────────────────────────
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Amount")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(themeManager.textSecondary)
                                .tracking(0.5)

                            HStack {
                                Image(systemName: mode == .shield ? "shield.lefthalf.filled" : "lock.open.fill")
                                    .foregroundStyle(mode == .shield ? Color(hex: "#9B6DFF") : Color(hex: "#FF6B35"))
                                    .frame(width: 20)
                                TextField("0.0", text: $amountText)
                                    .keyboardType(.decimalPad)
                                    .foregroundStyle(themeManager.textPrimary)
                                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                                Spacer()
                                Text("STRK")
                                    .font(.system(size: 14))
                                    .foregroundStyle(themeManager.textSecondary)
                            }
                            .padding(16)
                            .background(themeManager.surface1)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(themeManager.surface2, lineWidth: 1))

                            // Available balance
                            HStack {
                                Spacer()
                                Button(action: { amountText = String(format: "%.6f", availableBalance) }) {
                                    Text("Available: \(String(format: "%.4f", availableBalance)) STRK")
                                        .font(.system(size: 11))
                                        .foregroundStyle(themeManager.textSecondary.opacity(0.6))
                                }
                            }
                        }

                        // ── Error ────────────────────────────────────────
                        if let err = errorMessage {
                            HStack(spacing: 8) {
                                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                                Text(err).font(.system(size: 13)).foregroundStyle(.red)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        // ── Success ──────────────────────────────────────
                        if let hash = txHash {
                            let explorerUrl = URL(string: "https://sepolia.voyager.online/tx/\(hash)")
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.shield.fill")
                                    .foregroundStyle(mode == .shield ? Color(hex: "#9B6DFF") : Color(hex: "#FF6B35"))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(mode == .shield ? "Shielded successfully!" : "Unshielded successfully!")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(themeManager.textPrimary)
                                    if let url = explorerUrl {
                                        Link(destination: url) {
                                            HStack(spacing: 4) {
                                                Text("Tx: \(hash.prefix(14))…")
                                                    .font(.system(size: 11, design: .monospaced))
                                                Image(systemName: "arrow.up.right.square")
                                                    .font(.system(size: 10))
                                            }
                                            .foregroundStyle(mode == .shield ? Color(hex: "#9B6DFF") : Color(hex: "#FF6B35"))
                                        }
                                    }
                                }
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background((mode == .shield ? Color(hex: "#4A1DB5") : Color(hex: "#FF6B35")).opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }

                        // ── Execute button ───────────────────────────────
                        Button(action: { executeAction() }) {
                            Group {
                                if isProcessing {
                                    HStack(spacing: 10) {
                                        ProgressView().tint(themeManager.bgColor)
                                        Text(mode == .shield ? "Shielding…" : "Unshielding…")
                                    }
                                } else if txHash != nil {
                                    HStack(spacing: 8) {
                                        Image(systemName: "checkmark")
                                        Text("Done")
                                    }
                                } else {
                                    Text(mode == .shield ? "Shield" : "Unshield")
                                }
                            }
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(canExecute ? themeManager.bgColor : themeManager.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(canExecute ? themeManager.textPrimary : themeManager.surface2)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .disabled(!canExecute && txHash == nil)

                        Spacer(minLength: 40)
                    }
                    .padding(20)
                }
            }
            .navigationTitle(mode == .shield ? "Shield STRK" : "Unshield STRK")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(txHash != nil ? "Done" : "Cancel") { dismiss() }
                        .foregroundStyle(themeManager.textSecondary)
                }
            }
        }
        .preferredColorScheme(themeManager.colorScheme)
    }

    private func executeAction() {
        guard let amount = parsedAmount else { return }
        errorMessage = nil
        isProcessing = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        Task {
            do {
                let rpcUrl = networkManager.activeNetwork.rpcUrl
                let contract = networkManager.activeNetwork.contractAddress
                let network = networkManager.activeNetwork

                let hash: String
                if mode == .shield {
                    hash = try await walletManager.executeShield(
                        amount: amount,
                        memo: "shielded deposit",
                        rpcUrl: rpcUrl,
                        contractAddress: contract,
                        network: network
                    )
                } else {
                    let selfAddress = KeychainManager.accountAddress() ?? ""
                    try await walletManager.executeUnshield(
                        recipient: selfAddress,
                        amount: amount,
                        rpcUrl: rpcUrl,
                        contractAddress: contract,
                        network: network
                    )
                    hash = walletManager.lastUnshieldTxHash ?? "submitted"
                }

                UINotificationFeedbackGenerator().notificationOccurred(.success)
                // Refresh public balance so the vault shows updated amounts immediately
                Task {
                    await walletManager.refreshPublicBalance(rpcUrl: networkManager.activeNetwork.rpcUrl)
                }
                withAnimation {
                    txHash = hash
                    isProcessing = false
                }
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                dismiss()
            } catch {
                isProcessing = false
                errorMessage = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}
