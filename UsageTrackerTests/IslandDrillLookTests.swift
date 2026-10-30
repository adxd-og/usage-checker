import SwiftUI
import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.2 (Drill-down, Interrupt) with prototype v9's numbers: the
/// page shows through a rect growing from its tile (corner 18 → 0) over the tile's surface,
/// which fades as it grows; its words come in from a quarter of the way to three quarters,
/// rising 6 pt; All fades out early and shrinks 3 % toward the tile; Back is the same
/// backwards; without a tile the pages cross-fade, the old one sinking and the new one rising
/// 8 pt; Reduce Motion only cross-fades. Exactly one page takes clicks at any moment; All is
/// drawn under the page; a reversal changes nothing on screen (Codex review finding 4); the
/// stage and the lower row go from one page's height to the other's, the lower row showing the
/// destination throughout, so the column never jumps (finding 3); the strip's ‹ All and logos
/// come in late.
final class IslandDrillLookTests: XCTestCase {
    private let claude = IslandNavigation.Page.provider("claude")
    private let codex = IslandNavigation.Page.provider("codex")
    private let four = ["claude", "codex", "antigravity", "grok"]
    /// Codex's tile, right in the first row of a 450 pt grid.
    private let tile = CGRect(x: 230, y: 0, width: 220, height: 120)
    private let page = CGSize(width: 450, height: 400)
    private let all = CGSize(width: 450, height: 250)

    private func frame(
        _ from: IslandNavigation.Page, _ to: IslandNavigation.Page, _ motion: IslandDrill.Motion, _ progress: Double
    ) -> IslandDrill.Frame {
        IslandDrill.Frame(from: from, to: to, motion: motion, progress: progress)
    }

    /// Two looks of one layer draw it in the same place, at the same strength.
    private func assertSame(_ a: IslandDrillLook.Layer, _ b: IslandDrillLook.Layer, _ message: String) {
        XCTAssertEqual(a.opacity, b.opacity, accuracy: 1e-9, message)
        XCTAssertEqual(a.contentOpacity, b.contentOpacity, accuracy: 1e-9, message)
        XCTAssertEqual(Double(a.contentOffsetY), Double(b.contentOffsetY), accuracy: 1e-9, message)
        XCTAssertEqual(Double(a.scale), Double(b.scale), accuracy: 1e-9, message)
        XCTAssertEqual(a.surfaceOpacity, b.surfaceOpacity, accuracy: 1e-9, message)
        XCTAssertEqual(Double(a.clipRadius), Double(b.clipRadius), accuracy: 1e-9, message)
        XCTAssertEqual(a.clip == nil, b.clip == nil, message)
        if let x = a.clip, let y = b.clip {
            XCTAssertEqual(Double(x.minX), Double(y.minX), accuracy: 1e-6, message)
            XCTAssertEqual(Double(x.minY), Double(y.minY), accuracy: 1e-6, message)
            XCTAssertEqual(Double(x.width), Double(y.width), accuracy: 1e-6, message)
            XCTAssertEqual(Double(x.height), Double(y.height), accuracy: 1e-6, message)
        }
        XCTAssertEqual(a.interactive, b.interactive, message)
    }

    func testAtRestThePageIsDrawnWholeAndAloneAtItsOwnHeight() {
        let rest = IslandDrill.Frame.resting(at: codex)
        XCTAssertEqual(IslandDrillLook.layer(codex, in: rest, tile: tile, size: page), .whole)
        XCTAssertEqual(IslandDrillLook.layer(.all, in: rest, tile: tile, size: all).opacity, 0)
        XCTAssertFalse(IslandDrillLook.layer(.all, in: rest, tile: tile, size: all).interactive)
        XCTAssertNil(IslandDrillLook.height(rest, from: 400, to: 400))
        XCTAssertNil(IslandDrillLook.hiddenTile(rest))
        XCTAssertEqual(IslandDrillLook.shownPage(rest), codex)
    }

    func testAtTheStartOfADrillThePageIsTheTile() {
        let start = frame(.all, codex, .reveal, 0)
        let look = IslandDrillLook.layer(codex, in: start, tile: tile, size: page)
        XCTAssertEqual(look.clip, tile)
        XCTAssertEqual(look.clipRadius, 18)
        XCTAssertEqual(look.surfaceOpacity, 1)
        XCTAssertEqual(look.contentOpacity, 0)
        XCTAssertEqual(look.contentOffsetY, 6)
        XCTAssertFalse(look.interactive)
        let allLook = IslandDrillLook.layer(.all, in: start, tile: tile, size: all)
        XCTAssertEqual(allLook.opacity, 1)
        XCTAssertEqual(allLook.scale, 1)
        XCTAssertTrue(allLook.interactive)
        XCTAssertNil(IslandDrillLook.hiddenTile(start), "the tile is still itself")
    }

    func testHalfwayTheTileHasGrownHalfwayAndThePageTakesOver() {
        let half = frame(.all, codex, .reveal, 0.5)
        let look = IslandDrillLook.layer(codex, in: half, tile: tile, size: page)
        XCTAssertEqual(look.clip, CGRect(x: 115, y: 0, width: 335, height: 260))
        XCTAssertEqual(look.clipRadius, 9)
        XCTAssertEqual(look.surfaceOpacity, 0.5)
        XCTAssertEqual(look.contentOpacity, 0.5)
        XCTAssertEqual(look.contentOffsetY, 3)
        XCTAssertTrue(look.interactive)
        let allLook = IslandDrillLook.layer(.all, in: half, tile: tile, size: all)
        XCTAssertEqual(allLook.opacity, 0.1, accuracy: 1e-12)
        XCTAssertEqual(Double(allLook.scale), 0.985, accuracy: 1e-12)
        XCTAssertEqual(Double(allLook.anchor.x), 340.0 / 450.0, accuracy: 1e-12)
        XCTAssertEqual(Double(allLook.anchor.y), 60.0 / 250.0, accuracy: 1e-12)
        XCTAssertFalse(allLook.interactive)
        XCTAssertEqual(IslandDrillLook.hiddenTile(half), "codex")
        XCTAssertEqual(IslandDrillLook.shownPage(half), codex)
    }

    func testPastTheEndTheOvershootIsHeldAtTheWholePage() {
        let over = frame(.all, codex, .reveal, 1.004)
        let look = IslandDrillLook.layer(codex, in: over, tile: tile, size: page)
        XCTAssertEqual(look.clip, CGRect(origin: .zero, size: page))
        XCTAssertEqual(look.clipRadius, 0)
        XCTAssertEqual(look.surfaceOpacity, 0)
        XCTAssertEqual(look.contentOpacity, 1)
        XCTAssertEqual(look.contentOffsetY, 0)
        XCTAssertEqual(IslandDrillLook.height(over, from: 250, to: 400), 400)
    }

    func testBackIsTheDrillBackwardsIntoTheSameTile() {
        let back = frame(codex, .all, .reveal, 0.25)
        let look = IslandDrillLook.layer(codex, in: back, tile: tile, size: page)
        XCTAssertEqual(look.clip, CGRect(x: 57.5, y: 0, width: 392.5, height: 330))
        XCTAssertEqual(look.clipRadius, 4.5)
        XCTAssertTrue(look.interactive, "a quarter of the way back, the page is still the one shown")
        XCTAssertEqual(IslandDrillLook.layer(.all, in: back, tile: tile, size: all).opacity, 0)
        XCTAssertEqual(IslandDrillLook.revealedProvider(back), "codex")
        XCTAssertEqual(IslandDrillLook.shownPage(frame(codex, .all, .reveal, 0.5)), .all)
    }

    func testWithoutAMeasuredTileThePageFadesInWhereItIs() {
        let look = IslandDrillLook.layer(codex, in: frame(.all, codex, .reveal, 0.4), tile: nil, size: page)
        XCTAssertNil(look.clip)
        XCTAssertEqual(look.opacity, 0.4, accuracy: 1e-12)
        XCTAssertEqual(look.contentOpacity, 1)
    }

    func testWithoutATileThePagesCrossFadeTheOldOneSinkingAndTheNewOneRising() {
        let slide = frame(claude, codex, .slide, 0.25)
        let leaving = IslandDrillLook.layer(claude, in: slide, tile: nil, size: page)
        let coming = IslandDrillLook.layer(codex, in: slide, tile: nil, size: page)
        XCTAssertEqual(leaving.opacity, 0.75)
        XCTAssertEqual(leaving.contentOffsetY, 2, "a quarter of the 8 pt down")
        XCTAssertTrue(leaving.interactive)
        XCTAssertEqual(coming.opacity, 0.25)
        XCTAssertEqual(coming.contentOffsetY, 6)
        XCTAssertFalse(coming.interactive)
        XCTAssertNil(coming.clip)
        XCTAssertNil(IslandDrillLook.hiddenTile(slide))
    }

    func testUnderReduceMotionThePagesOnlyCrossFade() {
        let fade = frame(.all, codex, .fade, 0.6)
        let coming = IslandDrillLook.layer(codex, in: fade, tile: tile, size: page)
        XCTAssertEqual(coming.opacity, 0.6, accuracy: 1e-12)
        XCTAssertEqual(coming.contentOffsetY, 0)
        XCTAssertNil(coming.clip)
        XCTAssertEqual(coming.scale, 1)
        XCTAssertTrue(coming.interactive)
        XCTAssertEqual(IslandDrillLook.layer(.all, in: fade, tile: tile, size: all).opacity, 0.4, accuracy: 1e-12)
        XCTAssertNil(IslandDrillLook.hiddenTile(fade))
    }

    func testTheHeightGoesFromOnePagesToTheOthers() {
        XCTAssertEqual(IslandDrillLook.height(frame(.all, codex, .reveal, 0.25), from: 300, to: 500), 350)
        XCTAssertEqual(IslandDrillLook.height(frame(codex, .all, .reveal, 0.25), from: 500, to: 300), 450)
        XCTAssertEqual(IslandDrillLook.height(frame(.all, codex, .reveal, 0.25), from: 300, to: nil), 300, "not measured yet")
        XCTAssertEqual(IslandDrillLook.height(frame(.all, codex, .reveal, 0.25), from: nil, to: 500), 500)
        XCTAssertNil(IslandDrillLook.height(frame(.all, codex, .reveal, 0.25), from: nil, to: nil))
        XCTAssertEqual(IslandDrillLook.height(frame(.all, codex, .reveal, -0.1), from: 300, to: 500), 300)
    }

    func testTheStripTurnsToAllAndTheLogosLateInTheMove() {
        XCTAssertEqual(IslandDrillLook.navigationOpacity(.resting(at: .all), providers: four), 0)
        XCTAssertEqual(IslandDrillLook.navigationOpacity(.resting(at: codex), providers: four), 1)
        XCTAssertEqual(IslandDrillLook.navigationOpacity(frame(.all, codex, .reveal, 0.3), providers: four), 0)
        XCTAssertEqual(IslandDrillLook.navigationOpacity(frame(.all, codex, .reveal, 0.55), providers: four), 0.5, accuracy: 1e-12)
        XCTAssertEqual(IslandDrillLook.navigationOpacity(frame(.all, codex, .reveal, 0.8), providers: four), 1, accuracy: 1e-12)
        XCTAssertEqual(IslandDrillLook.navigationOpacity(frame(claude, codex, .slide, 0.5), providers: four), 1)
        XCTAssertEqual(IslandDrillLook.navigationOpacity(frame(codex, .all, .reveal, 0.45), providers: four), 0.5, accuracy: 1e-12)
    }

    func testTheOnlyProvidersPageKeepsTheTitleStrip() {
        XCTAssertEqual(IslandDrillLook.navigationOpacity(.resting(at: .provider("grok")), providers: ["grok"]), 0)
    }

    func testExactlyOnePageTakesClicksAtEveryMoment() {
        for motion in [IslandDrill.Motion.reveal, .slide, .fade] {
            for step in 0...20 {
                let moment = frame(.all, codex, motion, Double(step) / 20)
                let allTakes = IslandDrillLook.layer(.all, in: moment, tile: tile, size: all).interactive
                let pageTakes = IslandDrillLook.layer(codex, in: moment, tile: tile, size: page).interactive
                XCTAssertNotEqual(allTakes, pageTakes, "\(motion) at \(step)")
            }
        }
    }

    func testAllIsDrawnUnderThePageEitherWayAndTwoPagesInIdOrder() {
        XCTAssertEqual(IslandDrillLook.layers(frame(.all, codex, .reveal, 0.3)), [.all, codex])
        XCTAssertEqual(IslandDrillLook.layers(frame(codex, .all, .reveal, 0.3)), [.all, codex])
        XCTAssertEqual(IslandDrillLook.layers(frame(claude, codex, .slide, 0.3)), [claude, codex])
        XCTAssertEqual(IslandDrillLook.layers(frame(codex, claude, .slide, 0.3)), [claude, codex], "a reversal keeps the order")
        XCTAssertEqual(IslandDrillLook.layers(.resting(at: codex)), [codex])
    }

    func testReversingASlideMovesNeitherPage() {
        var drill = IslandDrill(at: claude)
        drill.move(to: codex, motion: .slide, at: 0)
        let before = drill.frame(at: 0.1)
        drill.move(to: claude, motion: .slide, at: 0.1)
        let after = drill.frame(at: 0.1)
        XCTAssertEqual(after.to, claude, "turned around")
        for side in [claude, codex] {
            assertSame(
                IslandDrillLook.layer(side, in: before, tile: nil, size: page),
                IslandDrillLook.layer(side, in: after, tile: nil, size: page),
                "\(side)"
            )
        }
        XCTAssertEqual(IslandDrillLook.layers(before), IslandDrillLook.layers(after))
        XCTAssertEqual(IslandDrillLook.shownPage(before), IslandDrillLook.shownPage(after))
    }

    func testReversingADrillMovesNeitherLayer() {
        var drill = IslandDrill(at: .all)
        drill.move(to: codex, motion: .reveal, at: 0)
        let before = drill.frame(at: 0.1)
        drill.move(to: .all, motion: .reveal, at: 0.1)
        let after = drill.frame(at: 0.1)
        XCTAssertEqual(after.to, .all, "turned around")
        assertSame(
            IslandDrillLook.layer(.all, in: before, tile: tile, size: all),
            IslandDrillLook.layer(.all, in: after, tile: tile, size: all),
            "All"
        )
        assertSame(
            IslandDrillLook.layer(codex, in: before, tile: tile, size: page),
            IslandDrillLook.layer(codex, in: after, tile: tile, size: page),
            "Codex"
        )
        XCTAssertEqual(IslandDrillLook.hiddenTile(before), IslandDrillLook.hiddenTile(after))
        XCTAssertEqual(IslandDrillLook.layers(before), IslandDrillLook.layers(after))
        XCTAssertEqual(
            Double(IslandDrillLook.height(before, from: 250, to: 400)!),
            Double(IslandDrillLook.height(after, from: 400, to: 250)!),
            accuracy: 1e-9
        )
    }

    func testTheLowerRowShowsTheDestinationForTheWholeMove() {
        let grok = IslandNavigation.Page.provider("grok")
        for progress in [0.0, 0.2, 0.499, 0.501, 0.8, 1.0] {
            XCTAssertEqual(IslandDrillLook.lowerRowPage(frame(.all, grok, .reveal, progress)), grok, "\(progress)")
        }
        XCTAssertEqual(IslandDrillLook.lowerRowPage(.resting(at: .all)), .all)
    }

    func testTheColumnsHeightNeverJumpsWhenTheLowerRowSwitches() {
        // All: tiles 250 over agents | cost + keep awake 330. Grok: its page 300 over keep awake
        // alone 140. The stage and the lower row each go from one page's height to the other's.
        let grok = IslandNavigation.Page.provider("grok")
        func column(_ moment: IslandDrill.Frame, upper: (CGFloat, CGFloat), lower: (CGFloat, CGFloat)) -> Double {
            let stage = IslandDrillLook.height(moment, from: upper.0, to: upper.1) ?? 0
            let row = IslandDrillLook.height(moment, from: lower.0, to: lower.1) ?? 0
            return Double(stage + ProviderGridRules.gap + row)
        }
        let drill = (upper: (CGFloat(250), CGFloat(300)), lower: (CGFloat(330), CGFloat(140)))
        XCTAssertEqual(column(frame(.all, grok, .reveal, 0), upper: drill.upper, lower: drill.lower), 250 + 10 + 330)
        XCTAssertEqual(column(frame(.all, grok, .reveal, 1), upper: drill.upper, lower: drill.lower), 300 + 10 + 140)
        let justBefore = column(frame(.all, grok, .reveal, 0.499), upper: drill.upper, lower: drill.lower)
        let justAfter = column(frame(.all, grok, .reveal, 0.501), upper: drill.upper, lower: drill.lower)
        XCTAssertEqual(justAfter - justBefore, (50 - 190) * 0.002, accuracy: 1e-6, "no jump at the midpoint")
        // Turned around a third of the way: the same column, the two pages' heights swapped.
        XCTAssertEqual(
            column(frame(.all, grok, .reveal, 0.3), upper: drill.upper, lower: drill.lower),
            column(frame(grok, .all, .reveal, 0.7), upper: (300, 250), lower: (140, 330)),
            accuracy: 1e-9
        )
    }

    func testTheHeightRulesGetTheMoveAsDrawnAndTheDestinationsStage() {
        let grok = IslandNavigation.Page.provider("grok")
        let quarter = frame(.all, grok, .reveal, 0.25)
        // Stage 250 + 50 × 0.25; lower row 330 − 190 × 0.25; Grok's stage at rest 300.
        XCTAssertEqual(
            IslandDrillLook.moveHeights(quarter, stage: (250, 300), lowerRow: (330, 140)),
            IslandHeightRules.MoveHeights(stageDrawn: 262.5, stageAtRest: 300, lowerRowDrawn: 282.5)
        )
        XCTAssertNil(IslandDrillLook.moveHeights(.resting(at: grok), stage: (300, 300), lowerRow: (140, 140)), "at rest")
        XCTAssertEqual(
            IslandDrillLook.moveHeights(quarter, stage: (250, nil), lowerRow: (330, nil)),
            IslandHeightRules.MoveHeights(stageDrawn: 250, stageAtRest: 250, lowerRowDrawn: 330),
            "the destination not measured yet: the page left stands in"
        )
        XCTAssertNil(IslandDrillLook.moveHeights(quarter, stage: (nil, nil), lowerRow: (330, 140)), "no stage height to draw at")
    }
}
