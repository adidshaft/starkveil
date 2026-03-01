import SwiftUI

struct PrivateSendForm: View {
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
                    .foregroundColor(Color(white: 0.5))
                TextField("Recipient (0x...)", text: $recipientAddress)
                    .foregroundColor(.white)
            }
            .padding()
            .background(Color(white: 0.15))
            .cornerRadius(12)
            
            // Amount Field
            HStack {
                Text("$")
                    .foregroundColor(Color(white: 0.5))
                TextField("Amount", text: $transferAmount)
                    .keyboardType(.decimalPad)
                    .foregroundColor(.white)
            }
            .padding()
            .background(Color(white: 0.15))
            .cornerRadius(12)
            
            // Error Display Matrix
            let displayError = walletManager.transferError ?? errorMessage
            if let msg = displayError {
                Text(msg)
                    .font(.caption)
                    .foregroundColor(.red)
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
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding()
                    // Neon accent if valid
                    .background(canSend ? Color(red: 0.8, green: 0.9, blue: 1.0) : Color.gray)
                    .cornerRadius(16)
                    .shadow(color: canSend ? Color.white.opacity(0.3) : .clear, radius: 8)
                }
            }
            // Animate transition between Skeleton and Button
            .animation(.easeInOut(duration: 0.3), value: walletManager.isProving)
            .disabled(!canSend && !walletManager.isProving)
            
            // Success State
            if let hash = walletManager.lastProvedTxHash {
                HStack {
                    Image(systemName: "checkmark.shield.fill")
                    Text("Sent! TxHash: \(hash.prefix(10))...")
                }
                .font(.caption.monospaced())
                .foregroundColor(.green)
            }
        }
        .padding(.horizontal)
    }
    
    private func sendAction() {
        errorMessage = nil

        guard let amount = parsedAmount else {
            errorMessage = amount == nil ? "Enter valid amount > 0." : "Amount exceeds shielded balance."
            return
        }

        // Haptic Trigger
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.warning) // Warning impact before complex block

        Task {
            do {
                try await walletManager.executePrivateTransfer(recipient: recipientAddress, amount: amount)
                generator.notificationOccurred(.success)
            } catch {
                errorMessage = error.localizedDescription
                generator.notificationOccurred(.error)
            }
        }
    }
}
