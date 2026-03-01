import SwiftUI

struct VaultHeaderView: View {
    @EnvironmentObject private var syncEngine: SyncEngine
    @State private var isBreathing = false

    var body: some View {
        HStack {
            // Branded Typography
            Text("StarkVeil")
                .font(.custom("SpaceGrotesk-Bold", size: 28, relativeTo: .title))
                .foregroundColor(.white)
                .tracking(1.2) // Slight letter spacing for tech-feel
            
            Spacer()
            
            // Sync Status Indicator (Breathing Animation)
            HStack(spacing: 8) {
                Circle()
                    .fill(syncEngine.isSyncing ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                    // Glow effect
                    .shadow(color: syncEngine.isSyncing ? Color.green.opacity(0.8) : Color.red.opacity(0.8), radius: isBreathing ? 6 : 2)
                    .scaleEffect(isBreathing ? 1.2 : 0.8)
                    .animation(
                        syncEngine.isSyncing ? 
                        Animation.easeInOut(duration: 1.5).repeatForever(autoreverses: true) : 
                        .default,
                        value: isBreathing
                    )
                
                Text(syncEngine.isSyncing ? "Syncing…" : "Offline")
                    .font(.caption.monospaced())
                    .foregroundColor(Color(white: 0.6))
            }
        }
        .padding(.horizontal)
        .onAppear {
            isBreathing = true
        }
    }
}
