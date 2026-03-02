import SwiftUI

// MARK: - Activity Tab

struct ActivityTabView: View {
    @EnvironmentObject private var themeManager: AppThemeManager
    @EnvironmentObject private var walletManager: WalletManager
    var isBalanceVisible: Bool

    var body: some View {
        if walletManager.activityEvents.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 36))
                    .foregroundStyle(themeManager.textSecondary)
                Text("No shielded activity yet.")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(themeManager.textSecondary)
                Text("Deposit funds to get started.")
                    .font(.system(size: 12))
                    .foregroundStyle(themeManager.textSecondary.opacity(0.6))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(walletManager.activityEvents) { event in
                    ActivityRowView(event: event, isBalanceVisible: isBalanceVisible)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 24)
                }
            }
        }
    }
}

// MARK: - Activity Row

struct ActivityRowView: View {
    @EnvironmentObject private var themeManager: AppThemeManager
    let event: ActivityEvent
    let isBalanceVisible: Bool

    // MARK: Kind helpers
    var iconName: String {
        switch event.kind {
        case .deposit:   return "arrow.down.shield.fill"
        case .transfer:  return "arrow.left.arrow.right"
        case .unshield:  return "lock.open.fill"
        }
    }

    var label: String {
        switch event.kind {
        case .deposit:   return "Shielded Deposit"
        case .transfer:  return "Private Transfer"
        case .unshield:  return "Unshield"
        }
    }

    // Deposits add value; transfers and unshields are outbound
    var amountPrefix: String { event.kind == .deposit ? "+" : "−" }
    var amountColor: Color { event.kind == .deposit ? Color(hex: "#4CAF50") : themeManager.textPrimary }

    // MARK: Body
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            // ── Icon badge ───────────────────────────────────────
            ZStack {
                Circle()
                    .fill(iconBackground)
                    .frame(width: 40, height: 40)
                Image(systemName: iconName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(iconForeground)
            }

            // ── Text content ─────────────────────────────────────
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(label)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(themeManager.textPrimary)
                    Spacer()
                    Text(isBalanceVisible ? "\(amountPrefix)\(event.amount) STRK" : "••••••")
                        .font(.system(size: 14, design: .monospaced, weight: .semibold))
                        .foregroundStyle(amountColor)
                        .blur(radius: isBalanceVisible ? 0 : 5)
                        .animation(.easeInOut(duration: 0.3), value: isBalanceVisible)
                }

                HStack(alignment: .firstTextBaseline) {
                    Text(event.counterparty)
                        .font(.system(size: 12))
                        .foregroundStyle(themeManager.textSecondary)
                        .lineLimit(1)
                    Spacer()
                    Text(event.timestamp.relativeFormatted)
                        .font(.system(size: 11))
                        .foregroundStyle(themeManager.textSecondary.opacity(0.7))
                }

                // Show tx hash badge if present
                if let hash = event.txHash {
                    Text(String(hash.prefix(16)) + "…")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(themeManager.textSecondary.opacity(0.5))
                        .padding(.top, 1)
                }
            }
        }
    }

    // MARK: Icon colours
    private var iconBackground: Color {
        switch event.kind {
        case .deposit:  return Color(hex: "#4CAF50").opacity(0.15)
        case .transfer: return themeManager.textPrimary.opacity(0.08)
        case .unshield: return Color(hex: "#FF9800").opacity(0.15)
        }
    }

    private var iconForeground: Color {
        switch event.kind {
        case .deposit:  return Color(hex: "#4CAF50")
        case .transfer: return themeManager.textPrimary
        case .unshield: return Color(hex: "#FF9800")
        }
    }
}

// MARK: - Date Helpers

private extension Date {
    var relativeFormatted: String {
        let diff = Date().timeIntervalSince(self)
        switch diff {
        case ..<60:           return "Just now"
        case ..<3600:         return "\(Int(diff / 60))m ago"
        case ..<86400:        return "\(Int(diff / 3600))h ago"
        case ..<604800:       return "\(Int(diff / 86400))d ago"
        default:
            let f = DateFormatter()
            f.dateStyle = .short
            return f.string(from: self)
        }
    }
}

// MARK: - Color(hex:) helper (if not already in codebase)

private extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: h).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8)  & 0xFF) / 255
        let b = Double( int        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
