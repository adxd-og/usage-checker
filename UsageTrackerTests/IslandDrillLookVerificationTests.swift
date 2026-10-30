import SwiftUI
import XCTest
@testable import Omelette

/// Verifier pass for notch-island spec 2026-10-29 § 3.2 (Drill-down: the tile grows into the
/// page; no source tile → cross-fade + 8 pt slide; Interrupt: reverses from the current value;
/// Reduce Motion: cross-fade) and § 3.3 (the column's height): every quantity the content draws —
/// both layers' opacity, words, offsets, scale, clip rect and corner, the tile's surface, the
/// stage and the lower row's height, the strip's cross-fade, the tile hidden — is continuous
/// across a reversal at any moment of any kind of move, stays in its range at any progress
/// (overshoot included), and has the prototype's numbers at 0, 0.5 and 1.
final class IslandDrillLookVerificationTests: XCTestCase {
    private typealias Page = IslandNavigation.Page
    private typealias Look = IslandDrillLook
    private let claude = Page.provider("claude")
    private let codex = Page.provider("codex")
    private let four = ["claude", "codex", "antigravity", "grok"]
    private let tile = CGRect(x: 230, y: 0, width: 220, height: 120)
    private let size = CGSize(width: 450, height: 400)

    private func frame(_ from: Page, _ to: Page, _ motion: IslandDrill.Motion, _ progress: Double) -> IslandDrill.Frame {
        IslandDrill.Frame(from: from, to: to, motion: motion, progress: progress)
    }

    private func assertSameLayer(
        _ a: Look.Layer, _ b: Look.Layer, interactive: Bool, _ tag: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(a.opacity, b.opacity, accuracy: 1e-9, "opacity \(tag)", file: file, line: line)
        XCTAssertEqual(a.contentOpacity, b.contentOpacity, accuracy: 1e-9, "contentOpacity \(tag)", file: file, line: line)
        XCTAssertEqual(Double(a.contentOffsetY), Double(b.contentOffsetY), accuracy: 1e-9, "offset \(tag)", file: file, line: line)
        XCTAssertEqual(Double(a.scale), Double(b.scale), accuracy: 1e-9, "scale \(tag)", file: file, line: line)
        XCTAssertEqual(Double(a.anchor.x), Double(b.anchor.x), accuracy: 1e-9, "anchor \(tag)", file: file, line: line)
        XCTAssertEqual(Double(a.anchor.y), Double(b.anchor.y), accuracy: 1e-9, "anchor \(tag)", file: file, line: line)
        XCTAssertEqual(a.surfaceOpacity, b.surfaceOpacity, accuracy: 1e-9, "surface \(tag)", file: file, line: line)
        XCTAssertEqual(Double(a.clipRadius), Double(b.clipRadius), accuracy: 1e-9, "radius \(tag)", file: file, line: line)
        XCTAssertEqual(a.clip == nil, b.clip == nil, "clip presence \(tag)", file: file, line: line)
        if let x = a.clip, let y = b.clip {
            XCTAssertEqual(Double(x.minX), Double(y.minX), accuracy: 1e-6, "clip.x \(tag)", file: file, line: line)
            XCTAssertEqual(Double(x.minY), Double(y.minY), accuracy: 1e-6, "clip.y \(tag)", file: file, line: line)
            XCTAssertEqual(Double(x.width), Double(y.width), accuracy: 1e-6, "clip.w \(tag)", file: file, line: line)
            XCTAssertEqual(Double(x.height), Double(y.height), accuracy: 1e-6, "clip.h \(tag)", file: file, line: line)
        }
        if interactive { XCTAssertEqual(a.interactive, b.interactive, "interactive \(tag)", file: file, line: line) }
    }

    private struct Case {
        let name: String
        let from: IslandNavigation.Page
        let to: IslandNavigation.Page
        let motion: IslandDrill.Motion
        let tile: CGRect?
    }

    private var cases: [Case] {
        [
            Case(name: "drill", from: .all, to: codex, motion: .reveal, tile: tile),
            Case(name: "back", from: codex, to: .all, motion: .reveal, tile: tile),
            Case(name: "drill, tile unmeasured", from: .all, to: codex, motion: .reveal, tile: nil),
            Case(name: "shortcut", from: .all, to: codex, motion: .slide, tile: tile),
            Case(name: "sibling", from: claude, to: codex, motion: .slide, tile: nil),
            Case(name: "reduced", from: .all, to: codex, motion: .fade, tile: tile),
            Case(name: "reduced sibling", from: codex, to: claude, motion: .fade, tile: nil),
        ]
    }

    private func sizeOf(_ page: Page) -> CGSize {
        page == .all ? CGSize(width: 450, height: 250) : size
    }

    // MARK: Continuity across a reversal

    func testEveryDrawnQuantityIsContinuousAcrossAReversalAtEveryMoment() {
        // Page heights as the content measures them; the lower row's under each page.
        let stageHeight: [Page: CGFloat] = [.all: 250, codex: 400, claude: 330]
        let rowHeight: [Page: CGFloat] = [.all: 330, codex: 140, claude: 200]
        for c in cases {
            for step in 0...100 {
                let t = Double(step) * 0.006
                var drill = IslandDrill(at: c.from)
                drill.move(to: c.to, motion: c.motion, at: 0)
                var probe = drill
                probe.advance(to: t)
                guard probe.isMoving else { continue }
                let before = drill.frame(at: t)
                drill.move(to: c.from, motion: .reveal, at: t)
                let after = drill.frame(at: t)
                XCTAssertEqual(after.to, c.from)
                let tag = "\(c.name) at \(t) (progress \(before.progress))"
                let ambiguous = abs(before.progress - 0.5) < 1e-6

                for page in [c.from, c.to] {
                    assertSameLayer(
                        Look.layer(page, in: before, tile: c.tile, size: sizeOf(page)),
                        Look.layer(page, in: after, tile: c.tile, size: sizeOf(page)),
                        interactive: !ambiguous, "\(page) \(tag)"
                    )
                }
                XCTAssertEqual(Look.layers(before), Look.layers(after), "order \(tag)")
                XCTAssertEqual(Look.hiddenTile(before), Look.hiddenTile(after), "hidden tile \(tag)")
                XCTAssertEqual(Look.revealedProvider(before), Look.revealedProvider(after), "revealed \(tag)")
                if !ambiguous {
                    XCTAssertEqual(Look.shownPage(before), Look.shownPage(after), "shown \(tag)")
                }
                XCTAssertEqual(
                    Look.navigationOpacity(before, providers: four), Look.navigationOpacity(after, providers: four),
                    accuracy: 1e-9, "strip \(tag)"
                )
                // The stage and the lower row each have the same height before and after, whether
                // or not the pages are measured.
                for known in [true, false] {
                    // The page left not measured yet (in both frames, it is the same page): the
                    // other's height stands in for it, before and after.
                    func h(_ f: IslandDrill.Frame, _ table: [Page: CGFloat]) -> Double? {
                        var t = table
                        if !known { t[c.from] = nil }
                        return Look.height(f, from: t[f.from], to: t[f.to]).map(Double.init)
                    }
                    for table in [stageHeight, rowHeight] {
                        let x = h(before, table), y = h(after, table)
                        XCTAssertEqual(x == nil, y == nil, "height presence \(tag)")
                        if let x, let y { XCTAssertEqual(x, y, accuracy: 1e-9, "height \(tag) known \(known)") }
                    }
                }
                let b = Look.moveHeights(
                    before, stage: (stageHeight[before.from], stageHeight[before.to]),
                    lowerRow: (rowHeight[before.from], rowHeight[before.to])
                )
                let a = Look.moveHeights(
                    after, stage: (stageHeight[after.from], stageHeight[after.to]),
                    lowerRow: (rowHeight[after.from], rowHeight[after.to])
                )
                XCTAssertEqual(Double(a?.stageDrawn ?? -1), Double(b?.stageDrawn ?? -2), accuracy: 1e-9, "stage drawn \(tag)")
                XCTAssertEqual(Double(a?.lowerRowDrawn ?? -1), Double(b?.lowerRowDrawn ?? -2), accuracy: 1e-9, "row drawn \(tag)")
                XCTAssertEqual(Double(a?.stageAtRest ?? -1), Double(stageHeight[c.from]!), "the destination's stage at rest: \(tag)")
            }
        }
    }

    func testAChainOfReversalsNeverMovesAnyLayer() {
        for c in cases where c.motion != .fade {
            var drill = IslandDrill(at: c.from)
            drill.move(to: c.to, motion: c.motion, at: 0)
            var target = c.from
            var t = 0.0
            for hop in 0..<5 {
                t += 0.027
                var probe = drill
                probe.advance(to: t)
                guard probe.isMoving else { break }
                let before = drill.frame(at: t)
                drill.move(to: target, motion: .reveal, at: t)
                let after = drill.frame(at: t)
                for page in [c.from, c.to] {
                    assertSameLayer(
                        Look.layer(page, in: before, tile: c.tile, size: sizeOf(page)),
                        Look.layer(page, in: after, tile: c.tile, size: sizeOf(page)),
                        interactive: abs(before.progress - 0.5) > 1e-6, "\(c.name) hop \(hop) \(page)"
                    )
                }
                target = target == c.from ? c.to : c.from
            }
        }
    }

    // MARK: Ranges at any progress

    func testNoQuantityLeavesItsRangeAtAnyProgressOvershootIncluded() {
        for c in cases {
            for step in -20...130 {
                let p = Double(step) * 0.01
                let f = frame(c.from, c.to, c.motion, p)
                var interactive = 0
                for page in [c.from, c.to] {
                    let l = Look.layer(page, in: f, tile: c.tile, size: sizeOf(page))
                    let tag = "\(c.name) \(page) at \(p)"
                    XCTAssertTrue((0...1).contains(l.opacity), "opacity \(l.opacity) \(tag)")
                    XCTAssertTrue((0...1).contains(l.contentOpacity), "words \(l.contentOpacity) \(tag)")
                    XCTAssertTrue((0...1).contains(l.surfaceOpacity), "surface \(l.surfaceOpacity) \(tag)")
                    XCTAssertTrue((0...8.0000001).contains(Double(l.contentOffsetY)), "offset \(l.contentOffsetY) \(tag)")
                    XCTAssertTrue((0.97 - 1e-9...1).contains(Double(l.scale)), "scale \(l.scale) \(tag)")
                    XCTAssertTrue((0...18 + 1e-9).contains(Double(l.clipRadius)), "radius \(l.clipRadius) \(tag)")
                    if let clip = l.clip {
                        let whole = CGRect(origin: .zero, size: sizeOf(page))
                        XCTAssertTrue(whole.insetBy(dx: -1e-6, dy: -1e-6).contains(clip), "clip \(clip) \(tag)")
                    }
                    if l.interactive { interactive += 1 }
                }
                XCTAssertEqual(interactive, 1, "exactly one page takes clicks: \(c.name) at \(p)")
                XCTAssertTrue((0...1).contains(Look.navigationOpacity(f, providers: four)), "\(c.name) \(p)")
            }
        }
    }

    func testTheHeightIsNeverOutsideTheTwoPagesAtAnyProgress() {
        for p in stride(from: -0.3, through: 1.4, by: 0.05) {
            let f = frame(.all, codex, .reveal, p)
            let h = Double(Look.height(f, from: 250, to: 400)!)
            XCTAssertTrue((250...400).contains(h), "\(p) → \(h)")
            let g = Double(Look.height(frame(codex, .all, .reveal, p), from: 400, to: 250)!)
            XCTAssertTrue((250...400).contains(g), "\(p) → \(g)")
        }
        XCTAssertEqual(Double(Look.height(frame(.all, codex, .reveal, 0), from: 250, to: 400)!), 250)
        XCTAssertEqual(Double(Look.height(frame(.all, codex, .reveal, 1), from: 250, to: 400)!), 400)
        XCTAssertEqual(Double(Look.height(frame(.all, codex, .reveal, 0.5), from: 250, to: 400)!), 325)
        XCTAssertEqual(Double(Look.height(frame(.all, codex, .reveal, 0.5), from: nil, to: 400)!), 400, "unmeasured: the other's")
        XCTAssertEqual(Double(Look.height(frame(.all, codex, .reveal, 0.5), from: 250, to: nil)!), 250)
        XCTAssertNil(Look.height(frame(.all, codex, .reveal, 0.5), from: nil, to: nil))
        XCTAssertNil(Look.height(.resting(at: codex), from: 250, to: 400), "at rest: its own")
    }

    // MARK: The prototype's numbers

    func testADrillAtZeroHalfAndOne() {
        let atZero = frame(.all, codex, .reveal, 0)
        let all0 = Look.layer(.all, in: atZero, tile: tile, size: sizeOf(.all))
        XCTAssertEqual(all0.opacity, 1)
        XCTAssertEqual(Double(all0.scale), 1)
        XCTAssertTrue(all0.interactive)
        XCTAssertEqual(Double(all0.anchor.x), 340.0 / 450, accuracy: 1e-9, "All shrinks toward the tile's middle")
        XCTAssertEqual(Double(all0.anchor.y), 60.0 / 250, accuracy: 1e-9)
        let page0 = Look.layer(codex, in: atZero, tile: tile, size: size)
        XCTAssertEqual(page0.clip, tile, "the page starts as its tile")
        XCTAssertEqual(Double(page0.clipRadius), 18)
        XCTAssertEqual(page0.surfaceOpacity, 1)
        XCTAssertEqual(page0.contentOpacity, 0)
        XCTAssertEqual(Double(page0.contentOffsetY), 6)
        XCTAssertFalse(page0.interactive)
        XCTAssertNil(Look.hiddenTile(atZero))

        let atHalf = frame(.all, codex, .reveal, 0.5)
        let allHalf = Look.layer(.all, in: atHalf, tile: tile, size: sizeOf(.all))
        XCTAssertEqual(allHalf.opacity, 0.1, accuracy: 1e-9, "All is gone by 1 / 1.8")
        XCTAssertEqual(Double(allHalf.scale), 0.985, accuracy: 1e-9)
        let pageHalf = Look.layer(codex, in: atHalf, tile: tile, size: size)
        XCTAssertEqual(Double(pageHalf.clipRadius), 9, accuracy: 1e-9)
        XCTAssertEqual(pageHalf.surfaceOpacity, 0.5, accuracy: 1e-9)
        XCTAssertEqual(pageHalf.contentOpacity, 0.5, accuracy: 1e-9, "words from 0.25 over 0.5")
        XCTAssertEqual(Double(pageHalf.contentOffsetY), 3, accuracy: 1e-9)
        XCTAssertEqual(pageHalf.clip!.minX, 115, accuracy: 1e-9)
        XCTAssertEqual(pageHalf.clip!.width, 335, accuracy: 1e-9)
        XCTAssertEqual(pageHalf.clip!.height, 260, accuracy: 1e-9)
        XCTAssertTrue(pageHalf.interactive, "past half the page takes the clicks")
        XCTAssertEqual(Look.hiddenTile(atHalf), "codex")

        let atOne = frame(.all, codex, .reveal, 1)
        let all1 = Look.layer(.all, in: atOne, tile: tile, size: sizeOf(.all))
        XCTAssertEqual(all1.opacity, 0)
        XCTAssertEqual(Double(all1.scale), 0.97, accuracy: 1e-9)
        XCTAssertFalse(all1.interactive)
        let page1 = Look.layer(codex, in: atOne, tile: tile, size: size)
        XCTAssertEqual(page1.clip, CGRect(origin: .zero, size: size))
        XCTAssertEqual(Double(page1.clipRadius), 0)
        XCTAssertEqual(page1.surfaceOpacity, 0)
        XCTAssertEqual(page1.contentOpacity, 1)
        XCTAssertEqual(Double(page1.contentOffsetY), 0)
    }

    func testBackIsTheSameLooksPlayedBackward() {
        for p in stride(from: 0.0, through: 1.0, by: 0.1) {
            let drill = frame(.all, codex, .reveal, p)
            let back = frame(codex, .all, .reveal, 1 - p)
            for page in [Page.all, codex] {
                assertSameLayer(
                    Look.layer(page, in: drill, tile: tile, size: sizeOf(page)),
                    Look.layer(page, in: back, tile: tile, size: sizeOf(page)),
                    interactive: abs(p - 0.5) > 1e-6, "\(page) at \(p)"
                )
            }
        }
        // Back's own end: All whole, the page folded away into its tile with the tile drawn again.
        let end = frame(codex, .all, .reveal, 1)
        XCTAssertEqual(Look.layer(.all, in: end, tile: tile, size: sizeOf(.all)).opacity, 1)
        XCTAssertNil(Look.hiddenTile(end), "the tile is back")
        XCTAssertEqual(Look.layer(codex, in: end, tile: tile, size: size).clip, tile)
        XCTAssertFalse(Look.layer(codex, in: end, tile: tile, size: size).interactive)
    }

    func testASlideAndAFadeAtZeroHalfAndOne() {
        for (motion, rise) in [(IslandDrill.Motion.slide, 8.0), (.fade, 0.0)] {
            let start = frame(claude, codex, motion, 0)
            let old = Look.layer(claude, in: start, tile: nil, size: size)
            let new = Look.layer(codex, in: start, tile: nil, size: size)
            XCTAssertEqual(old.opacity, 1, "\(motion)")
            XCTAssertEqual(Double(old.contentOffsetY), 0)
            XCTAssertEqual(new.opacity, 0)
            XCTAssertEqual(Double(new.contentOffsetY), rise, "the incoming page starts \(rise) pt low")
            XCTAssertTrue(old.interactive)
            XCTAssertFalse(new.interactive)
            let mid = frame(claude, codex, motion, 0.5)
            let oldMid = Look.layer(claude, in: mid, tile: nil, size: size)
            let newMid = Look.layer(codex, in: mid, tile: nil, size: size)
            XCTAssertEqual(oldMid.opacity, 0.5)
            XCTAssertEqual(newMid.opacity, 0.5)
            XCTAssertEqual(Double(oldMid.contentOffsetY), rise / 2, accuracy: 1e-9, "the old one sinks as it fades")
            XCTAssertEqual(Double(newMid.contentOffsetY), rise / 2, accuracy: 1e-9)
            XCTAssertNil(oldMid.clip)
            XCTAssertNil(newMid.clip)
            XCTAssertEqual(Double(oldMid.scale), 1)
            XCTAssertNil(Look.hiddenTile(mid), "no tile is hidden for a move that grows from none")
            let end = frame(claude, codex, motion, 1)
            XCTAssertEqual(Look.layer(claude, in: end, tile: nil, size: size).opacity, 0)
            XCTAssertEqual(Look.layer(codex, in: end, tile: nil, size: size).opacity, 1)
            XCTAssertEqual(Double(Look.layer(codex, in: end, tile: nil, size: size).contentOffsetY), 0)
        }
    }

    func testAReduceMotionDrillFromAllCrossFadesWithoutAClipOrAHiddenTile() {
        for p in stride(from: 0.0, through: 1.0, by: 0.1) {
            let f = frame(.all, codex, .fade, p)
            for page in [Page.all, codex] {
                let l = Look.layer(page, in: f, tile: tile, size: sizeOf(page))
                XCTAssertNil(l.clip, "\(page) \(p)")
                XCTAssertEqual(Double(l.scale), 1)
                XCTAssertEqual(Double(l.contentOffsetY), 0)
                XCTAssertEqual(l.surfaceOpacity, 0)
            }
            XCTAssertNil(Look.hiddenTile(f))
            XCTAssertNil(Look.revealedProvider(f))
        }
    }

    // MARK: Shown page, layers, strip, lower row

    func testTheShownPageSwitchesAtHalf() {
        XCTAssertEqual(Look.shownPage(frame(.all, codex, .reveal, 0.4999)), .all)
        XCTAssertEqual(Look.shownPage(frame(.all, codex, .reveal, 0.5)), codex)
        XCTAssertEqual(Look.shownPage(frame(codex, .all, .reveal, 0.4999)), codex)
        XCTAssertEqual(Look.shownPage(frame(codex, .all, .reveal, 0.5)), .all)
        XCTAssertEqual(Look.shownPage(.resting(at: claude)), claude)
    }

    func testTheLowerRowShowsTheDestinationAtEveryProgress() {
        for p in stride(from: -0.2, through: 1.3, by: 0.05) {
            for c in cases {
                XCTAssertEqual(Look.lowerRowPage(frame(c.from, c.to, c.motion, p)), c.to, "\(c.name) \(p)")
            }
        }
    }

    func testTheStripShowsTheNavigationOnlyForAPageWithSiblings() {
        // To a page and back, with siblings: 0 → 1 over 0.3…0.8.
        XCTAssertEqual(Look.navigationOpacity(frame(.all, codex, .reveal, 0.3), providers: four), 0, accuracy: 1e-9)
        XCTAssertEqual(Look.navigationOpacity(frame(.all, codex, .reveal, 0.55), providers: four), 0.5, accuracy: 1e-9)
        XCTAssertEqual(Look.navigationOpacity(frame(.all, codex, .reveal, 0.8), providers: four), 1, accuracy: 1e-9)
        XCTAssertEqual(Look.navigationOpacity(frame(codex, .all, .reveal, 0.45), providers: four), 0.5, accuracy: 1e-9)
        XCTAssertEqual(Look.navigationOpacity(.resting(at: .all), providers: four), 0)
        XCTAssertEqual(Look.navigationOpacity(.resting(at: codex), providers: four), 1)
        // Sibling to sibling: the logos stay.
        for p in stride(from: 0.0, through: 1.0, by: 0.1) {
            XCTAssertEqual(Look.navigationOpacity(frame(claude, codex, .slide, p), providers: four), 1, "\(p)")
        }
        // One provider: never; a provider not on screen: never.
        for p in stride(from: 0.0, through: 1.0, by: 0.1) {
            XCTAssertEqual(Look.navigationOpacity(frame(.all, claude, .reveal, p), providers: ["claude"]), 0)
            XCTAssertEqual(Look.navigationOpacity(frame(.all, .provider("gone"), .fade, p), providers: four), 0)
        }
    }

    func testLayersAreAllUnderAPageAndProvidersInIdOrderWhateverTheDirection() {
        let grok = Page.provider("grok")
        for (a, b) in [(Page.all, claude), (.all, grok), (claude, codex), (grok, claude), (codex, grok)] {
            XCTAssertEqual(Look.layers(frame(a, b, .slide, 0.4)), Look.layers(frame(b, a, .slide, 0.6)), "\(a) \(b)")
        }
        XCTAssertEqual(Look.layers(frame(.all, grok, .reveal, 0.4)).first, .all)
        XCTAssertEqual(Look.layers(frame(grok, .all, .reveal, 0.4)).first, .all)
        XCTAssertEqual(Look.layers(frame(grok, claude, .slide, 0.4)), [claude, grok])
        XCTAssertEqual(Look.layers(frame(grok, claude, .slide, 0.4)).count, 2)
    }

    func testAMovesLastFrameDrawsTheRestingPage() {
        // The frame the move settles from draws what the resting frame draws: the page whole,
        // its clip (if any) the whole page, nothing of the page left.
        for c in cases {
            let last = frame(c.from, c.to, c.motion, 1)
            let rest = IslandDrill.Frame.resting(at: c.to)
            let a = Look.layer(c.to, in: last, tile: c.tile, size: sizeOf(c.to))
            let b = Look.layer(c.to, in: rest, tile: c.tile, size: sizeOf(c.to))
            XCTAssertEqual(a.opacity, b.opacity, c.name)
            XCTAssertEqual(a.contentOpacity, b.contentOpacity, c.name)
            XCTAssertEqual(Double(a.contentOffsetY), Double(b.contentOffsetY), c.name)
            XCTAssertEqual(Double(a.scale), Double(b.scale), c.name)
            XCTAssertEqual(a.surfaceOpacity, b.surfaceOpacity, c.name)
            XCTAssertEqual(Double(a.clipRadius), Double(b.clipRadius), c.name)
            if let clip = a.clip { XCTAssertEqual(clip, CGRect(origin: .zero, size: sizeOf(c.to)), c.name) }
            XCTAssertTrue(a.interactive, c.name)
            let left = Look.layer(c.from, in: last, tile: c.tile, size: sizeOf(c.from))
            XCTAssertFalse(left.interactive, c.name)
            if c.motion != .reveal || c.from == .all { XCTAssertEqual(left.opacity, 0, c.name) }
        }
    }
}
