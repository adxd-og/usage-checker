import Combine
import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.4: the model between the island's controller and its
/// content — inputs applied through `IslandNavigation`, the move ticked on the controller's
/// clock (`IslandDrill`), every open starting at All and stopping any move, the content's
/// requests handed to the controller (applied at once without one), only what moved published,
/// the content's measurements kept for the reveal and the heights between two pages — a page's
/// lower row filed under it when the row leaves it, measured or not (Codex re-review finding 1).
@MainActor
final class IslandNavigationModelTests: XCTestCase {
    private let four = ["claude", "codex", "antigravity", "grok"]
    private let codex = IslandNavigation.Page.provider("codex")

    func testItStartsAtAllAtRest() {
        let model = IslandNavigationModel()
        XCTAssertEqual(model.page, .all)
        XCTAssertEqual(model.frame, .resting(at: .all))
        XCTAssertFalse(model.isMoving)
    }

    func testATileDrillsInAndTheFrameMovesUntilItSettles() {
        let model = IslandNavigationModel()
        XCTAssertEqual(model.apply(.tile("codex"), providers: four, reduceMotion: false, at: 10), .go(.drillFromTile))
        XCTAssertEqual(model.page, codex)
        XCTAssertTrue(model.isMoving)
        XCTAssertEqual(model.frame.motion, .reveal)
        XCTAssertEqual(model.frame.progress, 0, accuracy: 1e-12)
        model.advance(to: 10.1)
        XCTAssertEqual(model.frame.progress, IslandMotion.drill.value(target: 1.0, time: 0.1), accuracy: 1e-9)
        model.advance(to: 12)
        XCTAssertEqual(model.frame, .resting(at: codex))
        XCTAssertFalse(model.isMoving)
    }

    func testEscInAPageGoesBackAndEscAtAllCloses() {
        let model = IslandNavigationModel()
        model.apply(.tile("codex"), providers: four, reduceMotion: false, at: 0)
        model.advance(to: 2)
        XCTAssertEqual(model.apply(.escape, providers: four, reduceMotion: false, at: 3), .go(.back))
        XCTAssertEqual(model.page, .all)
        XCTAssertEqual(model.frame.motion, .reveal)
        model.advance(to: 5)
        XCTAssertEqual(model.apply(.escape, providers: four, reduceMotion: false, at: 6), .close)
        XCTAssertEqual(model.frame, .resting(at: .all))
    }

    func testEveryOpenStartsAtAllAndStopsAnyMove() {
        let model = IslandNavigationModel()
        model.apply(.tile("codex"), providers: four, reduceMotion: false, at: 0)
        model.apply(.open(subject: nil), providers: four, reduceMotion: false, at: 0.1)
        XCTAssertEqual(model.page, .all)
        XCTAssertEqual(model.frame, .resting(at: .all))
        XCTAssertFalse(model.isMoving)
    }

    func testAShortcutSlidesAndUnderReduceMotionEveryMoveFades() {
        let model = IslandNavigationModel()
        model.apply(.shortcut(2), providers: four, reduceMotion: false, at: 0)
        XCTAssertEqual(model.frame.motion, .slide)
        let reduced = IslandNavigationModel()
        reduced.apply(.tile("codex"), providers: four, reduceMotion: true, at: 0)
        XCTAssertEqual(reduced.frame.motion, .fade)
        reduced.advance(to: 0.15)
        XCTAssertEqual(reduced.frame, .resting(at: codex))
    }

    func testWithoutAControllerARequestAppliesAtOnce() {
        let model = IslandNavigationModel()
        model.request(.tile("codex"), providers: four)
        XCTAssertEqual(model.frame, .resting(at: codex))
        model.request(.back, providers: four)
        XCTAssertEqual(model.frame, .resting(at: .all))
    }

    func testWithAControllerARequestGoesToIt() {
        let model = IslandNavigationModel()
        var inputs: [IslandNavigation.Input] = []
        var lists: [[String]] = []
        model.onRequest = { input, providers in
            inputs.append(input)
            lists.append(providers)
        }
        model.request(.logo("grok"), providers: four)
        XCTAssertEqual(inputs, [.logo("grok")])
        XCTAssertEqual(lists, [four])
        XCTAssertEqual(model.page, .all, "the controller applies it, not the request")
    }

    func testAPassOrAStayPublishesNothing() {
        let model = IslandNavigationModel()
        var sends = 0
        let watch = model.objectWillChange.sink { _ in sends += 1 }
        model.apply(.shortcut(0), providers: four, reduceMotion: false, at: 0)
        model.apply(.back, providers: four, reduceMotion: false, at: 0)
        model.apply(.shortcut(7), providers: four, reduceMotion: false, at: 0)
        model.advance(to: 1)
        XCTAssertEqual(sends, 0)
        model.apply(.tile("codex"), providers: four, reduceMotion: false, at: 2)
        XCTAssertEqual(sends, 1)
        watch.cancel()
    }

    func testAPageWhoseLowerRowLaidOutAtTheSameHeightStillHasItForTheNextMove() {
        // Codex re-review finding 1: All's lower row and Claude's are both 330, so showing Claude's
        // brings no new measurement; the next move, from Claude, must still start at 330.
        let claude = IslandNavigation.Page.provider("claude")
        let grok = IslandNavigation.Page.provider("grok")
        let model = IslandNavigationModel()
        model.record(lowerRow: .all, height: 330)
        model.apply(.tile("claude"), providers: four, reduceMotion: false, at: 0)
        model.advance(to: 2)
        model.apply(.shortcut(4), providers: four, reduceMotion: false, at: 3)
        XCTAssertEqual(model.lowerRowHeights[claude], 330, "filed under Claude as the row left it")
        let start = model.frame
        XCTAssertEqual(start.from, claude)
        XCTAssertEqual(start.to, grok)
        XCTAssertEqual(start.progress, 0, accuracy: 1e-12)
        XCTAssertEqual(
            IslandDrillLook.height(start, from: model.lowerRowHeights[start.from], to: model.lowerRowHeights[start.to]),
            330, "the move starts from Claude's height"
        )
        model.record(lowerRow: grok, height: 140)
        XCTAssertEqual(model.lowerRowHeights[grok], 140)
        XCTAssertEqual(model.lowerRowHeights[claude], 330, "kept for the way back")
    }

    func testTheContentsMeasurementsAreKept() {
        let model = IslandNavigationModel()
        let tile = CGRect(x: 230, y: 1, width: 220, height: 120)
        model.record(tile: "codex", frame: tile)
        model.record(page: codex, height: 412)
        model.record(lowerRow: codex, height: 140)
        model.record(lowerRow: .all, height: 330)
        XCTAssertEqual(model.tileFrames["codex"], tile)
        XCTAssertEqual(model.pageHeights[codex], 412)
        XCTAssertEqual(model.lowerRowHeights[codex], 140)
        XCTAssertEqual(model.lowerRowHeights[.all], 330)
        XCTAssertNil(model.lowerRowHeights[.provider("grok")])
    }
}
