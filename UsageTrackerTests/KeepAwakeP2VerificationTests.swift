import XCTest
import ServiceManagement
@testable import Omelette

/// Verifier tests for keep-awake Package 2 (spec 2026-10-26, § Design › Behaviour › Visible,
/// § UI, § Packages row 2). Edges the executor's `KeepAwakeCopyTests` / `KeepAwakeTooltipTests`
/// / `KeepAwakeModelOrderTests` leave open: rounding at every second of a minute, the tick grid
/// at fractional offsets, precedence under a dismissal, a deadline exactly now, a stale reply
/// that was itself a lost reply, and the model's own countdown task.
final class KeepAwakeP2CopyVerificationTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_GB")
        return c
    }()
    private let locale = Locale(identifier: "en_GB")
    /// Monday 2026-10-26 13:48 UTC.
    private let now = Date(timeIntervalSince1970: 1_793_022_480)

    // MARK: - Rounding

    /// "Minutes round up": every fraction of a minute reads as the next whole minute. The
    /// executor's cases (30 s, x:30) also pass under round-half-away-from-zero; these do not.
    func testAnyFractionOfAMinuteRoundsUpNeverToTheNearest() {
        XCTAssertEqual(KeepAwakeCopy.remaining(0.001), "1 min")
        XCTAssertEqual(KeepAwakeCopy.remaining(1), "1 min")
        XCTAssertEqual(KeepAwakeCopy.remaining(20), "1 min")
        XCTAssertEqual(KeepAwakeCopy.remaining(59.5), "1 min")
        XCTAssertEqual(KeepAwakeCopy.remaining(60), "1 min")
        XCTAssertEqual(KeepAwakeCopy.remaining(60.5), "2 min")
        XCTAssertEqual(KeepAwakeCopy.remaining(4 * 3_600 + 51 * 60 + 10), "4 h 52 min")
        XCTAssertEqual(KeepAwakeCopy.remaining(4 * 3_600 + 51 * 60 + 1), "4 h 52 min")
        XCTAssertEqual(KeepAwakeCopy.remaining(4 * 3_600 + 52 * 60), "4 h 52 min")
    }

    /// The unit switches exactly where the minutes do: 59 min → 60 min is "1 h", an hour and a
    /// second is "1 h 1 min", never "60 min".
    func testTheHourAndDayBoundariesRoundUpIntoTheNextUnit() {
        XCTAssertEqual(KeepAwakeCopy.remaining(59 * 60), "59 min")
        XCTAssertEqual(KeepAwakeCopy.remaining(59 * 60 + 1), "1 h")
        XCTAssertEqual(KeepAwakeCopy.remaining(3_599), "1 h")
        XCTAssertEqual(KeepAwakeCopy.remaining(3_600), "1 h")
        XCTAssertEqual(KeepAwakeCopy.remaining(3_600.5), "1 h 1 min")
        XCTAssertEqual(KeepAwakeCopy.remaining(86_400), "1 d")
        XCTAssertEqual(KeepAwakeCopy.remaining(90_000), "1 d 1 h")
        XCTAssertEqual(KeepAwakeCopy.remaining(604_799.5), "7 d")
        XCTAssertEqual(KeepAwakeCopy.remaining(604_800), "7 d")
    }

    /// The block's minute timer must fire where the shown minute changes: at every offset into
    /// a minute (fractions binary-exact), the anchor is at or before `now`, less than a minute
    /// back, on the deadline's own minute grid, and the text at the anchor is the text now.
    func testTheTickAnchorSitsOnTheDeadlinesMinuteGridAtEveryOffset() {
        let offsets: [TimeInterval] = [0.25, 0.5, 30, 59.5, 60, 60.25, 61, 119.75, 120, 17_471.25, 17_490.5, 17_520, 86_399.5, 604_800]
        for offset in offsets {
            let deadline = now.addingTimeInterval(offset)
            let anchor = KeepAwakeCopy.tickAnchor(deadline: deadline, now: now)
            XCTAssertLessThanOrEqual(anchor, now, "offset \(offset)")
            XCTAssertLessThan(now.timeIntervalSince(anchor), 60, "offset \(offset): the next tick is within a minute")
            XCTAssertEqual(deadline.timeIntervalSince(anchor).truncatingRemainder(dividingBy: 60), 0, accuracy: 1e-6, "offset \(offset): on the grid")
            XCTAssertEqual(
                KeepAwakeCopy.remaining(deadline.timeIntervalSince(anchor)),
                KeepAwakeCopy.remaining(offset),
                "offset \(offset): the text at the anchor is the text now"
            )
        }
    }

    // MARK: - Status precedence and dismissal

    /// armed › ended › approval › idle: an armed mode shows even while the registration reads
    /// "needs approval" (a stale read) and even when a later dismissal exists.
    func testAnArmedModeBeatsApprovalAndAnyDismissal() {
        let deadline = now.addingTimeInterval(3_600)
        let armed = KeepAwakeState.armed(deadline: deadline, floorEnabled: true)
        XCTAssertEqual(
            KeepAwakeCopy.status(registration: .requiresApproval, state: armed, dismissedThrough: now.addingTimeInterval(86_400).timeIntervalSince1970, now: now),
            .armed(deadline: deadline)
        )
    }

    /// A deadline exactly now is already over: ended at the deadline, shown until a dismissal
    /// reaching that moment, and the line says "Ended 13:48" with no countdown left.
    func testADeadlineExactlyNowReadsAsEndedAtThatMoment() {
        let armed = KeepAwakeState.armed(deadline: now, floorEnabled: false)
        XCTAssertEqual(
            KeepAwakeCopy.status(registration: .ready, state: armed, dismissedThrough: 0, now: now),
            .ended(at: now, reason: .deadline)
        )
        XCTAssertEqual(
            KeepAwakeCopy.status(registration: .ready, state: armed, dismissedThrough: now.timeIntervalSince1970, now: now),
            .idle
        )
        XCTAssertEqual(
            KeepAwakeCopy.endedLine(at: now, reason: .deadline, now: now, calendar: calendar, locale: locale),
            "Ended 13:48 · time is up"
        )
        let justBefore = now.addingTimeInterval(-0.001)
        XCTAssertEqual(
            KeepAwakeCopy.status(registration: .ready, state: armed, dismissedThrough: 0, now: justBefore),
            .armed(deadline: now)
        )
    }

    /// The app's own end of a mode and the helper's report of it must be one moment, or the
    /// dismissal of one leaves the other showing: through the engine, the two agree.
    func testTheEnginesDeadlineEndAndTheLocalCountdownHideBehindOneDismissal() {
        var engine = KeepAwakeEngine()
        _ = engine.arm(duration: 600, floorEnabled: true, now: now, lidClosed: false)
        let deadline = now.addingTimeInterval(600)
        let helperSays = engine.tick(now: deadline.addingTimeInterval(37.5), lidClosed: false).state
        let local = KeepAwakeRules.effectiveState(.armed(deadline: deadline, floorEnabled: true), now: deadline.addingTimeInterval(37.5))
        XCTAssertEqual(helperSays, local)
        let dismissed = deadline.timeIntervalSince1970
        for state in [helperSays, local] {
            XCTAssertEqual(
                KeepAwakeCopy.status(registration: .ready, state: state, dismissedThrough: dismissed, now: deadline.addingTimeInterval(40)),
                .idle
            )
        }
    }

    // MARK: - Tooltip and marker once the local deadline has passed

    private func claude() -> UsageSnapshot {
        let service = Fixture.snapshot(
            id: "claude", displayName: "Claude", plan: "Max 20x",
            buckets: [Fixture.bucket(id: "five_hour", label: "Current session", percent: 42, kind: .session)],
            at: now
        )
        return UsageSnapshot(services: [service], fetchedAt: now, isStale: false, lastError: nil)
    }

    /// A deadline a moment ago, with the helper still silent: neither the tooltip's first line
    /// nor the marker outlives it (the local countdown), on a loaded and on a loading tooltip.
    func testAfterTheLocalDeadlineTheTooltipLineAndTheMarkerAreGone() {
        let stale = KeepAwakeState.armed(deadline: now.addingTimeInterval(-1), floorEnabled: true)
        XCTAssertNil(KeepAwakeCopy.menuBarMarker(stale, now: now))
        XCTAssertNil(KeepAwakeCopy.tooltipLine(stale, now: now, calendar: calendar, locale: locale))
        let plain = StatusBarController.tooltipText(snapshot: claude(), mode: .used, now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(
            StatusBarController.tooltipText(snapshot: claude(), mode: .used, keepAwake: stale, now: now, calendar: calendar, locale: locale),
            plain
        )
        let empty = UsageSnapshot(services: [], fetchedAt: Date(timeIntervalSince1970: 0), isStale: false, lastError: nil)
        XCTAssertEqual(
            StatusBarController.tooltipText(snapshot: empty, mode: .used, keepAwake: stale, now: now, calendar: calendar, locale: locale),
            "Omelette — loading…"
        )
    }

    /// The marker is there up to the last instant before the deadline.
    func testTheMarkerStaysUntilTheDeadlineItself() {
        let deadline = now.addingTimeInterval(90)
        let armed = KeepAwakeState.armed(deadline: deadline, floorEnabled: true)
        XCTAssertEqual(KeepAwakeCopy.menuBarMarker(armed, now: deadline.addingTimeInterval(-0.001)), "☾")
        XCTAssertNil(KeepAwakeCopy.menuBarMarker(armed, now: deadline))
    }

    /// A seven-day deadline names its date in the tooltip's first line.
    func testASevenDayDeadlineNamesItsDateInTheTooltip() {
        let text = StatusBarController.tooltipText(
            snapshot: claude(), mode: .used,
            keepAwake: .armed(deadline: now.addingTimeInterval(604_800), floorEnabled: true),
            now: now, calendar: calendar, locale: locale
        )
        XCTAssertEqual(text.components(separatedBy: "\n").first, "Keep awake until 2 Nov, 13:48")
    }
}

/// § Behaviour › Visible and plan D13: a state reply that a command overtook is dropped whole
/// (its failure and its reconcile bookkeeping too), and the model's own countdown retires a
/// mode at its deadline with nobody polling.
final class KeepAwakeP2ModelVerificationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)

    /// A reply held until the test releases it.
    private actor Gate {
        private var waiter: CheckedContinuation<Result<KeepAwakeReply, KeepAwakeFailure>, Never>?
        private var arrival: CheckedContinuation<Void, Never>?
        private var arrived = false

        func wait() async -> Result<KeepAwakeReply, KeepAwakeFailure> {
            arrived = true
            arrival?.resume()
            arrival = nil
            return await withCheckedContinuation { waiter = $0 }
        }

        func untilArrived() async {
            if arrived { return }
            await withCheckedContinuation { arrival = $0 }
        }

        func release(_ result: Result<KeepAwakeReply, KeepAwakeFailure>) {
            waiter?.resume(returning: result)
            waiter = nil
        }
    }

    @MainActor private func makeModel(
        send: @escaping @Sendable (KeepAwakeRequest) async -> Result<KeepAwakeReply, KeepAwakeFailure>
    ) -> KeepAwakeModel {
        var dependencies = KeepAwakeFakeHelper(statuses: [.enabled]).dependencies()
        dependencies.send = send
        return KeepAwakeModel(
            client: KeepAwakeClient(dependencies: dependencies),
            floorEnabled: { true },
            rememberDuration: { _ in },
            resetSettings: {}
        )
    }

    private func answer(_ state: KeepAwakeState) -> Result<KeepAwakeReply, KeepAwakeFailure> {
        .success(KeepAwakeReply(state: state, failure: nil))
    }

    /// The overtaken request was itself a lost reply (a timeout): it says nothing, so it must
    /// not put a failure on a block that just armed, nor flag the model as unreconciled (which
    /// would keep the poll hammering a helper that answered the Apply).
    @MainActor func testAnOvertakenReplyThatWasALostReplyLeavesNoFailureAndNoReconcile() async {
        let t0 = self.t0
        let gate = Gate()
        let model = makeModel { request in
            if case .arm(let seconds, _) = request {
                return .success(KeepAwakeReply(state: .armed(deadline: t0 + seconds, floorEnabled: true), failure: nil))
            }
            return await gate.wait()
        }
        let refresh = Task { await model.refresh(now: t0) }
        await gate.untilArrived()
        await model.arm(days: 0, hours: 2, minutes: 0, now: t0)
        await gate.release(.failure(.helperTimedOut))
        await refresh.value
        XCTAssertEqual(model.state, .armed(deadline: t0 + 7_200, floorEnabled: true))
        XCTAssertNil(model.failure, "a dropped reply leaves no failure behind")
        XCTAssertFalse(model.needsReconcile, "a dropped reply does not mark the state unknown")
        XCTAssertEqual(model.registration, .ready)
    }

    /// The second bump of Cancel (plan D13): a state request sent while Cancel is out is older
    /// than the Cancel's outcome, though it started after the Cancel began; its late "armed"
    /// must not bring the marker back.
    @MainActor func testAStateRequestSentWhileCancelIsInFlightDoesNotBringTheMarkerBack() async {
        let t0 = self.t0
        let command = Gate()
        let state = Gate()
        let model = makeModel { request in
            switch request {
            case .arm(let seconds, _): return .success(KeepAwakeReply(state: .armed(deadline: t0 + seconds, floorEnabled: true), failure: nil))
            case .disarm: return await command.wait()
            case .setFloor, .state: return await state.wait()
            }
        }
        await model.arm(days: 0, hours: 2, minutes: 0, now: t0)
        let cancelling = Task { await model.cancel(now: t0 + 60) }
        await command.untilArrived()
        let refresh = Task { await model.refresh(now: t0 + 61) }
        await state.untilArrived()
        await command.release(answer(.ended(at: t0 + 60, reason: .cancelled)))
        await cancelling.value
        await state.release(answer(.armed(deadline: t0 + 7_200, floorEnabled: true)))
        await refresh.value
        XCTAssertEqual(model.state, .ended(at: t0 + 60, reason: .cancelled))
    }

    /// The same for the floor switch: the helper ended the mode on a low battery when the
    /// switch went on; an older state reply sent meanwhile must not undo that.
    @MainActor func testAStateRequestSentWhileTheFloorSwitchIsInFlightDoesNotUndoIt() async {
        let t0 = self.t0
        let command = Gate()
        let state = Gate()
        let model = makeModel { request in
            switch request {
            case .arm(let seconds, _): return .success(KeepAwakeReply(state: .armed(deadline: t0 + seconds, floorEnabled: false), failure: nil))
            case .setFloor: return await command.wait()
            case .disarm, .state: return await state.wait()
            }
        }
        await model.arm(days: 0, hours: 2, minutes: 0, now: t0)
        let switching = Task { await model.floorChanged(true, now: t0 + 60) }
        await command.untilArrived()
        let refresh = Task { await model.refresh(now: t0 + 61) }
        await state.untilArrived()
        await command.release(answer(.ended(at: t0 + 60, reason: .batteryFloor)))
        await switching.value
        await state.release(answer(.armed(deadline: t0 + 7_200, floorEnabled: false)))
        await refresh.value
        XCTAssertEqual(model.state, .ended(at: t0 + 60, reason: .batteryFloor))
    }

    /// And for Reset keep awake: a state request sent while the reset runs must not bring a
    /// mode back that the reset has just put away.
    @MainActor func testAStateRequestSentWhileAResetIsInFlightDoesNotBringTheModeBack() async {
        let t0 = self.t0
        let command = Gate()
        let state = Gate()
        let model = makeModel { request in
            switch request {
            case .arm(let seconds, _): return .success(KeepAwakeReply(state: .armed(deadline: t0 + seconds, floorEnabled: true), failure: nil))
            case .disarm: return await command.wait()
            case .setFloor, .state: return await state.wait()
            }
        }
        await model.arm(days: 0, hours: 2, minutes: 0, now: t0)
        let resetting = Task { await model.reset(now: t0 + 60) }
        await command.untilArrived()
        let refresh = Task { await model.refresh(now: t0 + 61) }
        await state.untilArrived()
        await command.release(answer(.ended(at: t0 + 60, reason: .cancelled)))
        await resetting.value
        await state.release(answer(.armed(deadline: t0 + 7_200, floorEnabled: true)))
        await refresh.value
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(model.registration, .notRegistered)
    }

    /// Spec § Behaviour › Visible: "keeps a local countdown for the deadline". With the helper
    /// silent and no poll or popover, the model's own task retires the mode a moment after the
    /// deadline, real time: the marker leaves on time.
    @MainActor func testTheLocalCountdownRetiresTheModeAtItsDeadlineWhileTheHelperIsSilent() async {
        let deadline = Date().addingTimeInterval(0.4)
        let model = makeModel { request in
            if case .arm = request { return .success(KeepAwakeReply(state: .armed(deadline: deadline, floorEnabled: true), failure: nil)) }
            return .failure(.helperTimedOut)
        }
        await model.arm(days: 0, hours: 0, minutes: 1, now: Date())
        XCTAssertTrue(model.state.isArmed)
        for _ in 0..<60 where model.state.isArmed {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(model.state, .ended(at: deadline, reason: .deadline))
    }

    /// The same countdown asks the helper once: what it answers is what the block then shows
    /// (a floor end the helper knows and the app does not).
    @MainActor func testTheLocalCountdownsPollTakesTheHelpersWord() async {
        let deadline = Date().addingTimeInterval(0.4)
        let floorEnd = deadline.addingTimeInterval(-0.2)
        let model = makeModel { request in
            if case .arm = request { return .success(KeepAwakeReply(state: .armed(deadline: deadline, floorEnabled: true), failure: nil)) }
            return .success(KeepAwakeReply(state: .ended(at: floorEnd, reason: .batteryFloor), failure: nil))
        }
        await model.arm(days: 0, hours: 0, minutes: 1, now: Date())
        for _ in 0..<60 where model.state.isArmed {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(model.state, .ended(at: floorEnd, reason: .batteryFloor))
    }
}
