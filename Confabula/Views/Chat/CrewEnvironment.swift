import SwiftUI

/// Name → bot lookup for Captain's crew surfaces.
///
/// The manifest card inside a bubble and the deck above the thread both need
/// to resolve a specialist *by name* at render time; holding the map in the
/// environment keeps `@Query` out of the per-bubble views (one query per row
/// would hammer the store) and lets the chat compute it once per update.
///
/// The map rides in an unchecked-Sendable box because `Bot` is a main-actor
/// SwiftData model; the value is only ever produced and read on the main
/// actor (all parties are chat views), so the isolation holds in practice.
struct CrewLookupBox: @unchecked Sendable {
    let byName: [String: Bot]
}

private struct CrewLookupKey: EnvironmentKey {
    static let defaultValue = CrewLookupBox(byName: [:])
}

extension EnvironmentValues {
    /// Lowercased bot name → bot, for every bot currently in the store.
    var crewLookup: CrewLookupBox {
        get { self[CrewLookupKey.self] }
        set { self[CrewLookupKey.self] = newValue }
    }
}
