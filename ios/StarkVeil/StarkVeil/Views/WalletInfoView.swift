import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

/// Shown when the user taps the top-left avatar circle.
/// Displays the shielded address (IVK) + QR code so others can send funds privately.
/// SECURITY: Only the IVK (a public receive key) is shown — no spending key, seed, or mnemonic.
struct WalletInfoView: View {
    @EnvironmentObject private var themeManager: AppThemeManager
    @EnvironmentObject private var networkManager: NetworkManager
    @EnvironmentObject private var syncEngine: SyncEngine
    @Environment(\.dismiss) private var dismiss

    @State private var copied = false

    // IVK is the public-facing viewing key — safe to share (receive-only).
    private var ivkHex: String {
        guard let ivkData = KeychainManager.ownerIVK() else { return "Not available" }
        return "0x" + ivkData.map { String(format: "%02x", $0) }.joined()
    }

    private var shortIVK: String {
        let full = ivkHex
        guard full.count > 20 else { return full }
        let start = full.prefix(10)
        let end   = full.suffix(8)
        return "\(start)…\(end)"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {

                    // ── Avatar ─────────────────────────────────────────────
                    ZStack {
                        Circle()
                            .fill(LinearGradient(
                                colors: [themeManager.surface2, themeManager.surface1],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 80, height: 80)
                            .overlay(Circle().stroke(themeManager.surface2, lineWidth: 1.5))
                        Image(systemName: "person.fill.viewfinder")
                            .font(.system(size: 34))
                            .foregroundStyle(themeManager.textSecondary)
                    }

                    VStack(spacing: 4) {
                        Text("anon.stark")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(themeManager.textPrimary)
                        HStack(spacing: 6) {
                            Circle()
                                .fill(syncEngine.isSyncing ? Color.green : Color(hex: "#8A8885"))
                                .frame(width: 7, height: 7)
                            Text(networkManager.activeNetwork.rawValue)
                                .font(.system(size: 13))
                                .foregroundStyle(themeManager.textSecondary)
                        }
                    }

                    // ── QR Code ────────────────────────────────────────────
                    if let qr = generateQR(from: ivkHex) {
                        Image(uiImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 200, height: 200)
                            .padding(12)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(themeManager.surface2, lineWidth: 1))
                    }

                    // ── IVK address ────────────────────────────────────────
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Shielded Receive Address (IVK)")
                            .font(.system(size: 12))
                            .foregroundStyle(themeManager.textSecondary)
                        HStack {
                            Text(shortIVK)
                                .font(.system(size: 14, design: .monospaced))
                                .foregroundStyle(themeManager.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            Button(action: copyIVK) {
                                HStack(spacing: 4) {
                                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                        .font(.system(size: 12))
                                    Text(copied ? "Copied!" : "Copy")
                                        .font(.system(size: 13, weight: .medium))
                                }
                                .foregroundStyle(themeManager.textPrimary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(themeManager.surface2)
                                .clipShape(Capsule())
                            }
                        }
                        .padding(14)
                        .background(themeManager.surface1)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(themeManager.surface2, lineWidth: 1))
                    }

                    // ── Privacy note ───────────────────────────────────────
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "lock.shield.fill")
                            .foregroundStyle(themeManager.textSecondary)
                            .font(.system(size: 14))
                        Text("This is your public IVK (incoming viewing key). Sharing it lets others send shielded funds to you. It cannot be used to spend funds or identify past transactions.")
                            .font(.system(size: 12))
                            .foregroundStyle(themeManager.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .background(themeManager.surface1.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .padding(24)
            }
            .background(themeManager.bgColor.ignoresSafeArea())
            .navigationTitle("Wallet Info")
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

    private func copyIVK() {
        UIPasteboard.general.string = ivkHex
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { copied = false }
        }
    }

    private func generateQR(from string: String) -> UIImage? {
        let context = CIContext()
        let filter  = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
