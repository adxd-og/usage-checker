import XCTest
@testable import Omelette

/// Spec 2026-11-19 keep-awake thermal guard, § Plan decisions accepted by the session, item 2a
/// ("The helper never moves a pending reading later … The tick the helper schedules is the
/// earlier of the pending one and the one the input calls for; the bounds of item 2 hold
/// whatever arrives in between") and item 2's bounds: `critical` ends the mode within a minute
/// of the lid closing, `serious` within two.
final class KeepAwakePendingTickTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeepAwakePendingTickTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var stateFile: KeepAwakeStateFile {
        KeepAwakeStateFile(url: directory.appendingPathComponent("keepawake.json"))
    }

    private let lidClosed = KeepAwakeLid(closed: true, causesSleep: true)
    /// A battery far above the floor, so that a power notification reaches the apply step and
    /// ends nothing.
    private let onBattery = KeepAwakePower(onBattery: true, percent: 80)
    private var stillArmed: KeepAwakeState { .armed(deadline: t0 + 7_200, floorEnabled: true) }

    /// Armed for two hours at t0 with the lid open: the tick pending is the arm's, at t0 + 60.
    /// The pmset calls and the schedule calls so far are forgotten.
    private func armed(_ fake: FakeKeepAwakeMachine) async -> KeepAwakeService {
        let service = KeepAwakeService(machine: fake.machine(), stateFile: stateFile)
        _ = await service.start(now: t0)
        _ = await service.arm(seconds: 7_200, floorEnabled: true, now: t0)
        fake.with { $0.calls = []; $0.scheduled = []; $0.exits = [] }
        return service
    }

    private func scheduled(_ fake: FakeKeepAwakeMachine) -> [Date?] {
        fake.with { $0.scheduled }
    }

    private struct Fired: Equatable {
        var at: Date
        var state: KeepAwakeState
    }

    /// The helper's clock from `start` on: a power notification every 20 s, and the tick
    /// whenever the time the machine was last asked for has come, as the daemon's one
    /// wall-clock timer delivers it. `pending` is the tick the machine holds at `start`. It
    /// runs until a tick finds the mode ended, or until `end`; the ticks that fired come back.
    private func runWithPowerNotifications(
        _ service: KeepAwakeService,
        _ fake: FakeKeepAwakeMachine,
        pending: Date?,
        from start: Date,
        until end: Date
    ) async -> [Fired] {
        var fired: [Fired] = []
        var pending = pending
        var notification = start + 20
        while true {
            if let due = pending, due <= notification {
                guard due <= end else { break }
                let reply = await service.tick(now: due)
                fired.append(Fired(at: due, state: reply.state))
                if !reply.state.isArmed { break }
            } else {
                guard notification <= end else { break }
                _ = await service.powerChanged(now: notification)
                notification += 20
            }
            pending = fake.with { $0.scheduled.last ?? nil }
        }
        return fired
    }

    // MARK: - The bounds under power notifications

    /// Critical from before the lid closed, on battery under load: the power source reports
    /// every 20 s and takes no thermal reading. The reading pending when the lid closed still
    /// comes, and ends the mode.
    func testPowerNotificationsEvery20SecondsDoNotPostponeTheCriticalReadingAfterTheLidCloses() async {
        let fake = FakeKeepAwakeMachine()
        fake.with { $0.power = onBattery; $0.thermal = .critical }
        let service = await armed(fake)
        let open = await service.tick(now: t0 + 30)
        XCTAssertEqual(open.state, stillArmed, "lid open: nothing ends")
        let lidClosedAt = t0 + 30   // just after that tick; closing it is no reading
        let pendingAtTheClose = t0 + 90
        XCTAssertEqual(scheduled(fake), [pendingAtTheClose])
        XCTAssertLessThanOrEqual(pendingAtTheClose, lidClosedAt + 60)
        fake.with { $0.lid = lidClosed; $0.scheduled = [] }

        let fired = await runWithPowerNotifications(service, fake, pending: pendingAtTheClose, from: lidClosedAt, until: t0 + 600)

        XCTAssertEqual(fired, [Fired(at: t0 + 90, state: .ended(at: t0 + 90, reason: .overheated))])
        XCTAssertEqual(
            scheduled(fake),
            [t0 + 90, t0 + 90, nil],
            "the notifications at 50 and 70 leave the tick where it was; the end cancels it"
        )
        XCTAssertEqual(fake.with { $0.calls }, ["set 0", "read", "sleepnow"])
    }

    /// The same at serious: the first closed-lid reading comes when it was due and starts the
    /// minute, and the minute's end is not postponed either.
    func testPowerNotificationsEvery20SecondsDoNotPostponeTheSeriousEndPastTwoMinutesAfterTheLidCloses() async {
        let fake = FakeKeepAwakeMachine()
        fake.with { $0.power = onBattery; $0.thermal = .serious }
        let service = await armed(fake)
        _ = await service.tick(now: t0 + 30)
        let lidClosedAt = t0 + 30
        XCTAssertEqual(scheduled(fake), [t0 + 90])
        fake.with { $0.lid = lidClosed; $0.scheduled = [] }

        let fired = await runWithPowerNotifications(service, fake, pending: t0 + 90, from: lidClosedAt, until: t0 + 600)

        XCTAssertEqual(fired, [
            Fired(at: t0 + 90, state: stillArmed),
            Fired(at: t0 + 150, state: .ended(at: t0 + 150, reason: .overheated)),
        ])
        XCTAssertLessThanOrEqual(t0 + 150, lidClosedAt + 120)
        XCTAssertEqual(
            scheduled(fake),
            [t0 + 90, t0 + 90, t0 + 150, t0 + 150, t0 + 150, t0 + 150, nil],
            "50 and 70 keep the tick at 90; it fires and sets 150; 90, 110 and 130 keep that"
        )
    }

    // MARK: - Inputs between ticks

    func testTheFloorSwitchTheGuardSwitchAndAReArmBetweenTicksLeaveThePendingTickWhereItWas() async {
        let fake = FakeKeepAwakeMachine()
        let service = await armed(fake)
        _ = await service.setFloor(enabled: false, now: t0 + 10)
        _ = await service.setThermalGuard(enabled: false, now: t0 + 20)
        _ = await service.setThermalGuard(enabled: true, now: t0 + 25)
        _ = await service.arm(seconds: 7_200, floorEnabled: true, now: t0 + 30)
        let longer = await service.arm(seconds: 14_400, floorEnabled: true, now: t0 + 40)
        XCTAssertEqual(longer.state, .armed(deadline: t0 + 14_440, floorEnabled: true))
        XCTAssertEqual(scheduled(fake), [t0 + 60, t0 + 60, t0 + 60, t0 + 60, t0 + 60])
    }

    /// The app's poll reads everything a tick reads, but it is not the timer firing: the tick
    /// the timer holds stays. So does it after a thermal notification.
    func testTheAppsPollAndAThermalNotificationLeaveThePendingTickWhereItWas() async {
        let fake = FakeKeepAwakeMachine()
        let service = await armed(fake)
        _ = await service.state(now: t0 + 15)
        _ = await service.thermalChanged(now: t0 + 45)
        XCTAssertEqual(scheduled(fake), [t0 + 60, t0 + 60])
    }

    /// A deadline is never nearer than a minute from its Apply and a hot minute never ends
    /// sooner than a minute from its first reading, so while the clock runs forward the pending
    /// tick is already the earlier one. A clock set back is what leaves it the later one: the
    /// next input brings the tick to a minute from the new time.
    func testAnInputThatCallsForAnEarlierTickMovesItEarlier() async {
        let fake = FakeKeepAwakeMachine()
        fake.with { $0.power = onBattery }
        let service = await armed(fake)
        _ = await service.powerChanged(now: t0 - 3_600)
        _ = await service.powerChanged(now: t0 - 3_590)
        XCTAssertEqual(scheduled(fake), [t0 - 3_540, t0 - 3_540])
    }

    // MARK: - A new deadline

    /// The shortest duration is a minute, the tick interval, so the pending tick is never past a
    /// new deadline: it reads on the way, and the tick it sets is the deadline's.
    func testAfterAReArmWithAShorterDurationTheModeEndsAtItsNewDeadline() async {
        let fake = FakeKeepAwakeMachine()
        let service = await armed(fake)
        _ = await service.tick(now: t0 + 60)
        let shorter = await service.arm(seconds: 60, floorEnabled: true, now: t0 + 100)
        XCTAssertEqual(shorter.state, .armed(deadline: t0 + 160, floorEnabled: true))
        XCTAssertEqual(scheduled(fake), [t0 + 120, t0 + 120])
        let onTheWay = await service.tick(now: t0 + 120)
        XCTAssertEqual(onTheWay.state, .armed(deadline: t0 + 160, floorEnabled: true))
        XCTAssertEqual(scheduled(fake).last ?? nil, t0 + 160)
        let atTheDeadline = await service.tick(now: t0 + 160)
        XCTAssertEqual(atTheDeadline.state, .ended(at: t0 + 160, reason: .deadline))
        XCTAssertEqual(scheduled(fake).last ?? t0, nil)
    }

    /// The tick pending is the old deadline's. Kept after an Apply with a later deadline, it
    /// only reads: the mode runs on to the new one.
    func testAfterAReArmWithALongerDurationTheTickAtTheOldDeadlineReadsAndEndsNothing() async {
        let fake = FakeKeepAwakeMachine()
        let service = KeepAwakeService(machine: fake.machine(), stateFile: stateFile)
        _ = await service.start(now: t0)
        _ = await service.arm(seconds: 90, floorEnabled: true, now: t0)
        _ = await service.tick(now: t0 + 60)
        fake.with { $0.calls = []; $0.scheduled = [] }
        let longer = await service.arm(seconds: 7_200, floorEnabled: true, now: t0 + 70)
        XCTAssertEqual(scheduled(fake), [t0 + 90], "the old deadline's tick, not a minute after the Apply")
        fake.with { $0.calls = [] }
        let atTheOldDeadline = await service.tick(now: t0 + 90)
        XCTAssertEqual(atTheOldDeadline.state, .armed(deadline: t0 + 7_270, floorEnabled: true))
        XCTAssertEqual(atTheOldDeadline.state, longer.state)
        XCTAssertEqual(fake.with { $0.calls }, [], "the flag stays on")
        XCTAssertEqual(fake.with { $0.flag }, .set)
        XCTAssertEqual(scheduled(fake), [t0 + 90, t0 + 150])
    }

    // MARK: - A tick that fired

    func testATickThatFiredIsNotHeldAgainstTheNextOne() async {
        let fake = FakeKeepAwakeMachine()
        let service = await armed(fake)
        _ = await service.setFloor(enabled: false, now: t0 + 50)
        _ = await service.tick(now: t0 + 60)
        XCTAssertEqual(scheduled(fake), [t0 + 60, t0 + 120], "a full interval on from the tick")
    }

    /// A hot minute that began at a notification between ticks: the tick pending comes first,
    /// and the one it sets is the minute's end.
    func testATickThatFiredDuringAHotMinuteSetsTheMinutesEnd() async {
        let fake = FakeKeepAwakeMachine()
        let service = await armed(fake)
        fake.with { $0.lid = lidClosed; $0.thermal = .serious }
        _ = await service.thermalChanged(now: t0 + 40)
        let first = await service.tick(now: t0 + 60)
        XCTAssertEqual(first.state, stillArmed, "twenty seconds into the minute")
        XCTAssertEqual(scheduled(fake), [t0 + 60, t0 + 100])
        let second = await service.tick(now: t0 + 100)
        XCTAssertEqual(second.state, .ended(at: t0 + 100, reason: .overheated))
    }

    /// The timer fired and its tick has not reached the service yet, or the clock jumped past
    /// it: an input in between keeps the overdue tick at its own time, which a wall-clock timer
    /// fires at once. It is neither cancelled nor replaced by a later one, and the tick, when it
    /// runs, sets the next from its own time.
    func testAnOverdueTickIsKeptUntilItRunsAndThenTheNextIsAFullIntervalOn() async {
        let fake = FakeKeepAwakeMachine()
        fake.with { $0.power = onBattery }
        let service = await armed(fake)
        _ = await service.powerChanged(now: t0 + 70)
        _ = await service.powerChanged(now: t0 + 80)
        XCTAssertEqual(scheduled(fake), [t0 + 60, t0 + 60])
        _ = await service.tick(now: t0 + 81)
        _ = await service.powerChanged(now: t0 + 100)
        XCTAssertEqual(scheduled(fake), [t0 + 60, t0 + 60, t0 + 141, t0 + 141])
    }

    // MARK: - No tick, and the retry tick

    /// An end with nothing owed cancels the tick, and the cancelled tick is not held against
    /// the next mode's first one.
    func testAfterAnEndWithNothingOwedNoTickIsPending() async {
        let fake = FakeKeepAwakeMachine()
        fake.with { $0.power = onBattery }
        let service = await armed(fake)
        _ = await service.disarm(now: t0 + 10)
        _ = await service.powerChanged(now: t0 + 20)
        XCTAssertEqual(scheduled(fake), [nil, nil])
        _ = await service.arm(seconds: 7_200, floorEnabled: true, now: t0 + 30)
        XCTAssertEqual(scheduled(fake), [nil, nil, t0 + 90], "a minute from the new Apply, not the old mode's 60")
    }

    /// While a clear is owed every input retries it and the tick is the retry that comes
    /// without one: notifications do not postpone it, and once the flag reads clear there is no
    /// tick.
    func testWhileAClearIsOwedNotificationsDoNotPostponeTheRetryTick() async {
        let fake = FakeKeepAwakeMachine()
        fake.with { $0.power = onBattery }
        let service = await armed(fake)
        fake.with { $0.setStatus = 1 }
        let refused = await service.disarm(now: t0 + 10)
        XCTAssertEqual(refused.failure, .commandFailed(command: "pmset", status: 1))
        _ = await service.powerChanged(now: t0 + 30)
        _ = await service.powerChanged(now: t0 + 50)
        XCTAssertEqual(scheduled(fake), [t0 + 60, t0 + 60, t0 + 60], "the mode's own tick was the earlier one")
        _ = await service.tick(now: t0 + 60)
        _ = await service.powerChanged(now: t0 + 80)
        XCTAssertEqual(Array(scheduled(fake).suffix(2)), [t0 + 120, t0 + 120], "still refused: a minute from the tick")
        fake.with { $0.setStatus = 0 }
        _ = await service.tick(now: t0 + 120)
        XCTAssertEqual(scheduled(fake).last ?? t0, nil)
        XCTAssertEqual(fake.with { $0.flag }, .cleared)
    }
}
