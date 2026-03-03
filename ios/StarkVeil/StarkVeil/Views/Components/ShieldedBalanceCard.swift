import SwiftUI

/// Main wallet balance card — 4-action grid.
/// Send / Unshield are live. Shield/Receive show a coming-soon toast
/// until Phase 11 (Account Abstraction) is wired.
struct ShieldedBalanceCard: View {
    @EnvironmentObject private var themeManager: AppThemeManager
    @EnvironmentObject private var walletManager: WalletManager

    @Binding var isBalanceVisible: Bool
    @Binding var showSendSheet: Bool
    @Binding var showUnshieldSheet: Bool
    @Binding var showPrivateTransferSheet: Bool

    @State private var impact       = UIImpactFeedbackGenerator(style: .medium)
    @State private var toastMessage: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            // ── Balance header ────────────────────────────────────────
            HStack {
                Text("SHIELDED BALANCE")
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
                    Text(String(format: "%.2f", walletManager.balance))
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

            // USD fiat conversion row (approximate)
            Text(isBalanceVisible
                 ? String(format: "$%.2f USD", walletManager.balance * 0.63)
                 : "$– – – – – – USD")
                .font(.system(size: 15, design: .monospaced))
                .foregroundStyle(themeManager.textSecondary)
                .animation(.easeInOut(duration: 0.3), value: isBalanceVisible)
                .padding(.top, 6)
                .padding(.bottom, 24)

            // ── Action grid ───────────────────────────────────────────
            // Shield / Receive require a Starknet account address (Phase 11).
            // They are visible but show a contextual tooltip until wired.
            HStack(spacing: 12) {
                actionButton(
                    icon: "arrow.down.circle.fill",
                    label: "Receive",
                    isLive: false,
                    action: { showToast("Receive address coming soon") }
                )
                actionButton(
                    icon: "plus.circle.fill",
                    label: "Shield",
                    isLive: false,
                    action: { showToast("Shielding requires account activation") }
                )
                actionButton(
                    icon: "arrow.up.circle.fill",
                    label: "Send",
                    isLive: true,
                    action: { showSendSheet = true }
                )
                actionButton(
                    icon: "lock.open.fill",
                    label: "Unshield",
                    isLive: true,
                    action: { showUnshieldSheet = true }
                )
            }

            // Private Transfer — shield-to-shield, no public pool
            Button(action: {
                impact.impactOccurred()
                showPrivateTransferSheet = true
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "lock.doc.fill")
                        .font(.system(size: 13))
                    Text("Private Transfer")
                        .font(.system(size: 13, weight: .semibold))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(themeManager.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(themeManager.surface2)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(themeManager.textSecondary.opacity(0.12), lineWidth: 1)
                )
            }
            .padding(.top, 10)

            // Toast overlay
            if let msg = toastMessage {
                Text(msg)
                    .font(.system(size: 12))
                    .foregroundStyle(themeManager.bgColor)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(themeManager.textPrimary.opacity(0.88))
                    .clipShape(Capsule())
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.top, 12)
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

    // MARK: - Helpers

    private func showToast(_ msg: String) {
        withAnimation(.spring(response: 0.3)) { toastMessage = msg }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation(.easeOut(duration: 0.3)) { toastMessage = nil }
        }
    }

    private func actionButton(
        icon: String,
        label: String,
        isLive: Bool,
        action: @escaping () -> Void
    ) -> some View {
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
                        .foregroundStyle(isLive ? themeManager.textPrimary : themeManager.textSecondary.opacity(0.5))
                }
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isLive ? themeManager.textSecondary : themeManager.textSecondary.opacity(0.45))
            }
        }
        .frame(maxWidth: .infinity)
    }
}
