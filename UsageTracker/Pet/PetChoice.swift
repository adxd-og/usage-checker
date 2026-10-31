import Foundation

/// The pet the user chose, by id, as it is stored (notch-island spec 2026-10-29 § 3.5 Roster, § 3.7).
/// It may have gone stale since: `PetChoiceRules.resolved` makes it one that exists.
struct PetChoice: Hashable, Sendable {
    let animal: String
    let palette: String

    /// § 3.5 Roster: the cat, ginger.
    static let standard = PetChoice(animal: PetHabitatRules.animal, palette: PetHabitatRules.palette)
}

/// The roster's order and the way from a stored pair to one that can be drawn (§ 3.5, § 3.7; the P5d
/// tester's F5: a palette the pet lacks builds nothing and leaves a still). Pure. Nothing is written
/// back, so a pack that returns brings the choice back.
enum PetChoiceRules {
    /// The animals in the spec's order.
    static let animalOrder = ["cat", "duck", "dog", "raccoon"]
    /// Each animal's palettes in the spec's order: a manifest's JSON object keeps none.
    static let paletteOrder: [String: [String]] = [
        "cat": ["ginger", "cream", "tuxedo"],
        "duck": ["yellow", "white", "mallard"],
        "dog": ["tan", "black-white", "cream"],
        "raccoon": ["grey", "brown", "silver"],
    ]

    /// The library's animals: the roster first, then any other alphabetically.
    static func animals(in library: PetLibrary) -> [String] {
        animalOrder.filter { library.manifests[$0] != nil }
            + library.animalIDs.filter { !animalOrder.contains($0) }
    }

    /// The pet's palettes: the table's first, then any other alphabetically.
    static func palettes(of manifest: PetManifest) -> [String] {
        let named = (paletteOrder[manifest.id] ?? []).filter { manifest.palettes[$0] != nil }
        return named + manifest.paletteNames.filter { !named.contains($0) }
    }

    /// `stored` when the library has it. An animal that lost the palette keeps its first one; an
    /// animal that is gone gives way to the first animal left, in that animal's first palette. Nil
    /// only with no pet to show.
    static func resolved(_ stored: PetChoice, in library: PetLibrary) -> PetChoice? {
        if let manifest = library.manifests[stored.animal] {
            if manifest.palettes[stored.palette] != nil { return stored }
            return palettes(of: manifest).first.map { PetChoice(animal: stored.animal, palette: $0) }
        }
        for animal in animals(in: library) {
            guard let manifest = library.manifests[animal], let palette = palettes(of: manifest).first else { continue }
            return PetChoice(animal: animal, palette: palette)
        }
        return nil
    }

    /// A palette's id as the picker prints it: "Ginger", "Black-white".
    static func paletteName(_ palette: String) -> String {
        palette.prefix(1).uppercased() + palette.dropFirst()
    }
}
