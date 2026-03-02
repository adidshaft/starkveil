import SwiftUI

struct VaultHeaderView: View {
    @EnvironmentObject private var themeManager: AppThemeManager
    @EnvironmentObject private var syncEngine: SyncEngine
    @EnvironmentObject private var networkManager: NetworkManager
    @State private var isBreathing = false

    var body: some View {
        HStack(spacing: 12) {
            // Avatar circle (user-ninja equivalent)
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [themeManager.surface2, themeManager.surface1],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 44, height: 44)
                    .overlay(Circle().stroke(themeManager.surface2, lineWidth: 1))
                Image(systemName: "person.fill.viewfinder")
                    .font(.system(size: 18))
                    .foregroundStyle(themeManager.textSecondary)
            }

            // StarkNet ID + Shielded status pill
            VStack(alignment: .leading, spacing: 2) {
                Text("anon.stark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(themeManager.textPrimary)
                    .tracking(0.5)

                // Syncing indicator as a pill badge
                HStack(spacing: 4) {
                    Circle()
                        .fill(syncEngine.isSyncing ? Color.green : Color(hex: "#8A8885"))
                        .frame(width: 6, height: 6)
                        .scaleEffect(isBreathing ? 1.2 : 0.9)
                        .animation(
                            syncEngine.isSyncing ? .easeInOut(duration: 1.4).repeatForever(autoreverses: true) : .none,
                            value: isBreathing
                        )
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 9))
                    Text(syncEngine.isSyncing ? "Shielded" : "Offline")
                        .font(.system(size: 11))
                }
                .foregroundStyle(themeManager.bgColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(syncEngine.isSyncing ? themeManager.textPrimary : themeManager.textSecondary)
                .clipShape(Capsule())
            }
            .onChange(of: syncEngine.isSyncing) { _, isSyncing in
                isBreathing = false
                if isSyncing { Task { @MainActor in isBreathing = true } }
            }

            Spacer()

            // Theme toggle (moon/sun icon button)
            Button(action: { themeManager.toggleTheme() }) {
                Image(systemName: themeManager.isDarkMode ? "sun.max.fill" : "moon.fill")
                    .font(.system(size: 15))
                    .frame(width: 44, height: 44)
                    .background(themeManager.surface2)
                    .foregroundStyle(themeManager.textPrimary)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(themeManager.surface2.opacity(0.8), lineWidth: 1))
            }

            // Network switcher (QR-code/grid icon equivalent)
            Menu {
                Picker("Network", selection: $networkManager.activeNetwork) {
                    ForEach(NetworkEnvironment.allCases) { env in
                        Text(env.rawValue).tag(env)
                    }
                }
            } label: {
                Group {
                    if networkManager.activeNetwork == .sepolia {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                    } else {
                        Image(systemName: "network")
                    }
                }
                .font(.system(size: 15))
                .frame(width: 44, height: 44)
                .background(themeManager.surface2)
                .foregroundStyle(themeManager.textPrimary)
                .clipShape(Circle())
                .overlay(Circle().stroke(themeManager.surface2.opacity(0.8), lineWidth: 1))
            }
        }
        .padding(.horizontal, 20)
        .onAppear { if syncEngine.isSyncing { isBreathing = true } }
    }
}
