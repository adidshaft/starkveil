import SwiftUI

enum BottomNavTab: CaseIterable {
    case wallet, swap, activity, settings

    var label: String {
        switch self {
        case .wallet: return "Wallet"
        case .swap: return "Swap"
        case .activity: return "Activity"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .wallet: return "wallet.bifold.fill"
        case .swap: return "arrow.left.arrow.right"
        case .activity: return "clock.arrow.circlepath"
        case .settings: return "gearshape.fill"
        }
    }
}

struct BottomNavView: View {
    @EnvironmentObject private var themeManager: AppThemeManager
    @Binding var selectedTab: BottomNavTab

    var body: some View {
        HStack {
            ForEach(BottomNavTab.allCases, id: \.label) { tab in
                Button(action: { selectedTab = tab }) {
                    VStack(spacing: 6) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 20))
                        Text(tab.label)
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(selectedTab == tab ? themeManager.textPrimary : themeManager.textSecondary)
                    .fontWeight(selectedTab == tab ? .bold : .regular)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 15)
        .padding(.bottom, 25)
        .background(
            themeManager.bgColor.opacity(0.85)
                .background(.ultraThinMaterial)
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(themeManager.surface2)
                .frame(height: 1)
        }
    }
}
