import SwiftUI

struct ProofSynthesisSkeleton: View {
    @State private var rotation: Double = 0.0
    @State private var pulse: CGFloat = 1.0

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(Color.purple.opacity(0.3), lineWidth: 3)
                    .frame(width: 20, height: 20)
                
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
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    pulse = 1.1
                }
            }
            
            Text("Synthesizing STARK Proof…")
                .font(.headline.monospaced())
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(white: 0.1))
        .cornerRadius(16)
        // Electric purple stroke during generation
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.purple.opacity(0.6), lineWidth: 1)
        )
    }
}
