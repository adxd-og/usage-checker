import Foundation

/// One animal in one palette in the picker (notch-island spec 2026-10-29 § 3.7).
struct PetPickerCell: Equatable, Sendable, Identifiable {
    let choice: PetChoice
    /// "Black-white".
    let paletteName: String
    /// "Dog, black-white".
    let accessibilityLabel: String
    let isSelected: Bool

    var id: PetChoice { choice }
}

/// One animal's palettes.
struct PetPickerColumn: Equatable, Sendable, Identifiable {
    let animal: String
    /// The manifest's name: "Dog".
    let name: String
    let cells: [PetPickerCell]

    var id: String { animal }
}

/// The picker Settings › Pet and onboarding share (§ 3.7): a grid of the animals in their palettes,
/// the selected cell alone looping, only under the gate. Pure.
enum PetPickerRules {
    /// `selected` is the pair as resolved (`PetChoiceRules.resolved`).
    static func columns(library: PetLibrary, selected: PetChoice) -> [PetPickerColumn] {
        PetChoiceRules.animals(in: library).compactMap { animal in
            guard let manifest = library.manifests[animal] else { return nil }
            return PetPickerColumn(
                animal: animal,
                name: manifest.name,
                cells: PetChoiceRules.palettes(of: manifest).map { palette in
                    let choice = PetChoice(animal: animal, palette: palette)
                    return PetPickerCell(
                        choice: choice,
                        paletteName: PetChoiceRules.paletteName(palette),
                        accessibilityLabel: "\(manifest.name), \(palette)",
                        isSelected: choice == selected
                    )
                }
            )
        }
    }

    /// Only the selected one, only under the gate, not with the pet off.
    static func loops(_ cell: PetPickerCell, gateOn: Bool, petOn: Bool) -> Bool {
        cell.isSelected && gateOn && petOn
    }

    /// The frame of a looping preview at `date`: the animation at its own rate, on a fixed clock.
    static func frameName(of animation: PetAnimation, at date: Date) -> String {
        let count = animation.frames.count
        let step = Int((date.timeIntervalSinceReferenceDate * animation.fps).rounded(.down))
        return animation.frames[((step % count) + count) % count]
    }
}
