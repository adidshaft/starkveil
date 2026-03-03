import SwiftUI

/// Shield flow: Public STRK → Private shielded note.
/// User enters an amount of their public STRK to deposit into the PrivacyPool contract.
/// The contract emits a `Shielded` event that SyncEngine detects and converts to a local note.
///
/// Privacy model (matches ZODL/Zashi "auto-shield" philosophy):
/// - This is the ENTRY POINT into privacy. Once shielded, all further operations
///   (Send, Swap, Unshield) generate STARK proofs that break the on-chain link.
/// - The on-chain `shield` call reveals: depositing address + amount + contract.
///   Everything after that is private.
struct ShieldView: View {
    @EnvironmentObject private var themeManager: AppThemeManager
    @EnvironmentObject private var walletManager: WalletManager
    @EnvironmentObject private var networkManager: NetworkManager
    @Environment(\.dismiss) private var dismiss

    @State private var amountText = ""
    @State private var memo = ""
    @State private var isShielding = false
    @State private var errorMessage: String? = nil
    @State private var txHash: String? = nil
    @State private var showReview = false

    private var parsedAmount: Double? {
        guard let v = Double(amountText), v > 0, v.isFinite else { return nil }
        return v
    }
    private var canReview: Bool { parsedAmount != nil && !isShielding }

    var body: some View {
        NavigationStack {
            ZStack {
                themeManager.bgColor.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 24) {

                        // ── Balance being shielded (large, ZODL style) ──────
                        VStack(spacing: 4) {
                            Image(systemName: "shield.lefthalf.filled")
                                .font(.system(size: 30))
                                .foregroundStyle(Color(hex: "#9B6DFF"))

                            if amountText.isEmpty {
                                Text("Ž – – – – – –")
                                    .font(.system(size: 38, weight: .bold, design: .monospaced))
                                    .foregroundStyle(themeManager.textSecondary)
                            } else {
                                Text("Ž \(amountText)")
                                    .font(.system(size: 38, weight: .bold, design: .monospaced))
                                    .foregroundStyle(themeManager.textPrimary)
                                    .contentTransition(.numericText())
                                    .animation(.easeInOut(duration: 0.2), value: amountText)
                            }
                        }
                        .padding(.top, 8)

                        // ── Privacy info banner ─────────────────────────────
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.down.to.line.compact")
                                .foregroundStyle(Color(hex: "#9B6DFF"))
                                .font(.system(size: 14))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Public → Shielded")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(themeManager.textPrimary)
                                Text("Your public STRK enters the privacy pool. The deposit amount is visible on-chain. Everything after is private.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(themeManager.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(14)
                        .background(Color(hex: "#4A1DB5").opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color(hex: "#6B3DE8").opacity(0.3), lineWidth: 1))

                        // ── Amount ──────────────────────────────────────────
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Amount")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(themeManager.textSecondary)
                                .tracking(0.5)

                            HStack {
                                Image(systemName: "shield.lefthalf.filled")
                                    .foregroundStyle(Color(hex: "#9B6DFF"))
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
                        }

                        // ── Encrypted memo (ZODL-style) ─────────────────────
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Encrypted Memo")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(themeManager.textSecondary)
                                    .tracking(0.5)
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(themeManager.textSecondary)
                            }
                            ZStack(alignment: .topLeading) {
                                if memo.isEmpty {
                                    Text("Add a private note to this deposit…")
                                        .font(.system(size: 14))
                                        .foregroundStyle(themeManager.textSecondary.opacity(0.5))
                                        .padding(.top, 14)
                                        .padding(.leading, 4)
                                }
                                TextEditor(text: $memo)
                                    .foregroundStyle(themeManager.textPrimary)
                                    .font(.system(size: 14))
                                    .scrollContentBackground(.hidden)
                                    .background(Color.clear)
                                    .frame(minHeight: 80, maxHeight: 120)
                            }
                            HStack {
                                Spacer()
                                Text("\(memo.count)/512")
                                    .font(.system(size: 11))
                                    .foregroundStyle(themeManager.textSecondary.opacity(0.5))
                            }
                        }
                        .padding(14)
                        .background(themeManager.surface1)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(themeManager.surface2, lineWidth: 1))
                        .onChange(of: memo) { _, new in
                            if new.count > 512 { memo = String(new.prefix(512)) }
                        }

                        // ── Error ───────────────────────────────────────────
                        if let err = errorMessage {
                            HStack(spacing: 8) {
                                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                                Text(err).font(.system(size: 13)).foregroundStyle(.red)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        // ── Success ─────────────────────────────────────────
                        if let hash = txHash {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.shield.fill")
                                    .foregroundStyle(Color(hex: "#9B6DFF"))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Shielded successfully!")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(themeManager.textPrimary)
                                    Text("Tx: \(hash.prefix(16))…")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(themeManager.textSecondary)
                                }
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(hex: "#4A1DB5").opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }

                        // ── Review button (ZODL pattern) ────────────────────
                        Button(action: {
                            if txHash == nil {
                                if showReview {
                                    executeShield()
                                } else {
                                    withAnimation { showReview = true }
                                }
                            }
                        }) {
                            Group {
                                if isShielding {
                                    HStack(spacing: 10) {
                                        ProgressView().tint(themeManager.bgColor)
                                        Text("Shielding…")
                                    }
                                } else if txHash != nil {
                                    HStack(spacing: 8) {
                                        Image(systemName: "checkmark")
                                        Text("Done")
                                    }
                                } else {
                                    Text(showReview ? "Confirm Shield" : "Review")
                                }
                            }
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(canReview ? themeManager.bgColor : themeManager.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(canReview ? themeManager.textPrimary : themeManager.surface2)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .disabled(!canReview && txHash == nil)
                        .animation(.easeInOut(duration: 0.2), value: showReview)

                        // Review summary (shown after tapping Review, before Confirm)
                        if showReview, let amount = parsedAmount, txHash == nil {
                            reviewSummary(amount: amount)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }

                        Spacer(minLength: 40)
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Shield STRK")
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

    // MARK: - Review summary card
    private func reviewSummary(amount: Double) -> some View {
        VStack(spacing: 12) {
            Text("REVIEW SHIELD")
                .font(.system(size: 11, weight: .bold))
                .tracking(2)
                .foregroundStyle(themeManager.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            reviewRow(label: "Amount", value: "\(String(format: "%.6f", amount)) STRK")
            reviewRow(label: "Direction", value: "Public → Shielded Pool")
            reviewRow(label: "Memo", value: memo.isEmpty ? "None" : String(memo.prefix(30)) + (memo.count > 30 ? "…" : ""))
            reviewRow(label: "Network", value: networkManager.activeNetwork.rawValue)
            reviewRow(label: "On-chain visibility", value: "Amount only (no link to future txns)")
        }
        .padding(16)
        .background(themeManager.surface1)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(themeManager.surface2, lineWidth: 1))
    }

    private func reviewRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(themeManager.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(themeManager.textPrimary)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - Execute shield
    private func executeShield() {
        guard let amount = parsedAmount else { return }
        errorMessage = nil
        isShielding = true
        let feedback = UIImpactFeedbackGenerator(style: .medium)
        feedback.prepare(); feedback.impactOccurred()

        Task {
            do {
                let hash = try await walletManager.executeShield(
                    amount: amount,
                    memo: memo.isEmpty ? "shielded deposit" : memo,
                    rpcUrl: networkManager.activeNetwork.rpcUrl,
                    contractAddress: networkManager.activeNetwork.contractAddress,
                    network: networkManager.activeNetwork   // M-CHAIN-ID-HARDCODED fix
                )
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                withAnimation {
                    txHash = hash
                    isShielding = false
                }
                // Auto-dismiss after 2.5s so user sees success
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                dismiss()
            } catch {
                isShielding = false
                errorMessage = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}
