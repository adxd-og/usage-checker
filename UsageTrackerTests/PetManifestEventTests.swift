import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.5, "Owner 2026-10-30 (events)": a manifest may carry events.
/// Each is checked on its own: frames 35 × 35, at most eight, every role coloured in every palette
/// once its props are merged, props from x y z u v, steps naming its frames, whole-bead deltas
/// summing to zero, the lift and drift limits, 4–12 fps, 1.5–8 s, a unique id. A bad event is left
/// out with its reason; the pet stays.
final class PetManifestEventTests: XCTestCase {
    private func check(events: Any?) throws -> PetManifestCheck {
        let object = PetFixture.setting(["events"], to: events, in: PetFixture.manifest())
        return PetManifestValidator.check(try PetFixture.data(object), folder: PetFixture.id)
    }

    /// `PetFixture.event()` with the value at `path` replaced; nil removes it.
    private func hop(_ path: [String], _ value: Any?) -> [String: Any] {
        PetFixture.setting(path, to: value, in: PetFixture.event())
    }

    /// Why `event` is dropped, having checked it costs nothing but itself.
    private func issues(
        of event: [String: Any], file: StaticString = #filePath, line: UInt = #line
    ) throws -> [PetEventIssue] {
        let result = try check(events: [event, PetFixture.event(id: "good")])
        XCTAssertEqual(result.issues, [], file: file, line: line)
        XCTAssertEqual(result.manifest?.events.map(\.id), ["good"], file: file, line: line)
        guard result.notes.count == 1, case .eventDropped(_, let issues) = result.notes[0] else {
            XCTFail("notes: \(result.notes)", file: file, line: line)
            return []
        }
        return issues
    }

    /// `event` keeps the contract.
    private func assertKept(_ event: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws {
        let result = try check(events: [event])
        XCTAssertEqual(result.notes, [], file: file, line: line)
        XCTAssertEqual(result.manifest?.events.count, 1, file: file, line: line)
    }

    func testAManifestWithoutEventsHasNoneAndNoNote() throws {
        let result = try check(events: nil)
        XCTAssertEqual(result.issues, [])
        XCTAssertEqual(result.notes, [])
        XCTAssertEqual(result.manifest?.events, [])
    }

    func testAnEmptyListIsNoEvents() throws {
        let result = try check(events: [Any]())
        XCTAssertEqual(result.notes, [])
        XCTAssertEqual(result.manifest?.events, [])
    }

    func testAnEventThatKeepsTheContractComesBackWhole() throws {
        let result = try check(events: [PetFixture.event()])
        XCTAssertEqual(result.issues, [])
        XCTAssertEqual(result.notes, [])
        let event = try XCTUnwrap(result.manifest?.event(id: "hop"))
        XCTAssertEqual(event.fps, 4)
        XCTAssertEqual(event.duration, 1.5)
        XCTAssertEqual(event.frames.keys.sorted(), ["a", "b"])
        XCTAssertEqual(event.frames["a"]?.bead(x: 2, y: 0), "x")
        XCTAssertEqual(event.steps.count, 6)
        XCTAssertEqual(event.steps[2], PetEventStep(frame: "a", dx: 2, dy: -2))
        XCTAssertEqual(event.palette["x"], PetRGB(hex: "#ff0000"))
        XCTAssertEqual(event.offsets.map(\.lift), [0, 2, 4, 2, 0, 0])
        XCTAssertNil(result.manifest?.event(id: "nope"))
    }

    func testEventsKeepTheManifestsOrder() throws {
        let result = try check(events: ["b", "a", "c"].map { PetFixture.event(id: $0) })
        XCTAssertEqual(result.manifest?.events.map(\.id), ["b", "a", "c"])
    }

    func testEventsThatAreNotAListCostOnlyThemselves() throws {
        let result = try check(events: 5)
        XCTAssertEqual(result.issues, [])
        XCTAssertEqual(result.manifest?.events, [])
        XCTAssertEqual(result.notes, [.eventDropped(id: "events", issues: [.notAList])])
    }

    func testAnEntryThatIsNotAnObjectIsDroppedByItsPlace() throws {
        let result = try check(events: [7, PetFixture.event()] as [Any])
        XCTAssertEqual(result.manifest?.events.map(\.id), ["hop"])
        XCTAssertEqual(result.notes, [.eventDropped(id: "#0", issues: [.notAnObject])])
    }

    func testAnEventNeedsAnId() throws {
        XCTAssertEqual(try issues(of: hop(["id"], nil)), [.noID])
        XCTAssertEqual(try issues(of: hop(["id"], "  ")), [.noID])
        XCTAssertEqual(try issues(of: hop(["id"], 7)), [.noID])
        let result = try check(events: [hop(["id"], nil)])
        XCTAssertEqual(result.notes, [.eventDropped(id: "#0", issues: [.noID])])
    }

    func testALaterEventWithTheSameIdIsDropped() throws {
        let result = try check(events: [PetFixture.event(), PetFixture.event()])
        XCTAssertEqual(result.manifest?.events.map(\.id), ["hop"])
        XCTAssertEqual(result.notes, [.eventDropped(id: "hop", issues: [.duplicateID])])
    }

    func testTheRateIsANumberFrom4To12() throws {
        let bad: [Any?] = [3, 12.5, "8", true, nil]
        for fps in bad {
            XCTAssertEqual(try issues(of: hop(["fps"], fps)), [.fps], "\(String(describing: fps))")
        }
        var fastest = hop(["fps"], 12)
        fastest["steps"] = PetFixture.stillSteps(18)
        try assertKept(fastest)
        var fractional = hop(["fps"], 4.5)
        fractional["steps"] = PetFixture.stillSteps(9)
        try assertKept(fractional)
    }

    func testEveryFrameIs35By35() throws {
        let small = PetFixture.rows(side: 34, beads: [(0, 0, "o")])
        XCTAssertEqual(try issues(of: hop(["frames", "a"], small)), [.frameShape("a")])
        var short = PetFixture.frameRows
        short[3] = String(short[3].dropLast())
        XCTAssertEqual(try issues(of: hop(["frames", "a"], short)), [.frameShape("a")])
        XCTAssertEqual(try issues(of: hop(["frames", "a"], 5)), [.frameShape("a")])
    }

    func testAtMostEightFrames() throws {
        var frames = ["a": PetFixture.eventRows, "b": PetFixture.frameRows]
        for name in ["c", "d", "e", "f", "g", "h"] { frames[name] = PetFixture.frameRows }
        try assertKept(hop(["frames"], frames))
        frames["i"] = PetFixture.frameRows
        XCTAssertEqual(try issues(of: hop(["frames"], frames)), [.tooManyFrames(9)])
    }

    func testAnEventWithoutFramesIsDropped() throws {
        var event = hop(["frames"], [String: Any]())
        event["steps"] = [Any]()
        XCTAssertEqual(try issues(of: event), [.noFrames, .noSteps])
    }

    func testEveryRoleMustBeColouredInEveryPaletteOnceThePropsAreMerged() throws {
        let painted = PetFixture.rows(side: 35, beads: [(0, 0, "q")])
        XCTAssertEqual(try issues(of: hop(["frames", "a"], painted)), [
            .paletteLacksRoles(palette: "grey", roles: "q"),
            .paletteLacksRoles(palette: "white", roles: "q"),
        ])
        XCTAssertEqual(try issues(of: hop(["palette"], nil)), [
            .paletteLacksRoles(palette: "grey", roles: "x"),
            .paletteLacksRoles(palette: "white", roles: "x"),
        ])
    }

    func testARoleOnlyOneColourwayHasIsNotEnough() throws {
        var object = PetFixture.setting(["palettes", "grey", "k"], to: "#123456", in: PetFixture.manifest())
        let painted = PetFixture.rows(side: 35, beads: [(0, 0, "k")])
        object = PetFixture.setting(["events"], to: [hop(["frames", "a"], painted)], in: object)
        let result = PetManifestValidator.check(try PetFixture.data(object), folder: PetFixture.id)
        XCTAssertEqual(result.manifest?.events, [])
        XCTAssertTrue(result.notes.contains(.eventDropped(
            id: "hop", issues: [.paletteLacksRoles(palette: "white", roles: "k")]
        )))
    }

    func testPropRolesComeFromXYZUVAndHaveAColour() throws {
        for role in ["q", "o", ".", "xy"] {
            XCTAssertEqual(try issues(of: hop(["palette", role], "#000000")), [.propRole(role)], role)
        }
        XCTAssertEqual(try issues(of: hop(["palette", "x"], "red")), [.propColour("x")])
        XCTAssertEqual(try issues(of: hop(["palette"], 5)), [
            .paletteNotObject,
            .paletteLacksRoles(palette: "grey", roles: "x"),
            .paletteLacksRoles(palette: "white", roles: "x"),
        ])
        var all = PetFixture.event()
        for role in ["y", "z", "u", "v"] {
            all = PetFixture.setting(["palette", role], to: "#00ff00", in: all)
        }
        try assertKept(all)
    }

    /// Codex plan review 6: a prop must not repaint a role any colourway of the animal already uses.
    func testAPropRoleTheAnimalAlreadyHasIsDropped() throws {
        var object = PetFixture.setting(["palettes", "grey", "x"], to: "#123456", in: PetFixture.manifest())
        object = PetFixture.setting(["events"], to: [PetFixture.event()], in: object)
        let result = PetManifestValidator.check(try PetFixture.data(object), folder: PetFixture.id)
        XCTAssertEqual(result.issues, [])
        XCTAssertEqual(result.manifest?.events, [])
        XCTAssertTrue(result.notes.contains(.eventDropped(id: "hop", issues: [.propCollides("x")])), "\(result.notes)")
    }

    func testAnEventWithNoPropsNeedsNoPalette() throws {
        var event = hop(["palette"], nil)
        event = PetFixture.setting(["frames", "a"], to: PetFixture.frameRows, in: event)
        try assertKept(event)
    }

    func testAStepNamesAFrameOfItsEvent() throws {
        let unknown = PetFixture.steps([("a", 0, 0), ("c", 0, 0), ("a", 0, 0), ("a", 0, 0), ("a", 0, 0), ("a", 0, 0)])
        XCTAssertEqual(try issues(of: hop(["steps"], unknown)), [.stepUnknownFrame(step: 1, frame: "c")])
        var missing = PetFixture.stillSteps(6)
        missing[4]["f"] = nil
        XCTAssertEqual(try issues(of: hop(["steps"], missing)), [.stepUnknownFrame(step: 4, frame: "null")])
    }

    func testAStepsDeltasAreWholeBeads() throws {
        for bad in [0.5, "1", true] as [Any] {
            let steps = PetFixture.steps([("a", 0, 0), ("a", 0, 0), ("a", bad, 0), ("a", 0, 0), ("a", 0, 0), ("a", 0, 0)])
            XCTAssertEqual(try issues(of: hop(["steps"], steps)), [.stepDelta(step: 2)], "\(bad)")
        }
    }

    func testAStepWithoutDeltasStaysPut() throws {
        let steps = Array(repeating: ["f": "a"], count: 6)
        try assertKept(hop(["steps"], steps))
    }

    func testTheDeltasMustSumToZero() throws {
        let across = PetFixture.steps([("a", 0, 0), ("a", 2, 0), ("a", 0, 0), ("a", 0, 0), ("a", 0, 0), ("a", 0, 0)])
        XCTAssertEqual(try issues(of: hop(["steps"], across)), [.notBalanced(dx: 2, dy: 0)])
        let up = PetFixture.steps([("a", 0, 0), ("a", 0, -2), ("a", 0, 0), ("a", 0, 0), ("a", 0, 0), ("a", 0, 0)])
        XCTAssertEqual(try issues(of: hop(["steps"], up)), [.notBalanced(dx: 0, dy: -2)])
    }

    func testTheLiftIsAtMost120BeadsAboveTheFloor() throws {
        func rising(_ beads: Int) -> [[String: Any]] {
            let first = beads / 2
            let second = beads - first
            return PetFixture.steps([("a", 0, 0), ("a", 0, -first), ("a", 0, -second), ("a", 0, second), ("a", 0, first), ("a", 0, 0)])
        }
        try assertKept(hop(["steps"], rising(120)))
        XCTAssertEqual(try issues(of: hop(["steps"], rising(121))), [.liftTooHigh(121)])
    }

    /// Codex plan review 7: `Int.min` would trap in `abs`, and large deltas in the sum.
    func testAHugeDeltaIsDroppedBeforeItIsAddedUp() throws {
        for huge in [Int.min, Int.max, 121, -121] {
            let across = PetFixture.steps([("a", 0, 0), ("a", huge, 0), ("a", 0, 0), ("a", 0, 0), ("a", 0, 0), ("a", 0, 0)])
            XCTAssertEqual(try issues(of: hop(["steps"], across)), [.stepDelta(step: 1)], "dx \(huge)")
            let up = PetFixture.steps([("a", 0, 0), ("a", 0, huge), ("a", 0, 0), ("a", 0, 0), ("a", 0, 0), ("a", 0, 0)])
            XCTAssertEqual(try issues(of: hop(["steps"], up)), [.stepDelta(step: 1)], "dy \(huge)")
        }
        let largest = PetFixture.steps([("a", 0, 0), ("a", 0, -120), ("a", 0, 0), ("a", 0, 120), ("a", 0, 0), ("a", 0, 0)])
        try assertKept(hop(["steps"], largest))
    }

    func testTheDriftIsAtMost30BeadsEitherWay() throws {
        func going(_ beads: Int) -> [[String: Any]] {
            PetFixture.steps([("a", 0, 0), ("a", beads, 0), ("a", 0, 0), ("a", -beads, 0), ("a", 0, 0), ("a", 0, 0)])
        }
        try assertKept(hop(["steps"], going(30)))
        try assertKept(hop(["steps"], going(-30)))
        XCTAssertEqual(try issues(of: hop(["steps"], going(31))), [.driftTooFar(31)])
        XCTAssertEqual(try issues(of: hop(["steps"], going(-31))), [.driftTooFar(31)])
    }

    func testTheDurationIsFrom1Point5To8Seconds() throws {
        try assertKept(hop(["steps"], PetFixture.stillSteps(6)))
        try assertKept(hop(["steps"], PetFixture.stillSteps(32)))
        XCTAssertEqual(try issues(of: hop(["steps"], PetFixture.stillSteps(5))), [.duration(1.25)])
        XCTAssertEqual(try issues(of: hop(["steps"], PetFixture.stillSteps(33))), [.duration(8.25)])
    }

    func testAnEventWithoutStepsIsDropped() throws {
        XCTAssertEqual(try issues(of: hop(["steps"], nil)), [.noSteps])
        XCTAssertEqual(try issues(of: hop(["steps"], [Any]())), [.noSteps])
    }

    func testADroppedEventSaysWhy() {
        let note = PetManifestNote.eventDropped(id: "hop", issues: [.fps, .liftTooHigh(121)])
        XCTAssertEqual(note.description, "event hop dropped: fps outside 4-12; lift 121 beads, at most 120")
        XCTAssertTrue(note.isDroppedEvent)
        XCTAssertFalse(PetManifestNote.unusedRoles("3w").isDroppedEvent)
    }
}
