import CoreGraphics

/// What the island is on one display (notch-island spec 2026-10-29 § 3.1 Presentation,
/// § 3.9, D12): its width, and whether it has the pet's habitat, the ears and the
/// ear-to-habitat morph. One output, so the four never disagree. Pure.
enum IslandPresentationRules {
    struct Presentation: Equatable, Sendable {
        /// The open body's width in points, island or panel.
        let width: CGFloat
        /// The habitat column (§ 3.3): needs the pet on and a screen 1420 pt or wider (D12).
        let showsHabitat: Bool
        /// The ears beside the notch (§ 3.6): only where there is a notch, only when on.
        let showsEars: Bool
        /// An ear's head morphs into the habitat pet on an ear open (§ 3.6): needs both.
        let morphEligible: Bool
    }

    static let regularWidth: CGFloat = 640
    static let wideWidth: CGFloat = 720
    static let narrowWidth: CGFloat = 560
    /// From this screen width on, the island is `wideWidth`.
    static let wideScreenWidth: CGFloat = 1700
    /// Below this screen width, the island is `narrowWidth` and has no habitat (D12).
    static let habitatScreenWidth: CGFloat = 1420

    /// 720 on a screen 1700 pt or wider, 560 below 1420, 640 between.
    static func width(screenWidth: CGFloat) -> CGFloat {
        if screenWidth >= wideScreenWidth { return wideWidth }
        if screenWidth < habitatScreenWidth { return narrowWidth }
        return regularWidth
    }

    static func presentation(notchPresent: Bool, screenWidth: CGFloat, petOn: Bool, earsOn: Bool) -> Presentation {
        let habitat = petOn && screenWidth >= habitatScreenWidth
        let ears = notchPresent && earsOn
        return Presentation(
            width: width(screenWidth: screenWidth),
            showsHabitat: habitat,
            showsEars: ears,
            morphEligible: ears && habitat
        )
    }
}
