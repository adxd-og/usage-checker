import SwiftUI
import XCTest
@testable import Omelette

/// Verification of `IslandTransition` against notch-island spec 2026-10-29 § 3.2 (Interrupt:
/// reverses from the current value, a stale completion never revives closing content) and
/// § 3.9 (content hit-testable and exposed to accessibility only in the `open` state), and the
/// plan's M1, M4, M8, M10, M13: an interrupt at many points of the open and the close keeps
/// the shape's value and speed, every completion belongs to the open or close that made it,
/// the entrance is never short-cut by a late first frame, and what the island is at a time
/// does not depend on which frames came.
final class IslandTransitionVerificationTests: XCTestCase {
    private let h = 1e-5

    /// Forward slope of the shape at `time`, in progress per second.
    private func slope(_ t: IslandTransition, at time: TimeInterval) -> Double {
        (t.progress(at: time + h) - t.progress(at: time)) / h
    }

    /// An island opened at 0 and shown every frame (1/100 s) until `until`.
    private func opening(until: TimeInterval, style: IslandMotion.Style = .spring) -> IslandTransition {
        var t = IslandTransition()
        t.open(style: style, at: 0)
        var time = 0.0
        while time < until - 1e-9 {
            t.advance(to: time)
            time += 0.01
        }
        t.advance(to: until)
        return t
    }

    /// An island that has been open and at rest since 1: closed at 2, frames every 1/100 s.
    private func closing(until: TimeInterval) -> IslandTransition {
        var t = opening(until: 1)
        t.advance(to: 1.5)
        t.close(style: .spring, at: 2)
        var time = 2.0
        while time < until - 1e-9 {
            t.advance(to: time)
            time += 0.01
        }
        t.advance(to: until)
        return t
    }

    // MARK: Interrupt: value and speed are continuous

    func testACloseAtAnyPointOfTheOpenKeepsTheShapesValueAndSpeed() {
        for step in 0...70 {
            let time = Double(step) * 0.01
            var t = opening(until: time)
            let value = t.progress(at: time)
            let speed = slope(t, at: time)
            t.close(style: .spring, at: time)
            XCTAssertEqual(t.progress(at: time), value, accuracy: 1e-9, "value at \(time)")
            XCTAssertEqual(slope(t, at: time), speed, accuracy: 0.01, "speed at \(time)")
        }
    }

    func testAReopenAtAnyPointOfTheCloseKeepsTheShapesValueAndSpeed() {
        // The content fades 2.0 ..< 2.1, the shape shrinks from 2.1 and is back at about 2.705.
        for step in 0...70 {
            let time = 2.0 + Double(step) * 0.01
            var t = closing(until: time)
            XCTAssertEqual(t.phase, .closing, "\(time)")
            let value = t.progress(at: time)
            let speed = slope(t, at: time)
            t.open(style: .spring, at: time)
            XCTAssertEqual(t.phase, .opening, "\(time)")
            XCTAssertEqual(t.progress(at: time), value, accuracy: 1e-9, "value at \(time)")
            XCTAssertEqual(slope(t, at: time), speed, accuracy: 0.01, "speed at \(time)")
        }
    }

    func testReopeningAtTheShrinksEndStartsAfreshFromTheNotch() {
        var t = closing(until: 2.7)
        t.advance(to: 2.8)
        XCTAssertEqual(t.phase, .closed)
        t.open(style: .spring, at: 2.8)
        t.advance(to: 2.8)
        XCTAssertEqual(t.phase, .opening)
        XCTAssertEqual(t.progress(at: 2.8), 0, accuracy: 1e-9)
        XCTAssertFalse(t.stage.contentShown, "a fresh open waits its head start again")
    }

    func testAPingPongOfOpensAndClosesNeverJumpsAndAlwaysSettles() {
        var t = IslandTransition()
        var time = 0.0
        var opensNext = true
        for _ in 0..<60 {
            t.advance(to: time)
            let before = t.progress(at: time)
            if opensNext {
                t.open(style: .spring, at: time)
            } else {
                t.close(style: .spring, at: time)
            }
            if t.phase != .closed {
                XCTAssertEqual(t.progress(at: time), before, accuracy: 1e-9, "no jump at \(time)")
            }
            XCTAssertGreaterThan(t.progress(at: time + 0.02), -0.05)
            XCTAssertLessThan(t.progress(at: time + 0.02), 1.2)
            opensNext.toggle()
            time += 0.037
        }
        t.advance(to: time)
        t.open(style: .spring, at: time)
        t.advance(to: time + 0.2)
        t.advance(to: time + 0.7)
        t.advance(to: time + 1.5)
        XCTAssertEqual(t.phase, .open)
        XCTAssertTrue(t.stage.interactive)
        XCTAssertEqual(t.progress(at: time + 1.5), 1, accuracy: 1e-9)
        XCTAssertFalse(t.needsFrames)
    }

    // MARK: Stale completions

    func testAnOpenDoneFromBeforeACloseAndReopenNeverMakesTheReopenedIslandInteractive() {
        var t = IslandTransition()
        t.open(style: .spring, at: 0)
        t.advance(to: 0)
        t.advance(to: 0.125)  // the content's fade began: the old entrance would end at 0.405
        t.close(style: .spring, at: 0.2)
        t.open(style: .spring, at: 0.25)
        t.advance(to: 0.25)  // the shape never left: the content comes back now, in until 0.53
        for time in [0.3, 0.41, 0.5, 0.52] {
            t.advance(to: time)
            XCTAssertFalse(t.stage.interactive, "\(time)")
            XCTAssertEqual(t.phase, .opening, "\(time)")
        }
        t.advance(to: 0.54)
        XCTAssertEqual(t.phase, .open)
        XCTAssertTrue(t.stage.interactive)
    }

    func testAPanelsFadeOutDoneFromBeforeAReopenNeverClosesTheReopenedPanel() {
        var t = IslandTransition()
        t.open(style: .contentOnly, at: 0)
        t.advance(to: 0)
        t.advance(to: 0.5)
        t.close(style: .contentOnly, at: 1)  // would be closed at 1.1
        t.open(style: .contentOnly, at: 1.05)
        for time in [1.05, 1.1, 1.2, 1.4] {
            t.advance(to: time)
            XCTAssertNotEqual(t.phase, .closed, "\(time)")
        }
        XCTAssertEqual(t.phase, .open)
        XCTAssertTrue(t.stage.interactive)
        XCTAssertTrue(t.stage.contentShown)
    }

    func testACrossFadeDoneFromBeforeAReopenNeverClosesTheReopenedIsland() {
        var t = opening(until: 1, style: .crossFade)
        t.advance(to: 1.5)
        t.close(style: .crossFade, at: 2)  // closed at 2.15
        t.open(style: .crossFade, at: 2.1)
        t.advance(to: 2.1)
        for time in [2.14, 2.16, 2.2, 2.3] {
            t.advance(to: time)
            XCTAssertNotEqual(t.phase, .closed, "\(time)")
        }
        XCTAssertEqual(t.phase, .open)
    }

    func testAShrinkDueAfterAReopenIsNeverApplied() {
        var t = opening(until: 1)
        t.advance(to: 1.5)
        t.close(style: .spring, at: 2)  // the shape would set off at 2.1
        t.open(style: .spring, at: 2.05)
        for time in [2.05, 2.1, 2.11, 2.3, 3] {
            t.advance(to: time)
            XCTAssertEqual(t.progress(at: time), 1, accuracy: 1e-9, "the shape stays open at \(time)")
        }
        XCTAssertEqual(t.phase, .open)
    }

    func testAnIslandOpenedWithOneMotionAndClosedWithAnotherStillCloses() {
        // Reduce Motion switched on or off while the island is open applies to the next close.
        let pairs: [(IslandMotion.Style, IslandMotion.Style)] = [
            (.crossFade, .spring), (.spring, .crossFade), (.contentOnly, .crossFade), (.crossFade, .contentOnly),
        ]
        for (openStyle, closeStyle) in pairs {
            var t = opening(until: 1, style: openStyle)
            t.advance(to: 1.5)
            t.close(style: closeStyle, at: 2)
            XCTAssertFalse(t.stage.interactive, "\(openStyle) -> \(closeStyle)")
            t.advance(to: 2.05)
            t.advance(to: 5)
            XCTAssertEqual(t.phase, .closed, "\(openStyle) -> \(closeStyle)")
            XCTAssertEqual(t.stage, .closed, "\(openStyle) -> \(closeStyle)")
            XCTAssertFalse(t.needsFrames)
        }
    }

    func testAnIslandClosedByCrossFadeAndReopenedBySpringEndsOpenAndInteractive() {
        var t = IslandTransition()
        t.open(style: .spring, at: 0)
        t.advance(to: 0.05)
        t.close(style: .crossFade, at: 0.05)
        t.open(style: .spring, at: 0.1)
        for step in 0...150 {
            t.advance(to: 0.1 + Double(step) * 0.01)
        }
        XCTAssertEqual(t.phase, .open)
        XCTAssertTrue(t.stage.interactive)
        XCTAssertTrue(t.stage.islandShown)
        XCTAssertEqual(t.progress(at: 1.6), 1, accuracy: 1e-9)
    }

    // MARK: Interactive only after the entrance

    func testTheIslandIsInteractiveExactlyWhenOpenAndOnlyAfterTheContentsEntranceWhateverFrameCameFirst() {
        let entrances: [(IslandMotion.Style, Double)] = [(.spring, 0.28), (.contentOnly, 0.28), (.crossFade, 0.15)]
        for (style, entrance) in entrances {
            for firstFrame in [0.0, 0.03, 0.119, 0.12, 0.2, 0.3, 0.7, 2.0, 30.0] {
                var t = IslandTransition()
                t.open(style: style, at: 0)
                var time = firstFrame
                var fadeBegan: TimeInterval?
                var interactiveSince: TimeInterval?
                while time < firstFrame + 3 {
                    t.advance(to: time)
                    XCTAssertEqual(t.stage.interactive, t.phase == .open, "\(style) first \(firstFrame) at \(time)")
                    if t.stage.contentShown, fadeBegan == nil { fadeBegan = time }
                    if t.stage.interactive {
                        XCTAssertTrue(t.stage.contentShown, "\(style) first \(firstFrame) at \(time)")
                        if interactiveSince == nil { interactiveSince = time }
                    }
                    time += 1.0 / 60
                }
                guard let began = fadeBegan, let since = interactiveSince else {
                    XCTFail("\(style) first frame \(firstFrame): never became interactive")
                    continue
                }
                XCTAssertGreaterThanOrEqual(
                    since - began, entrance - 1e-9,
                    "\(style) first frame \(firstFrame): interactive \(since - began) s after the fade began"
                )
                XCTAssertLessThan(since - began, entrance + 0.05, "\(style) first frame \(firstFrame)")
            }
        }
    }

    func testOneFrameMuchLaterShowsTheContentAndWaitsItsWholeEntranceAfterThat() {
        // The displays slept through the whole open: the first frame comes at 30 s.
        var t = IslandTransition()
        t.open(style: .spring, at: 0)
        t.advance(to: 30)
        XCTAssertTrue(t.stage.contentShown)
        XCTAssertFalse(t.stage.interactive)
        XCTAssertEqual(t.phase, .opening)
        t.advance(to: 30.27)
        XCTAssertFalse(t.stage.interactive)
        t.advance(to: 30.29)
        XCTAssertTrue(t.stage.interactive)
        XCTAssertEqual(t.progress(at: 30.29), 1, accuracy: 1e-9, "the shape settled while nobody looked")
        XCTAssertFalse(t.needsFrames)
    }

    // MARK: Rest thresholds (M10)

    func testTheOpenShapeNeedsFramesUntilAboutSixTenthsAfterTheOpenAndThenNone() {
        let early = opening(until: 0.59)
        XCTAssertTrue(early.needsFrames, "still settling at 0.59")
        let late = opening(until: 0.64)
        XCTAssertFalse(late.needsFrames, "at rest by 0.64 (rest from 0.625)")
        XCTAssertEqual(late.progress(at: 0.64), 1)
    }

    func testACloseIsDoneAboutSevenTenthsAfterItsStartAndNotBefore() {
        // 0.1 s of content fade, then the critically damped shrink, at rest from 0.605 s on.
        let beforeEnd = closing(until: 2.68)
        XCTAssertEqual(beforeEnd.phase, .closing)
        XCTAssertTrue(beforeEnd.needsFrames)
        let afterEnd = closing(until: 2.73)
        XCTAssertEqual(afterEnd.phase, .closed)
        XCTAssertFalse(afterEnd.needsFrames)
        XCTAssertEqual(afterEnd.progress(at: 2.73), 0)
    }

    // MARK: The answer depends on the times, not on the frames

    private enum Event {
        case open(IslandMotion.Style, TimeInterval)
        case close(IslandMotion.Style, TimeInterval)
        var time: TimeInterval {
            switch self {
            case .open(_, let time), .close(_, let time): return time
            }
        }
    }

    /// Runs `events` with `frames` delivered between them every `interval` (nil: never), and
    /// returns what the island was right after each event plus its far-future state.
    private func run(
        _ events: [Event], frameEvery interval: TimeInterval?
    ) -> (afterEach: [(isOpen: Bool, shown: Bool, progress: Double)], final: IslandTransition) {
        var t = IslandTransition()
        var afterEach: [(isOpen: Bool, shown: Bool, progress: Double)] = []
        var clock = 0.0
        for event in events {
            if let interval {
                while clock + interval < event.time {
                    clock += interval
                    t.advance(to: clock)
                }
            }
            switch event {
            case .open(let style, let time): t.open(style: style, at: time)
            case .close(let style, let time): t.close(style: style, at: time)
            }
            clock = event.time
            afterEach.append((t.isOpen, t.stage.contentShown, t.progress(at: event.time)))
        }
        let end = clock
        for step in 1...400 {
            t.advance(to: end + Double(step) * 0.025)
        }
        return (afterEach, t)
    }

    func testWhatTheIslandIsAfterEachEntryAndAtTheEndDoesNotDependOnWhichFramesCame() {
        let scripts: [[Event]] = [
            [.open(.spring, 0), .close(.spring, 0.3), .open(.spring, 0.45), .close(.spring, 1.4)],
            [.open(.spring, 0), .close(.spring, 0.05), .open(.spring, 0.2), .close(.spring, 0.31), .open(.spring, 0.9)],
            [.open(.spring, 0), .close(.spring, 1.0), .open(.spring, 1.37), .close(.spring, 2.5), .open(.spring, 2.62)],
            [.open(.contentOnly, 0), .close(.contentOnly, 0.5), .open(.contentOnly, 0.57), .close(.contentOnly, 1.4)],
            [.open(.crossFade, 0), .close(.crossFade, 0.07), .open(.crossFade, 0.12), .close(.crossFade, 0.7)],
            [.open(.spring, 0), .close(.spring, 0.8), .open(.spring, 0.93), .close(.spring, 1.05), .open(.spring, 1.5)],
        ]
        for (index, script) in scripts.enumerated() {
            let dense = run(script, frameEvery: 1.0 / 120)
            let sparse = run(script, frameEvery: 0.23)
            let never = run(script, frameEvery: nil)
            for (kind, other) in [("sparse", sparse), ("none", never)] {
                XCTAssertEqual(other.afterEach.count, dense.afterEach.count)
                for (i, (a, b)) in zip(dense.afterEach, other.afterEach).enumerated() {
                    XCTAssertEqual(a.isOpen, b.isOpen, "script \(index) event \(i) \(kind)")
                    XCTAssertEqual(a.shown, b.shown, "script \(index) event \(i) \(kind) content shown")
                    XCTAssertEqual(a.progress, b.progress, accuracy: 1e-9, "script \(index) event \(i) \(kind)")
                }
                XCTAssertEqual(other.final, dense.final, "script \(index) \(kind): far-future state")
            }
        }
    }

    func testACloseAfterALongGapWithoutFramesStillEndsClosedAfterASingleLateFrame() {
        var t = IslandTransition()
        t.open(style: .spring, at: 0)
        t.advance(to: 0)
        t.advance(to: 0.5)
        t.close(style: .spring, at: 0.6)
        // The displays slept: one frame, a minute later.
        t.advance(to: 60)
        XCTAssertEqual(t.phase, .closed)
        XCTAssertEqual(t.stage, .closed)
        XCTAssertFalse(t.needsFrames)
    }

    // MARK: Keys while closing

    func testKeysAreSwallowedOnlyWhileClosingWhateverTheMotionAndNotAgainOnceReversedOrDone() {
        for style in [IslandMotion.Style.spring, .contentOnly, .crossFade] {
            var t = opening(until: 1, style: style)
            t.advance(to: 1.5)
            XCTAssertFalse(t.swallowsKey(inIsland: true, command: false), "\(style) open")
            t.close(style: style, at: 2)
            XCTAssertTrue(t.swallowsKey(inIsland: true, command: false), "\(style) closing")
            XCTAssertFalse(t.swallowsKey(inIsland: false, command: false), "\(style) another window's key")
            t.open(style: style, at: 2.02)
            XCTAssertFalse(t.swallowsKey(inIsland: true, command: false), "\(style) reversed: Esc closes again")
            t.close(style: style, at: 2.5)
            XCTAssertTrue(t.swallowsKey(inIsland: true, command: false), "\(style) closing again")
            t.advance(to: 2.55)
            t.advance(to: 6)
            XCTAssertEqual(t.phase, .closed)
            XCTAssertFalse(t.swallowsKey(inIsland: true, command: false), "\(style) closed")
        }
    }

    // MARK: Invariants over a random walk

    private struct Generator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func pick<T>(_ options: [T]) -> T { options[Int(next() % UInt64(options.count))] }
    }

    func testTheStagePhaseAndFramesAgreeAfterAnySequenceOfOpensClosesAndFrames() {
        let styles: [IslandMotion.Style] = [.spring, .spring, .spring, .contentOnly, .crossFade]
        let steps: [TimeInterval] = [0, 0.004, 0.016, 0.016, 0.05, 0.13, 0.4, 1.5]
        for seed in 1...12 {
            var rng = Generator(state: UInt64(seed))
            var t = IslandTransition()
            var time = 0.0
            for i in 0..<1500 {
                time += rng.pick(steps)
                switch rng.next() % 4 {
                case 0: t.open(style: rng.pick(styles), at: time)
                case 1: t.close(style: rng.pick(styles), at: time)
                default: t.advance(to: time)
                }
                let note = "seed \(seed) step \(i) at \(time): \(t.phase) \(t.style)"
                XCTAssertEqual(t.stage.interactive, t.phase == .open, note)
                XCTAssertEqual(t.isOpen, t.phase == .opening || t.phase == .open, note)
                XCTAssertEqual(t.swallowsKey(inIsland: true, command: false), t.phase == .closing, note)
                switch t.phase {
                case .closed:
                    XCTAssertEqual(t.stage, .closed, note)
                    XCTAssertFalse(t.needsFrames, note)
                    XCTAssertEqual(t.progress(at: time), 0, note)
                case .opening, .closing:
                    XCTAssertTrue(t.needsFrames, note)
                    XCTAssertFalse(t.stage.interactive, note)
                case .open:
                    XCTAssertTrue(t.stage.contentShown, note)
                    XCTAssertTrue(t.stage.islandShown, note)
                }
                if t.phase == .closing, t.style != .crossFade {
                    XCTAssertFalse(t.stage.contentShown, "closing content never shows: " + note)
                }
                let p = t.progress(at: time)
                XCTAssertTrue(p.isFinite && p > -0.1 && p < 1.2, "progress \(p): " + note)
            }
        }
    }
}
