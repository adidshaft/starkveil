import SwiftUI

struct TabSwitcherView: View {
    @EnvironmentObject private var themeManager: AppThemeManager
    @Binding var selectedTab: VaultTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(VaultTab.allCases) { tab in
                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { selectedTab = tab } }) {
                    VStack(spacing: 0) {
                        Text(tab.label)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(selectedTab == tab ? themeManager.textPrimary : themeManager.textSecondary)
                            .padding(.bottom, 10)

                        // Active underline
                        Rectangle()
                            .fill(selectedTab == tab ? themeManager.textPrimary : Color.clear)
                            .frame(height: 2)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(themeManager.surface2)
                .frame(height: 1)
        }
        .padding(.horizontal, 20)
    }
}

enum VaultTab: String, CaseIterable, Identifiable {
    case assets = "assets"
    case activity = "activity"
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}
