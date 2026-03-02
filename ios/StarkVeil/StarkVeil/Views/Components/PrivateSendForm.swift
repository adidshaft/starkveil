import SwiftUI

struct PrivateSendForm: View {
    @EnvironmentObject private var themeManager: AppThemeManager
    @EnvironmentObject private var walletManager: WalletManager

    @Binding var recipientAddress: String
    @Binding var transferAmount: String
    @Binding var errorMessage: String?

    var parsedAmount: Double? {
        guard let v = Double(transferAmount), v > 0, v.isFinite, v <= walletManager.balance else {
            return nil
        }
        return v
    }

    var canSend: Bool {
        !walletManager.isProving && !recipientAddress.isEmpty && parsedAmount != nil
    }

    var body: some View {
        VStack(spacing: 20) {

            // Address Field
            HStack {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .foregroundStyle(themeManager.textSecondary)
                TextField("Recipient (0x...)", text: $recipientAddress)
                    .foregroundStyle(themeManager.textPrimary)
            }
            .padding()
            .background(themeManager.surface1)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            // Amount Field
            HStack {
                Text("$")
                    .foregroundStyle(themeManager.textSecondary)
                TextField("Amount", text: $transferAmount)
                    .keyboardType(.decimalPad)
                    .foregroundStyle(themeManager.textPrimary)
            }
            .padding()
            .background(themeManager.surface1)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            // Error Display
            let displayError = walletManager.transferError ?? errorMessage
            if let msg = displayError {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            // Dynamic Proving Button
            Button(action: sendAction) {
                if walletManager.isProving {
                    ProofSynthesisSkeleton()
                } else {
                    HStack(spacing: 12) {
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
            .animation(.easeInOut(duration: 0.3), value: walletManager.isProving)
            // canSend already encodes !isProving — no need for the compound expression
            // that previously left the button enabled during an active proof
            .disabled(!canSend)

            // Success State
            if let hash = walletManager.lastProvedTxHash {
                HStack {
                    Image(systemName: "checkmark.shield.fill")
                    Text("Sent! TxHash: \(hash.prefix(10))...")
                }
                .font(.caption.monospaced())
                .foregroundStyle(.green)
            }
        }
        .padding(.horizontal)
    }

    private func sendAction() {
        errorMessage = nil

        // Distinguish between "bad input" and "exceeds balance" before touching async work
        guard let amount = parsedAmount else {
            if let v = Double(transferAmount), v.isFinite, v > walletManager.balance {
                errorMessage = "Amount exceeds shielded balance."
            } else {
                errorMessage = "Enter a valid amount > 0."
            }
            return
        }

        // Impact haptic on confirmed tap — semantically neutral, signals action acceptance
        let tapImpact = UIImpactFeedbackGenerator(style: .medium)
        tapImpact.prepare()
        tapImpact.impactOccurred()

        Task {
            // Notification generator lives inside the Task — prepare() before the await
            // so it's primed when the result arrives regardless of how long proving takes
            let resultFeedback = UINotificationFeedbackGenerator()
            resultFeedback.prepare()
            do {
                try await walletManager.executePrivateTransfer(recipient: recipientAddress, amount: amount)
                resultFeedback.notificationOccurred(.success)
            } catch {
                errorMessage = error.localizedDescription
                resultFeedback.notificationOccurred(.error)
            }
        }
    }
}
