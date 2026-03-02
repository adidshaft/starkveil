import SwiftUI

struct STARKProofOverlay: View {
    @EnvironmentObject private var themeManager: AppThemeManager
    @EnvironmentObject private var walletManager: WalletManager

    @State private var rotation: Double = 0
    @State private var progress: Double = 0
    @State private var logLines: [String] = []
    @State private var logTimer: Timer?

    private let steps = [
        "> Constructing UTXO Note...",
        "> Computing Poseidon(value, asset_id, ivk, memo)",
        "> Generating S-Two STARK Proof...",
        "> Running Cairo verifier locally...",
        "> Assembling Invoke payload...",
        "> Submitting to Sequencer...",
        "> Proof verified. Note added to commitment tree."
    ]

    var body: some View {
        ZStack {
            // Blurred backdrop exactly like the prototype
            themeManager.bgColor.opacity(0.85)
                .background(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                // Animated spinner
                ZStack {
                    Circle()
                        .stroke(themeManager.surface2, lineWidth: 3)
                        .frame(width: 60, height: 60)
                    Circle()
                        .trim(from: 0, to: 0.75)
                        .stroke(themeManager.textPrimary, lineWidth: 3)
                        .frame(width: 60, height: 60)
                        .rotationEffect(.degrees(rotation))
                }
                .onAppear {
                    withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                        rotation = 360
                    }
                }

                // Text
                Text("Synthesizing STARK Proof")
                    .font(.system(size: 20, design: .monospaced))
                    .foregroundStyle(themeManager.textPrimary)
                    .tracking(1)

                Text("Executing Cairo Circuits Locally...")
                    .font(.system(size: 14))
                    .foregroundStyle(themeManager.textSecondary)

                // Progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(themeManager.surface2)
                            .frame(height: 4)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(themeManager.textPrimary)
                            .frame(width: geo.size.width * progress, height: 4)
                            .animation(.easeInOut(duration: 0.2), value: progress)
                    }
                }
                .frame(height: 4)

                // Log output
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(logLines.indices, id: \.self) { idx in
                                Text(logLines[idx])
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(themeManager.textSecondary)
                                    .id(idx)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 100)
                    .padding(12)
                    .background(themeManager.surface1)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(themeManager.surface2, lineWidth: 1))
                    .onChange(of: logLines.count) { _, _ in
                        proxy.scrollTo(logLines.count - 1)
                    }
                }
            }
            .padding(30)
        }
        .onAppear(perform: startProofAnimation)
        .onDisappear { logTimer?.invalidate() }
    }

    private func startProofAnimation() {
        logLines = ["> Compiling note configuration..."]
        progress = 0
        var stepIndex = 0

        logTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            let increment = Double.random(in: 0.1...0.18)
            progress = min(progress + increment, 1.0)

            if stepIndex < steps.count, progress > Double(stepIndex) / Double(steps.count) {
                logLines.append(steps[stepIndex])
                stepIndex += 1
            }
        }
    }
}
