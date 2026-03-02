import SwiftUI

/// First-launch wallet onboarding screen. Shown only when `KeychainManager.hasWallet == false`.
/// Once completed (either new wallet or restore), the main VaultView takes over.
struct WalletOnboardingView: View {
    @EnvironmentObject private var themeManager: AppThemeManager
    @State private var choice: OnboardingChoice? = nil
    var onComplete: () -> Void

    private enum OnboardingChoice { case createNew, restore }

    var body: some View {
        Group {
            if let choice = choice {
                switch choice {
                case .createNew:
                    MnemonicSetupView(onComplete: onComplete)
                        .environmentObject(themeManager)
                case .restore:
                    WalletImportView(onComplete: onComplete, onNewWallet: { self.choice = .createNew })
                        .environmentObject(themeManager)
                }
            } else {
                landingView
            }
        }
        .preferredColorScheme(themeManager.colorScheme)
    }

    private var landingView: some View {
        ZStack {
            themeManager.bgColor.ignoresSafeArea()

            // Ambient glow
            Circle()
                .fill(themeManager.textPrimary.opacity(0.08))
                .frame(width: 340, height: 340)
                .blur(radius: 120)
                .offset(x: -60, y: -280)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                Spacer()

                // Logo
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 64, weight: .ultraLight))
                    .foregroundStyle(themeManager.textPrimary)
                    .padding(.bottom, 20)

                Text("STARKVEIL")
                    .font(.system(size: 32, weight: .bold))
                    .tracking(4)
                    .foregroundStyle(themeManager.textPrimary)

                Text("Cypherpunk Grade Privacy on Starknet")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(themeManager.textSecondary)
                    .tracking(0.5)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
                    .padding(.horizontal, 32)

                Spacer()

                // Buttons
                VStack(spacing: 14) {
                    Button(action: { choice = .createNew }) {
                        Text("Create New Wallet")
                            .font(.system(size: 16, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .foregroundStyle(themeManager.bgColor)
                            .background(themeManager.textPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    Button(action: { choice = .restore }) {
                        Text("Restore from Seed Phrase")
                            .font(.system(size: 16, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .foregroundStyle(themeManager.textPrimary)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(themeManager.textPrimary, lineWidth: 1)
                            )
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 50)
            }
        }
    }
}
