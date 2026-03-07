import SwiftUI

// MARK: - Prover Activity Tab

struct ProverActivityView: View {
    @EnvironmentObject private var themeManager: AppThemeManager
    @EnvironmentObject private var walletManager: WalletManager

    private var visibleEvents: [ProverEvent] {
        walletManager.proverEvents.filter { $0.kind != .shield }
    }

    var body: some View {
        if visibleEvents.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "cpu")
                    .font(.system(size: 36))
                    .foregroundStyle(themeManager.textSecondary)
                Text("No proofs generated yet.")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(themeManager.textSecondary)
                Text("Send or unshield funds to trigger the Stwo prover.")
                    .font(.system(size: 12))
                    .foregroundStyle(themeManager.textSecondary.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
            .padding(.vertical, 40)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(visibleEvents) { event in
                    ProverEventRowView(event: event)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 14)
                }
            }
        }
    }
}

// MARK: - Prover Event Row

struct ProverEventRowView: View {
    @EnvironmentObject private var themeManager: AppThemeManager
    let event: ProverEvent

    @State private var showDetail = false

    var iconName: String {
        switch event.kind {
        case .shield: return "arrow.down.to.line.compact"
        case .transfer: return "lock.shield.fill"
        case .unshield: return "lock.open.fill"
        }
    }

    var label: String {
        switch event.kind {
        case .shield: return "Shield Proof"
        case .transfer: return "Private Transfer Proof"
        case .unshield: return "Unshield Proof"
        }
    }

    var accentColor: Color {
        switch event.kind {
        case .shield: return Color(hex: "#10B981")     // green — depositing
        case .transfer: return Color(hex: "#A855F7")   // purple — STARK privacy
        case .unshield: return Color(hex: "#FF9800")   // amber  — withdrawing
        }
    }

    var body: some View {
        Button(action: { showDetail = true }) {
            HStack(alignment: .center, spacing: 14) {
                // ── Icon badge ─────────────────────────────────────────
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(accentColor.opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: iconName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(accentColor)
                }

                // ── Text ──────────────────────────────────────────────
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(label)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(themeManager.textPrimary)
                        Spacer()
                        Text(String(format: "%.0f ms", event.durationMs))
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(accentColor)
                    }
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(event.proofElementCount) elements")
                            .font(.system(size: 12))
                            .foregroundStyle(themeManager.textSecondary)
                        Spacer()
                        Text(event.timestamp.proverRelativeFormatted)
                            .font(.system(size: 11))
                            .foregroundStyle(themeManager.textSecondary.opacity(0.7))
                    }
                    // Commitment badge
                    Text(String(event.noteCommitment.prefix(14)) + "…")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(themeManager.textSecondary.opacity(0.5))
                        .padding(.top, 1)
                }

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
            ProverEventDetailSheet(event: event)
                .environmentObject(themeManager)
        }
    }
}

// MARK: - Prover Detail Sheet

struct ProverEventDetailSheet: View {
    @EnvironmentObject private var themeManager: AppThemeManager
    @Environment(\.dismiss) private var dismiss
    let event: ProverEvent

    private var kindLabel: String {
        switch event.kind {
        case .shield: return "Shield Proof"
        case .transfer: return "Private Transfer Proof"
        case .unshield: return "Unshield Proof"
        }
    }

    private var kindIcon: String {
        switch event.kind {
        case .shield: return "arrow.down.to.line.compact"
        case .transfer: return "lock.shield.fill"
        case .unshield: return "lock.open.fill"
        }
    }

    private var accentColor: Color {
        switch event.kind {
        case .shield: return Color(hex: "#10B981")
        case .transfer: return Color(hex: "#A855F7")
        case .unshield: return Color(hex: "#FF9800")
        }
    }

    private var fullTimestamp: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f.string(from: event.timestamp)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                themeManager.bgColor.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        // ── Hero ─────────────────────────────────────
                        VStack(spacing: 8) {
                            Image(systemName: kindIcon)
                                .font(.system(size: 36))
                                .foregroundStyle(accentColor)
                            Text(kindLabel)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(themeManager.textSecondary)
                            Text(String(format: "%.0f ms  ·  %d elements", event.durationMs, event.proofElementCount))
                                .font(.system(size: 22, weight: .bold, design: .monospaced))
                                .foregroundStyle(accentColor)
                            Text("Proved natively on-device via Stwo Circle STARK")
                                .font(.system(size: 12))
                                .foregroundStyle(themeManager.textSecondary.opacity(0.7))
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)

                        // ── Details card ─────────────────────────────
                        VStack(spacing: 0) {
                            detailRow(label: "Algorithm", value: "Poseidon-based Circle STARK")
                            Divider().background(themeManager.surface2)
                            detailRow(label: "Date", value: fullTimestamp)
                            Divider().background(themeManager.surface2)
                            detailRow(label: "Proof Size", value: "\(event.proofElementCount) felt252 elements")
                            Divider().background(themeManager.surface2)
                            detailRow(label: "Duration", value: String(format: "%.1f ms", event.durationMs))
                            Divider().background(themeManager.surface2)
                            detailRow(label: "Commitment", value: event.noteCommitment, monospaced: true, truncate: true)
                            Divider().background(themeManager.surface2)
                            detailRow(label: "Nullifier", value: event.nullifier, monospaced: true, truncate: true)
                            Divider().background(themeManager.surface2)
                            detailRow(label: "Merkle Root", value: event.historicRoot, monospaced: true, truncate: true)
                            if let hash = event.txHash {
                                Divider().background(themeManager.surface2)
                                detailRow(label: "Tx Hash", value: hash, monospaced: true, truncate: true)
                            }
                        }
                        .background(themeManager.surface1)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(AppTheme.glassStroke, lineWidth: 1))

                        // ── Privacy note ─────────────────────────────
                        HStack(spacing: 8) {
                            Image(systemName: "cpu")
                                .font(.system(size: 13))
                                .foregroundStyle(themeManager.textSecondary)
                            Text("This proof was generated entirely on your device. No private data left the device during synthesis.")
                                .font(.system(size: 12))
                                .foregroundStyle(themeManager.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12)
                        .background(themeManager.surface1)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                        Spacer(minLength: 40)
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Proof Details")
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

    @ViewBuilder
    private func detailRow(label: String, value: String,
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
                .font(monospaced ? .system(size: 13, design: .monospaced) : .system(size: 13))
                .foregroundStyle(themeManager.textPrimary)
                .multilineTextAlignment(.trailing)
                .lineLimit(truncate ? 1 : 3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

// MARK: - Date Helper

private extension Date {
    var proverRelativeFormatted: String {
        let diff = Date().timeIntervalSince(self)
        switch diff {
        case ..<60:      return "Just now"
        case ..<3600:    return "\(Int(diff / 60))m ago"
        case ..<86400:   return "\(Int(diff / 3600))h ago"
        default:
            let f = DateFormatter(); f.dateStyle = .short
            return f.string(from: self)
        }
    }
}
