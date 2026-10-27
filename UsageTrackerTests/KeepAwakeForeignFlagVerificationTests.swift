import XCTest
@testable import Omelette

/// Verifier tests for reviewer V3 (spec 2026-10-26, § Design › Helper): the helper's start
/// clears only its own sleep flag, so a flag another tool set is left alone; `ownsFlag` in the
/// state file carries the helper's claim across a restart. And V4: the popover's visible
/// height when the menu bar hides.
final class KeepAwakeForeignFlagVerificationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeepAwakeForeignFlagVerificationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var stateFile: KeepAwakeStateFile {
        KeepAwakeStateFile(url: directory.appendingPathComponent("keepawake.json"))
    }

    private let lidClosed = KeepAwakeLid(closed: true, causesSleep: true)
    private let lidOpen = KeepAwakeLid(closed: false, causesSleep: true)

    // MARK: - A foreign flag at start

    /// Sleepless, or `pmset` by hand, set the flag; the lid is closed. Nothing the daemon is
    /// asked afterwards touches the flag or sleeps the Mac, and it may go idle and exit.
    func testAForeignFlagWithTheLidClosedNeverSleepsOrIsTouchedByLaterInputs() async {
        let fake = FakeKeepAwakeMachine()
        fake.with { $0.flag = .set; $0.lid = lidClosed }
        let service = KeepAwakeService(machine: fake.machine(), stateFile: stateFile)
        let reply = await service.start(now: t0)
        XCTAssertEqual(reply, KeepAwakeReply(state: .idle, failure: nil))
        XCTAssertFalse(stateFile.loadOwnsFlag(), "nothing of its own on disk")
        fake.with { $0.power = KeepAwakePower(onBattery: true, percent: 3) }
        _ = await service.tick(now: t0 + 60)
        _ = await service.state(now: t0 + 90)
        _ = await service.powerChanged(now: t0 + 100)
        _ = await service.setFloor(enabled: false, now: t0 + 110)
        fake.with { $0.lid = lidOpen }
        _ = await service.tick(now: t0 + 120)
        fake.with { $0.lid = lidClosed }
        _ = await service.tick(now: t0 + 130)
        XCTAssertEqual(fake.with { $0.calls }, ["read"], "only the start's read: no set, no sleepnow")
        XCTAssertEqual(fake.with { $0.flag }, .set)
        await service.exitIfIdle(now: t0 + 1_000)
        XCTAssertEqual(fake.with { $0.terminations }, [0], "a foreign flag does not hold the daemon")
        XCTAssertEqual(fake.with { $0.flag }, .set)
    }

    /// pmset's flag is global: an Apply over a foreign flag sets it (the fake records the set
    /// though it reads set already) and the end of the mode clears it, the foreign one too.
    /// That is the documented cost of V3; the start alone is what leaves the flag alone.
    func testAnApplyOverAForeignFlagTakesItOverAndTheEndClearsIt() async {
        let fake = FakeKeepAwakeMachine()
        fake.with { $0.flag = .set }
        let service = KeepAwakeService(machine: fake.machine(), stateFile: stateFile)
        _ = await service.start(now: t0)
        fake.with { $0.calls = [] }
        let armed = await service.arm(seconds: 120, floorEnabled: true, now: t0)
        XCTAssertEqual(armed.state, .armed(deadline: t0 + 120, floorEnabled: true))
        XCTAssertEqual(fake.with { $0.calls }, ["set 1", "read"])
        XCTAssertTrue(stateFile.loadOwnsFlag(), "ours from the set on")
        fake.with { $0.calls = [] }
        let ended = await service.tick(now: t0 + 120)
        XCTAssertEqual(ended.state, .ended(at: t0 + 120, reason: .deadline))
        XCTAssertEqual(fake.with { $0.calls }, ["set 0", "read"])
        XCTAssertEqual(fake.with { $0.flag }, .cleared, "pmset is global: the foreign flag goes too")
        XCTAssertFalse(stateFile.loadOwnsFlag())
    }

    /// Terminate after that Apply: the flag is ours now, so the stop clears it.
    func testATerminateAfterAnApplyOverAForeignFlagClearsItAsOurs() async {
        let fake = FakeKeepAwakeMachine()
        fake.with { $0.flag = .set }
        let service = KeepAwakeService(machine: fake.machine(), stateFile: stateFile)
        _ = await service.start(now: t0)
        _ = await service.arm(seconds: 3_600, floorEnabled: true, now: t0)
        fake.with { $0.calls = [] }
        await service.terminate(now: t0 + 30)
        XCTAssertEqual(fake.with { $0.calls }, ["set 0", "read"])
        XCTAssertEqual(fake.with { $0.terminations }, [0])
        XCTAssertEqual(fake.with { $0.flag }, .cleared)
        XCTAssertFalse(stateFile.loadOwnsFlag())
        XCTAssertEqual(stateFile.load(), .ended(at: t0 + 30, reason: .stopped))
    }

    /// A stop whose clear takes after an unknown flag (the state itself unchanged): the claim
    /// leaves the file, so a flag another tool sets before the next start is left alone.
    func testATerminateThatClearsAnUnknownFlagReleasesTheClaimOnDisk() async {
        let fake = FakeKeepAwakeMachine()
        let service = KeepAwakeService(machine: fake.machine(), stateFile: stateFile)
        _ = await service.start(now: t0)
        fake.with { $0.setStatus = 1 }
        _ = await service.arm(seconds: 600, floorEnabled: true, now: t0)
        XCTAssertTrue(stateFile.loadOwnsFlag(), "unknown after the failed set and rollback")
        XCTAssertEqual(stateFile.load(), .idle)
        fake.with { $0.setStatus = 0; $0.calls = [] }
        await service.terminate(now: t0 + 30)
        XCTAssertEqual(fake.with { $0.calls }, ["set 0", "read"])
        XCTAssertEqual(fake.with { $0.terminations }, [0])
        XCTAssertFalse(stateFile.loadOwnsFlag(), "cleared and read back: the claim is gone")
        fake.with { $0.flag = .set; $0.calls = [] }
        _ = await KeepAwakeService(machine: fake.machine(), stateFile: stateFile).start(now: t0 + 60)
        XCTAssertEqual(fake.with { $0.calls }, ["read"], "a flag set since is another tool's")
    }

    // MARK: - What the file says at start

    /// The crash between the early save and the set (rule 12): the file says armed, the flag
    /// is clear, the lid is closed. Nothing to sleep from; the mode ends as restarted.
    func testAnArmedFileWithTheFlagClearAndTheLidClosedEndsAsRestartedWithoutSleeping() async throws {
        try stateFile.save(.armed(deadline: t0 + 3_600, floorEnabled: true))
        let fake = FakeKeepAwakeMachine()
        fake.with { $0.flag = .cleared; $0.lid = lidClosed }
        let service = KeepAwakeService(machine: fake.machine(), stateFile: stateFile)
        let reply = await service.start(now: t0)
        XCTAssertEqual(reply, KeepAwakeReply(state: .ended(at: t0, reason: .restarted), failure: nil))
        XCTAssertEqual(fake.with { $0.calls }, ["read", "set 0", "read"])
        XCTAssertEqual(stateFile.load(), .ended(at: t0, reason: .restarted))
        XCTAssertFalse(stateFile.loadOwnsFlag())
    }

    /// `ownsFlag` with an idle state (a clear that never read back, then a crash), the flag
    /// set and the lid closed: the flag is the helper's, so it is cleared and the Mac sleeps.
    func testAnOwnedIdleFileWithTheFlagSetAndTheLidClosedClearsAndSleeps() async throws {
        try stateFile.save(.idle, ownsFlag: true)
        let fake = FakeKeepAwakeMachine()
        fake.with { $0.flag = .set; $0.lid = lidClosed }
        let service = KeepAwakeService(machine: fake.machine(), stateFile: stateFile)
        let reply = await service.start(now: t0)
        XCTAssertEqual(reply, KeepAwakeReply(state: .ended(at: t0, reason: .restarted), failure: nil))
        XCTAssertEqual(fake.with { $0.calls }, ["read", "set 0", "read", "sleepnow"])
        XCTAssertFalse(stateFile.loadOwnsFlag(), "let go once it reads clear")
    }

    /// The same file with the lid open clears and does not sleep.
    func testAnOwnedIdleFileWithTheFlagSetAndTheLidOpenClearsWithoutSleeping() async throws {
        try stateFile.save(.idle, ownsFlag: true)
        let fake = FakeKeepAwakeMachine()
        fake.with { $0.flag = .set; $0.lid = lidOpen }
        let service = KeepAwakeService(machine: fake.machine(), stateFile: stateFile)
        _ = await service.start(now: t0)
        XCTAssertEqual(fake.with { $0.calls }, ["read", "set 0", "read"])
    }

    /// Ownership of a file whose clear fails again at the restart is kept for the next one.
    func testAnOwnedFlagWhoseClearFailsAtTheRestartStaysOwned() async throws {
        try stateFile.save(.ended(at: t0 - 60, reason: .deadline), ownsFlag: true)
        let fake = FakeKeepAwakeMachine()
        fake.with { $0.flag = .set; $0.setStatus = 1 }
        let service = KeepAwakeService(machine: fake.machine(), stateFile: stateFile)
        let reply = await service.start(now: t0)
        XCTAssertNotNil(reply.failure)
        XCTAssertTrue(stateFile.loadOwnsFlag())
        XCTAssertEqual(fake.with { $0.exits }, [nil], "not idle while the flag may be ours")
    }

    // MARK: - ownsFlag through the service

    /// A set that fails (and the rollback's clear fails too) leaves the flag possibly on: the
    /// file keeps the claim and the idle state, and a restart that finds the flag set clears
    /// it and, with the lid closed, sleeps.
    func testASetThatFailedLeavesTheFlagOwnedAndTheNextStartClearsIt() async {
        let fake = FakeKeepAwakeMachine()
        let service = KeepAwakeService(machine: fake.machine(), stateFile: stateFile)
        _ = await service.start(now: t0)
        fake.with { $0.setStatus = 1 }
        let reply = await service.arm(seconds: 600, floorEnabled: true, now: t0)
        XCTAssertEqual(reply.state, .idle)
        XCTAssertNotNil(reply.failure)
        XCTAssertEqual(stateFile.load(), .idle)
        XCTAssertTrue(stateFile.loadOwnsFlag(), "unknown: still the helper's")
        fake.with { $0.calls = []; $0.setStatus = 0; $0.flag = .set; $0.lid = lidClosed }
        let restarted = KeepAwakeService(machine: fake.machine(), stateFile: stateFile)
        _ = await restarted.start(now: t0 + 30)
        XCTAssertEqual(fake.with { $0.calls }, ["read", "set 0", "read", "sleepnow"])
        XCTAssertFalse(stateFile.loadOwnsFlag())
    }

    /// A set that took and a clear that read back: ownership comes and goes with them, and a
    /// foreign flag found afterwards is left alone.
    func testOwnershipReleasedAfterAClearReadsBackLeavesALaterForeignFlagAlone() async {
        let fake = FakeKeepAwakeMachine()
        let service = KeepAwakeService(machine: fake.machine(), stateFile: stateFile)
        _ = await service.start(now: t0)
        _ = await service.arm(seconds: 600, floorEnabled: true, now: t0)
        XCTAssertTrue(stateFile.loadOwnsFlag())
        _ = await service.disarm(now: t0 + 10)
        XCTAssertFalse(stateFile.loadOwnsFlag())
        fake.with { $0.flag = .set; $0.calls = [] }
        let restarted = KeepAwakeService(machine: fake.machine(), stateFile: stateFile)
        let reply = await restarted.start(now: t0 + 20)
        XCTAssertEqual(reply.state, .ended(at: t0 + 10, reason: .cancelled))
        XCTAssertEqual(fake.with { $0.calls }, ["read"])
        XCTAssertEqual(fake.with { $0.flag }, .set)
    }

    /// A file with `ownsFlag` false, null or garbage owns nothing: a set flag stays alone.
    func testAnOwnsFlagFieldThatIsFalseNullOrGarbageOwnsNothing() async throws {
        try stateFile.save(.idle, ownsFlag: true)
        let owning = try String(contentsOf: stateFile.url, encoding: .utf8)
        for spelling in [#""ownsFlag":false"#, #""ownsFlag":null"#, #""ownsFlag":"yes""#, #""ownsFlag":1"#, #""ownsFlag":[]"#] {
            let rewritten = owning.replacingOccurrences(of: #""ownsFlag":true"#, with: spelling)
            XCTAssertNotEqual(rewritten, owning, "the fixture has the field: \(owning)")
            try Data(rewritten.utf8).write(to: stateFile.url)
            XCTAssertFalse(stateFile.loadOwnsFlag(), spelling)
            let fake = FakeKeepAwakeMachine()
            fake.with { $0.flag = .set; $0.lid = lidClosed }
            _ = await KeepAwakeService(machine: fake.machine(), stateFile: stateFile).start(now: t0)
            XCTAssertEqual(fake.with { $0.calls }, ["read"], spelling)
        }
    }

    /// A file of another version, or none, owns nothing.
    func testAFileOfAnotherVersionOrNoneOwnsNoFlag() throws {
        XCTAssertFalse(stateFile.loadOwnsFlag())
        try stateFile.save(.idle, ownsFlag: true)
        let owning = try String(contentsOf: stateFile.url, encoding: .utf8)
        try Data(owning.replacingOccurrences(of: #""version":1"#, with: #""version":2"#).utf8).write(to: stateFile.url)
        XCTAssertFalse(stateFile.loadOwnsFlag())
    }

    /// A file written before V3 has no `ownsFlag` and no sleep owed: it claims nothing.
    func testAFileWithoutTheFieldAndAnEndedStateLeavesASetFlagAlone() async throws {
        try Data(#"{"state":{"ended":{"at":1792999940,"reason":"deadline"}},"version":1}"#.utf8).write(to: stateFile.url)
        XCTAssertFalse(stateFile.loadOwnsFlag())
        let fake = FakeKeepAwakeMachine()
        fake.with { $0.flag = .set; $0.lid = lidClosed }
        let reply = await KeepAwakeService(machine: fake.machine(), stateFile: stateFile).start(now: t0)
        XCTAssertEqual(reply.state, .ended(at: Date(timeIntervalSince1970: 1_792_999_940), reason: .deadline))
        XCTAssertEqual(fake.with { $0.calls }, ["read"])
    }

    // MARK: - The invariants with a foreign flag at the first start

    private final class SleepLog: @unchecked Sendable {
        struct Entry { var flag: KeepAwakeFlagReading; var lid: KeepAwakeLid }
        private let lock = NSLock()
        private var storage: [Entry] = []
        var entries: [Entry] { lock.withLock { storage } }
        func record(_ entry: Entry) { lock.withLock { storage.append(entry) } }
    }

    private struct Random {
        var state: UInt64
        mutating func int(_ bound: Int) -> Int {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Int((z ^ (z >> 31)) % UInt64(bound))
        }
    }

    /// Phase one: inputs that never arm (ticks, power, lid, floor switch) leave a foreign flag
    /// set, issue no pmset call and never sleep. Phase two: once Apply is used, the sleeps
    /// still happen only with the flag read clear and the lid sleeping, once per ended mode.
    func testAForeignFlagAtTheFirstStartKeepsTheInvariantsAcrossRandomHistories() async {
        for seed in [1, 2, 3, 5, 8, 13] as [UInt64] {
            var rng = Random(state: seed)
            let fake = FakeKeepAwakeMachine()
            fake.with { $0.flag = .set; $0.lid = lidClosed }
            let log = SleepLog()
            var machine = fake.machine()
            let inner = machine.sleepNow
            machine.sleepNow = {
                let seen = fake.with { ($0.flag, $0.lid) }
                log.record(.init(flag: seen.0, lid: seen.1))
                return inner()
            }
            let service = KeepAwakeService(
                machine: machine,
                stateFile: KeepAwakeStateFile(url: directory.appendingPathComponent("seed-\(seed).json"))
            )
            var now = t0
            _ = await service.start(now: now)
            for step in 0..<80 {
                let tag = "seed \(seed) step \(step)"
                now += TimeInterval(1 + rng.int(300))
                switch rng.int(4) {
                case 0: _ = await service.tick(now: now)
                case 1:
                    fake.with { $0.power = KeepAwakePower(onBattery: rng.int(2) == 0, percent: rng.int(60)) }
                    _ = await service.powerChanged(now: now)
                case 2:
                    fake.with { $0.lid = KeepAwakeLid(closed: rng.int(2) == 0, causesSleep: rng.int(5) != 0) }
                    _ = await service.state(now: now)
                default: _ = await service.setFloor(enabled: rng.int(2) == 0, now: now)
                }
                XCTAssertEqual(fake.with { $0.calls }, ["read"], "phase one: \(tag)")
                XCTAssertEqual(fake.with { $0.flag }, .set, tag)
            }
            // Phase two.
            var previous = KeepAwakeState.idle
            var checked = 0
            for step in 0..<150 {
                let tag = "seed \(seed) phase two step \(step)"
                now += TimeInterval(1 + rng.int(400))
                let before = log.entries.count
                let reply: KeepAwakeReply
                switch rng.int(6) {
                case 0, 1: reply = await service.arm(seconds: TimeInterval(60 + rng.int(3_000)), floorEnabled: rng.int(4) != 0, now: now)
                case 2: reply = await service.disarm(now: now)
                case 3:
                    fake.with { $0.lid = KeepAwakeLid(closed: rng.int(2) == 0, causesSleep: rng.int(5) != 0) }
                    reply = await service.tick(now: now)
                case 4: reply = await service.setFloor(enabled: rng.int(2) == 0, now: now)
                default: reply = await service.state(now: now)
                }
                let lidSleeps = fake.with { $0.lid.sleepsWhenClosed }
                let endedHere = previous.isArmed && !reply.state.isArmed
                XCTAssertEqual(log.entries.count - before, endedHere && lidSleeps ? 1 : 0, "sleepnow count: \(tag) \(previous) -> \(reply.state)")
                if reply.state.isArmed { XCTAssertEqual(fake.with { $0.flag }, .set, "armed means set: \(tag)") }
                previous = reply.state
                for entry in log.entries[checked...] {
                    XCTAssertTrue(entry.flag.isClear, "sleepnow with the flag \(entry.flag): \(tag)")
                    XCTAssertTrue(entry.lid.sleepsWhenClosed, tag)
                }
                checked = log.entries.count
            }
        }
    }

    // MARK: - V4: the menu bar rule

    /// A menu bar that reserves nothing (zero height) takes nothing off, at either top.
    func testAZeroMenuBarTakesNothingOff() {
        XCTAssertEqual(PopoverHeightRules.screenVisibleHeight(frameMaxY: 982, visibleFrameMaxY: 982, visibleFrameHeight: 933, menuBarHeight: 0), 933)
        XCTAssertEqual(PopoverHeightRules.screenVisibleHeight(frameMaxY: 982, visibleFrameMaxY: 949, visibleFrameHeight: 900, menuBarHeight: 0), 900)
    }

    /// A visible frame that stops short of the top (menu bar shown, or a Dock-less gap) is the
    /// height as it is, whatever the menu bar height says.
    func testAVisibleFrameShortOfTheTopIsTheHeightWhateverTheMenuBarHeight() {
        for menuBar in [0, 24, 33, 200] as [CGFloat] {
            XCTAssertEqual(PopoverHeightRules.screenVisibleHeight(frameMaxY: 982, visibleFrameMaxY: 981.5, visibleFrameHeight: 900, menuBarHeight: menuBar), 900, "\(menuBar)")
        }
    }

    /// A visible frame that reaches past the frame's top (a rounding or an odd arrangement)
    /// is still "nothing reserved at the top": the menu bar comes off.
    func testAVisibleFrameReachingPastTheFramesTopLosesTheMenuBar() {
        XCTAssertEqual(PopoverHeightRules.screenVisibleHeight(frameMaxY: 982, visibleFrameMaxY: 983, visibleFrameHeight: 934, menuBarHeight: 33), 901)
    }

    /// The menu bar comes off the visible height and the result feeds the budget.
    func testTheHiddenMenuBarLowersTheBudget() {
        let height = PopoverHeightRules.screenVisibleHeight(frameMaxY: 1_117, visibleFrameMaxY: 1_117, visibleFrameHeight: 1_050, menuBarHeight: 37)
        XCTAssertEqual(height, 1_013)
        XCTAssertEqual(PopoverHeightRules.budget(screenVisibleHeight: height), 973)
    }
}
