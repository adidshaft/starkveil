import SwiftUI

// MARK: - PrivateTransferView
//
// Phase 15 Item 4 — Private-to-Private Transfer.
// Sends a shielded note to another StarkVeil wallet address without going through
// the public pool. The recipient receives an encrypted note they can scan during
// their next SyncEngine poll cycle.
//
// Architecture:
//   1. Select sender's note (exact amount match)
//   2. Derive recipient's IVK key from their address (for memo encryption)
//   3. Encrypt note details with recipient's IVK-derived key
//   4. Build PrivacyPool.transfer(nullifier, new_commitment, encrypted_memo) calldata
//   5. Sign + submit via real nonce / estimateFee flow

struct PrivateTransferView: View {
    @EnvironmentObject private var walletManager: WalletManager
    @EnvironmentObject private var networkManager: NetworkManager
    @EnvironmentObject private var themeManager: AppThemeManager
    @Environment(\.dismiss) private var dismiss

    @State private var recipientAddress: String = ""
    @State private var recipientIVK: String = ""
    @State private var transferAmount: String = ""
    @State private var memo: String = ""
    @State private var isSubmitting = false
    @State private var successTxHash: String? = nil
    @State private var errorMessage: String? = nil

    private var amountDouble: Double? { Double(transferAmount) }

    var body: some View {
        NavigationStack {
            ZStack {
                themeManager.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 24) {
                        header
                        formCard
                        if let err = errorMessage {
                            errorBanner(err)
                        }
                        if let hash = successTxHash {
                            successBanner(hash)
                        } else {
                            submitButton
                        }
                    }
                    .padding(20)
                }
            }
            .navigationBarHidden(true)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(themeManager.textSecondary)
                    .padding(8)
                    .background(themeManager.surface1)
                    .clipShape(Circle())
            }
            Spacer()
            Text("Private Transfer")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(themeManager.textPrimary)
            Spacer()
            Color.clear.frame(width: 32)
        }
    }

    // MARK: - Form Card

    private var formCard: some View {
        VStack(spacing: 16) {
            // Balance row
            HStack {
                Text("Shielded Balance")
                    .font(.system(size: 12))
                    .foregroundStyle(themeManager.textSecondary)
                Spacer()
                Text("\(walletManager.balance, specifier: "%.6f") STRK")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(themeManager.textPrimary)
            }
            Divider().background(themeManager.textSecondary.opacity(0.15))

            // Recipient Address field
            inputField(
                label: "RECIPIENT ADDRESS",
                placeholder: "0x04a44...",
                text: $recipientAddress,
                monospaced: true
            )

            // Recipient IVK field
            inputField(
                label: "RECIPIENT VIEWING KEY (IVK)",
                placeholder: "0x123abc...",
                text: $recipientIVK,
                monospaced: true
            )

            // Amount field
            inputField(
                label: "AMOUNT (STRK)",
                placeholder: "0.000000",
                text: $transferAmount
            )

            // Memo field
            inputField(
                label: "MEMO (ENCRYPTED)",
                placeholder: "Optional note for recipient",
                text: $memo
            )

            // Privacy note
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(themeManager.textSecondary.opacity(0.6))
                Text("Memo is encrypted with the recipient's viewing key")
                    .font(.system(size: 10))
                    .foregroundStyle(themeManager.textSecondary.opacity(0.6))
            }
        }
        .padding(16)
        .background(themeManager.surface1)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func inputField(label: String, placeholder: String, text: Binding<String>, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(themeManager.textSecondary)
            TextField(placeholder, text: text)
                .font(monospaced ? .system(size: 13, design: .monospaced) : .system(size: 13))
                .foregroundStyle(themeManager.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(10)
                .background(themeManager.background.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Banners

    private func errorBanner(_ msg: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(msg)
                .font(.system(size: 13))
                .foregroundStyle(.red)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func successBanner(_ hash: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 32))
                .foregroundStyle(.green)
            Text("Transfer Submitted")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(themeManager.textPrimary)
            Text(hash.prefix(20) + "…")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(themeManager.textSecondary)
            Button("Done") { dismiss() }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 32).padding(.vertical, 12)
                .background(Color.green)
                .clipShape(Capsule())
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(themeManager.surface1)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Submit Button

    private var submitButton: some View {
        let valid = !recipientAddress.isEmpty
            && !recipientIVK.isEmpty
            && (amountDouble ?? 0) > 0
            && (amountDouble ?? 0) <= walletManager.balance

        return Button(action: submit) {
            HStack(spacing: 8) {
                if isSubmitting {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "arrow.right.circle.fill")
                }
                Text(isSubmitting ? "Submitting…" : "Send Privately")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(valid && !isSubmitting ? Color.accentColor : Color.gray.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(!valid || isSubmitting)
    }

    // MARK: - Submit Action

    private func submit() {
        guard let amount = amountDouble, amount > 0 else { return }
        errorMessage = nil
        isSubmitting = true

        Task {
            do {
                let rpcUrl = networkManager.activeNetwork.rpcUrl
                let contract = networkManager.activeNetwork.contractAddress
                let txHash = try await walletManager.executePrivateTransfer(
                    recipientAddress: recipientAddress,
                    recipientIVK: recipientIVK,
                    amount: amount,
                    memo: memo,
                    rpcUrl: rpcUrl,
                    contractAddress: contract,
                    network: networkManager.activeNetwork
                )
                await MainActor.run {
                    successTxHash = txHash
                    isSubmitting = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSubmitting = false
                }
            }
        }
    }
}
