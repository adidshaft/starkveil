import SwiftUI

enum AppTheme {
    static let lightBg = Color(hex: "#F1EFED")
    static let lightSurface1 = Color(hex: "#EBE8E5")
    static let lightSurface2 = Color(hex: "#E1DCD8")
    static let lightTextPrimary = Color(hex: "#333333")
    static let lightTextSecondary = Color(hex: "#6B6A68")

    static let darkBg = Color(hex: "#333333")
    static let darkSurface1 = Color(hex: "#2B2B2B")
    static let darkSurface2 = Color(hex: "#242424")
    static let darkTextPrimary = Color(hex: "#F1EFED")
    static let darkTextSecondary = Color(hex: "#A3A19E")

    // MARK: - Phase 21: Glass & accent tokens
    static let accentPurple = Color(hex: "#9B6DFF")
    static let accentGreen  = Color(hex: "#4CAF50")
    static let accentRed    = Color(hex: "#F44336")
    /// Subtle border for glassmorphic cards
    static let glassStroke  = Color(hex: "#9B6DFF").opacity(0.12)
    /// Frosted fill tint — overlay on top of .ultraThinMaterial
    static let glassFill    = Color(hex: "#6B3DE8").opacity(0.06)
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
