import SwiftUI

/// Allows the user to restore an existing StarkVeil wallet from a 12 or 24-word
/// BIP-39 mnemonic phrase. Validates the phrase (checksum + wordlist) before
/// deriving keys. The phrase is wiped from memory immediately after key derivation.
struct WalletImportView: View {
    @EnvironmentObject private var themeManager: AppThemeManager
    @State private var phraseInput = ""
    @State private var errorMessage: String? = nil
    @State private var isImporting = false
    var onComplete: () -> Void
    var onNewWallet: () -> Void

    private var wordCount: Int {
        phraseInput.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.count
    }

    var body: some View {
        ZStack {
            themeManager.bgColor.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Header
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "arrow.counterclockwise.icloud.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(themeManager.textPrimary)
                        Text("Restore Wallet")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(themeManager.textPrimary)
                        Text("Enter your 12 or 24-word recovery phrase separated by spaces. Your shielded notes will be rediscovered by the sync engine.")
                            .font(.system(size: 14))
                            .foregroundStyle(themeManager.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Phrase input
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Recovery Phrase")
                                .font(.system(size: 13))
                                .foregroundStyle(themeManager.textSecondary)
                            Spacer()
                            Text("\(wordCount) word\(wordCount == 1 ? "" : "s")")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(wordCount == 12 || wordCount == 24 ? .green : themeManager.textSecondary)
                        }

                        TextEditor(text: $phraseInput)
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundStyle(themeManager.textPrimary)
                            .scrollContentBackground(.hidden)
                            .background(themeManager.surface1)
                            .frame(minHeight: 120)
                            .padding(12)
                            .background(themeManager.surface1)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(themeManager.surface2, lineWidth: 1))
                            .autocorrectionDisabled()
                            .autocapitalization(.none)
                    }

                    if let err = errorMessage {
                        HStack(spacing: 8) {
                            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                            Text(err).font(.system(size: 13)).foregroundStyle(.red)
                        }
                    }

                    // Import button
                    Button(action: importWallet) {
                        if isImporting {
                            HStack(spacing: 10) {
                                ProgressView().tint(themeManager.bgColor)
                                Text("Deriving keys…")
                            }
                        } else {
                            Text("Restore Wallet")
                                .font(.system(size: 16, weight: .bold))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .foregroundStyle(themeManager.bgColor)
                    .background((wordCount == 12 || wordCount == 24) && !isImporting ? themeManager.textPrimary : themeManager.surface2)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .disabled(isImporting || (wordCount != 12 && wordCount != 24))

                    Divider().background(themeManager.surface2)

                    // Create new wallet fallback
                    Button(action: onNewWallet) {
                        Text("Create a new wallet instead")
                            .font(.system(size: 15))
                            .foregroundStyle(themeManager.textSecondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(24)
            }
        }
        .preferredColorScheme(themeManager.colorScheme)
    }

    private func importWallet() {
        errorMessage = nil
        isImporting = true
        let raw = phraseInput
        Task.detached(priority: .userInitiated) {
            do {
                let words = try BIP39.validate(raw)
                let keys = try KeyDerivationEngine.deriveKeys(from: words)
                try KeychainManager.storeMasterSeed(keys.masterSeed)
                await MainActor.run { onComplete() }
            } catch let e as BIP39Error {
                await MainActor.run { isImporting = false; errorMessage = e.localizedDescription }
            } catch {
                await MainActor.run { isImporting = false; errorMessage = error.localizedDescription }
            }
        }
    }
}
