import XCTest
@testable import Omelette

/// A chance the test steers: whatever `value` is when the runtime draws.
private final class Dial {
    var value = 0.0
}

/// A seeded source for the fuzz: the same sessions on every run.
private final class Source {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    }

    func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / Double(UInt64(1) << 53)
    }

    func pick(_ count: Int) -> Int {
        min(count - 1, Int(next() * Double(count)))
    }
}

/// Verification of P5d (notch-island spec 2026-10-29 § 3.5, "Owner 2026-10-30 (events)", § 3.8) over
/// the art that ships and over the runtime under interruptions: a real event at a realistic room
/// ends on its start spot, stays in the column and inside its timing limits; the pet is on the
/// floor whenever no event is up; a hand-played queue is neither lost nor stuck by what interrupts
/// it; the same event never plays twice in a row.
final class PetEventsVerificationTests: XCTestCase {
    private let t0 = PetRuntimeFixture.t0
    private let library = PetLibrary.bundled()
    private let animations = PetRuntimeFixture.animations

    // MARK: - The shipped art at realistic rooms

    /// Rooms a column can offer: none, tiny, the climbs' own peaks and around them, more than any event goes.
    private let rooms = [0, 1, 2, 5, 14, 21, 22, 23, 40, 67, 80, 120, 500]

    /// A runtime after `walks` walks of a pet in `roam` beads, standing at a known spot, facing a known
    /// way; the clock after it. Walks at roam 40: 0 → (16, right), (32, right), (16, left).
    private func prerolled(walks: Int, roam: Int = 40) -> (runtime: PetRuntime, clock: Double, dial: Dial) {
        let dial = Dial()
        var runtime = PetRuntime(random: PetRandom { dial.value })
        var clock = 0.0
        var done = 0
        var inWalk = false
        while done < walks, clock < 200 {
            let frame = runtime.at(clock, roam: roam, events: [])
            if frame.bit == .walk {
                inWalk = true
            } else if inWalk {
                inWalk = false
                done += 1
            }
            clock += 0.125
        }
        dial.value = 0.99
        return (runtime, clock, dial)
    }

    private struct Outcome {
        let frames: [PetFrame]
        let startX: Int
        let facesLeft: Bool
    }

    /// Plays `event` by hand from the runtime in `state`, in a column of `room` beads and a floor of `roam`.
    private func play(
        _ event: PetEvent, among events: [PetEvent], from state: (runtime: PetRuntime, clock: Double, dial: Dial),
        roam: Int, room: Int, seconds: Double = 10, dt: Double = 1.0 / 16
    ) -> Outcome {
        var runtime = state.runtime
        let startX = min(runtime.xBeads, roam)
        let faces = runtime.facesLeft
        runtime.play([event.id])
        var frames: [PetFrame] = []
        var clock = state.clock
        let end = clock + seconds
        while clock < end {
            frames.append(runtime.at(clock, roam: roam, events: events, liftRoom: room))
            clock += dt
        }
        return Outcome(frames: frames, startX: startX, facesLeft: faces)
    }

    private func assertKeepsItsSpot(
        _ outcome: Outcome, event: PetEvent, roam: Int, room: Int, dt: Double = 1.0 / 16, label: String
    ) {
        var eventTicks = 0
        var ended = false
        for frame in outcome.frames {
            if case .event(let id) = frame.bit {
                XCTAssertFalse(ended, "\(label): an event frame after the pet was back")
                XCTAssertEqual(id, event.id, label)
                eventTicks += 1
                XCTAssertTrue((0...min(room, PetContract.eventMaxLift)).contains(frame.yBeads), "\(label): lift \(frame.yBeads)")
                XCTAssertTrue((0...roam).contains(frame.xBeads), "\(label): x \(frame.xBeads) of \(roam)")
                XCTAssertLessThanOrEqual(abs(frame.xBeads - outcome.startX), PetContract.eventMaxDrift, label)
                XCTAssertEqual(frame.facesLeft, outcome.facesLeft, label)
                XCTAssertTrue(PetContract.eventFPS.contains(frame.fps), "\(label): fps \(frame.fps)")
            } else {
                ended = true
                XCTAssertEqual(frame.yBeads, 0, "\(label): off the floor with no event")
                XCTAssertEqual(frame.xBeads, outcome.startX, "\(label): not on its start spot")
                XCTAssertEqual(frame.facesLeft, outcome.facesLeft, label)
            }
        }
        XCTAssertGreaterThan(eventTicks, 0, "\(label): never started")
        XCTAssertTrue(ended, "\(label): still up after the run")
        XCTAssertLessThanOrEqual(
            Double(eventTicks) * dt, min(PetContract.eventDuration.upperBound, event.duration) + 2 * dt,
            "\(label): ran past its time"
        )
    }

    func testEveryShippedEventAtEveryRoomEndsOnItsSpotInTheColumnAndInTime() {
        let states = (0...3).map { prerolled(walks: $0) }
        var runs = 0
        for animal in library.animalIDs {
            guard let events = library.manifests[animal]?.events else { continue }
            for event in events {
                for room in rooms {
                    for state in states {
                        let x = state.runtime.xBeads
                        for roam in [40, x + 3, x] {
                            let outcome = play(event, among: events, from: state, roam: roam, room: room)
                            assertKeepsItsSpot(
                                outcome, event: event, roam: roam, room: room,
                                label: "\(animal) \(event.id) room \(room) x \(x) roam \(roam)"
                            )
                            runs += 1
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThanOrEqual(runs, 4 * 10 * rooms.count * 4 * 3)
    }

    func testAFittedShippedEventKeepsItsShapeAtEveryRoom() {
        for animal in library.animalIDs {
            for event in library.manifests[animal]?.events ?? [] {
                for room in rooms {
                    let label = "\(animal) \(event.id) room \(room)"
                    let fitted = event.fitted(room: room)
                    XCTAssertLessThanOrEqual(fitted.offsets.map(\.lift).max() ?? 0, room, label)
                    XCTAssertEqual(fitted.offsets.last, .zero, label)
                    XCTAssertEqual(fitted.steps.map(\.dx).reduce(0, +), 0, label)
                    XCTAssertEqual(fitted.steps.map(\.dy).reduce(0, +), 0, label)
                    XCTAssertLessThanOrEqual(fitted.duration, event.duration + 1e-9, label)
                    XCTAssertEqual(fitted.fps, event.fps, label)
                    XCTAssertEqual(fitted.frames, event.frames, label)
                    XCTAssertEqual(fitted.steps.last?.frame, event.steps.last?.frame, label)
                    XCTAssertEqual(
                        fitted.offsets.map(\.x).map(abs).max() ?? 0, event.offsets.map(\.x).map(abs).max() ?? 0,
                        "\(label): the sideways drift is kept"
                    )
                    XCTAssertEqual(fitted.fitted(room: room), fitted, "\(label): fitting twice changes nothing")
                    // Its frames are the drawn ones, in the drawn order.
                    var rest = event.steps.map(\.frame)[...]
                    for step in fitted.steps {
                        guard let at = rest.firstIndex(of: step.frame) else {
                            XCTFail("\(label): frame \(step.frame) out of order")
                            break
                        }
                        rest = rest[(at + 1)...]
                    }
                }
            }
        }
    }

    /// With no room at all, an event whose last step is its descent still plays that last step's frame:
    /// it ends on the frame it was drawn to end on, not one step early.
    func testWithNoRoomAClimbThatEndsOnItsDescendingStepKeepsItsLastFrame() {
        let drop = PetEventFixture.event(id: "drop", fps: 8, moves: [(0, 0), (0, -4), (0, 0), (0, 4)])
        let fitted = drop.fitted(room: 0)
        XCTAssertEqual(fitted.steps.map(\.frame), ["a", "a", "b"], "the rise is skipped, the pause and the last step are not")
        XCTAssertEqual(fitted.steps.map(\.dy), [0, 0, 0])
        XCTAssertFalse(fitted.moves)
    }

    /// The wall climbs, at the room a column really has: they reach the top (or the climb's own peak), no
    /// further, and the descent from the last moment at the top is a steady one. (The dog's authored climb
    /// slips back six beads on its way up: the rise is not asserted to be steady.)
    func testAWallClimbReachesTheTopOrItsPeakNoFurtherAndComesDownSteadily() throws {
        var checked = 0
        for animal in library.animalIDs {
            for event in library.manifests[animal]?.events ?? [] where (event.offsets.map(\.lift).max() ?? 0) >= 40 {
                let authored = event.offsets.map(\.lift).max() ?? 0
                for room in [0, 1, 5, 22, 40, 60, 100, 200] {
                    let state = prerolled(walks: 1)
                    let lifts = play(event, among: [event], from: state, roam: 40, room: room, seconds: 9).frames
                        .compactMap { frame -> Int? in
                            if case .event = frame.bit { return frame.yBeads }
                            return nil
                        }
                    let label = "\(animal) \(event.id) room \(room)"
                    XCTAssertEqual(lifts.max(), min(room, authored), "\(label): reaches the top and no further")
                    let last = try XCTUnwrap(lifts.lastIndex(of: lifts.max() ?? 0))
                    XCTAssertEqual(lifts[last...].sorted(by: >), Array(lifts[last...]), "\(label): comes down without rising")
                    checked += 1
                }
            }
        }
        XCTAssertEqual(checked, 4 * 8, "one wall climb per animal")
    }

    /// Where the sprite is actually drawn, for the columns and displays an island really has: inside the
    /// 150 pt column, never above its top or below the floor, and never held down by the clamp (the
    /// runtime's lift already fits).
    func testEveryShippedEventIsDrawnInsideTheColumnAtEveryHeightAndScale() {
        var drawn = 0
        for backingScale in [CGFloat(1), 2, 3] {
            for height in [CGFloat(60), 100, 150, 200, 280, 360, 500] {
                let scale = PetHabitatRules.scale(petBeads: PetContract.size, backingScale: backingScale)
                let side = scale.points(beads: PetContract.size)
                let footY = PetHabitatRules.floorY(height: height, petSide: side)
                let room = PetHabitatRules.liftRoom(footY: footY, petBeads: PetContract.size, scale: scale)
                let roam = PetHabitatRules.roamBeads(petBeads: PetContract.size, scale: scale)
                XCTAssertGreaterThanOrEqual(room, 0)
                let state = prerolled(walks: 3, roam: roam)
                for animal in library.animalIDs {
                    let events = library.manifests[animal]?.events ?? []
                    for event in events {
                        let outcome = play(event, among: events, from: state, roam: roam, room: room)
                        for frame in outcome.frames {
                            let at = PetHabitatRules.origin(
                                xBeads: frame.xBeads, yBeads: frame.yBeads, footY: footY,
                                petBeads: PetContract.size, roamBeads: roam, scale: scale
                            )
                            let label = "\(animal) \(event.id) h \(height) @\(backingScale)x"
                            XCTAssertGreaterThanOrEqual(at.x, 0, label)
                            XCTAssertLessThanOrEqual(at.x + side, ProviderGridRules.habitatWidth + 1e-6, label)
                            XCTAssertGreaterThanOrEqual(at.y, 0, "\(label): above the column")
                            XCTAssertLessThanOrEqual(at.y + side, footY + 1e-6, "\(label): below the floor")
                            let wanted = PetScaleRules.snapped(
                                CGPoint(
                                    x: scale.points(beads: frame.xBeads),
                                    y: footY - scale.points(beads: PetContract.size + frame.yBeads)
                                ),
                                backingScale: scale.backingScale
                            )
                            XCTAssertEqual(at, wanted, "\(label): the clamp moved a sprite the runtime had fitted")
                            drawn += 1
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(drawn, 10_000)
    }

    // MARK: - Interruptions

    /// Events whose frames are unique per step ("s0", "s1", …), so a test can see each start.
    private static func stepped(id: String, fps: Double, _ moves: [(dx: Int, dy: Int)]) -> PetEvent {
        PetEvent(
            id: id, fps: fps,
            frames: Dictionary(uniqueKeysWithValues: moves.indices.map { ("s\($0)", PetEventFixture.map) }),
            steps: moves.enumerated().map { PetEventStep(frame: "s\($0.offset)", dx: $0.element.dx, dy: $0.element.dy) },
            palette: [:]
        )
    }

    private static func repeated(_ count: Int, _ move: (dx: Int, dy: Int)) -> [(dx: Int, dy: Int)] {
        Array(repeating: move, count: count)
    }

    private static let fuzzEvents: [PetEvent] = [
        stepped(id: "e0", fps: 8, repeated(12, (0, 0))),
        stepped(
            id: "e1", fps: 8,
            repeated(1, (0, 0)) + repeated(8, (0, -3)) + repeated(4, (0, 0)) + repeated(8, (0, 3)) + repeated(3, (0, 0))
        ),
        stepped(
            id: "e2", fps: 8,
            repeated(1, (0, 0)) + repeated(5, (4, 0)) + repeated(3, (0, 0)) + repeated(5, (-4, 0)) + repeated(2, (0, 0))
        ),
        stepped(
            id: "e3", fps: 8,
            repeated(1, (0, 0)) + repeated(5, (4, -2)) + repeated(3, (0, 0)) + repeated(5, (-4, 2)) + repeated(2, (0, 0))
        ),
    ]

    /// Random sessions of ticks, gate-offs and reopens, pats, pointer and field, alert moods, and a list of
    /// events that comes and goes: with no hand play, whatever the order, a pet with no event up is on
    /// the floor; an event never leaves the column or the floor; a reopened island has no event up
    /// before its first bit is due; and no slot starts the event that played last.
    func testWhateverInterruptsAnEventThePetIsOnTheFloorAndNeverRepeatsOne() {
        var starts = 0
        var reopens = 0
        for session in 0..<200 {
            let source = Source(seed: UInt64(session))
            var runtime = PetRuntime(random: PetRandom { source.next() })
            let room = [0, 1, 5, 16, 30, 60, 120][source.pick(7)]
            let roam = [0, 10, 65][source.pick(3)]
            var clock = 0.0
            var reopenedAt: Double? = 0
            var previousKey: String?
            var lastStarted: String?
            for _ in 0..<300 {
                let roll = source.next()
                if roll < 0.04 {
                    runtime.pause(at: t0 + clock)
                    clock += 0.3 + 5 * source.next()
                    runtime.resume(at: t0 + clock)
                    reopenedAt = clock
                    reopens += 1
                    previousKey = nil
                } else if roll < 0.07 {
                    runtime.pat(at: t0 + clock)
                }
                clock += [0.04, 0.08, 0.125, 0.25, 0.5, 1, 3][source.pick(7)]
                let events = source.next() < 0.88 ? Self.fuzzEvents : []
                let frame = runtime.tick(
                    at: t0 + clock, pose: PetPose.allCases[source.pick(3)], loops: source.next() < 0.8,
                    activity: PetUserActivity(pointerOverContent: source.next() < 0.2, fieldFocused: source.next() < 0.05),
                    animations: animations, roamBeads: roam, events: events, liftRoom: room
                )
                let label = "session \(session) t \(clock)"
                XCTAssertTrue((0...roam).contains(frame.xBeads), "\(label): x \(frame.xBeads) of \(roam)")
                if case .event(let id) = frame.bit {
                    XCTAssertTrue((0...room).contains(frame.yBeads), "\(label): lift \(frame.yBeads) of \(room)")
                    if let reopenedAt {
                        XCTAssertGreaterThanOrEqual(clock - reopenedAt, 1.4, "\(label): an event in a reopened island's first 1.4 s")
                    }
                    if frame.frame == "s0", previousKey != "s0" {
                        starts += 1
                        if let lastStarted { XCTAssertNotEqual(id, lastStarted, "\(label): twice in a row") }
                        lastStarted = id
                    }
                } else {
                    XCTAssertEqual(frame.yBeads, 0, "\(label): off the floor with no event up")
                }
                if let at = reopenedAt, clock - at > 1.4 { reopenedAt = nil }
                if case .event = frame.bit { previousKey = frame.frame } else { previousKey = nil }
            }
        }
        XCTAssertGreaterThan(starts, 400, "the sessions have to start events for the rest to mean anything")
        XCTAssertGreaterThan(reopens, 200)
    }

    // MARK: - Hand play across interruptions

    private let queueEvents = [PetEventFixture.climb, PetEventFixture.drift, PetEventFixture.flat, PetEventFixture.climb80]

    /// Ticks `runtime` from `from` to `to` every 1/12 s, `shape` giving each tick's mood and user.
    private func tickAll(
        _ runtime: inout PetRuntime, from: Double, to: Double, room: Int = 22,
        events: [PetEvent]? = nil,
        shape: (Double) -> (loops: Bool, pose: PetPose, activity: PetUserActivity) = { _ in (true, .idle, .none) }
    ) -> [(at: Double, frame: PetFrame)] {
        var out: [(Double, PetFrame)] = []
        var clock = from
        while clock < to {
            let mood = shape(clock)
            out.append((
                clock,
                runtime.tick(
                    at: t0 + clock, pose: mood.pose, loops: mood.loops, activity: mood.activity,
                    animations: animations, roamBeads: 40, events: events ?? queueEvents, liftRoom: room
                )
            ))
            clock += 1.0 / 12
        }
        return out
    }

    /// The ids of the events shown, one per run of ticks.
    private func order(_ ticks: [(at: Double, frame: PetFrame)]) -> [String] {
        var ids: [String] = []
        for tick in ticks {
            if case .event(let id) = tick.frame.bit, ids.last != id { ids.append(id) }
        }
        return ids
    }

    func testAQueueIsPlayedWholeAndInOrderThroughAPointerAndAMoodThatHoldsStill() {
        let dial = Dial()
        dial.value = 0.99
        var runtime = PetRuntime(random: PetRandom { dial.value })
        _ = runtime.at(0, events: queueEvents)
        runtime.play(["climb", "drift", "flat", "climb80"])
        let ticks = tickAll(&runtime, from: 0.1, to: 30) { clock in
            switch clock {
            case 0.5..<1.5: return (true, .idle, PetUserActivity(pointerOverContent: true, fieldFocused: false))
            case 2..<3: return (false, .look, .none)
            case 3.5..<4.5: return (false, .sleep, PetUserActivity(pointerOverContent: false, fieldFocused: true))
            default: return (true, .idle, .none)
            }
        }
        XCTAssertEqual(order(ticks), ["climb", "drift", "flat", "climb80"])
        let eventTicks = ticks.filter { if case .event = $0.frame.bit { return true } else { return false } }
        let first = eventTicks.first?.at ?? 0
        let last = eventTicks.last?.at ?? 0
        XCTAssertEqual(first, 0.1, accuracy: 0.001, "at the next tick")
        for tick in ticks where tick.at >= first && tick.at <= last {
            guard case .event = tick.frame.bit else {
                return XCTFail("a bit or a slot got between the queued events at \(tick.at)")
            }
        }
        let expected = queueEvents.map { $0.fitted(room: 22).duration }.reduce(0, +)
        XCTAssertEqual(last - first, expected, accuracy: 0.2, "each ran to its end, none cut by the pointer or the mood")
        XCTAssertEqual(ticks.last?.frame.yBeads, 0)
        XCTAssertFalse(ticks.last.map { if case .event = $0.frame.bit { return true } else { return false } } ?? true)
    }

    /// The island closes mid-climb and reopens before the climb's own time is up: the pet is on the floor
    /// at once, not back up the wall, whether the climb was a slot's or a hand's.
    func testACloseAndQuickReopenMidClimbIsOnTheFloorNotBackUpTheWall() {
        for byHand in [false, true] {
            let dial = Dial()
            dial.value = 0
            var runtime = PetRuntime(random: PetRandom { dial.value })
            let events = [PetEventFixture.climb80]
            _ = runtime.at(0, events: events)
            if byHand { runtime.play(["climb80"]) }
            let start = byHand ? 0.1 : 2.0
            let up = tickAll(&runtime, from: start, to: start + 1.0, room: 40, events: events)
            XCTAssertGreaterThan(up.last?.frame.yBeads ?? 0, 10, "byHand \(byHand): it is up the wall")
            dial.value = 0.99
            runtime.pause(at: t0 + start + 1.0)
            runtime.resume(at: t0 + start + 1.1)
            let after = tickAll(&runtime, from: start + 1.1, to: start + 1.1 + 1.3, room: 40, events: events)
            for tick in after {
                XCTAssertNil(tick.frame.bit, "byHand \(byHand): at \(tick.at)")
                XCTAssertEqual(tick.frame.yBeads, 0, "byHand \(byHand): at \(tick.at)")
            }
        }
    }

    func testAPatInTheMiddleOfAQueueLeavesItWhole() {
        let dial = Dial()
        dial.value = 0.99
        var runtime = PetRuntime(random: PetRandom { dial.value })
        _ = runtime.at(0, events: queueEvents)
        runtime.play(["drift", "flat"])
        var ticks = tickAll(&runtime, from: 0.1, to: 2)
        runtime.pat(at: t0 + 2)
        ticks += tickAll(&runtime, from: 2, to: 12)
        XCTAssertEqual(order(ticks), ["drift", "flat"])
    }

    func testAGateOffInTheMiddleOfAQueueDropsTheRestAndTheNextOpenIsOnTheFloor() {
        let dial = Dial()
        dial.value = 0.99
        var runtime = PetRuntime(random: PetRandom { dial.value })
        _ = runtime.at(0, events: queueEvents)
        runtime.play(["climb", "drift", "flat", "climb80"])
        let before = tickAll(&runtime, from: 0.1, to: 2.0)
        XCTAssertEqual(order(before), ["climb", "drift"], "the second is up when the island closes")
        runtime.pause(at: t0 + 2.0)
        runtime.resume(at: t0 + 30)
        let after = tickAll(&runtime, from: 30, to: 45)
        XCTAssertEqual(order(after), [], "none of the dropped ones comes back")
        XCTAssertEqual(after.first?.frame.yBeads, 0)
        XCTAssertNil(after.first?.frame.bit)
        // A new ask after the reopen works as on the first day.
        runtime.play(["flat"])
        let again = tickAll(&runtime, from: 45, to: 50)
        XCTAssertEqual(order(again), ["flat"])
    }

    func testANewAskReplacesWhatWaitsAndWhatIsUp() {
        let dial = Dial()
        dial.value = 0.99
        var runtime = PetRuntime(random: PetRandom { dial.value })
        _ = runtime.at(0, events: queueEvents)
        runtime.play(["climb80", "climb", "drift"])
        var ticks = tickAll(&runtime, from: 0.1, to: 1.0)
        XCTAssertEqual(order(ticks), ["climb80"])
        runtime.play(["flat"])
        ticks += tickAll(&runtime, from: 1.0, to: 15)
        XCTAssertEqual(order(ticks), ["climb80", "flat"], "the old queue is gone, not postponed")
    }

    func testAnIdThePetLacksIsSkippedWithoutStallingTheRest() {
        let dial = Dial()
        dial.value = 0.99
        var runtime = PetRuntime(random: PetRandom { dial.value })
        _ = runtime.at(0, events: queueEvents)
        runtime.play(["nope", "drift", "also-nope", "also-nope", "flat", "nope"])
        let ticks = tickAll(&runtime, from: 0.1, to: 12)
        XCTAssertEqual(order(ticks), ["drift", "flat"])
        XCTAssertNil(ticks.last?.frame.bit)
    }

    /// A slot's climb that the mood cut short is coming down when the hand asks for another event: the
    /// landing is replaced, and the pet is on the floor at the end of the new one, never back on the old.
    func testAHandPlayOverALandingEndsOnTheFloorWithoutTheOldEvent() {
        let dial = Dial()
        dial.value = 0
        var runtime = PetRuntime(random: PetRandom { dial.value })
        let events = [PetEventFixture.climb80, PetEventFixture.drift]
        _ = runtime.at(0, events: events)
        var ticks = tickAll(&runtime, from: 0.1, to: 3.0, room: 22, events: events)
        XCTAssertEqual(order(ticks), ["climb80"], "the slot at 2 s starts the first event")
        // A climb at 2.6 s is partway up: the mood turns to an alert and it starts to come down.
        ticks += tickAll(&runtime, from: 3.0, to: 3.2, room: 22, events: events) { _ in (false, .look, .none) }
        let landing = ticks.last?.frame
        XCTAssertEqual(landing?.bit, .event("climb80"))
        XCTAssertGreaterThan(landing?.yBeads ?? 0, 0, "still on its way down")
        XCTAssertLessThan(landing?.yBeads ?? 99, 22, "coming down, not held at the top")
        dial.value = 0.99
        runtime.play(["drift"])
        let rest = tickAll(&runtime, from: 3.2, to: 12, room: 22, events: events) { _ in (false, .look, .none) }
        XCTAssertEqual(order(rest), ["drift"])
        XCTAssertEqual(rest.last?.frame.yBeads, 0)
        XCTAssertNil(rest.last?.frame.bit)
    }

    // MARK: - Never the same event twice in a row

    private func claude(resetsAt: Date) -> ServiceSnapshot {
        Fixture.snapshot(id: "claude", displayName: "Claude", buckets: [
            Fixture.bucket(id: "five_hour", label: "Current session", percent: 3, resetsAt: resetsAt, kind: .session),
        ], at: t0)
    }

    /// The bits seen, one per run of ticks every 1/8 s from 0 to `until`; `before` may poke the runtime first.
    private func bits(
        _ runtime: inout PetRuntime, until: Double, events: (Double) -> [PetEvent],
        before: (inout PetRuntime, Double) -> Void = { _, _ in }
    ) -> [PetBit] {
        var seen: [PetBit] = []
        var clock = 0.0
        while clock < until {
            before(&runtime, clock)
            if let bit = runtime.at(clock, roam: 40, events: events(clock)).bit, seen.last != bit { seen.append(bit) }
            clock += 0.125
        }
        return seen
    }

    /// A reset seen in a live poll at 3 s, while the first event is up.
    private func runtimeWithAResetAt3(_ runtime: inout PetRuntime) -> (inout PetRuntime, Double) -> Void {
        let reset = t0.addingTimeInterval(-3_600)
        runtime.observe([claude(resetsAt: reset)], now: reset.addingTimeInterval(-60))
        var seen = false
        return { runtime, clock in
            if clock >= 3, !seen {
                seen = true
                runtime.observe([self.claude(resetsAt: reset.addingTimeInterval(5 * 3_600))], now: self.t0 + clock)
            }
        }
    }

    func testAStretchBetweenTwoSlotsDoesNotMakeTheLastEventEligible() {
        var runtime = PetRuntime(random: PetRandom { 0 })
        let both = [PetEventFixture.flat, PetEventFixture.climb]
        let poke = runtimeWithAResetAt3(&runtime)
        // 2 s the flat event; 9 s the stretch; 16 s a slot with flat barred: climb.
        XCTAssertEqual(
            bits(&runtime, until: 20, events: { _ in both }, before: poke),
            [.event("flat"), .stretch, .event("climb")]
        )
    }

    func testAPetWithOneEventPlaysItAgainOnlyAfterABitNotAfterAStretch() {
        var runtime = PetRuntime(random: PetRandom { 0 })
        let only = [PetEventFixture.flat]
        let poke = runtimeWithAResetAt3(&runtime)
        // 2 s the event; 9 s the stretch; 16 s no event may play (it is the last one), so a bit does and
        // frees it; 23 s the event again.
        XCTAssertEqual(
            bits(&runtime, until: 30, events: { _ in only }, before: poke),
            [.event("flat"), .stretch, .walk, .event("flat")]
        )
    }

    func testADrainedListBetweenTwoSlotsDoesNotMakeTheLastEventEligible() {
        var runtime = PetRuntime(random: PetRandom { 0 })
        let both = [PetEventFixture.flat, PetEventFixture.climb]
        // 2 s flat; 9 s the list is empty (the pet is warming up): a bit; 16 s climb, not flat.
        XCTAssertEqual(
            bits(&runtime, until: 20, events: { (5..<12).contains($0) ? [] : both }),
            [.event("flat"), .walk, .event("climb")]
        )
    }
}
