import SwiftUI

struct ShieldedBalanceCard: View {
    @EnvironmentObject private var walletManager: WalletManager
    @State private var isBalanceRevealed = false
    
    // Impact feedback for haptics when pressing
    let impact = UIImpactFeedbackGenerator(style: .heavy)
    
    var body: some View {
        VStack(spacing: 15) {
            Text("Shielded Balance")
                .font(.subheadline)
                .tracking(2.0)
                .foregroundColor(Color(white: 0.5))
            
            ZStack {
                if isBalanceRevealed {
                    Text("$\(walletManager.balance, specifier: "%.2f")")
                        .font(.system(size: 48, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        // Smooth neon glow for revealed private value
                        .shadow(color: Color.white.opacity(0.3), radius: 10)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                } else {
                    Text("••••••")
                        .font(.system(size: 48, weight: .bold))
                        .foregroundColor(.white)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
            // Continuous Spring Gesture
            .onLongPressGesture(minimumDuration: 0.1, pressing: { isPressing in
                if isPressing { impact.impactOccurred() }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                    isBalanceRevealed = isPressing
                }
            }, perform: {})
            
            Text("Hold to decrypt")
                .font(.caption2.monospaced())
                .foregroundColor(Color.white.opacity(0.3))
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
        .background(
            // Premium Glassmorphic / Obsidian Card
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
    }
}
