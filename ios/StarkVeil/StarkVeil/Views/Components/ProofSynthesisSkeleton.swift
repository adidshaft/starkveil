import SwiftUI

struct ProofSynthesisSkeleton: View {
    @EnvironmentObject private var themeManager: AppThemeManager
    @State private var rotation: Double = 0.0
    @State private var pulse: CGFloat = 1.0

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                // Static track — strokeBorder keeps stroke inward so both rings share
                // the same rendered boundary (no 3pt offset between track and arc)
                Circle()
                    .strokeBorder(Color.purple.opacity(0.3), lineWidth: 3)
                    .frame(width: 20, height: 20)

                // Animated gradient arc — .clear creates the gap that reads as a moving arc
                Circle()
                    .strokeBorder(
                        AngularGradient(
                            gradient: Gradient(colors: [.purple, .blue, .clear]),
                            center: .center
                        ),
                        lineWidth: 3
                    )
                    .frame(width: 20, height: 20)
                    .rotationEffect(.degrees(rotation))
            }
            .scaleEffect(pulse)
            .onAppear {
                // Both animations run independently on the render thread —
                // no main-thread body calls per frame
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    pulse = 1.1
                }
            }

            Text("Synthesizing STARK Proof…")
                .font(.headline.monospaced())
                .foregroundStyle(themeManager.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(themeManager.surface1)
        // clipShape with .continuous matches the superellipse used in ShieldedBalanceCard
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        // Electric purple stroke — .continuous matches the background clip shape
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.purple.opacity(0.6), lineWidth: 1)
        )
    }
}
