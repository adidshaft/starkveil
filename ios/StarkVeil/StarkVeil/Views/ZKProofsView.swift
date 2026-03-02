import SwiftUI

/// ZK Proofs tab — shows the user their own local proof history.
/// SECURITY: Only public data is surfaced (tx hashes, timestamps, operation type).
/// No private keys, seeds, notes, or IVK values are displayed here.
struct ZKProofsView: View {
    @EnvironmentObject private var themeManager: AppThemeManager
    @EnvironmentObject private var walletManager: WalletManager

    @State private var showCircuitInfo = false
    @State private var copiedHash: String? = nil
    @State private var showExportSheet = false
    @State private var exportItems: [Any] = []

    var body: some View {
        ZStack {
            themeManager.bgColor.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {

                    // ── Header ───────────────────────────────────────────
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("ZK Proof Log")
                                .font(.system(size: 26, weight: .bold))
                                .foregroundStyle(themeManager.textPrimary)
                            Text("\(walletManager.activityEvents.count) proofs generated")
                                .font(.system(size: 13))
                                .foregroundStyle(themeManager.textSecondary)
                        }
                        Spacer()
                        if !walletManager.activityEvents.isEmpty {
                            Button(action: prepareExport) {
                                HStack(spacing: 5) {
                                    Image(systemName: "square.and.arrow.up")
                                        .font(.system(size: 13))
                                    Text("Export")
                                        .font(.system(size: 13, weight: .medium))
                                }
                                .foregroundStyle(themeManager.textPrimary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(themeManager.surface2)
                                .clipShape(Capsule())
                            }
                        }
                    }

                    // ── Cairo Circuit Info card ──────────────────────────
                    circuitInfoCard

                    // ── Proof entries ─────────────────────────────────────
                    if walletManager.activityEvents.isEmpty {
                        emptyState
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(walletManager.activityEvents.reversed()) { event in
                                proofRow(event: event)
                            }
                        }
                    }

                    Spacer(minLength: 80)
                }
                .padding(20)
            }
        }
        .sheet(isPresented: $showExportSheet) {
            ActivityViewController(activityItems: exportItems)
        }
    }

    // MARK: - Circuit info card
    private var circuitInfoCard: some View {
        VStack(spacing: 0) {
            Button(action: { withAnimation(.easeInOut(duration: 0.25)) { showCircuitInfo.toggle() } }) {
                HStack {
                    Image(systemName: "cpu.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(themeManager.textPrimary)
                    Text("Cairo Circuit Details")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(themeManager.textPrimary)
                    Spacer()
                    Image(systemName: showCircuitInfo ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12))
                        .foregroundStyle(themeManager.textSecondary)
                }
                .padding(14)
            }

            if showCircuitInfo {
                Divider().background(themeManager.surface2)
                VStack(alignment: .leading, spacing: 8) {
                    circuitRow("Proving System", "S-Two STARK")
                    circuitRow("Language",       "Cairo 1.x")
                    circuitRow("Hash Function",  "Poseidon")
                    circuitRow("Commitment",     "Merkle Tree (depth 32)")
                    circuitRow("Verifier",       "On-chain Cairo verifier")
                    circuitRow("Proof Location", "Generated locally, never uploaded")
                }
                .padding(14)
            }
        }
        .background(themeManager.surface1)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(themeManager.surface2, lineWidth: 1))
    }

    private func circuitRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key)
                .font(.system(size: 12))
                .foregroundStyle(themeManager.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(themeManager.textPrimary)
        }
    }

    // MARK: - Proof row
    private func proofRow(event: ActivityEvent) -> some View {
        HStack(spacing: 14) {
            // Icon
            ZStack {
                Circle()
                    .fill(proofIconBackground(event.kind))
                    .frame(width: 40, height: 40)
                Image(systemName: proofIcon(event.kind))
                    .font(.system(size: 14))
                    .foregroundStyle(proofIconForeground(event.kind))
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(proofLabel(event.kind))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(themeManager.textPrimary)
                    Spacer()
                    // Status badge
                    Text(badgeLabel(for: event))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(badgeColor(for: event))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(badgeColor(for: event).opacity(0.12))
                        .clipShape(Capsule())
                }

                if let hash = event.txHash {
                    Button(action: { copyHash(hash) }) {
                        HStack(spacing: 4) {
                            Text(String(hash.prefix(16)) + "…")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(themeManager.textSecondary)
                            Image(systemName: copiedHash == hash ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 9))
                                .foregroundStyle(themeManager.textSecondary)
                        }
                    }
                } else {
                    Text("Awaiting on-chain confirmation")
                        .font(.system(size: 11))
                        .foregroundStyle(themeManager.textSecondary.opacity(0.6))
                }

                Text(event.timestamp.relativeFormatted)
                    .font(.system(size: 11))
                    .foregroundStyle(themeManager.textSecondary.opacity(0.5))
            }
        }
        .padding(14)
        .background(themeManager.surface1)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(themeManager.surface2, lineWidth: 1))
    }

    // MARK: - Empty state
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 36))
                .foregroundStyle(themeManager.textSecondary)
            Text("No proofs generated yet.")
                .font(.system(size: 14))
                .foregroundStyle(themeManager.textSecondary)
            Text("Shield, transfer or unshield funds to generate your first STARK proof.")
                .font(.system(size: 12))
                .foregroundStyle(themeManager.textSecondary.opacity(0.6))
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 40)
    }

    // MARK: - Helpers
    private func proofIcon(_ kind: ActivityKind) -> String {
        switch kind {
        case .deposit:  return "arrow.down.shield.fill"
        case .transfer: return "arrow.left.arrow.right"
        case .unshield: return "lock.open.fill"
        }
    }
    private func proofLabel(_ kind: ActivityKind) -> String {
        switch kind {
        case .deposit:  return "Shield Deposit"
        case .transfer: return "Private Transfer"
        case .unshield: return "Unshield"
        }
    }
    private func proofIconBackground(_ kind: ActivityKind) -> Color {
        switch kind {
        case .deposit:  return Color(hex: "#4CAF50").opacity(0.15)
        case .transfer: return themeManager.textPrimary.opacity(0.08)
        case .unshield: return Color(hex: "#FF9800").opacity(0.15)
        }
    }
    private func proofIconForeground(_ kind: ActivityKind) -> Color {
        switch kind {
        case .deposit:  return Color(hex: "#4CAF50")
        case .transfer: return themeManager.textPrimary
        case .unshield: return Color(hex: "#FF9800")
        }
    }

    /// L3 fix: Private transfers are local STARK proofs — they never get a sequencer txHash.
    /// Calling them "VERIFIED ✓" is misleading. Only on-chain events (deposit, unshield) can
    /// be VERIFIED when a real txHash exists.
    private func badgeLabel(for event: ActivityEvent) -> String {
        switch event.kind {
        case .transfer:
            return "PROVED (local)"
        default:
            return event.txHash != nil ? "VERIFIED ✓" : "PENDING"
        }
    }
    private func badgeColor(for event: ActivityEvent) -> Color {
        switch event.kind {
        case .transfer:
            return Color(hex: "#6B3DE8") // Purple — private proof
        default:
            return event.txHash != nil ? Color.green : Color.orange
        }
    }

    private func copyHash(_ hash: String) {
        UIPasteboard.general.string = hash
        withAnimation { copiedHash = hash }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { copiedHash = nil }
        }
    }

    private func prepareExport() {
        let records = walletManager.activityEvents.map { event -> [String: String] in
            [
                "type":        event.kind.rawValue,
                "amount":      event.amount,
                "asset":       event.assetId,
                "tx_hash":     event.txHash ?? "pending",
                "timestamp":   ISO8601DateFormatter().string(from: event.timestamp)
                // NOTE: No private keys, seeds, note values, or IVK included in export.
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: records, options: .prettyPrinted),
           let json = String(data: data, encoding: .utf8) {
            exportItems = [json]
            showExportSheet = true
        }
    }
}

// MARK: - UIActivityViewController wrapper
private struct ActivityViewController: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Date helper (shared with ActivityTabView but defined privately here)
private extension Date {
    var relativeFormatted: String {
        let diff = Date().timeIntervalSince(self)
        switch diff {
        case ..<60:      return "Just now"
        case ..<3600:    return "\(Int(diff / 60))m ago"
        case ..<86400:   return "\(Int(diff / 3600))h ago"
        case ..<604800:  return "\(Int(diff / 86400))d ago"
        default:
            let f = DateFormatter(); f.dateStyle = .short
            return f.string(from: self)
        }
    }
}
