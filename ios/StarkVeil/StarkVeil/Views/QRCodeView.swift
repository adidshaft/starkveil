import SwiftUI
import CoreImage.CIFilterBuiltins

// MARK: - QRCodeView
//
// Renders a QR code using CoreImage — zero external dependencies.
// Used to display the Starknet account address in AccountActivationView so
// the user can easily receive funds from exchanges or other wallets.

struct QRCodeView: View {
    let data: String
    var size: CGFloat = 200

    private var qrImage: UIImage? { generateQR(from: data) }

    var body: some View {
        Group {
            if let img = qrImage {
                Image(uiImage: img)
                    .interpolation(.none)        // keep pixels crisp — no blur on upscale
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                // Fallback: should never be reached for valid ASCII strings
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: size, height: size)
                    .overlay(
                        Image(systemName: "qrcode")
                            .font(.system(size: 40))
                            .foregroundStyle(Color.secondary)
                    )
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Core Image generator
    // ─────────────────────────────────────────────────────────────────────────

    private func generateQR(from string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.correctionLevel = "M"        // 15% error correction — good balance
        filter.message = Data(string.utf8)

        guard let output = filter.outputImage else { return nil }

        // Scale up from the tiny native QR size to the requested display size
        let scaleX = size / output.extent.width
        let scaleY = size / output.extent.height
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        return UIImage(ciImage: scaled)
    }
}

#Preview {
    QRCodeView(data: "0x04a444b6c41af0c01a166e2b5a5d94c90d2640abc8f89e13b7e2a5db93c7ef5b")
        .padding()
}
