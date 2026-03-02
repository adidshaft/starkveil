import SwiftUI

struct VaultView: View {
    @EnvironmentObject private var themeManager: AppThemeManager
    @EnvironmentObject private var syncEngine: SyncEngine
    @EnvironmentObject private var walletManager: WalletManager
    @EnvironmentObject private var networkManager: NetworkManager
    @EnvironmentObject private var appSettings: AppSettings

    // Splash gate
    @State private var showSplash = true
    @State private var splashOpacity: Double = 1.0

    // Global balance visibility (drives all tabs simultaneously, matching prototype)
    @State private var isBalanceVisible = false

    // Tab state
    @State private var vaultTab: VaultTab = .assets
    @State private var bottomTab: BottomNavTab = .wallet

    // Send sheet
    @State private var showSendSheet = false
    @State private var transferAmount = ""
    @State private var recipientAddress = ""
    @State private var errorMessage: String? = nil

    // Transaction sheets
    @State private var showSendSheet     = false
    @State private var showUnshieldSheet = false

    // Wallet deleted callback
    var onWalletDeleted: (() -> Void)? = nil

    var body: some View {
        ZStack(alignment: .bottom) {
            // ── Background ──────────────────────────────────────────
            themeManager.bgColor.ignoresSafeArea()

            // Ambient glow orbs matching the prototype
            Circle()
                .fill(themeManager.textPrimary.opacity(0.07))
                .frame(width: 300, height: 300)
                .blur(radius: 100)
                .offset(x: -80, y: -300)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            Circle()
                .fill(themeManager.textSecondary.opacity(0.06))
                .frame(width: 300, height: 300)
                .blur(radius: 100)
                .offset(x: 100, y: 200)
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
                case .zkProofs:
                    ZKProofsView()
                        .padding(.bottom, 60)
                case .settings:
                    SettingsView(onWalletDeleted: onWalletDeleted)
                        .padding(.bottom, 60)
                }
            }

            // ── Bottom Nav (always on top of content) ────────────────
            VStack(spacing: 0) {
                Spacer()
                BottomNavView(selectedTab: $bottomTab)
            }
            .ignoresSafeArea(edges: .bottom)

            // ── STARK Proof overlay (shown during sends / swaps) ─────
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
                        // Match prototype: 2.5s delay, then 0.8s fade
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                            withAnimation(.easeInOut(duration: 0.8)) {
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
        .onAppear { syncEngine.startSyncing() }
        .onDisappear { syncEngine.stopSyncing() }
        // Send sheet
        .sheet(isPresented: $showSendSheet) {
            SendSheetView(
                recipientAddress: $recipientAddress,
                transferAmount: $transferAmount,
                errorMessage: $errorMessage,
                isPresented: $showSendSheet
            )
            .environmentObject(themeManager)
            .environmentObject(walletManager)
        }
        .sheet(isPresented: $showUnshieldSheet) {
            UnshieldFormView(isPresented: $showUnshieldSheet)
                .environmentObject(themeManager)
                .environmentObject(walletManager)
                .environmentObject(networkManager)
        }
    }

    // MARK: - Wallet tab layout (extracted to keep body readable)
    @ViewBuilder
    private var walletTabContent: some View {
        // Balance card
        ShieldedBalanceCard(
            isBalanceVisible: $isBalanceVisible,
            showSendSheet:     $showSendSheet,
            showUnshieldSheet: $showUnshieldSheet
        )
        .padding(.bottom, 28)

        // Tab switcher
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


// MARK: - Send Sheet (moved out of main scroll)

private struct SendSheetView: View {
    @EnvironmentObject private var themeManager: AppThemeManager
    @EnvironmentObject private var walletManager: WalletManager
    @Binding var recipientAddress: String
    @Binding var transferAmount: String
    @Binding var errorMessage: String?
    @Binding var isPresented: Bool

    @State private var memo = ""

    var parsedAmount: Double? {
        guard let v = Double(transferAmount), v > 0, v.isFinite, v <= walletManager.balance else { return nil }
        return v
    }
    var canSend: Bool { !walletManager.isProving && !recipientAddress.isEmpty && parsedAmount != nil }

    var body: some View {
        NavigationStack {
            ZStack {
                themeManager.bgColor.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {

                        // ZODL big dashes / amount display
                        HStack(spacing: 10) {
                            Image(systemName: "shield.lefthalf.filled")
                                .font(.system(size: 28))
                                .foregroundStyle(themeManager.textSecondary)
                            if transferAmount.isEmpty {
                                Text("– – – – – –")
                                    .font(.system(size: 32, weight: .bold, design: .monospaced))
                                    .foregroundStyle(themeManager.textSecondary)
                            } else {
                                Text(transferAmount)
                                    .font(.system(size: 32, weight: .bold, design: .monospaced))
                                    .foregroundStyle(themeManager.textPrimary)
                                    .contentTransition(.numericText())
                            }
                        }
                        .padding(.top, 4)

                        // Send to label + address
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Send to")
                                .font(.system(size: 13))
                                .foregroundStyle(themeManager.textSecondary)
                            HStack {
                                Image(systemName: "person.crop.circle.badge.checkmark")
                                    .foregroundStyle(themeManager.textSecondary)
                                TextField("Shielded address (0x...)", text: $recipientAddress)
                                    .foregroundStyle(themeManager.textPrimary)
                                    .autocorrectionDisabled()
                                    .autocapitalization(.none)
                                    .font(.system(size: 14, design: .monospaced))
                                Spacer()
                                Button(action: { /* QR scan — future */ }) {
                                    Image(systemName: "qrcode.viewfinder")
                                        .font(.system(size: 18))
                                        .foregroundStyle(themeManager.textSecondary)
                                }
                            }
                            .padding(14)
                            .background(themeManager.surface1)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(themeManager.surface2, lineWidth: 1))
                        }

                        // Amount
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Amount")
                                .font(.system(size: 13))
                                .foregroundStyle(themeManager.textSecondary)
                            HStack {
                                Image(systemName: "shield.lefthalf.filled")
                                    .foregroundStyle(themeManager.textSecondary).frame(width: 20)
                                TextField("0.0", text: $transferAmount)
                                    .keyboardType(.decimalPad)
                                    .foregroundStyle(themeManager.textPrimary)
                                    .font(.system(size: 16, design: .monospaced))
                                Spacer()
                                Text("STRK")
                                    .foregroundStyle(themeManager.textSecondary)
                                    .font(.system(size: 13))
                            }
                            .padding(14)
                            .background(themeManager.surface1)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(themeManager.surface2, lineWidth: 1))
                        }

                        // Encrypted memo (ZODL-style)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Message")
                                    .font(.system(size: 13))
                                    .foregroundStyle(themeManager.textSecondary)
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(themeManager.textSecondary)
                            }
                            ZStack(alignment: .topLeading) {
                                if memo.isEmpty {
                                    Text("Write encrypted message here…")
                                        .font(.system(size: 14))
                                        .foregroundStyle(themeManager.textSecondary.opacity(0.45))
                                        .padding(.top, 12)
                                        .padding(.leading, 2)
                                }
                                TextEditor(text: $memo)
                                    .foregroundStyle(themeManager.textPrimary)
                                    .font(.system(size: 14))
                                    .scrollContentBackground(.hidden)
                                    .background(Color.clear)
                                    .frame(minHeight: 100, maxHeight: 140)
                            }
                            HStack {
                                Spacer()
                                Text("\(memo.count)/512")
                                    .font(.system(size: 11))
                                    .foregroundStyle(themeManager.textSecondary.opacity(0.5))
                            }
                        }
                        .padding(14)
                        .background(themeManager.surface1)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(themeManager.surface2, lineWidth: 1))
                        .onChange(of: memo) { _, new in if new.count > 512 { memo = String(new.prefix(512)) } }

                        // Error
                        if let msg = walletManager.transferError ?? errorMessage {
                            Text(msg).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
                        }

                        // Review / Send button
                        Button(action: sendAction) {
                            if walletManager.isProving {
                                ProofSynthesisSkeleton()
                            } else {
                                Text("Review")
                                    .font(.headline.weight(.heavy))
                                    .tracking(0.5)
                                    .foregroundStyle(canSend ? themeManager.bgColor : themeManager.textSecondary)
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(canSend ? themeManager.textPrimary : themeManager.surface2)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                        }
                        .disabled(!canSend)
                        .animation(.easeInOut(duration: 0.3), value: walletManager.isProving)

                        if let hash = walletManager.lastProvedTxHash {
                            HStack {
                                Image(systemName: "checkmark.shield.fill")
                                Text("Sent! \(hash.prefix(10))…")
                            }
                            .font(.caption.monospaced())
                            .foregroundStyle(.green)
                        }

                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("SEND")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { isPresented = false } label: {
                        Image(systemName: "arrow.backward")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(themeManager.textPrimary)
                    }
                }
            }
        }
        .preferredColorScheme(themeManager.colorScheme)
    }

    private func sendAction() {
        errorMessage = nil
        guard let amount = parsedAmount else {
            errorMessage = Double(transferAmount).map { $0 > walletManager.balance ? "Exceeds balance." : "Invalid amount." } ?? "Enter a valid amount > 0."
            return
        }
        let tap = UIImpactFeedbackGenerator(style: .medium)
        tap.prepare(); tap.impactOccurred()
        Task {
            let feedback = UINotificationFeedbackGenerator(); feedback.prepare()
            do {
                try await walletManager.executePrivateTransfer(recipient: recipientAddress, amount: amount)
                feedback.notificationOccurred(.success)
                isPresented = false
            } catch {
                errorMessage = error.localizedDescription
                feedback.notificationOccurred(.error)
            }
        }
    }
}

// MARK: - Previews

struct VaultView_Previews: PreviewProvider {
    static var previews: some View {
        let networkManager = NetworkManager()
        VaultView()
            .environmentObject(AppThemeManager())
            .environmentObject(networkManager)
            .environmentObject(WalletManager())
            .environmentObject(SyncEngine(networkManager: networkManager))
            .environmentObject(AppSettings())
    }
}
