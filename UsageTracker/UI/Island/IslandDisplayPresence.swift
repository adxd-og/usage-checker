import Combine

/// Whether a display shows the island, a notch or a virtual one, for the views that word themselves
/// on it: Settings › General's Show in menu bar, Settings › Pet's ears caption, onboarding's tip
/// (small backlog spec 2026-11-10 § A). The island's re-place points hand it every reading they place
/// on (`IslandController.placePills(on:)`), so a view never lists the windows on screen itself. An
/// unchanged answer is not assigned again, so it redraws nothing.
@MainActor
final class IslandDisplayPresence: ObservableObject {
    /// Starts from one reading of its own, for a view shown before the launch placement; the
    /// controller, made first at launch, places right after.
    static let shared = IslandDisplayPresence(screens: IslandScreen.current())

    @Published private(set) var islandDisplayAttached: Bool

    init(screens: [IslandScreen]) {
        islandDisplayAttached = StatusItemVisibilityRules.islandDisplayAttached(screens)
    }

    /// A re-place point placed the pills on this reading.
    func placed(on screens: [IslandScreen]) {
        let attached = StatusItemVisibilityRules.islandDisplayAttached(screens)
        if attached != islandDisplayAttached { islandDisplayAttached = attached }
    }
}
