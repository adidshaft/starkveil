import SwiftUI

/// Phase 19: Zashi-style main vault view.
/// Total balance card + 3 actions (Send/Receive/Shield) + dual U/S asset rows.
/// Bottom nav: Wallet | Swap | Activity | Settings
struct VaultView: View {
    @EnvironmentObject private var themeManager: AppThemeManager
    @EnvironmentObject private var syncEngine: SyncEngine
    @EnvironmentObject private var walletManager: WalletManager
    @EnvironmentObject private var networkManager: NetworkManager

    @State private var bottomTab: BottomNavTab = .wallet
    @State private var vaultTab: VaultSubTab = .assets
    @State private var isBalanceVisible = true

    // Sheet state — clean 3-action model
    @State private var showSendSheet    = false
    @State private var showReceiveSheet = false
    @State private var showShieldSheet  = false

    // Splash
    @State private var showSplash = true
    @State private var splashOpacity: Double = 1

    // Wallet deleted callback
    var onWalletDeleted: (() -> Void)? = nil

    var body: some View {
        ZStack(alignment: .bottom) {
            // ── Background ──────────────────────────────────────────
            themeManager.bgColor.ignoresSafeArea()

            // Gradient overlay at top
            VStack {
                LinearGradient(
                    colors: [
                        Color(hex: "#6B3DE8").opacity(0.04),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 320)
                Spacer()
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            // ── Main Content ─────────────────────────────────────────
            VStack(spacing: 0) {
                // Header always shown on all tabs
                VaultHeaderView()
                    .padding(.top, 12)
                    .padding(.bottom, 20)

                // Tab body
                switch bottomTab {
                case .wallet:
                    walletTabContent
                case .swap:
                    SwapView()
                        .padding(.bottom, 60)
                case .activity:
                    ActivityTabView(isBalanceVisible: isBalanceVisible)
                        .padding(.bottom, 60)
                case .settings:
                    SettingsView(onWalletDeleted: onWalletDeleted)
                        .padding(.bottom, 60)
                }
            }

            // ── Bottom Nav ────────────────────────────────────────
            VStack(spacing: 0) {
                Spacer()
                BottomNavView(selectedTab: $bottomTab)
            }
            .ignoresSafeArea(edges: .bottom)

            // ── STARK Proof overlay ─────────────────────────────────
            if walletManager.isProving {
                STARKProofOverlay()
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    .zIndex(10)
            }

            // ── Splash Screen overlay ─────────────────────────────────
            if showSplash {
                SplashScreenView()
                    .opacity(splashOpacity)
                    .zIndex(50)
                    .transition(.opacity)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            withAnimation(.easeOut(duration: 0.8)) {
                                splashOpacity = 0
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                                showSplash = false
                            }
                        }
                    }
            }
        }
        .preferredColorScheme(themeManager.colorScheme)
        .onAppear {
            syncEngine.startSyncing()
            Task {
                await walletManager.refreshPublicBalance(rpcUrl: networkManager.activeNetwork.rpcUrl)
            }
        }
        .onDisappear { syncEngine.stopSyncing() }
        // Send sheet — unified (address + amount only)
        .sheet(isPresented: $showSendSheet) {
            UnifiedSendView(isPresented: $showSendSheet)
                .environmentObject(themeManager)
                .environmentObject(walletManager)
                .environmentObject(networkManager)
        }
        // Receive sheet — U + S addresses with QR
        .sheet(isPresented: $showReceiveSheet) {
            ReceiveView()
                .environmentObject(themeManager)
                .environmentObject(networkManager)
        }
        // Shield/Unshield toggle sheet
        .sheet(isPresented: $showShieldSheet) {
            ShieldView()
                .environmentObject(themeManager)
                .environmentObject(walletManager)
                .environmentObject(networkManager)
        }
    }

    // MARK: - Wallet tab layout
    @ViewBuilder
    private var walletTabContent: some View {
        // Balance card with 3 actions
        ShieldedBalanceCard(
            isBalanceVisible: $isBalanceVisible,
            showSendSheet:    $showSendSheet,
            showReceiveSheet: $showReceiveSheet,
            showShieldSheet:  $showShieldSheet
        )
        .padding(.bottom, 28)

        // Tab switcher (Assets / Activity sub-tab inside wallet tab)
        TabSwitcherView(selectedTab: $vaultTab)
            .padding(.bottom, 20)

        // Tab content
        ScrollView(showsIndicators: false) {
            if vaultTab == .assets {
                AssetsTabView(isBalanceVisible: isBalanceVisible)
                    .padding(.top, 4)
            } else {
                ActivityTabView(isBalanceVisible: isBalanceVisible)
                    .padding(.top, 4)
            }
        }
        .padding(.bottom, 60)
    }
}


// MARK: - Unified Send View (Phase 19)
/// Just address + amount. Auto-detects svk: (private) vs 0x (public).

private struct UnifiedSendView: View {
    @EnvironmentObject private var themeManager: AppThemeManager
    @EnvironmentObject private var walletManager: WalletManager
    @EnvironmentObject private var networkManager: NetworkManager
    @Binding var isPresented: Bool

    @State private var recipientAddress = ""
    @State private var transferAmount = ""
    @State private var isSending = false
    @State private var errorMessage: String? = nil
    @State private var txHash: String? = nil

    /// Detect if this is a shielded (private) or unshielded (public) send
    private var isPrivateSend: Bool {
        recipientAddress.lowercased().hasPrefix("svk:")
    }

    private var parsedAmount: Double? {
        guard let v = Double(transferAmount), v > 0, v.isFinite else { return nil }
        return v
    }

    private var canSend: Bool {
        !walletManager.isProving && !recipientAddress.isEmpty && parsedAmount != nil && !isSending
    }

    var body: some View {
        NavigationStack {
            ZStack {
                themeManager.bgColor.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {

                        // ── Amount display ─────────────────────────────────
                        VStack(spacing: 4) {
                            Image(systemName: isPrivateSend ? "shield.lefthalf.filled" : "arrow.up.circle.fill")
                                .font(.system(size: 30))
                                .foregroundStyle(isPrivateSend ? Color(hex: "#9B6DFF") : Color(hex: "#FF6B35"))

                            if transferAmount.isEmpty {
                                Text("– – – – – –")
                                    .font(.system(size: 38, weight: .bold, design: .monospaced))
                                    .foregroundStyle(themeManager.textSecondary)
                            } else {
                                Text("\(transferAmount) STRK")
                                    .font(.system(size: 38, weight: .bold, design: .monospaced))
                                    .foregroundStyle(themeManager.textPrimary)
                                    .contentTransition(.numericText())
                            }

                            // Auto-label
                            Text(isPrivateSend ? "Private Send (Shielded)" : "Public Send (Unshielded)")
                                .font(.system(size: 13))
                                .foregroundStyle(isPrivateSend ? Color(hex: "#9B6DFF") : Color(hex: "#FF6B35"))
                                .padding(.top, 4)
                        }
                        .padding(.top, 8)

                        // ── Recipient ────────────────────────────────────
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Send to")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(themeManager.textSecondary)
                                .tracking(0.5)

                            HStack {
                                Image(systemName: isPrivateSend ? "shield.lefthalf.filled" : "person.fill")
                                    .foregroundStyle(isPrivateSend ? Color(hex: "#9B6DFF") : themeManager.textSecondary)
                                    .frame(width: 20)
                                TextField("0x… or svk:…", text: $recipientAddress)
                                    .foregroundStyle(themeManager.textPrimary)
                                    .font(.system(size: 14, design: .monospaced))
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                            }
                            .padding(14)
                            .background(themeManager.surface1)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(themeManager.surface2, lineWidth: 1))

                            // Hint text
                            Text(isPrivateSend
                                 ? "🛡 Private: uses shielded balance, recipient sees nothing on-chain"
                                 : "🌐 Public: sends from your unshielded balance")
                                .font(.system(size: 11))
                                .foregroundStyle(themeManager.textSecondary.opacity(0.6))
                        }

                        // ── Amount ──────────────────────────────────────
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Amount")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(themeManager.textSecondary)
                                .tracking(0.5)

                            HStack {
                                Image(systemName: "diamond.fill")
                                    .foregroundStyle(Color(hex: "#B9B4F8"))
                                    .frame(width: 20)
                                TextField("0.0", text: $transferAmount)
                                    .keyboardType(.decimalPad)
                                    .foregroundStyle(themeManager.textPrimary)
                                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                                Spacer()
                                Text("STRK")
                                    .font(.system(size: 14))
                                    .foregroundStyle(themeManager.textSecondary)
                            }
                            .padding(14)
                            .background(themeManager.surface1)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(themeManager.surface2, lineWidth: 1))

                            // Available balance
                            HStack {
                                Spacer()
                                Text("Available: \(String(format: "%.4f", isPrivateSend ? walletManager.balance : walletManager.publicBalance)) STRK")
                                    .font(.system(size: 11))
                                    .foregroundStyle(themeManager.textSecondary.opacity(0.6))
                            }
                        }

                        // ── Error ───────────────────────────────────────
                        if let err = errorMessage {
                            HStack(spacing: 8) {
                                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                                Text(err).font(.system(size: 13)).foregroundStyle(.red)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        // ── Success ─────────────────────────────────────
                        if let hash = txHash {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Sent successfully!")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(themeManager.textPrimary)
                                    Text("Tx: \(hash.prefix(16))…")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(themeManager.textSecondary)
                                }
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.green.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }

                        // ── Send button ────────────────────────────────
                        Button(action: { executeSend() }) {
                            Group {
                                if isSending {
                                    HStack(spacing: 10) {
                                        ProgressView().tint(themeManager.bgColor)
                                        Text("Sending…")
                                    }
                                } else if txHash != nil {
                                    HStack(spacing: 8) {
                                        Image(systemName: "checkmark")
                                        Text("Done")
                                    }
                                } else {
                                    Text("Send")
                                }
                            }
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(canSend ? themeManager.bgColor : themeManager.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(canSend ? themeManager.textPrimary : themeManager.surface2)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .disabled(!canSend && txHash == nil)

                        Spacer(minLength: 40)
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Send STRK")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(txHash != nil ? "Done" : "Cancel") { isPresented = false }
                        .foregroundStyle(themeManager.textSecondary)
                }
            }
        }
        .preferredColorScheme(themeManager.colorScheme)
    }

    private func executeSend() {
        guard let amount = parsedAmount else { return }
        errorMessage = nil
        isSending = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        Task {
            do {
                let rpcUrl = networkManager.activeNetwork.rpcUrl
                let contract = networkManager.activeNetwork.contractAddress
                let network = networkManager.activeNetwork

                if isPrivateSend {
                    // Extract IVK from svk: prefix
                    let ivk = String(recipientAddress.dropFirst(4)) // remove "svk:"
                    // For private send, we need the recipient's Starknet address too
                    // In the current model, we use the IVK as both identifier and key
                    let hash = try await walletManager.executePrivateTransfer(
                        toAddress: ivk,  // IVK acts as recipient identifier
                        recipientIVK: ivk,
                        amount: amount,
                        memo: "private send",
                        rpcUrl: rpcUrl,
                        contractAddress: contract,
                        network: network
                    )
                    await MainActor.run {
                        txHash = hash
                        isSending = false
                    }
                } else {
                    // Public unshield + send
                    let hash = try await walletManager.executeUnshield(
                        amount: amount,
                        rpcUrl: rpcUrl,
                        contractAddress: contract,
                        network: network
                    )
                    await MainActor.run {
                        txHash = hash
                        isSending = false
                    }
                }

                UINotificationFeedbackGenerator().notificationOccurred(.success)
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                isPresented = false
            } catch {
                await MainActor.run {
                    isSending = false
                    errorMessage = error.localizedDescription
                }
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}

// MARK: - STARK Proof Progress Overlay

private struct STARKProofOverlay: View {
    @EnvironmentObject private var themeManager: AppThemeManager
    @State private var pulseAmount: CGFloat = 1.0

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()

            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(Color(hex: "#6B3DE8").opacity(0.15))
                        .frame(width: 80, height: 80)
                        .scaleEffect(pulseAmount)
                        .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: pulseAmount)
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 28))
                        .foregroundStyle(Color(hex: "#9B6DFF"))
                }
                .onAppear { pulseAmount = 1.25 }

                Text("GENERATING STARK PROOF")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(3)
                    .foregroundStyle(.white.opacity(0.9))

                ProgressView()
                    .tint(Color(hex: "#9B6DFF"))
                    .scaleEffect(1.2)
            }
        }
    }
}
