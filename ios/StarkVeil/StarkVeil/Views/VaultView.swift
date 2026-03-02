import SwiftUI

struct VaultView: View {
    @EnvironmentObject private var themeManager: AppThemeManager
    @EnvironmentObject private var syncEngine: SyncEngine
    @EnvironmentObject private var walletManager: WalletManager

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

    // Unshield sheet
    @State private var showUnshieldSheet = false

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
                // Header
                VaultHeaderView()
                    .padding(.top, 12)
                    .padding(.bottom, 28)

                // Balance card
                ShieldedBalanceCard(
                    isBalanceVisible: $isBalanceVisible,
                    showSendSheet: $showSendSheet,
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
                .padding(.bottom, 60) // Room for the bottom nav

                Spacer(minLength: 0)
            }

            // ── Bottom Nav (always on top of content) ────────────────
            VStack(spacing: 0) {
                Spacer()
                BottomNavView(selectedTab: $bottomTab)
            }
            .ignoresSafeArea(edges: .bottom)

            // ── STARK Proof overlay (shown during sends) ─────────────
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
}

// MARK: - Send Sheet (moved out of main scroll)

private struct SendSheetView: View {
    @EnvironmentObject private var themeManager: AppThemeManager
    @EnvironmentObject private var walletManager: WalletManager
    @Binding var recipientAddress: String
    @Binding var transferAmount: String
    @Binding var errorMessage: String?
    @Binding var isPresented: Bool

    var parsedAmount: Double? {
        guard let v = Double(transferAmount), v > 0, v.isFinite, v <= walletManager.balance else { return nil }
        return v
    }
    var canSend: Bool { !walletManager.isProving && !recipientAddress.isEmpty && parsedAmount != nil }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Address field
                HStack {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .foregroundStyle(themeManager.textSecondary)
                    TextField("Recipient (0x...)", text: $recipientAddress)
                        .foregroundStyle(themeManager.textPrimary)
                }
                .padding()
                .background(themeManager.surface1)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                // Amount field
                HStack {
                    Text("STRK").foregroundStyle(themeManager.textSecondary)
                    TextField("Amount", text: $transferAmount)
                        .keyboardType(.decimalPad)
                        .foregroundStyle(themeManager.textPrimary)
                }
                .padding()
                .background(themeManager.surface1)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                // Error
                if let msg = walletManager.transferError ?? errorMessage {
                    Text(msg).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
                }

                // Send button
                Button(action: sendAction) {
                    if walletManager.isProving {
                        ProofSynthesisSkeleton()
                    } else {
                        HStack(spacing: 10) {
                            Image(systemName: "paperplane.fill")
                            Text("Private Send")
                        }
                        .font(.headline.weight(.heavy))
                        .tracking(1.0)
                        .foregroundStyle(themeManager.bgColor)
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
            .padding(.horizontal)
            .padding(.top, 20)
            .background(themeManager.bgColor.ignoresSafeArea())
            .navigationTitle("Private Send")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                        .foregroundStyle(themeManager.textSecondary)
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
    }
}
