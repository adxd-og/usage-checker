import Combine
import CoreGraphics
import Foundation

/// The island's navigation between its controller and its content (notch-island spec 2026-10-29
/// § 3.4): the page, the move toward it as drawn now, and what the content measured for the
/// move (each tile's frame, each page's height, the lower row's height under each page). The
/// controller applies every input with its
/// clock and Reduce Motion — its own keys and swipe, and the content's tiles, logos and "‹ All"
/// through `onRequest` — and ticks the move on its frames. Without a controller (previews) a
/// request applies at once. It publishes only a frame that changed. The decisions are
/// `IslandNavigation`'s and `IslandDrill`'s.
@MainActor
final class IslandNavigationModel: ObservableObject {
    /// The move as drawn now; resting at the page when nothing moves.
    @Published private(set) var frame: IslandDrill.Frame = .resting(at: .all)

    /// The page shown or moved to: what `IslandNavigation` reduces from.
    var page: IslandNavigation.Page { drill.to }
    var isMoving: Bool { drill.isMoving }

    /// Each tile's frame in the content's stage, for the reveal (`IslandDrillLook`).
    private(set) var tileFrames: [String: CGRect] = [:]
    /// Each page's own height in the stage, for the height between two pages.
    private(set) var pageHeights: [IslandNavigation.Page: CGFloat] = [:]
    /// The lower row's own height under each page it last showed, for its height during a move
    /// (`IslandDrillLook.height`, `moveHeights`).
    private(set) var lowerRowHeights: [IslandNavigation.Page: CGFloat] = [:]
    /// The lower row's last measurement: its height ever since, whatever page it showed.
    private var lastLowerRowHeight: CGFloat?

    /// The controller's way in for the content's requests; nil in previews.
    var onRequest: (@MainActor (IslandNavigation.Input, [String]) -> Void)?

    private var drill = IslandDrill()

    /// A tile, a logo, "‹ All" or the providers changing, from the content: to the controller,
    /// or, with none, applied at once.
    func request(_ input: IslandNavigation.Input, providers: [String]) {
        if let onRequest {
            onRequest(input, providers)
            return
        }
        let left = drill.to
        let outcome = IslandNavigation.reduce(page, input, providers: providers)
        drill.reset(at: outcome.page)
        lowerRowLeaves(left)
        publish(at: 0)
    }

    /// Applies `input` at `now` over the providers on screen: an open lands at rest, any other
    /// move sets off with the look its move and Reduce Motion give it. Returns the action, for
    /// the controller to close the island on.
    @discardableResult
    func apply(
        _ input: IslandNavigation.Input, providers: [String], reduceMotion: Bool, at now: TimeInterval
    ) -> IslandNavigation.Action {
        let left = drill.to
        let outcome = IslandNavigation.reduce(page, input, providers: providers)
        if case .open = input {
            drill.reset(at: outcome.page)
        } else if case .go(let move) = outcome.action {
            drill.move(to: outcome.page, motion: IslandDrill.motion(for: move, reduceMotion: reduceMotion), at: now)
        }
        lowerRowLeaves(left)
        publish(at: now)
        return outcome.action
    }

    /// One frame of the controller's clock.
    func advance(to now: TimeInterval) {
        drill.advance(to: now)
        publish(at: now)
    }

    func record(tile id: String, frame: CGRect) {
        tileFrames[id] = frame
    }

    func record(page: IslandNavigation.Page, height: CGFloat) {
        pageHeights[page] = height
    }

    func record(lowerRow page: IslandNavigation.Page, height: CGFloat) {
        lowerRowHeights[page] = height
        lastLowerRowHeight = height
    }

    /// The lower row shows the destination; when that changes, the page it showed until now keeps
    /// the row's height as last measured — a page whose row laid out at the height the row already
    /// had brought no measurement of its own (Codex re-review finding 1).
    private func lowerRowLeaves(_ page: IslandNavigation.Page) {
        guard drill.to != page, let lastLowerRowHeight else { return }
        lowerRowHeights[page] = lastLowerRowHeight
    }

    private func publish(at now: TimeInterval) {
        let next = drill.frame(at: now)
        if next != frame { frame = next }
    }
}
