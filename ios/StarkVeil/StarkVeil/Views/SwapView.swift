import SwiftUI

/// Private Swap tab — routes all swaps through the shielded pool so no
/// public on-chain link exists between the input and output asset.
struct SwapView: View {
    @EnvironmentObject private var themeManager: AppThemeManager
    @EnvironmentObject private var walletManager: WalletManager
    @EnvironmentObject private var networkManager: NetworkManager

    // Supported tokens
    private let tokens = ["STRK", "ETH", "USDC"]
    private let stubRates: [String: [String: Double]] = [
        "STRK": ["ETH": 0.00035, "USDC": 0.41],
        "ETH":  ["STRK": 2857.0, "USDC": 1172.0],
        "USDC": ["STRK": 2.44, "ETH": 0.000853]
    ]

    @State private var fromToken = "STRK"
    @State private var toToken   = "ETH"
    @State private var fromAmount = ""
    @State private var showComingSoon = false

    private var rate: Double { stubRates[fromToken]?[toToken] ?? 0 }
    private var parsedAmount: Double? {
        guard let v = Double(fromAmount), v > 0, v.isFinite else { return nil }
        return v
    }
    private var toAmount: String {
        guard let a = parsedAmount else { return "" }
        let received = a * rate
        return received >= 1 ? String(format: "%.4f", received) : String(format: "%.8f", received)
    }
    private var canSwap: Bool {
        !walletManager.isProving &&
        parsedAmount != nil &&
        (parsedAmount ?? 0) <= walletManager.balance &&
        fromToken != toToken
    }

    var body: some View {
        ZStack {
            themeManager.bgColor.ignoresSafeArea()

            // Ambient orbs
            Circle()
                .fill(themeManager.textPrimary.opacity(0.05))
                .frame(width: 280, height: 280)
                .blur(radius: 90)
                .offset(x: 80, y: -200)
                .allowsHitTesting(false)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    // ── Header ──────────────────────────────────────────
                    VStack(spacing: 4) {
                        Text("Private Swap")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(themeManager.textPrimary)
                        Text("Swaps are routed through your shielded pool")
                            .font(.system(size: 13))
                            .foregroundStyle(themeManager.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // ── Privacy notice ───────────────────────────────────
                    HStack(spacing: 10) {
                        Image(systemName: "lock.shield.fill")
                            .foregroundStyle(themeManager.textPrimary)
                            .font(.system(size: 13))
                        Text("No public on-chain link between your input and output assets.")
                            .font(.system(size: 12))
                            .foregroundStyle(themeManager.textSecondary)
                    }
                    .padding(12)
                    .background(themeManager.surface1)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(themeManager.surface2, lineWidth: 1))

                    // ── From ─────────────────────────────────────────────
                    tokenInputCard(
                        label: "You Pay",
                        selectedToken: $fromToken,
                        amount: $fromAmount,
                        isEditable: true,
                        balance: walletManager.balance
                    )

                    // ── Swap direction button ───────────────────────────
                    Button(action: { showComingSoon = true }) {
                        ZStack {
                            Circle()
                                .fill(themeManager.surface2)
                                .frame(width: 44, height: 44)
                            Image(systemName: "arrow.up.arrow.down")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(themeManager.textPrimary)
                        }
                    }

                    // ── To ───────────────────────────────────────────────
                    toCard

                    // ── Rate ─────────────────────────────────────────────
                    if fromToken != toToken {
                        HStack {
                            Image(systemName: "chart.line.uptrend.xyaxis")
                                .font(.system(size: 11))
                                .foregroundStyle(themeManager.textSecondary)
                            Text("1 \(fromToken) ≈ \(rate >= 1 ? String(format: "%.4f", rate) : String(format: "%.8f", rate)) \(toToken)")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(themeManager.textSecondary)
                            Spacer()
                            Text("Stub rate — MVP")
                                .font(.system(size: 10))
                                .foregroundStyle(themeManager.textSecondary.opacity(0.5))
                        }
                        .padding(.horizontal, 4)
                    }


                    // ── Execute button ────────────────────────────────────
                    Button(action: { showComingSoon = true }) {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.left.arrow.right.circle.fill")
                            Text("Execute Private Swap")
                        }
                        .font(.headline.weight(.heavy))
                        .tracking(0.5)
                        .foregroundStyle(themeManager.bgColor)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(themeManager.textPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .animation(.easeInOut(duration: 0.25), value: showComingSoon)

                    Spacer(minLength: 40)
                }
                .padding(20)
                .padding(.bottom, 80)
            }

            // STARK proof overlay
            if walletManager.isProving {
                STARKProofOverlay()
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    .zIndex(10)
            }
        }
        .alert("Coming Soon", isPresented: $showComingSoon) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Swap feature is yet to be enabled.")
        }
    }

    // MARK: - Token input card
    @ViewBuilder
    private func tokenInputCard(
        label: String,
        selectedToken: Binding<String>,
        amount: Binding<String>,
        isEditable: Bool,
        balance: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(themeManager.textSecondary)

            HStack(spacing: 12) {
                // Token picker
                Menu {
                    ForEach(tokens, id: \.self) { token in
                        Button(token) { showComingSoon = true }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(tokenColor(selectedToken.wrappedValue))
                            .frame(width: 28, height: 28)
                            .overlay(
                                Text(String(selectedToken.wrappedValue.prefix(1)))
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.white)
                            )
                        Text(selectedToken.wrappedValue)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(themeManager.textPrimary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10))
                            .foregroundStyle(themeManager.textSecondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(themeManager.surface2)
                    .clipShape(Capsule())
                }

                Spacer()

                if isEditable {
                    TextField("0.0", text: amount)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .font(.system(size: 22, weight: .semibold, design: .monospaced))
                        .foregroundStyle(themeManager.textPrimary)
                        .frame(maxWidth: 160)
                } else {
                    Text(toAmount.isEmpty ? "—" : toAmount)
                        .font(.system(size: 22, weight: .semibold, design: .monospaced))
                        .foregroundStyle(themeManager.textPrimary)
                }
            }

            if isEditable {
                HStack {
                    Text("Balance: \(String(format: "%.4f", balance)) \(selectedToken.wrappedValue)")
                        .font(.system(size: 11))
                        .foregroundStyle(themeManager.textSecondary)
                    Spacer()
                    Button("MAX") {
                        showComingSoon = true
                    }
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(themeManager.textPrimary)
                }
            }
        }
        .padding(16)
        .background(themeManager.surface1)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(themeManager.surface2, lineWidth: 1))
    }

    // MARK: - To card (read-only)
    private var toCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("You Receive")
                .font(.system(size: 12))
                .foregroundStyle(themeManager.textSecondary)
            HStack(spacing: 12) {
                Menu {
                    ForEach(tokens.filter { $0 != fromToken }, id: \.self) { token in
                        Button(token) { showComingSoon = true }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(tokenColor(toToken))
                            .frame(width: 28, height: 28)
                            .overlay(
                                Text(String(toToken.prefix(1)))
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.white)
                            )
                        Text(toToken)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(themeManager.textPrimary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10))
                            .foregroundStyle(themeManager.textSecondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(themeManager.surface2)
                    .clipShape(Capsule())
                }
                Spacer()
                Text(toAmount.isEmpty ? "—" : toAmount)
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .foregroundStyle(themeManager.textPrimary)
            }
        }
        .padding(16)
        .background(themeManager.surface1)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(themeManager.surface2, lineWidth: 1))
    }

    private func swapDirection() {
        showComingSoon = true
    }

    private func tokenColor(_ token: String) -> Color {
        switch token {
        case "STRK": return Color(hex: "#E07B3F")
        case "ETH":  return Color(hex: "#627EEA")
        case "USDC": return Color(hex: "#2775CA")
        default:     return Color(hex: "#888888")
        }
    }
}
