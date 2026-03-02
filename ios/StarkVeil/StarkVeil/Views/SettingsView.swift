import SwiftUI
import LocalAuthentication

/// Settings tab.
/// SECURITY: Destructive actions (Delete Wallet, Clear History) require
/// explicit double-confirmation. "View Recovery Phrase" is honestly
/// unavailable because only the derived seed is stored — never the mnemonic.
struct SettingsView: View {
    @EnvironmentObject private var themeManager: AppThemeManager
    @EnvironmentObject private var networkManager: NetworkManager
    @EnvironmentObject private var walletManager: WalletManager
    @EnvironmentObject private var appSettings: AppSettings

    @State private var showDeleteAlert  = false
    @State private var showDeleteConfirm = false
    @State private var showClearHistoryAlert = false
    @State private var biometricError: String? = nil

    // Callback to reset the app to onboarding after wallet deletion
    var onWalletDeleted: (() -> Void)? = nil

    var body: some View {
        ZStack {
            themeManager.bgColor.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 6) {
                    settingsHeader

                    // ── Security ──────────────────────────────────────────
                    sectionHeader("Security")
                    settingsCard {
                        Toggle(isOn: $appSettings.isBiometricLockEnabled) {
                            settingsRowContent(
                                icon: "faceid",
                                title: "Biometric Lock",
                                subtitle: "Require Face ID / Touch ID on launch"
                            )
                        }
                        .tint(themeManager.textPrimary)
                        .padding(16)

                        Divider().background(themeManager.surface2).padding(.horizontal, 16)

                        HStack {
                            settingsRowContent(
                                icon: "timer",
                                title: "Auto-lock",
                                subtitle: nil
                            )
                            Spacer()
                            Picker("", selection: $appSettings.autoLockTimeout) {
                                ForEach(AppSettings.AutoLockTimeout.allCases) { t in
                                    Text(t.label).tag(t)
                                }
                            }
                            .pickerStyle(.menu)
                            .foregroundStyle(themeManager.textPrimary)
                        }
                        .padding(16)
                    }

                    // ── Privacy ───────────────────────────────────────────
                    sectionHeader("Privacy")
                    settingsCard {
                        HStack {
                            settingsRowContent(icon: "antenna.radiowaves.left.and.right",
                                              title: "Network", subtitle: nil)
                            Spacer()
                            Picker("", selection: $networkManager.activeNetwork) {
                                ForEach(NetworkEnvironment.allCases) { env in
                                    Text(env.rawValue).tag(env)
                                }
                            }
                            .pickerStyle(.menu)
                            .foregroundStyle(themeManager.textPrimary)
                        }
                        .padding(16)

                        Divider().background(themeManager.surface2).padding(.horizontal, 16)

                        Button(action: { showClearHistoryAlert = true }) {
                            HStack {
                                settingsRowContent(icon: "clock.badge.xmark",
                                                  title: "Clear Shielded History",
                                                  subtitle: "Removes local activity log for current network")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12))
                                    .foregroundStyle(themeManager.textSecondary)
                            }
                            .padding(16)
                        }
                    }
                    .alert("Clear History?", isPresented: $showClearHistoryAlert) {
                        Button("Cancel", role: .cancel) {}
                        Button("Clear", role: .destructive) { walletManager.clearActivityEvents() }
                    } message: {
                        Text("This removes your local activity log for \(networkManager.activeNetwork.rawValue). On-chain data is unaffected.")
                    }

                    // ── Wallet ────────────────────────────────────────────
                    sectionHeader("Wallet")
                    settingsCard {
                        // Recovery phrase info (can't reverse BIP-39)
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(themeManager.textSecondary)
                                .font(.system(size: 16))
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Recovery Phrase Not Stored")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(themeManager.textPrimary)
                                Text("For your security, StarkVeil stores only your 64-byte derived seed — never the 12-word mnemonic itself. BIP-39 key derivation is one-way and cannot be reversed. Keep your phrase in a safe physical location.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(themeManager.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(16)

                        Divider().background(themeManager.surface2).padding(.horizontal, 16)

                        // Delete wallet
                        Button(action: { showDeleteAlert = true }) {
                            HStack {
                                settingsRowContent(
                                    icon: "trash.fill",
                                    title: "Delete Wallet",
                                    subtitle: "Wipes all keys and notes from this device",
                                    tintLeft: .red
                                )
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12))
                                    .foregroundStyle(themeManager.textSecondary)
                            }
                            .padding(16)
                        }
                    }
                    // First alert
                    .alert("Delete Wallet?", isPresented: $showDeleteAlert) {
                        Button("Cancel", role: .cancel) {}
                        Button("Continue", role: .destructive) { showDeleteConfirm = true }
                    } message: {
                        Text("This will permanently delete your shielded keys, notes, and activity from this device. Make sure you have your 12-word recovery phrase before continuing.")
                    }
                    // Second confirmation
                    .alert("Are you absolutely sure?", isPresented: $showDeleteConfirm) {
                        Button("Cancel", role: .cancel) {}
                        Button("Delete Forever", role: .destructive) { deleteWalletWithAuth() }
                    } message: {
                        Text("This action cannot be undone. Your on-chain notes will be gone if you haven't backed up your recovery phrase.")
                    }

                    if let err = biometricError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 20)
                    }

                    // ── About ─────────────────────────────────────────────
                    sectionHeader("About")
                    settingsCard {
                        HStack {
                            settingsRowContent(icon: "app.badge.fill", title: "Version", subtitle: nil)
                            Spacer()
                            Text(appVersion)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(themeManager.textSecondary)
                        }
                        .padding(16)

                        Divider().background(themeManager.surface2).padding(.horizontal, 16)

                        Button(action: openRepo) {
                            HStack {
                                settingsRowContent(icon: "chevron.left.forwardslash.chevron.right",
                                                  title: "Open-Source Repository", subtitle: nil)
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 12))
                                    .foregroundStyle(themeManager.textSecondary)
                            }
                            .padding(16)
                        }
                    }

                    Spacer(minLength: 80)
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Sub-components

    private var settingsHeader: some View {
        HStack {
            Text("Settings")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(themeManager.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 8)
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(themeManager.textSecondary)
                .tracking(1.2)
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(themeManager.surface1)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(themeManager.surface2, lineWidth: 1))
    }

    private func settingsRowContent(
        icon: String,
        title: String,
        subtitle: String?,
        tintLeft: Color? = nil
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .frame(width: 24)
                .foregroundStyle(tintLeft ?? themeManager.textPrimary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14))
                    .foregroundStyle(tintLeft ?? themeManager.textPrimary)
                if let sub = subtitle {
                    Text(sub)
                        .font(.system(size: 11))
                        .foregroundStyle(themeManager.textSecondary)
                }
            }
        }
    }

    // MARK: - Actions

    private func deleteWalletWithAuth() {
        let context = LAContext()
        var error: NSError?
        let reason = "Authenticate to permanently delete your wallet."

        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, authError in
                DispatchQueue.main.async {
                    if success {
                        performWalletDeletion()
                    } else {
                        biometricError = authError?.localizedDescription ?? "Authentication failed."
                    }
                }
            }
        } else {
            // No biometrics/passcode — allow deletion (device has no lock screen)
            performWalletDeletion()
        }
    }

    private func performWalletDeletion() {
        KeychainManager.deleteWallet()
        // H3: deleteAllNetworksData() wipes ALL networks, not just the active one.
        // clearStore() + clearActivityEvents() would leave orphaned data from other networks.
        walletManager.deleteAllNetworksData()
        onWalletDeleted?()
    }

    private func openRepo() {
        if let url = URL(string: "https://github.com/anon-stark") {
            UIApplication.shared.open(url)
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
