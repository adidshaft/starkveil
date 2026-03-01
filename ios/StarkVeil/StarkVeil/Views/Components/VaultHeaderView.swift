import SwiftUI

struct VaultHeaderView: View {
    @EnvironmentObject private var syncEngine: SyncEngine
    @State private var isBreathing = false

    var body: some View {
        HStack {
            // Branded Typography
            Text("StarkVeil")
                .font(.custom("SpaceGrotesk-Bold", size: 28, relativeTo: .title))
                .foregroundStyle(.white)
                .tracking(1.2)

            Spacer()

            // Sync Status Indicator (Breathing Animation)
            // drawingGroup() promotes to a single GPU layer — avoids per-frame CPU compositing
            HStack(spacing: 8) {
                Circle()
                    .fill(syncEngine.isSyncing ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                    .shadow(
                        color: syncEngine.isSyncing ? Color.green.opacity(0.8) : Color.red.opacity(0.8),
                        radius: isBreathing ? 6 : 2
                    )
                    .scaleEffect(isBreathing ? 1.2 : 0.8)
                    // value: isBreathing is the correct pivot — the state that actually
                    // toggles triggers the animation. .none suppresses motion when offline.
                    .animation(
                        syncEngine.isSyncing
                            ? .easeInOut(duration: 1.5).repeatForever(autoreverses: true)
                            : .none,
                        value: isBreathing
                    )
                    .onChange(of: syncEngine.isSyncing) { _, isSyncing in
                        // Reset first so SwiftUI sees a false → true (or true → false) transition.
                        isBreathing = false
                        if isSyncing {
                            // One-frame delay gives SwiftUI time to commit the false state
                            // before we drive it back to true, re-triggering the animation.
                            Task { @MainActor in isBreathing = true }
                        }
                    }

                Text(syncEngine.isSyncing ? "Syncing…" : "Offline")
                    .font(.caption.monospaced())
                    .foregroundStyle(Color(white: 0.6))
            }
            .drawingGroup()
        }
        .padding(.horizontal)
        .onAppear {
            // Only breathe if we're already syncing on mount
            if syncEngine.isSyncing { isBreathing = true }
        }
        .onDisappear {
            // Reset so onAppear fires the false→true transition correctly on re-mount
            isBreathing = false
        }
    }
}
