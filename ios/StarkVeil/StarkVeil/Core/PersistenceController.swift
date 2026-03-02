import Foundation
import SwiftData

/// Owns the SwiftData ModelContainer for the StarkVeil app.
/// All model types are registered here once — views and services pull
/// the shared `ModelContext` via the environment or direct injection.
class PersistenceController {
    static let shared = PersistenceController()

    let container: ModelContainer

    private init() {
        let schema = Schema([StoredNote.self, SyncCheckpoint.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            // A failed model container is a hard crash — better to surface it loudly
            // during development than to silently lose user data at runtime.
            fatalError("[Persistence] Failed to create ModelContainer: \(error)")
        }
    }

    var context: ModelContext {
        ModelContext(container)
    }
}
