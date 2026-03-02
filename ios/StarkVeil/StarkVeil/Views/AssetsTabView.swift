import SwiftUI

struct AssetsTabView: View {
    @EnvironmentObject private var themeManager: AppThemeManager
    @EnvironmentObject private var walletManager: WalletManager
    var isBalanceVisible: Bool

    var body: some View {
        VStack(spacing: 12) {
            AssetRowView(
                iconSystemName: "diamond.fill",
                iconBgColor: Color(hex: "#6E00FF").opacity(0.2),
                iconFgColor: Color(hex: "#B9B4F8"),
                name: "Starknet (STRK)",
                subtitle: "Private Token",
                amount: walletManager.balance,
                amountSuffix: "STRK",
                fiatAmount: walletManager.balance * 0.63,
                isVisible: isBalanceVisible
            )

            AssetRowView(
                iconSystemName: "bitcoinsign.circle.fill",
                iconBgColor: Color(hex: "#F7931A").opacity(0.2),
                iconFgColor: Color(hex: "#F7931A"),
                name: "strkBTC",
                subtitle: "Shielded Pool",
                amount: 0,
                amountSuffix: "BTC",
                fiatAmount: 0,
                isVisible: isBalanceVisible
            )
        }
        .padding(.horizontal, 20)
    }
}

private struct AssetRowView: View {
    @EnvironmentObject private var themeManager: AppThemeManager
    let iconSystemName: String
    let iconBgColor: Color
    let iconFgColor: Color
    let name: String
    let subtitle: String
    let amount: Double
    let amountSuffix: String
    let fiatAmount: Double
    let isVisible: Bool

    var body: some View {
        HStack(spacing: 15) {
            // Asset icon
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(iconBgColor)
                    .frame(width: 40, height: 40)
                Image(systemName: iconSystemName)
                    .font(.system(size: 18))
                    .foregroundStyle(iconFgColor)
            }

            // Name + subtitle
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(themeManager.textPrimary)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(themeManager.textSecondary)
            }

            Spacer()

            // Balance (redacted or revealed)
            VStack(alignment: .trailing, spacing: 4) {
                Text(isVisible ? String(format: "%.4f %@", amount, amountSuffix) : "••••••")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(themeManager.textPrimary)
                    .blur(radius: isVisible ? 0 : 5)
                    .animation(.easeInOut(duration: 0.3), value: isVisible)
                Text(isVisible ? String(format: "$%.2f", fiatAmount) : "$••••••")
                    .font(.system(size: 13))
                    .foregroundStyle(themeManager.textSecondary)
                    .blur(radius: isVisible ? 0 : 5)
                    .animation(.easeInOut(duration: 0.3), value: isVisible)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(themeManager.surface1.opacity(0.65))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(themeManager.surface2, lineWidth: 1)
                )
        )
    }
}
