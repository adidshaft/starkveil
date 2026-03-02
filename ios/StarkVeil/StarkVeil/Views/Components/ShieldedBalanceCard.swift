import SwiftUI

struct ShieldedBalanceCard: View {
    @EnvironmentObject private var themeManager: AppThemeManager
    @EnvironmentObject private var walletManager: WalletManager
    @State private var isBalanceRevealed = false

    // @State keeps the same generator instance alive across body re-evaluations.
    // prepare() is called on appear so the taptic engine is primed and fires on time.
    @State private var impact = UIImpactFeedbackGenerator(style: .heavy)

    var body: some View {
        VStack(spacing: 15) {
            Text("SHIELDED BALANCE")
                .font(.system(size: 12, weight: .bold, design: .default))
                .tracking(2.0)
                .foregroundStyle(themeManager.textSecondary)

            ZStack {
                if isBalanceRevealed {
                    Text("$\(walletManager.balance, specifier: "%.2f")")
                        .font(.system(size: 42, weight: .bold, design: .monospaced))
                        .foregroundStyle(themeManager.textPrimary)
                        // contentTransition gives digit-by-digit morphing on iOS 16+
                        .contentTransition(.numericText())
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                } else {
                    // .monospaced keeps glyph width consistent with the balance text
                    // to prevent ZStack layout shift on reveal
                    Text("••••••")
                        .font(.system(size: 42, weight: .bold, design: .monospaced))
                        .foregroundStyle(themeManager.textPrimary)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
            // pressing: tracks continuous touch state — reveals on press, hides on release
            .onLongPressGesture(minimumDuration: 0.1, pressing: { isPressing in
                if isPressing { impact.impactOccurred() }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                    isBalanceRevealed = isPressing
                }
            }, perform: {})

            Text("Hold to decrypt")
                .font(.caption2.monospaced())
                .foregroundStyle(themeManager.textSecondary)
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(themeManager.surface1.opacity(0.85)) // Glass effect mapping
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(themeManager.surface2, lineWidth: 1)
                )
        )
        .padding(.horizontal)
        .onAppear {
            // Prime the taptic engine so impactOccurred fires with zero latency
            impact.prepare()
        }
    }
}
