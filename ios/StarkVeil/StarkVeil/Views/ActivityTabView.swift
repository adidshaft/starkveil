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
                        .padding(.bottom, 14)
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

    @State private var showDetail = false

    // MARK: Kind helpers
    var iconName: String {
        switch event.kind {
        case .deposit:    return "shield.lefthalf.filled"
        case .transfer:   return "arrow.up.circle.fill"
        case .received:   return "arrow.down.circle.fill"
        case .unshield:   return "lock.open.fill"
        case .publicSend: return "arrow.up.right.circle.fill"
        }
    }

    var label: String {
        switch event.kind {
        case .deposit:    return "Shielded Deposit"
        case .transfer:   return "Private Send"
        case .received:   return "Private Receive"
        case .unshield:   return "Unshield"
        case .publicSend: return "Public Send"
        }
    }

    // + for incoming funds, − for outgoing
    var amountPrefix: String {
        event.isIncoming ? "+" : "−"
    }

    var amountColor: Color {
        if event.isIncoming {
            return AppTheme.accentGreen
        } else if event.kind == .unshield || event.kind == .publicSend {
            return Color(hex: "#FF9800")
        } else {
            return AppTheme.accentRed
        }
    }

    // MARK: Body
    var body: some View {
        Button(action: { showDetail = true }) {
            HStack(alignment: .center, spacing: 14) {
                // ── Icon badge ───────────────────────────────────────
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(iconBackground)
                        .frame(width: 44, height: 44)
                    Image(systemName: iconName)
                        .font(.system(size: 16, weight: .semibold))
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
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
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

                    // Compact tx hash badge
                    if let hash = event.txHash {
                        HStack(spacing: 4) {
                            Text(String(hash.prefix(14)) + "…")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(themeManager.textSecondary.opacity(0.5))
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 9))
                                .foregroundStyle(themeManager.textSecondary.opacity(0.4))
                        }
                        .padding(.top, 1)
                    }
                }

                // ── Chevron ──────────────────────────────────────────
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(themeManager.textSecondary.opacity(0.4))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(themeManager.surface1.opacity(0.85))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(AppTheme.glassStroke, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showDetail) {
            ActivityDetailSheet(event: event, isBalanceVisible: isBalanceVisible)
                .environmentObject(themeManager)
        }
    }

    // MARK: Icon colours
    private var iconBackground: Color {
        switch event.kind {
        case .deposit:    return AppTheme.accentGreen.opacity(0.15)
        case .received:   return AppTheme.accentGreen.opacity(0.15)
        case .transfer:   return AppTheme.accentRed.opacity(0.12)
        case .unshield:   return Color(hex: "#FF9800").opacity(0.15)
        case .publicSend: return Color(hex: "#FF9800").opacity(0.15)
        }
    }

    private var iconForeground: Color {
        switch event.kind {
        case .deposit:    return AppTheme.accentGreen
        case .received:   return AppTheme.accentGreen
        case .transfer:   return AppTheme.accentRed
        case .unshield:   return Color(hex: "#FF9800")
        case .publicSend: return Color(hex: "#FF9800")
        }
    }
}

// MARK: - Activity Detail Sheet

struct ActivityDetailSheet: View {
    @EnvironmentObject private var themeManager: AppThemeManager
    @Environment(\.dismiss) private var dismiss
    let event: ActivityEvent
    let isBalanceVisible: Bool

    private var explorerUrl: URL? {
        guard let hash = event.txHash else { return nil }
        return URL(string: "https://sepolia.voyager.online/tx/\(hash)")
    }

    private var fullTimestamp: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f.string(from: event.timestamp)
    }

    private var kindLabel: String {
        switch event.kind {
        case .deposit:    return "Shielded Deposit"
        case .transfer:   return "Private Send"
        case .received:   return "Private Receive"
        case .unshield:   return "Unshield"
        case .publicSend: return "Public Send"
        }
    }

    private var kindIconName: String {
        switch event.kind {
        case .deposit:    return "shield.lefthalf.filled"
        case .transfer:   return "arrow.up.circle.fill"
        case .received:   return "arrow.down.circle.fill"
        case .unshield:   return "lock.open.fill"
        case .publicSend: return "arrow.up.right.circle.fill"
        }
    }

    private var amountSign: String { event.isIncoming ? "+" : "−" }
    private var amountColor: Color {
        if event.isIncoming { return AppTheme.accentGreen }
        if event.kind == .unshield || event.kind == .publicSend { return Color(hex: "#FF9800") }
        return AppTheme.accentRed
    }

    private var privacyNote: String {
        switch event.kind {
        case .deposit:
            return "Deposit visible on-chain. All subsequent operations are private."
        case .transfer:
            return "All amounts, sender and recipient are hidden on-chain."
        case .received:
            return "All amounts, sender and recipient are hidden on-chain."
        case .unshield:
            return "Amount and recipient visible on-chain. Source note is hidden."
        case .publicSend:
            return "Amount and recipient visible on-chain."
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                themeManager.bgColor.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {

                        // ── Amount hero ──────────────────────────────
                        VStack(spacing: 6) {
                            Image(systemName: kindIconName)
                                .font(.system(size: 32))
                                .foregroundStyle(kindColor)

                            Text(kindLabel)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(themeManager.textSecondary)

                            Text(isBalanceVisible
                                 ? "\(amountSign)\(event.amount) STRK"
                                 : "•••••• STRK")
                                .font(.system(size: 30, weight: .bold, design: .monospaced))
                                .foregroundStyle(amountColor)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)

                        // ── Details card ─────────────────────────────
                        VStack(spacing: 0) {
                            detailRow(label: "Status", value: "Confirmed", valueColor: AppTheme.accentGreen)
                            Divider().background(themeManager.surface2)
                            detailRow(label: "Date", value: fullTimestamp)
                            Divider().background(themeManager.surface2)
                            if let fee = event.fee {
                                detailRow(label: "Network Fee", value: "\(fee) STRK")
                                Divider().background(themeManager.surface2)
                            }
                            if !event.counterparty.isEmpty && event.counterparty != "Shielded Deposit" {
                                detailRow(label: event.kind == .unshield ? "Recipient" : "Address",
                                          value: event.counterparty, monospaced: true, truncate: true)
                                Divider().background(themeManager.surface2)
                            }
                            if let hash = event.txHash {
                                detailRow(label: "Tx ID", value: hash, monospaced: true, truncate: true)
                            } else {
                                detailRow(label: "Tx ID", value: "Pending confirmation…",
                                          valueColor: themeManager.textSecondary)
                            }
                        }
                        .background(themeManager.surface1)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(AppTheme.glassStroke, lineWidth: 1))

                        // ── Privacy note ─────────────────────────────
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.shield.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(themeManager.textSecondary)
                            Text(privacyNote)
                                .font(.system(size: 12))
                                .foregroundStyle(themeManager.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12)
                        .background(themeManager.surface1)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                        // ── Explorer button ───────────────────────────
                        if let url = explorerUrl {
                            Link(destination: url) {
                                HStack(spacing: 8) {
                                    Image(systemName: "arrow.up.right.square")
                                    Text("View on Voyager Explorer")
                                        .font(.system(size: 15, weight: .semibold))
                                }
                                .foregroundStyle(themeManager.bgColor)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(themeManager.textPrimary)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                        }

                        Spacer(minLength: 40)
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Transaction Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(themeManager.textPrimary)
                }
            }
        }
        .preferredColorScheme(themeManager.colorScheme)
    }

    private var kindColor: Color {
        switch event.kind {
        case .deposit:    return AppTheme.accentGreen
        case .received:   return AppTheme.accentGreen
        case .transfer:   return AppTheme.accentRed
        case .unshield:   return Color(hex: "#FF9800")
        case .publicSend: return Color(hex: "#FF9800")
        }
    }

    @ViewBuilder
    private func detailRow(label: String, value: String,
                            valueColor: Color? = nil,
                            monospaced: Bool = false,
                            truncate: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(themeManager.textSecondary)
                .frame(width: 100, alignment: .leading)
            Spacer()
            Text(truncate && value.count > 20
                 ? "\(value.prefix(12))…\(value.suffix(8))"
                 : value)
                .font(monospaced
                      ? .system(size: 13, design: .monospaced)
                      : .system(size: 13))
                .foregroundStyle(valueColor ?? themeManager.textPrimary)
                .multilineTextAlignment(.trailing)
                .lineLimit(truncate ? 1 : 3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
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
