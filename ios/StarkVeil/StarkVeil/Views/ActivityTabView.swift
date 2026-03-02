import SwiftUI

struct ActivityTabView: View {
    @EnvironmentObject private var themeManager: AppThemeManager
    @EnvironmentObject private var walletManager: WalletManager
    var isBalanceVisible: Bool

    var body: some View {
        if walletManager.notes.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 36))
                    .foregroundStyle(themeManager.textSecondary)
                Text("No shielded activity yet.")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(themeManager.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(walletManager.notes.indices.reversed(), id: \.self) { i in
                    ActivityRowView(note: walletManager.notes[i], isBalanceVisible: isBalanceVisible)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 24)
                }
            }
        }
    }
}

struct ActivityRowView: View {
    @EnvironmentObject private var themeManager: AppThemeManager
    let note: Note
    let isBalanceVisible: Bool

    var isShielded: Bool { note.memo.contains("shield") || note.memo.contains("RPC") }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            // Icon circle
            ZStack {
                Circle()
                    .fill(isShielded ? themeManager.textPrimary : themeManager.surface2)
                    .frame(width: 36, height: 36)
                Image(systemName: isShielded ? "shield.lefthalf.filled" : "arrow.up.right")
                    .font(.system(size: 14))
                    .foregroundStyle(isShielded ? themeManager.bgColor : themeManager.textSecondary)
            }

            // Content
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(isShielded ? "Auto-Shielded" : "Private Transfer")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(themeManager.textPrimary)
                    Spacer()
                    Text(isBalanceVisible ? "+\(note.value) STRK" : "••••••")
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundStyle(themeManager.textPrimary)
                        .fontWeight(.semibold)
                        .blur(radius: isBalanceVisible ? 0 : 5)
                        .animation(.easeInOut(duration: 0.3), value: isBalanceVisible)
                }
                HStack {
                    Text(note.memo.count > 20 ? String(note.memo.prefix(28)) + "…" : note.memo)
                        .font(.system(size: 12))
                        .foregroundStyle(themeManager.textSecondary)
                    Spacer()
                    Text("Just Now")
                        .font(.system(size: 12))
                        .foregroundStyle(themeManager.textSecondary)
                }
            }
        }
    }
}
