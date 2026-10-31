import Combine
import CoreGraphics

/// The island's content frame on one display (notch-island spec 2026-10-29 § 3.3):
/// island or panel, its width, the strip beside the camera, and whether the habitat
/// column is there. Pure value.
struct IslandLayout: Equatable, Sendable {
    let kind: IslandDisplayResolver.Kind
    /// The body's width (`IslandPresentationRules.width`), island and panel alike.
    let bodyWidth: CGFloat
    /// The strip beside the camera, as tall as the notch; 0 for the panel.
    let stripHeight: CGFloat
    /// The camera the strip's two sides keep clear of; 0 for the panel.
    let notchWidth: CGFloat
    /// The habitat's column (§ 3.3, D12).
    let showsHabitat: Bool

    /// Before the first open, and in previews: a 640 pt panel without a habitat.
    static let unplaced = IslandLayout(
        kind: .panel, bodyWidth: IslandPresentationRules.regularWidth,
        stripHeight: 0, notchWidth: 0, showsHabitat: false
    )

    var columns: ProviderGridRules.Columns {
        ProviderGridRules.columns(bodyWidth: bodyWidth, showsHabitat: showsHabitat)
    }
}

extension IslandLayout {
    /// The layout on `screen`: the island where it has a notch, the panel elsewhere; the
    /// width and the habitat from `IslandPresentationRules`.
    init(on screen: IslandScreen, petOn: Bool) {
        let notch = screen.notchRect
        let presentation = IslandPresentationRules.presentation(
            notchPresent: notch != nil, screenWidth: screen.frame.width, petOn: petOn, earsOn: false
        )
        self.init(
            kind: notch != nil ? .island : .panel,
            bodyWidth: presentation.width,
            stripHeight: notch?.height ?? 0,
            notchWidth: notch?.width ?? 0,
            showsHabitat: presentation.showsHabitat
        )
    }
}

/// What the island's content needs from its controller and from its own measurements
/// (notch-island spec 2026-10-29 § 3.3): the layout for the display it opens on, the
/// agents list's cap, whether the right column scrolls and how tall it is on screen.
/// `IslandController` tells it the screen before each open and on every re-placement; the
/// content reports what it measured. It publishes only what moved, so a measurement that
/// changes nothing redraws nothing. One set of measurements for whatever the island
/// shows, kept for the app's life: every open after the first starts from the last one
/// (plan ruling R6). During a page move the rules read the destination as it will lay out at
/// rest (`IslandHeightRules.restingColumn`); the island shows the column as drawn (P3b plan
/// ruling R2). The arithmetic is `IslandHeightRules`'.
@MainActor
final class IslandLayoutModel: ObservableObject {
    /// Settings › Pet's switch, read at every placing (§ 3.7, D12): the controller hands it in. Pet
    /// off, the column goes and the island keeps its width.
    private let petOn: @MainActor () -> Bool

    init(petOn: @escaping @MainActor () -> Bool = { true }) {
        self.petOn = petOn
    }

    @Published private(set) var layout = IslandLayout.unplaced
    @Published private(set) var agentsListCap: CGFloat = AgentsSection.defaultMaxListHeight
    @Published private(set) var scrolls = false
    /// The right column's height on screen: its own, rounded up to a whole point, while it
    /// fits (so the scroll view around it has nothing to scroll, plan ruling R8); the budget
    /// while it scrolls; nil before it is first measured.
    @Published private(set) var rightColumnViewport: CGFloat?

    /// The right column's budget on the current display; nil before the first `place`.
    private(set) var rightBudget: CGFloat?
    private(set) var samples = IslandHeightRules.Samples()
    /// The page move drawn in the pass the right column was last measured in; nil at rest.
    private(set) var move: IslandHeightRules.MoveHeights?

    /// The display the island is about to open on, or was re-placed on.
    func place(on screen: IslandScreen, visibleHeight: CGFloat) {
        let next = IslandLayout(on: screen, petOn: petOn())
        if next != layout { layout = next }
        rightBudget = IslandHeightRules.rightColumnBudget(on: screen, screenVisibleHeight: visibleHeight)
        publish()
    }

    func record(rightColumn: CGFloat?) { update(\.rightColumn, rightColumn) }
    func record(agentsColumn: CGFloat?) { update(\.agentsColumn, agentsColumn) }
    func record(costTile: CGFloat?) { update(\.costTile, costTile) }
    func record(keepAwake: CGFloat?) { update(\.keepAwake, keepAwake) }

    /// The right column as drawn, with the move drawn in the same pass (nil at rest): the two
    /// arrive together, so the rules never pair a column with another pass's move.
    func record(rightColumn: CGFloat?, move: IslandHeightRules.MoveHeights?) {
        guard samples.rightColumn != rightColumn || self.move != move else { return }
        samples.rightColumn = rightColumn
        self.move = move
        publish()
    }

    /// The agents list's report; nil when it emptied or left.
    func record(list: AgentsListGeometry?) {
        guard samples.list != list else { return }
        samples.list = list
        publish()
    }

    private func update(_ key: WritableKeyPath<IslandHeightRules.Samples, CGFloat?>, _ value: CGFloat?) {
        guard samples[keyPath: key] != value else { return }
        samples[keyPath: key] = value
        publish()
    }

    /// Recomputes the outcome and assigns only what changed. During a move the rules read the
    /// destination as it will lay out at rest; the viewport below keeps the column as drawn.
    private func publish() {
        var laidOut = samples
        if let move, let drawn = samples.rightColumn {
            laidOut.rightColumn = IslandHeightRules.restingColumn(drawn: drawn, move: move, samples: samples)
        }
        let outcome = IslandHeightRules.outcome(rightBudget: rightBudget, samples: laidOut)
        if outcome.agentsListCap != agentsListCap { agentsListCap = outcome.agentsListCap }
        if outcome.scrolls != scrolls { scrolls = outcome.scrolls }
        let viewport = outcome.scrolls ? rightBudget : samples.rightColumn.map { $0.rounded(.up) }
        if viewport != rightColumnViewport { rightColumnViewport = viewport }
    }
}
