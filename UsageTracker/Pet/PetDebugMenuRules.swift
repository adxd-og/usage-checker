#if DEBUG
import Foundation

/// What the pet's Debug menu lists.
struct PetDebugMenu: Equatable, Sendable {
    struct Animal: Equatable, Sendable {
        let id: String
        let isShown: Bool
    }

    /// A first line saying why nothing plays; nil when something can.
    let note: String?
    /// The shown animal's events, in the manifest's order.
    let eventIDs: [String]
    /// The event items and "Play all" are enabled.
    let canPlay: Bool
    let animals: [Animal]
}

/// The Debug trigger for pet events (notch-island spec 2026-10-29 § 3.5, "Owner 2026-10-30 (events)"):
/// Settings › Pet is P6, so testing forty events needs a way to pick the animal and play any of
/// them. Compiled only in Debug; Release has no menu. Pure.
enum PetDebugMenuRules {
    static let animalOrder = ["cat", "duck", "dog", "raccoon"]
    static let playAllTitle = "Play all in order"
    static let reduceMotionNote = "Reduce Motion is on: events do not play"

    static func menu(shown: String, library: PetLibrary, animates: Bool, reduceMotion: Bool) -> PetDebugMenu {
        let eventIDs = library.manifests[shown]?.events.map(\.id) ?? []
        return PetDebugMenu(
            note: reduceMotion ? reduceMotionNote : nil,
            eventIDs: eventIDs,
            canPlay: animates && !eventIDs.isEmpty,
            animals: animalOrder
                .filter { library.manifests[$0] != nil }
                .map { PetDebugMenu.Animal(id: $0, isShown: $0 == shown) }
        )
    }

    /// The default palette if the animal has it, else its first: every animal has its own.
    static func palette(of manifest: PetManifest) -> String {
        if manifest.palettes[PetHabitatRules.palette] != nil { return PetHabitatRules.palette }
        return manifest.paletteNames.first ?? PetHabitatRules.palette
    }
}
#endif
