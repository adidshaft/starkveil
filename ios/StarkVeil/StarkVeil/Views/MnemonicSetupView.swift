import SwiftUI

/// Displays the 12-word BIP-39 recovery phrase and asks the user to confirm
/// they have backed it up before proceeding. The mnemonic is shown once and
/// never stored — only the derived 64-byte seed reaches Keychain.
struct MnemonicSetupView: View {
    @EnvironmentObject private var themeManager: AppThemeManager
    @State private var mnemonic: [String] = []
    @State private var phase: SetupPhase = .generating
    @State private var confirmedWords: [String] = []
    @State private var confirmInput = ""
    @State private var errorMessage: String? = nil
    @State private var isSaving = false
    @State private var isCopied = false
    var onComplete: () -> Void

    private enum SetupPhase { case generating, display, confirm }

    // Indices to quiz the user on (3 random positions)
    @State private var quizIndices: [Int] = []

    var body: some View {
        ZStack {
            themeManager.bgColor.ignoresSafeArea()

            switch phase {
            case .generating:
                generatingView
            case .display:
                displayView
            case .confirm:
                confirmView
            }
        }
        .preferredColorScheme(themeManager.colorScheme)
        .onAppear(perform: generateMnemonic)
    }

    // MARK: - Generating

    private var generatingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(themeManager.textPrimary)
            Text("Generating secure recovery phrase…")
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(themeManager.textSecondary)
        }
    }

    // MARK: - Display Phase

    private var displayView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(themeManager.textPrimary)
                    Text("Recovery Phrase")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(themeManager.textPrimary)
                    Text("Write these 12 words down in order and store them somewhere safe. This is the ONLY way to recover your shielded notes if you lose this device.")
                        .font(.system(size: 14))
                        .foregroundStyle(themeManager.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Warning banner
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Never share this phrase. StarkVeil will never ask for it.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.orange)
                }
                .padding(14)
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                // Word grid
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(mnemonic.indices, id: \.self) { idx in
                        wordCell(number: idx + 1, word: mnemonic[idx])
                    }
                }
                .padding(.vertical, 8)

                // Copy all words button
                Button(action: copyPhrase) {
                    Label(
                        isCopied ? "Copied!" : "Copy All Words",
                        systemImage: isCopied ? "checkmark" : "doc.on.doc"
                    )
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundStyle(themeManager.textPrimary)
                    .background(themeManager.surface1)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(themeManager.surface2))
                }
                .animation(.easeInOut, value: isCopied)

                // Continue button
                Button(action: { prepareConfirmation() }) {
                    Text("I've backed it up →")
                        .font(.system(size: 16, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .foregroundStyle(themeManager.bgColor)
                        .background(themeManager.textPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .padding(24)
        }
    }

    private func wordCell(number: Int, word: String) -> some View {
        HStack(spacing: 6) {
            Text("\(number).")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(themeManager.textSecondary)
                .frame(width: 20, alignment: .trailing)
            Text(word)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(themeManager.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(themeManager.surface1)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(themeManager.surface2, lineWidth: 1))
    }

    // MARK: - Confirm Phase

    private var confirmView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(themeManager.textPrimary)
                    Text("Verify Your Phrase")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(themeManager.textPrimary)
                    Text("Enter the words at the positions below to confirm you saved them correctly.")
                        .font(.system(size: 14))
                        .foregroundStyle(themeManager.textSecondary)
                }

                ForEach(quizIndices.indices, id: \.self) { qi in
                    let idx = quizIndices[qi]
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Word #\(idx + 1)")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(themeManager.textSecondary)
                        TextField("Enter word \(idx + 1)", text: Binding(
                            get: { confirmedWords.indices.contains(qi) ? confirmedWords[qi] : "" },
                            set: { val in
                                while confirmedWords.count <= qi { confirmedWords.append("") }
                                confirmedWords[qi] = val.lowercased().trimmingCharacters(in: .whitespaces)
                            }
                        ))
                        .font(.system(size: 15, design: .monospaced))
                        .autocorrectionDisabled()
                        .autocapitalization(.none)
                        .padding()
                        .background(themeManager.surface1)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(themeManager.surface2, lineWidth: 1))
                        .foregroundStyle(themeManager.textPrimary)
                    }
                }

                if let err = errorMessage {
                    Text(err).font(.caption).foregroundStyle(.red)
                }

                Button(action: verifyAndSave) {
                    if isSaving {
                        ProgressView().tint(themeManager.bgColor)
                    } else {
                        Text("Confirm & Create Wallet")
                            .font(.system(size: 16, weight: .bold))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .foregroundStyle(themeManager.bgColor)
                .background(themeManager.textPrimary)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .disabled(isSaving || confirmedWords.filter({ !$0.isEmpty }).count < quizIndices.count)
            }
            .padding(24)
        }
    }

    // MARK: - Logic

    private func generateMnemonic() {
        Task.detached(priority: .userInitiated) {
            guard let words = try? BIP39.generateMnemonic() else { return }
            await MainActor.run {
                mnemonic = words
                phase = .display
            }
        }
    }

    private func copyPhrase() {
        UIPasteboard.general.string = mnemonic.joined(separator: " ")
        withAnimation { isCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation { isCopied = false }
        }
    }

    private func prepareConfirmation() {
        // Pick 3 random word positions for confirmation
        quizIndices = Array(mnemonic.indices.shuffled().prefix(3)).sorted()
        confirmedWords = []
        withAnimation { phase = .confirm }
    }

    private func verifyAndSave() {
        errorMessage = nil
        // Verify quiz words match
        for (qi, idx) in quizIndices.enumerated() {
            let entered = confirmedWords.indices.contains(qi) ? confirmedWords[qi] : ""
            guard entered == mnemonic[idx] else {
                errorMessage = "Word #\(idx + 1) is incorrect. Please check your backup."
                return
            }
        }

        isSaving = true
        var mnemonicSnapshot = mnemonic

        Task.detached(priority: .userInitiated) {
            defer {
                mnemonicSnapshot.removeAll(keepingCapacity: false)
            }
            do {
                let keys = try KeyDerivationEngine.deriveKeys(from: mnemonicSnapshot)
                try KeychainManager.storeMasterSeed(keys.masterSeed)
                await MainActor.run {
                    mnemonic.removeAll(keepingCapacity: false)
                    confirmedWords.removeAll(keepingCapacity: false)
                    onComplete()
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    errorMessage = "Wallet creation failed: \(error.localizedDescription)"
                }
            }
        }
    }
}
