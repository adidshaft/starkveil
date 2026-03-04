import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

/// Phase 19: Zashi-style Receive screen.
/// Shows two addresses:
/// - S address: svk:<IVK_hex> for private receives (shielded)
/// - U address: 0x<account_address> for public receives (unshielded)
///
/// Privacy model: IVK is a public receive key — safe to share.
/// It cannot spend funds or link to past transactions.
struct ReceiveView: View {
    @EnvironmentObject private var themeManager: AppThemeManager
    @EnvironmentObject private var networkManager: NetworkManager
    @Environment(\.dismiss) private var dismiss

    @State private var showQR = false
    @State private var copiedShielded = false
    @State private var requestAmount = ""
    @State private var showRequestSheet = false

    private var ivkHex: String {
        if let seed = KeychainManager.masterSeed(),
           let keys = try? StarknetAccount.deriveAccountKeys(fromSeed: seed),
           let derivedIVK = try? StarkVeilProver.deriveIVK(spendingKeyHex: keys.privateKey.hexString) {
            return derivedIVK
        }
        return "unavailable"
    }
    /// Phase 19: S address with svk: prefix for auto-detection by senders
    private var svkAddress: String {
        "svk:\(ivkHex)"
    }
    private var shortSVK: String {
        guard ivkHex.count > 20 else { return svkAddress }
        return "svk:\(ivkHex.prefix(10))…\(ivkHex.suffix(8))"
    }
    /// Real Starknet account address from Keychain (not a stub)
    private var publicAddress: String {
        KeychainManager.accountAddress() ?? "Account not activated"
    }
    private var shortPublicAddress: String {
        guard publicAddress.count > 20 else { return publicAddress }
        return "\(publicAddress.prefix(10))…\(publicAddress.suffix(8))"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                themeManager.bgColor.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {

                        // ── Shielded address card (ZODL purple-style) ───────
                        shieldedCard

                        // ── QR Code (expanded when tapped) ──────────────────
                        if showQR {
                            qrCard
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        // ── Public address (less prominent, for reference) ────
                        publicAddressCard

                        // ── Privacy nudge footer ─────────────────────────────
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.shield.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(themeManager.textSecondary)
                            Text("For privacy, always use the shielded address.")
                                .font(.system(size: 12))
                                .foregroundStyle(themeManager.textSecondary)
                        }
                        .padding(.top, 8)

                        Spacer(minLength: 40)
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Receive STRK")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(themeManager.textPrimary)
                }
            }
        }
        .preferredColorScheme(themeManager.colorScheme)
        .sheet(isPresented: $showRequestSheet) {
            requestSheet
        }
    }

    // MARK: - Shielded card
    private var shieldedCard: some View {
        VStack(spacing: 16) {
            // Header row
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color(hex: "#6B3DE8").opacity(0.25))
                        .frame(width: 44, height: 44)
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 18))
                        .foregroundStyle(Color(hex: "#9B6DFF"))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Shielded Address (S)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(shortSVK)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
                Button(action: {}) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }

            // Action buttons row — mirroring ZODL
            HStack(spacing: 10) {
                actionButton(icon: "doc.on.doc.fill", label: "Copy") {
                    UIPasteboard.general.string = svkAddress
                    withAnimation { copiedShielded = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation { copiedShielded = false }
                    }
                }
                .overlay(
                    copiedShielded ?
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.green, lineWidth: 1.5) : nil
                )

                actionButton(icon: showQR ? "qrcode.viewfinder" : "qrcode", label: "QR Code") {
                    withAnimation(.easeInOut(duration: 0.3)) { showQR.toggle() }
                }

                actionButton(icon: "hand.raised.fill", label: "Request") {
                    showRequestSheet = true
                }
            }
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [Color(hex: "#4A1DB5"), Color(hex: "#6B3DE8")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func actionButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(.white.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    // MARK: - QR Card
    private var qrCard: some View {
        VStack(spacing: 10) {
            // Label above QR
            Label("Shielded Address — for private receives", systemImage: "shield.lefthalf.filled")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(hex: "#9B6DFF"))
                .frame(maxWidth: .infinity, alignment: .leading)

            if let qr = generateQR(from: svkAddress) {
                Image(uiImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 220, height: 220)
                    .padding(16)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            Text("Share this with anyone who wants to send you STRK privately.")
                .font(.system(size: 12))
                .foregroundStyle(themeManager.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(themeManager.surface1)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .stroke(Color(hex: "#6B3DE8").opacity(0.3), lineWidth: 1))
    }

    // MARK: - Public address card
    @State private var copiedPublic = false
    private var publicAddressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Public Address (U) — for exchanges & public sends", systemImage: "globe")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(themeManager.textSecondary)

            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(themeManager.surface2)
                        .frame(width: 40, height: 40)
                    Image(systemName: "person.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(themeManager.textSecondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(shortPublicAddress)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(themeManager.textPrimary)
                    Text("On-chain visible — use for deposits from exchanges")
                        .font(.system(size: 11))
                        .foregroundStyle(themeManager.textSecondary)
                }
                Spacer()
                Button(action: {
                    UIPasteboard.general.string = publicAddress
                    withAnimation { copiedPublic = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation { copiedPublic = false }
                    }
                }) {
                    Image(systemName: copiedPublic ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 15))
                        .foregroundStyle(copiedPublic ? .green : themeManager.textSecondary)
                }
            }
        }
        .padding(16)
        .background(themeManager.surface1)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(themeManager.surface2, lineWidth: 1))
    }

    // MARK: - Request sheet
    private var requestSheet: some View {
        NavigationStack {
            ZStack {
                themeManager.bgColor.ignoresSafeArea()
                VStack(spacing: 24) {
                    Text("Set a requested amount that will be pre-filled for the sender.")
                        .font(.system(size: 14))
                        .foregroundStyle(themeManager.textSecondary)
                        .multilineTextAlignment(.center)

                    HStack {
                        Text("STRK")
                            .foregroundStyle(themeManager.textSecondary)
                            .font(.system(size: 16))
                        TextField("Amount", text: $requestAmount)
                            .keyboardType(.decimalPad)
                            .foregroundStyle(themeManager.textPrimary)
                            .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    }
                    .padding(16)
                    .background(themeManager.surface1)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(themeManager.surface2, lineWidth: 1))

                    Button(action: {
                        let request = "starkveil://receive?svk=\(svkAddress)&amount=\(requestAmount)"
                        // L4: Add 2-minute expiry so other apps cannot read the amount indefinitely
                        UIPasteboard.general.setItems(
                            [[UIPasteboard.typeAutomatic: request]],
                            options: [.expirationDate: Date().addingTimeInterval(120)]
                        )
                        showRequestSheet = false
                    }) {
                        Text("Copy Payment Request Link")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(themeManager.bgColor)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(themeManager.textPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    Spacer()
                }
                .padding(24)
            }
            .navigationTitle("Request Payment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showRequestSheet = false }
                        .foregroundStyle(themeManager.textSecondary)
                }
            }
        }
        .preferredColorScheme(themeManager.colorScheme)
    }

    // MARK: - QR helper
    private func generateQR(from string: String) -> UIImage? {
        let ctx = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let out = filter.outputImage else { return nil }
        let scaled = out.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cg = ctx.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
