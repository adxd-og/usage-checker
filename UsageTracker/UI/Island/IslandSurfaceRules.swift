/// What sits under the island's content (notch-island spec 2026-10-29 § 3.1, Appearance):
/// the island is the notch grown, always opaque black; the panel's content draws its own
/// body, and under Reduce Transparency the panel gets an opaque window-background fill
/// beneath it, so no glass the content draws ever shows the desktop through. Pure.
enum IslandSurfaceRules {
    enum Backing: Equatable, Sendable {
        /// The island's black shape, moving with the motion.
        case black
        /// An opaque fill in the panel's body: the system's window background.
        case windowBackground
        /// Nothing: the content's own surface is the panel.
        case contentsOwn
    }

    static func backing(kind: IslandDisplayResolver.Kind, reduceTransparency: Bool) -> Backing {
        switch kind {
        case .island: return .black
        case .panel: return reduceTransparency ? .windowBackground : .contentsOwn
        }
    }
}
