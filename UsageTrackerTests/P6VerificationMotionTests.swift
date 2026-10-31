import SwiftUI
import XCTest
@testable import Omelette

/// Tester's verification of P6, motion and geometry (notch-island spec 2026-10-29 § 3.1 Notch hint, D13,
/// § 3.6 Ears, § 3.8): the hint on a long random walk of pointer events, the resting window's rects on
/// every notch and ear combination, and the ear's morph over time.
final class P6VerificationNotchHintTests: XCTestCase {
    /// A small deterministic generator, so a failure replays.
    private struct Lcg {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    /// The controller's way of using the value: one wait per arrival, cancelled by a leave; frames
    /// until `needsFrames` is false. On every step the value must stay sane, a hint at rest draws
    /// nothing, and far enough ahead it settles exactly where it is going.
    func testALongWalkOfPointerEventsKeepsTheHintSaneAndSettlesExactly() {
        for seed in 1...40 {
            var random = Lcg(state: UInt64(seed))
            var hint = NotchHint()
            var now: TimeInterval = 1_000
            var waitingSince: TimeInterval?
            var upByReduceMotion = false
            for step in 0..<400 {
                let context = "seed \(seed) step \(step)"
                now += Double(random.next(30)) / 100
                switch random.next(7) {
                case 0:
                    if hint.pointerEntered() { waitingSince = now }
                case 1:
                    waitingSince = nil
                    hint.pointerLeft(at: now)
                case 2:
                    if let since = waitingSince, now - since >= IslandMotion.hintDelay {
                        let reduce = random.next(4) == 0
                        let closed = random.next(5) != 0
                        let wasUp = hint.isUp
                        hint.delayElapsed(at: now, islandClosed: closed, reduceMotion: reduce)
                        waitingSince = nil
                        if !wasUp && hint.isUp { upByReduceMotion = reduce }
                    }
                case 3:
                    hint.end()
                    waitingSince = nil
                case 4:
                    hint.advance(to: now)
                default:
                    break
                }
                let look = hint.look(at: now)
                XCTAssertTrue(look.down.isFinite && look.widen.isFinite, context)
                XCTAssertGreaterThanOrEqual(look.down, 0, context)
                XCTAssertGreaterThanOrEqual(look.widen, 0, context)
                XCTAssertLessThanOrEqual(look.down, IslandMotion.hintDown * 1.2, context)
                XCTAssertLessThanOrEqual(look.widen, IslandMotion.hintWiden * 1.2, context)
                if hint.isAtRest {
                    XCTAssertEqual(look, NotchHint.Look.rest, "at rest nothing is drawn: \(context)")
                    XCTAssertFalse(hint.needsFrames, context)
                }
                if hint.needsFrames { XCTAssertFalse(hint.isAtRest, "frames wanted means not at rest: \(context)") }
                if hint.isUp { XCTAssertTrue(hint.pointerInside, "a hint up has a pointer on it: \(context)") }
                if look.outlined { XCTAssertTrue(hint.isUp, "an outline only with the hint up: \(context)") }

                // Far enough ahead, the frames stop and the value is exact, not nearly.
                var later = hint
                later.advance(to: now + 100)
                XCTAssertFalse(later.needsFrames, "frames can stop: \(context)")
                let settled = later.look(at: now + 100)
                if later.isUp, !upByReduceMotion {
                    XCTAssertEqual(settled.down, IslandMotion.hintDown, context)
                    XCTAssertEqual(settled.widen, IslandMotion.hintWiden, context)
                } else if !later.isUp {
                    XCTAssertTrue(later.isAtRest, context)
                    XCTAssertEqual(settled, NotchHint.Look.rest, context)
                }
            }
        }
    }

    /// A clock that steps back (a wall clock set, a frame time ahead of the event) moves nothing early.
    func testATimeBeforeTheStartIsTheStartingValueAndSettlesNothing() {
        var hint = NotchHint()
        _ = hint.pointerEntered()
        hint.delayElapsed(at: 100, islandClosed: true, reduceMotion: false)
        XCTAssertEqual(hint.look(at: 50), NotchHint.Look.rest, "before its start it has not moved")
        hint.advance(to: 50)
        XCTAssertTrue(hint.needsFrames, "an earlier frame does not stop the spring")
        XCTAssertFalse(hint.isAtRest)
        hint.advance(to: 100.0001)
        XCTAssertTrue(hint.needsFrames, "a frame just after the start has not settled it")
    }

    func testEnteringTwiceThenLeavingOnceThenEnteringAsksOnceMoreAndReduceMotionNeverMoves() {
        var hint = NotchHint()
        XCTAssertTrue(hint.pointerEntered())
        XCTAssertFalse(hint.pointerEntered())
        hint.pointerLeft(at: 1)
        XCTAssertTrue(hint.pointerEntered())
        hint.delayElapsed(at: 2, islandClosed: true, reduceMotion: true)
        for time in stride(from: 2.0, through: 5.0, by: 0.1) {
            XCTAssertEqual(hint.look(at: time), NotchHint.Look(down: 0, widen: 0, outlined: true), "\(time)")
            XCTAssertFalse(hint.needsFrames)
        }
    }

    /// The outline is the whole of Reduce Motion's hint: after a motion hint was up and the setting turned
    /// on, a re-hover shows the outline only.
    func testAHintReachedAfterAMotionHintAndALeaveWithReduceMotionIsOnlyAnOutline() {
        var hint = NotchHint()
        _ = hint.pointerEntered()
        hint.delayElapsed(at: 10, islandClosed: true, reduceMotion: false)
        hint.pointerLeft(at: 12)
        hint.advance(to: 20)
        XCTAssertTrue(hint.isAtRest)
        XCTAssertTrue(hint.pointerEntered())
        hint.delayElapsed(at: 21, islandClosed: true, reduceMotion: true)
        XCTAssertEqual(hint.look(at: 22), NotchHint.Look(down: 0, widen: 0, outlined: true))
    }
}

/// § 3.1 Notch hint, § 3.6: the resting window and its rects, on the notches of the fixtures and on
/// fractional ones, with every combination of ears and the hint's room.
final class P6VerificationRestingLayoutTests: XCTestCase {
    private func notches() -> [(name: String, notch: CGRect, screen: CGRect)] {
        [
            ("builtIn", ScreenFixture.builtIn.notchRect!, ScreenFixture.builtIn.frame),
            ("narrow", ScreenFixture.narrowNotched.notchRect!, ScreenFixture.narrowNotched.frame),
            ("fractional", CGRect(x: 721.25, y: 868.5, width: 177.75, height: 37.5), CGRect(x: 0, y: 0, width: 1620.25, height: 906)),
            ("negative x", CGRect(x: -1500.5, y: 950, width: 185, height: 32), CGRect(x: -2160, y: 0, width: 1512, height: 982)),
        ]
    }

    private func contains(_ outer: CGRect, _ inner: CGRect, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let slack: CGFloat = 0.0001
        XCTAssertGreaterThanOrEqual(inner.minX, outer.minX - slack, message, file: file, line: line)
        XCTAssertGreaterThanOrEqual(inner.minY, outer.minY - slack, message, file: file, line: line)
        XCTAssertLessThanOrEqual(inner.maxX, outer.maxX + slack, message, file: file, line: line)
        XCTAssertLessThanOrEqual(inner.maxY, outer.maxY + slack, message, file: file, line: line)
    }

    func testEveryNotchAndEveryCombinationKeepsItsRectsInsideTheWindowAndTheWindowInsideTheScreen() {
        let tips = [CGSize(width: 24, height: 4.5), CGSize(width: 16, height: 5), CGSize(width: 24, height: 5)]
        for (name, notch, screen) in notches() {
            for left in [false, true] {
                for right in [false, true] {
                    for room in [false, true] {
                        let context = "\(name) left:\(left) right:\(right) room:\(room)"
                        let frame = RestingLayout.frame(notch: notch, left: left, right: right, hintRoom: room)
                        XCTAssertEqual(frame.minX, frame.minX.rounded(), context)
                        XCTAssertEqual(frame.maxX, frame.maxX.rounded(), context)
                        XCTAssertEqual(frame.minY, frame.minY.rounded(), context)
                        XCTAssertEqual(frame.maxY, frame.maxY.rounded(), context)
                        // Not above the screen's top edge, nor off its sides.
                        contains(screen.insetBy(dx: -0.0, dy: -1), frame, "window on the screen: \(context)")

                        let layout = RestingLayout(notch: notch, left: left, right: right, appliedFrame: frame)
                        let bounds = CGRect(origin: .zero, size: frame.size)
                        contains(bounds, layout.notch, "notch: \(context)")
                        XCTAssertEqual(layout.notch.size, notch.size, context)
                        XCTAssertEqual(layout.leftEar != nil, left, context)
                        XCTAssertEqual(layout.rightEar != nil, right, context)
                        if let ear = layout.leftEar {
                            contains(bounds, ear, "left ear: \(context)")
                            XCTAssertEqual(ear.maxX, layout.notch.minX, accuracy: 0.0001, "attached: \(context)")
                            XCTAssertEqual(ear.height, notch.height, context)
                            XCTAssertEqual(ear.width, IslandEarRules.earWidth, context)
                        }
                        if let ear = layout.rightEar {
                            contains(bounds, ear, "right ear: \(context)")
                            XCTAssertEqual(ear.minX, layout.notch.maxX, accuracy: 0.0001, "attached: \(context)")
                            XCTAssertEqual(ear.height, notch.height, context)
                        }

                        // The tracked rect at rest is the notch and shares no area with an ear.
                        let rest = layout.trackedRect(hintUp: false)
                        XCTAssertEqual(rest, layout.notch, context)
                        for ear in [layout.leftEar, layout.rightEar].compactMap({ $0 }) {
                            let overlap = rest.intersection(ear)
                            XCTAssertTrue(overlap.isNull || overlap.width * overlap.height == 0, "hovering an ear does not breathe: \(context)")
                        }

                        // The shape at rest is inside the window; with the room, the breath is too.
                        contains(bounds, layout.shape().boundingRect, "shape: \(context)")
                        XCTAssertFalse(layout.shape().contains(CGPoint(x: layout.notch.midX, y: layout.notch.maxY + 1)), "nothing under the notch at rest: \(context)")
                        if room {
                            let up = NotchHint.Look(down: IslandMotion.hintDown, widen: IslandMotion.hintWiden, outlined: false)
                            contains(bounds, layout.shape(up).boundingRect, "the breath has its room: \(context)")
                            contains(bounds, layout.trackedRect(hintUp: true), "tracked while up: \(context)")
                            contains(bounds, layout.outline().boundingRect, "outline: \(context)")
                            for size in tips {
                                contains(bounds, layout.tipsRect(size: size, look: up), "tips \(size): \(context)")
                            }
                        }
                    }
                }
            }
        }
    }

    func testTheRoomOnlyEverGrowsTheWindowAndNeverMovesTheNotchOffItsTop() {
        for (name, notch, _) in notches() {
            let bare = RestingLayout.frame(notch: notch, left: true, right: true, hintRoom: false)
            let roomy = RestingLayout.frame(notch: notch, left: true, right: true, hintRoom: true)
            contains(roomy, bare, name)
            XCTAssertEqual(roomy.maxY, bare.maxY, "the top edge stays on the screen's edge: \(name)")
            let layout = RestingLayout(notch: notch, left: true, right: true, appliedFrame: roomy)
            XCTAssertEqual(layout.notch.minY, 0, accuracy: 0.0001, name)
        }
    }

    func testTheShapeHoldsEachEarShownAndNoOther() throws {
        for (name, notch, _) in notches() {
            for (left, right) in [(true, false), (false, true), (true, true), (false, false)] {
                let frame = RestingLayout.frame(notch: notch, left: left, right: right, hintRoom: false)
                let layout = RestingLayout(notch: notch, left: left, right: right, appliedFrame: frame)
                let shape = layout.shape()
                let mid = layout.notch.midY
                XCTAssertTrue(shape.contains(CGPoint(x: layout.notch.midX, y: mid)), name)
                XCTAssertEqual(shape.contains(CGPoint(x: layout.notch.minX - 17, y: mid)), left, "left ear: \(name)")
                XCTAssertEqual(shape.contains(CGPoint(x: layout.notch.maxX + 17, y: mid)), right, "right ear: \(name)")
                XCTAssertFalse(shape.contains(CGPoint(x: layout.notch.minX - 36, y: mid)), "beyond the ear: \(name)")
                XCTAssertFalse(shape.contains(CGPoint(x: layout.notch.maxX + 36, y: mid)), "beyond the ear: \(name)")
            }
        }
    }

    func testTheTipsAreWholeBeadsThatFitTheBreathAtEveryScale() throws {
        let head = try XCTUnwrap(PetCharMap(rows: PetFixture.rows(side: 16, beads: [(3, 0, "o"), (4, 1, "o")]), side: 16))
        for backing in [1.0, 1.5, 2.0, 3.0] as [CGFloat] {
            for pixels in 1...5 {
                let scale = PetScaleRules.Scale(pixelsPerBead: pixels, backingScale: backing)
                guard let tips = PetEarTips.tips(of: head, band: IslandMotion.hintDown, scale: scale) else {
                    XCTAssertGreaterThan(scale.pointsPerBead, IslandMotion.hintDown, "no whole bead fits only when beads exceed the band: \(pixels)@\(backing)")
                    continue
                }
                XCTAssertLessThanOrEqual(tips.size.height, IslandMotion.hintDown + 0.000_001, "\(pixels)@\(backing)")
                XCTAssertEqual(tips.crop.height, CGFloat(Int(tips.crop.height / CGFloat(pixels)) * pixels), "whole beads: \(pixels)@\(backing)")
                XCTAssertEqual(tips.size.height, tips.crop.height / backing, accuracy: 0.000_001, "\(pixels)@\(backing)")
            }
        }
    }
}

/// § 3.6: the head's 180 ms into the habitat pet, in time.
final class P6VerificationEarMorphTests: XCTestCase {
    private let from = CGRect(x: 180, y: 4, width: 24, height: 24)
    private let to = CGRect(x: 129, y: 657.5, width: 52.5, height: 52.5)

    func testOverItsWholeLifeItOnlyMovesTowardThePetAndFades() throws {
        let morph = IslandEarMorph(start: 10, from: from, to: to)
        var previous: IslandEarMorph.Frame?
        var sawEnd = false
        for step in stride(from: 9.0, through: 10.3, by: 0.0025) {
            guard let frame = morph.frame(at: step) else {
                sawEnd = true
                XCTAssertGreaterThanOrEqual(step, 10 + IslandEarMorph.duration - 1e-9, "ends exactly at its duration, not before: \(step)")
                continue
            }
            XCTAssertFalse(sawEnd, "no frame once it is over: \(step)")
            XCTAssertGreaterThanOrEqual(frame.opacity, 0, "\(step)")
            XCTAssertLessThanOrEqual(frame.opacity, 1, "\(step)")
            if step <= 10 + IslandMotion.contentDelay { XCTAssertEqual(frame.opacity, 1, accuracy: 1e-6, "opaque until the content starts: \(step)") }
            if let previous {
                XCTAssertLessThanOrEqual(frame.opacity, previous.opacity + 1e-12, "never brighter again: \(step)")
                XCTAssertLessThanOrEqual(frame.rect.minX, previous.rect.minX + 1e-9, "x moves toward the pet: \(step)")
                XCTAssertGreaterThanOrEqual(frame.rect.minY, previous.rect.minY - 1e-9, "y moves toward the pet: \(step)")
                XCTAssertGreaterThanOrEqual(frame.rect.width, previous.rect.width - 1e-9, "it only grows: \(step)")
            }
            XCTAssertGreaterThanOrEqual(frame.rect.minX, to.minX - 1e-9, "no overshoot past the pet: \(step)")
            XCTAssertLessThanOrEqual(frame.rect.maxY, to.maxY + 1e-9, "no overshoot past the pet: \(step)")
            previous = frame
        }
        XCTAssertTrue(sawEnd)
    }

    /// The head hides while the morph carries it, so the frames must outlast it: the island's own open
    /// keeps asking for frames far beyond 180 ms, and the morph's last frame comes before the content is in.
    func testTheIslandsOwnFramesOutlastTheMorphSoTheHeadIsAlwaysGivenBack() {
        var transition = IslandTransition()
        transition.open(style: .spring, at: 100)
        for offset in stride(from: 0.0, through: IslandEarMorph.duration + 0.02, by: 0.01) {
            transition.advance(to: 100 + offset)
            XCTAssertTrue(transition.needsFrames, "frames still run at +\(offset) s")
            XCTAssertEqual(transition.phase, .opening, "+\(offset) s")
        }
    }

    @MainActor
    func testTheModelGivesTheImageBackAtEveryEnd() {
        let morph = IslandEarMorph(start: 10, from: from, to: to)
        let model = IslandEarMorphModel()
        XCTAssertFalse(model.advance(to: 10), "nothing started")
        model.start(morph, image: nil, backingScale: 2)
        XCTAssertTrue(model.advance(to: 9), "a frame time before the start is the start")
        XCTAssertEqual(model.frame?.rect, from)
        model.start(IslandEarMorph(start: 20, from: from, to: to), image: nil, backingScale: 2)
        XCTAssertEqual(model.frame?.rect, from, "a newer morph replaces the older at once")
        XCTAssertFalse(model.advance(to: 20.2))
        XCTAssertNil(model.frame)
        XCTAssertNil(model.image)
    }

    func testAnEarWithNoCoverageOfAnythingMorphsToItselfWithoutDividingByZero() throws {
        let morph = IslandEarMorph(start: 0, from: from, to: from)
        let frame = try XCTUnwrap(morph.frame(at: 0.09))
        XCTAssertEqual(frame.rect, from)
        XCTAssertTrue(frame.opacity.isFinite)
    }
}
