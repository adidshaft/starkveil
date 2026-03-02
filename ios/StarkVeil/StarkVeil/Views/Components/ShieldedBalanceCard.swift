import SwiftUI

struct ShieldedBalanceCard: View {
    @EnvironmentObject private var themeManager: AppThemeManager
    @EnvironmentObject private var walletManager: WalletManager
    @Binding var isBalanceVisible: Bool
    @Binding var showSendSheet: Bool
    @Binding var showUnshieldSheet: Bool

    @State private var impact = UIImpactFeedbackGenerator(style: .medium)

    var body: some View {
        VStack(spacing: 0) {
            // Card header row
            HStack {
                Text("SHIELDED BALANCE")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(themeManager.textSecondary)
                Spacer()
                // Eye-toggle button (matching the prototype's toggle-visibility)
                Button(action: {
                    impact.impactOccurred()
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isBalanceVisible.toggle()
                    }
                }) {
                    Image(systemName: isBalanceVisible ? "eye" : "eye.slash")
                        .font(.system(size: 13))
                        .frame(width: 32, height: 32)
                        .background(themeManager.surface2)
                        .foregroundStyle(themeManager.textPrimary)
                        .clipShape(Circle())
                }
            }
            .padding(.bottom, 20)

            // Balance amount with blur-redaction
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(isBalanceVisible ? String(format: "%.2f", walletManager.balance) : "••••••")
                    .font(.system(size: 42, weight: .bold, design: .default))
                    .foregroundStyle(themeManager.textPrimary)
                    .contentTransition(.numericText())
                    .blur(radius: isBalanceVisible ? 0 : 8)
                    .opacity(isBalanceVisible ? 1 : 0.6)
                    .animation(.easeInOut(duration: 0.3), value: isBalanceVisible)

                Text("STRK")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(themeManager.textSecondary)
                    .offset(y: -4)
            }

            // Fiat sub-label
            Text(isBalanceVisible ? String(format: "$%.2f USD", walletManager.balance * 0.63) : "$•••••• USD")
                .font(.system(size: 16, design: .monospaced))
                .foregroundStyle(themeManager.textSecondary)
                .blur(radius: isBalanceVisible ? 0 : 6)
                .animation(.easeInOut(duration: 0.3), value: isBalanceVisible)
                .padding(.top, 10)
                .padding(.bottom, 30)

            // Action buttons: Send (filled) + Receive (outlined)
            HStack(spacing: 12) {
                Button(action: { showSendSheet = true }) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Send")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(themeManager.bgColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(themeManager.textPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                Button(action: { showUnshieldSheet = true }) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Receive")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(themeManager.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(themeManager.textPrimary, lineWidth: 1)
                    )
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
}
