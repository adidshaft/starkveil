import SwiftUI

struct SplashScreenView: View {
    @EnvironmentObject private var themeManager: AppThemeManager
    @State private var logoScale: CGFloat = 1.0
    @State private var logoOpacity: Double = 0.9
    @State private var barOffset: CGFloat = -60

    var body: some View {
        ZStack {
            themeManager.bgColor.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Shield logo
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 64, weight: .ultraLight))
                    .foregroundStyle(themeManager.textPrimary)
                    .scaleEffect(logoScale)
                    .opacity(logoOpacity)
                    .padding(.bottom, 24)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) {
                            logoScale = 1.05
                            logoOpacity = 1.0
                        }
                    }

                // Brand name
                Text("STARKVEIL")
                    .font(.system(size: 32, weight: .bold, design: .default))
                    .tracking(4)
                    .foregroundStyle(themeManager.textPrimary)

                // Tagline
                Text("Cypherpunk Grade Privacy")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(themeManager.textSecondary)
                    .tracking(1)
                    .padding(.top, 8)
                    .opacity(0.8)

                // Animated loader bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(themeManager.surface2)
                            .frame(height: 2)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(themeManager.textPrimary)
                            .frame(width: 30, height: 2)
                            .offset(x: barOffset)
                            .onAppear {
                                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                                    barOffset = geo.size.width
                                }
                            }
                    }
                }
                .frame(width: 60, height: 2)
                .clipped()
                .padding(.top, 40)

                Spacer()
            }
        }
    }
}
