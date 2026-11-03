import CoreGraphics

/// The resting pills (spec 2026-11-03 § Resting pill): one panel per display that carries an island
/// notch, physical or virtual, keyed by display id, made and dropped at the controller's re-place
/// points (screen change, wake, lid open). Pure: `IslandController` applies it.
enum RestingPillRules {
    struct Pill: Equatable, Sendable {
        let displayID: UInt32
        /// The notch the pill covers, global coordinates.
        let notch: CGRect
    }

    /// One pill per display with an island notch, in the displays' order.
    static func pills(_ screens: [IslandScreen]) -> [Pill] {
        screens.compactMap { screen in
            screen.islandNotch.map { Pill(displayID: screen.id, notch: $0) }
        }
    }

    struct Changes: Equatable, Sendable {
        /// Displays that gained an island: a panel is made for each, in `wanted`'s order.
        let create: [UInt32]
        /// Displays that lost theirs or went away: their panels go, in id order.
        let drop: [UInt32]
    }

    /// What the panels kept so far need to become `wanted`.
    static func changes(kept: Set<UInt32>, wanted: [Pill]) -> Changes {
        let ids = wanted.map(\.displayID)
        return Changes(
            create: ids.filter { !kept.contains($0) },
            drop: kept.subtracting(ids).sorted()
        )
    }
}
