import CoreGraphics
import Foundation

/// What the habitat shows at one moment from the app's state: the mood's presentation and the
/// sky (notch-island spec 2026-10-29 § 3.3, § 3.5).
struct PetHabitatScene: Equatable, Sendable {
    let presentation: PetMoodPresentation
    let sky: PetSky
}

/// The habitat's geometry and its moment (notch-island spec 2026-10-29 § 3.3 "Left, 150 pt: the
/// habitat", § 3.5): which pet, its scale in the column, the floor it walks, where the sprite is
/// drawn, whether the pointer is over the content beside it, and the mood and sky at a given
/// time. The column draws no surface (owner 2026-10-30) and the pet always stands on its floor,
/// whatever the mood (owner 2026-10-30, P5c plan). Pure.
enum PetHabitatRules {
    /// The pet on the island until Settings › Pet lets the user choose (§ 3.5 Roster: the cat,
    /// ginger).
    static let animal = "cat"
    static let palette = "ginger"

    /// The mood line's size (§ 3.3 tokens: secondary 11.5).
    static let moodLineSize: CGFloat = 11.5
    /// At most two lines; a longer line truncates at its tail.
    static let moodLineLimit = 2
    /// The band the mood line keeps at the column's bottom whatever it says — two lines and the
    /// gap above them — so the floor never moves with the words.
    static let moodBand: CGFloat = 34

    /// The habitat's animation timeline counts from this fixed date, so a redraw never restarts
    /// the frame clock.
    static let timelineAnchor = Date(timeIntervalSinceReferenceDate: 0)

    /// The sprite's scale in the column on a display at `backingScale`: 3 px a bead at 2×
    /// (52.5 pt), 1 px at 1× (35 pt). The column's width is the box; its height never limits.
    static func scale(petBeads: Int, backingScale: CGFloat) -> PetScaleRules.Scale {
        PetScaleRules.scale(
            beads: petBeads,
            fitting: CGSize(width: ProviderGridRules.habitatWidth, height: .infinity),
            backingScale: backingScale
        )
    }

    /// The floor beside the pet in whole beads (`PetRuntime.tick`'s `roamBeads`): the column's
    /// width in beads less the pet's; 65 at 1.5 pt a bead, 115 at 1 pt.
    static func roamBeads(petBeads: Int, scale: PetScaleRules.Scale) -> Int {
        let across = Int((ProviderGridRules.habitatWidth / scale.pointsPerBead + 1e-6).rounded(.down))
        return max(0, across - petBeads)
    }

    /// Where the pet's feet are, in every mood: the floor at the column's bottom, above the mood
    /// line's band, never above the pet's own height.
    static func floorY(height: CGFloat, petSide: CGFloat) -> CGFloat {
        max(petSide, height - moodBand)
    }

    /// The whole beads between the floor and the column's top for a sprite of `petBeads`: what an
    /// event is fitted to when it starts (`PetEvent.fitted`).
    static func liftRoom(footY: CGFloat, petBeads: Int, scale: PetScaleRules.Scale) -> Int {
        max(0, Int(((footY - scale.points(beads: petBeads)) / scale.pointsPerBead + 1e-6).rounded(.down)))
    }

    /// The sprite's top-left corner: `xBeads` whole beads from the column's left edge, kept on the
    /// floor, its feet `yBeads` whole beads above `footY` (an event's lift), its top no higher than
    /// the column's, on the device-pixel grid.
    static func origin(
        xBeads: Int, yBeads: Int = 0, footY: CGFloat, petBeads: Int, roamBeads: Int, scale: PetScaleRules.Scale
    ) -> CGPoint {
        let x = scale.points(beads: min(max(xBeads, 0), max(roamBeads, 0)))
        let lift = min(max(yBeads, 0), liftRoom(footY: footY, petBeads: petBeads, scale: scale))
        let y = footY - scale.points(beads: petBeads + lift)
        return PetScaleRules.snapped(CGPoint(x: x, y: y), backingScale: scale.backingScale)
    }

    /// Where the right column starts in the content's coordinates: the island's padding, the
    /// habitat and the gap after it.
    static var contentColumnMinX: CGFloat {
        ProviderGridRules.padding + ProviderGridRules.habitatWidth + ProviderGridRules.habitatGap
    }

    /// The pointer is over the right column (§ 3.5 Runtime: no bit starts while it is): `point`
    /// in the content's coordinates, inside the content and right of the habitat.
    static func pointerOverContent(_ point: CGPoint, contentSize: CGSize) -> Bool {
        point.x >= contentColumnMinX && point.x <= contentSize.width
            && point.y >= 0 && point.y <= contentSize.height
    }

    /// The events the runtime may start: none until the pet shown is warm, so no event frame is
    /// missing when it plays (Codex's P5d plan review 4).
    static func playableEvents(_ events: [PetEvent], isWarm: Bool) -> [PetEvent] {
        isWarm ? events : []
    }

    /// The mood's presentation and the sky at `now`, the habitat's time-dependent parts in one
    /// place: read at every minute while the island is open, so keep awake's night and the moon
    /// turn on the minute with nothing else changing (Codex review 5).
    static func scene(
        _ input: PetMoodInput, petName: String, mode: PercentDisplay.Mode,
        now: Date, calendar: Calendar, locale: Locale
    ) -> PetHabitatScene {
        PetHabitatScene(
            presentation: PetMoodRules.presentation(
                of: PetMoodRules.mood(input, now: now, calendar: calendar),
                petName: petName, mode: mode, now: now, calendar: calendar, locale: locale
            ),
            sky: PetSkyRules.sky(at: now, calendar: calendar)
        )
    }
}
