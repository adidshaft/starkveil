import SwiftUI

/// Phase 19: Zashi-style balance card with total balance and 3 clean actions.
/// Shows total = U + S, with a breakdown visible in AssetsTabView below.
struct ShieldedBalanceCard: View {
    @EnvironmentObject private var themeManager: AppThemeManager
    @EnvironmentObject private var walletManager: WalletManager

    @Binding var isBalanceVisible: Bool
    @Binding var showSendSheet: Bool
    @Binding var showReceiveSheet: Bool
    @Binding var showShieldSheet: Bool

    @State private var impact = UIImpactFeedbackGenerator(style: .medium)

    /// Total balance = public (U) + shielded (S)
    private var totalBalance: Double {
        walletManager.publicBalance + walletManager.balance
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Balance header ────────────────────────────────────────
            HStack {
                Text("TOTAL BALANCE")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(themeManager.textSecondary)
                Spacer()
                Button(action: {
                    impact.impactOccurred()
                    withAnimation(.easeInOut(duration: 0.3)) { isBalanceVisible.toggle() }
                }) {
                    Image(systemName: isBalanceVisible ? "eye" : "eye.slash")
                        .font(.system(size: 13))
                        .frame(width: 32, height: 32)
                        .background(themeManager.surface2)
                        .foregroundStyle(themeManager.textPrimary)
                        .clipShape(Circle())
                }
            }
            .padding(.bottom, 16)

            // ── Balance amount ────────────────────────────────────────
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                if isBalanceVisible {
                    Text(String(format: "%.4f", totalBalance))
                        .font(.system(size: 42, weight: .bold))
                        .foregroundStyle(themeManager.textPrimary)
                        .contentTransition(.numericText())
                } else {
                    Text("– – – – – –")
                        .font(.system(size: 32, weight: .bold, design: .monospaced))
                        .foregroundStyle(themeManager.textSecondary)
                }
                Text("STRK")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(themeManager.textSecondary)
                    .offset(y: -4)
            }
            .animation(.easeInOut(duration: 0.3), value: isBalanceVisible)

            // USD fiat conversion
            Text(isBalanceVisible
                 ? String(format: "$%.2f USD", totalBalance * 0.63)
                 : "$– – – – – – USD")
                .font(.system(size: 15, design: .monospaced))
                .foregroundStyle(themeManager.textSecondary)
                .animation(.easeInOut(duration: 0.3), value: isBalanceVisible)
                .padding(.top, 6)
                .padding(.bottom, 8)

            // Mini breakdown: U | S
            if isBalanceVisible {
                HStack(spacing: 16) {
                    HStack(spacing: 4) {
                        Text("U")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color(hex: "#FF6B35"))
                            .clipShape(Capsule())
                        Text(String(format: "%.4f", walletManager.publicBalance))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(themeManager.textSecondary)
                    }
                    HStack(spacing: 4) {
                        Text("S")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color(hex: "#9B6DFF"))
                            .clipShape(Capsule())
                        Text(String(format: "%.4f", walletManager.balance))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(themeManager.textSecondary)
                    }
                }
                .padding(.bottom, 16)
                .transition(.opacity)
            } else {
                Spacer().frame(height: 16)
            }

            // ── 3 Action Buttons ─────────────────────────────────────
            HStack(spacing: 12) {
                actionButton(icon: "arrow.up.circle.fill", label: "Send") {
                    showSendSheet = true
                }
                actionButton(icon: "arrow.down.circle.fill", label: "Receive") {
                    showReceiveSheet = true
                }
                actionButton(icon: "shield.lefthalf.filled", label: "Shield") {
                    showShieldSheet = true
                }
            }
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(themeManager.surface1.opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(themeManager.surface2, lineWidth: 1)
                )
        )
        .padding(.horizontal, 20)
        .onAppear { impact.prepare() }
    }

    private func actionButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: {
            impact.impactOccurred()
            action()
        }) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(themeManager.surface2)
                        .frame(width: 52, height: 52)
                    Image(systemName: icon)
                        .font(.system(size: 20))
                        .foregroundStyle(themeManager.textPrimary)
                }
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(themeManager.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
