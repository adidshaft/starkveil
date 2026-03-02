import SwiftUI

/// Unshield flow: user selects the note amount to redeem and enters a public
/// recipient address. Generates a STARK proof binding (amount, asset, recipient)
/// and submits via `PrivacyPool.unshield()` on-chain.
struct UnshieldFormView: View {
    @EnvironmentObject private var themeManager: AppThemeManager
    @EnvironmentObject private var walletManager: WalletManager
    @EnvironmentObject private var networkManager: NetworkManager
    @Binding var isPresented: Bool

    @State private var recipientAddress = ""
    @State private var selectedNote: Note? = nil
    @State private var errorMessage: String? = nil

    private var rpcUrl: URL { URL(string: networkManager.activeNetwork.rpcURL)! }
    private var contractAddress: String { networkManager.activeNetwork.privacyPoolAddress }

    var body: some View {
        NavigationStack {
            ZStack {
                themeManager.bgColor.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {

                        // Info banner
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.down.to.line.compact")
                                .foregroundStyle(themeManager.textPrimary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Private → Public")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(themeManager.textPrimary)
                                Text("Recipient address and amount become public. Your identity remains hidden.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(themeManager.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(14)
                        .background(themeManager.surface1)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(themeManager.surface2, lineWidth: 1))

                        // Note selector
                        VStack(alignment: .leading, spacing: 8) {
                            Text("SELECT NOTE TO REDEEM")
                                .font(.system(size: 11, weight: .bold))
                                .tracking(2)
                                .foregroundStyle(themeManager.textSecondary)

                            if walletManager.notes.isEmpty {
                                Text("No shielded notes available.")
                                    .font(.system(size: 14))
                                    .foregroundStyle(themeManager.textSecondary)
                                    .padding()
                            } else {
                                VStack(spacing: 8) {
                                    ForEach(walletManager.notes.indices, id: \.self) { idx in
                                        let note = walletManager.notes[idx]
                                        noteRow(note: note, isSelected: selectedNote?.value == note.value)
                                            .onTapGesture { selectedNote = note }
                                    }
                                }
                            }
                        }

                        // Recipient address field
                        VStack(alignment: .leading, spacing: 6) {
                            Text("RECIPIENT ADDRESS")
                                .font(.system(size: 11, weight: .bold))
                                .tracking(2)
                                .foregroundStyle(themeManager.textSecondary)

                            HStack {
                                Image(systemName: "person.badge.shield.checkmark.fill")
                                    .foregroundStyle(themeManager.textSecondary)
                                TextField("0x...", text: $recipientAddress)
                                    .foregroundStyle(themeManager.textPrimary)
                                    .autocorrectionDisabled()
                                    .autocapitalization(.none)
                                    .font(.system(size: 14, design: .monospaced))
                            }
                            .padding()
                            .background(themeManager.surface1)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(themeManager.surface2, lineWidth: 1))
                        }

                        // Error
                        if let err = walletManager.unshieldError ?? errorMessage {
                            HStack(spacing: 8) {
                                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                                Text(err).font(.system(size: 13)).foregroundStyle(.red)
                            }
                        }

                        // Submit button
                        Button(action: submitUnshield) {
                            if walletManager.isUnshielding {
                                HStack(spacing: 10) {
                                    ProgressView().tint(themeManager.bgColor)
                                    Text("Generating Proof…")
                                        .font(.system(size: 15, weight: .semibold))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .foregroundStyle(themeManager.bgColor)
                                .background(themeManager.surface2)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            } else {
                                HStack(spacing: 8) {
                                    Image(systemName: "arrow.down.to.line.compact")
                                    Text("Unshield — Release to Public")
                                        .font(.system(size: 15, weight: .bold))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .foregroundStyle(themeManager.bgColor)
                                .background(canSubmit ? themeManager.textPrimary : themeManager.surface2)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                        }
                        .disabled(!canSubmit || walletManager.isUnshielding)

                        // Success tx hash
                        if let hash = walletManager.lastUnshieldTxHash {
                            HStack {
                                Image(systemName: "checkmark.shield.fill")
                                Text("Released! Tx: \(hash.prefix(12))…")
                            }
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.green)
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Unshield — Private → Public")
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

    private var canSubmit: Bool {
        selectedNote != nil &&
        !recipientAddress.isEmpty &&
        recipientAddress.hasPrefix("0x") &&
        !walletManager.isUnshielding
    }

    private func noteRow(note: Note, isSelected: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(note.value) STRK")
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(themeManager.textPrimary)
                Text(note.memo.prefix(30))
                    .font(.system(size: 12))
                    .foregroundStyle(themeManager.textSecondary)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(themeManager.textPrimary)
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(themeManager.textSecondary)
            }
        }
        .padding()
        .background(themeManager.surface1.opacity(isSelected ? 1 : 0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(isSelected ? themeManager.textPrimary : themeManager.surface2, lineWidth: isSelected ? 1.5 : 1))
        .animation(.easeInOut(duration: 0.2), value: isSelected)
    }

    private func submitUnshield() {
        errorMessage = nil
        guard let note = selectedNote, let amount = Double(note.value) else {
            errorMessage = "Please select a note to redeem."
            return
        }
        let feedback = UIImpactFeedbackGenerator(style: .medium)
        feedback.prepare(); feedback.impactOccurred()

        Task {
            do {
                try await walletManager.executeUnshield(
                    recipient: recipientAddress,
                    amount: amount,
                    rpcUrl: rpcUrl,
                    contractAddress: contractAddress
                )
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                // Dismiss after short delay so user sees success state
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                isPresented = false
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                errorMessage = error.localizedDescription
            }
        }
    }
}
