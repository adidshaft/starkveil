import SwiftUI

struct ShieldedBalanceCard: View {
    @EnvironmentObject private var walletManager: WalletManager
    @State private var isBalanceRevealed = false

    // @State keeps the same generator instance alive across body re-evaluations.
    // prepare() is called on appear so the taptic engine is primed and fires on time.
    @State private var impact = UIImpactFeedbackGenerator(style: .heavy)

    var body: some View {
        VStack(spacing: 15) {
            Text("Shielded Balance")
                .font(.subheadline)
                .tracking(2.0)
                .foregroundStyle(Color(white: 0.5))

            ZStack {
                if isBalanceRevealed {
                    Text("$\(walletManager.balance, specifier: "%.2f")")
                        .font(.system(size: 48, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .shadow(color: Color.white.opacity(0.3), radius: 10)
                        // contentTransition gives digit-by-digit morphing on iOS 16+
                        .contentTransition(.numericText())
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                } else {
                    // .monospaced keeps glyph width consistent with the balance text
                    // to prevent ZStack layout shift on reveal
                    Text("••••••")
                        .font(.system(size: 48, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
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
                .foregroundStyle(Color.white.opacity(0.3))
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(Color(white: 0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 32, style: .continuous)
                        .stroke(
                            LinearGradient(
                                gradient: Gradient(colors: [Color.white.opacity(0.2), Color.clear]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: Color.black.opacity(0.5), radius: 20, y: 10)
        )
        .padding(.horizontal)
        .onAppear {
            // Prime the taptic engine so impactOccurred fires with zero latency
            impact.prepare()
        }
    }
}
