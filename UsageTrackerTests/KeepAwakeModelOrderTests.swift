import XCTest
import ServiceManagement
@testable import Omelette

/// Plan review P1b (keep-awake spec 2026-10-26, § Behaviour › Visible): every XPC call has
/// its own connection, so the reply to a state request (popover open, poll) can land after
/// the reply to a later command. The command's outcome stands; the older reply is dropped.
final class KeepAwakeModelOrderTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)

    /// A reply held until the test releases it, as a slow connection would.
    private actor HeldReply {
        private var waiter: CheckedContinuation<Result<KeepAwakeReply, KeepAwakeFailure>, Never>?
        private var arrival: CheckedContinuation<Void, Never>?
        private var asked = false

        /// The helper's side: the request arrived; answer when released.
        func reply() async -> Result<KeepAwakeReply, KeepAwakeFailure> {
            asked = true
            arrival?.resume()
            arrival = nil
            return await withCheckedContinuation { waiter = $0 }
        }

        /// The test's side: returns once the request has reached the helper.
        func untilAsked() async {
            if asked { return }
            await withCheckedContinuation { arrival = $0 }
        }

        func release(_ result: Result<KeepAwakeReply, KeepAwakeFailure>) {
            waiter?.resume(returning: result)
            waiter = nil
        }
    }

    /// The first flag read is held until released, as a slow pmset would be; every later
    /// read answers `later` at once.
    private actor HeldFlag {
        private let later: KeepAwakeFlagReading
        private var waiter: CheckedContinuation<KeepAwakeFlagReading, Never>?
        private var arrival: CheckedContinuation<Void, Never>?
        private var reads = 0

        init(later: KeepAwakeFlagReading) { self.later = later }

        func read() async -> KeepAwakeFlagReading {
            reads += 1
            guard reads == 1 else { return later }
            arrival?.resume()
            arrival = nil
            return await withCheckedContinuation { waiter = $0 }
        }

        /// Returns once the first read has started.
        func untilRead() async {
            if reads > 0 { return }
            await withCheckedContinuation { arrival = $0 }
        }

        func release(_ reading: KeepAwakeFlagReading) {
            waiter?.resume(returning: reading)
            waiter = nil
        }
    }

    /// A helper whose replies come from `send`; registered and approved unless `statuses`
    /// says otherwise (consumed one per `SMAppService` status read, the last one kept);
    /// pmset answers `.neverSet` unless `readFlag` is given.
    @MainActor private func makeModel(
        statuses: [SMAppService.Status] = [.enabled],
        readFlag: (@Sendable () async -> KeepAwakeFlagReading)? = nil,
        send: @escaping @Sendable (KeepAwakeRequest) async -> Result<KeepAwakeReply, KeepAwakeFailure>
    ) -> KeepAwakeModel {
        var dependencies = KeepAwakeFakeHelper(statuses: statuses).dependencies()
        dependencies.send = send
        if let readFlag { dependencies.readFlag = readFlag }
        return KeepAwakeModel(
            client: KeepAwakeClient(dependencies: dependencies),
            floorEnabled: { true },
            rememberDuration: { _ in },
            resetSettings: {}
        )
    }

    /// The ruling's case: the popover opens, Apply follows, the open's reply lands last.
    @MainActor func testARefreshThatAnswersAfterAnApplyDoesNotUndoIt() async {
        let t0 = self.t0
        let state = HeldReply()
        let model = makeModel { request in
            if case .arm(let seconds, _) = request { return answer(.armed(deadline: t0 + seconds, floorEnabled: true)) }
            return await state.reply()
        }
        let refresh = Task { await model.refresh(now: t0) }
        await state.untilAsked()
        await model.arm(days: 0, hours: 2, minutes: 0, now: t0)
        await state.release(answer(.idle))
        await refresh.value
        XCTAssertEqual(model.state, .armed(deadline: t0 + 7_200, floorEnabled: true))
    }

    /// The second bump (plan D13): a state request sent while Apply is out is older too.
    @MainActor func testARefreshStartedWhileApplyIsInFlightDoesNotUndoIt() async {
        let t0 = self.t0
        let arm = HeldReply()
        let state = HeldReply()
        let model = makeModel { request in
            if case .arm = request { return await arm.reply() }
            return await state.reply()
        }
        let applying = Task { await model.arm(days: 0, hours: 2, minutes: 0, now: t0) }
        await arm.untilAsked()
        let refresh = Task { await model.refresh(now: t0) }
        await state.untilAsked()
        await arm.release(answer(.armed(deadline: t0 + 7_200, floorEnabled: true)))
        await applying.value
        await state.release(answer(.idle))
        await refresh.value
        XCTAssertEqual(model.state, .armed(deadline: t0 + 7_200, floorEnabled: true))
    }

    /// The first bump: an older reply that lands while Apply is out is dropped as well.
    @MainActor func testARefreshThatAnswersWhileApplyIsInFlightIsDropped() async {
        let t0 = self.t0
        let arm = HeldReply()
        let state = HeldReply()
        let model = makeModel { request in
            if case .arm = request { return await arm.reply() }
            return await state.reply()
        }
        let refresh = Task { await model.refresh(now: t0) }
        await state.untilAsked()
        let applying = Task { await model.arm(days: 0, hours: 2, minutes: 0, now: t0) }
        await arm.untilAsked()
        await state.release(answer(.ended(at: t0 - 600, reason: .batteryFloor)))
        await refresh.value
        XCTAssertEqual(model.state, .idle, "a reply older than the Apply in flight is dropped")
        await arm.release(answer(.armed(deadline: t0 + 7_200, floorEnabled: true)))
        await applying.value
        XCTAssertEqual(model.state, .armed(deadline: t0 + 7_200, floorEnabled: true))
    }

    @MainActor func testARefreshThatAnswersAfterACancelDoesNotBringTheModeBack() async {
        let t0 = self.t0
        let state = HeldReply()
        let model = makeModel { request in
            switch request {
            case .arm(let seconds, _): return answer(.armed(deadline: t0 + seconds, floorEnabled: true))
            case .disarm: return answer(.ended(at: t0 + 60, reason: .cancelled))
            case .setFloor, .state: return await state.reply()
            }
        }
        await model.arm(days: 0, hours: 2, minutes: 0, now: t0)
        let refresh = Task { await model.refresh(now: t0 + 30) }
        await state.untilAsked()
        await model.cancel(now: t0 + 60)
        await state.release(answer(.armed(deadline: t0 + 7_200, floorEnabled: true)))
        await refresh.value
        XCTAssertEqual(model.state, .ended(at: t0 + 60, reason: .cancelled))
    }

    /// Turning the floor on while on a low battery ends the mode (plan D13, addition 2).
    @MainActor func testARefreshThatAnswersAfterTheFloorEndedTheModeDoesNotBringItBack() async {
        let t0 = self.t0
        let state = HeldReply()
        let model = makeModel { request in
            switch request {
            case .arm(let seconds, _): return answer(.armed(deadline: t0 + seconds, floorEnabled: false))
            case .setFloor: return answer(.ended(at: t0 + 60, reason: .batteryFloor))
            case .disarm, .state: return await state.reply()
            }
        }
        await model.arm(days: 0, hours: 2, minutes: 0, now: t0)
        let refresh = Task { await model.refresh(now: t0 + 30) }
        await state.untilAsked()
        await model.floorChanged(true, now: t0 + 60)
        await state.release(answer(.armed(deadline: t0 + 7_200, floorEnabled: false)))
        await refresh.value
        XCTAssertEqual(model.state, .ended(at: t0 + 60, reason: .batteryFloor))
    }

    @MainActor func testARefreshThatAnswersAfterAResetDoesNotBringTheModeBack() async {
        let t0 = self.t0
        let state = HeldReply()
        let model = makeModel { request in
            switch request {
            case .arm(let seconds, _): return answer(.armed(deadline: t0 + seconds, floorEnabled: true))
            case .disarm: return answer(.ended(at: t0 + 60, reason: .cancelled))
            case .setFloor, .state: return await state.reply()
            }
        }
        await model.arm(days: 0, hours: 2, minutes: 0, now: t0)
        let refresh = Task { await model.refresh(now: t0 + 30) }
        await state.untilAsked()
        await model.reset(now: t0 + 60)
        await state.release(answer(.armed(deadline: t0 + 7_200, floorEnabled: true)))
        await refresh.value
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(model.registration, .notRegistered)
    }

    /// Re-review R1: a refresh that finds the helper unapproved while armed infers a stop and
    /// reads the flag after `ask`'s check passed; a Reset that finishes during that read is
    /// newer, so the late read changes nothing.
    @MainActor func testARefreshThatInfersAStopAfterAResetDoesNotUndoIt() async {
        let t0 = self.t0
        let flag = HeldFlag(later: .cleared)
        let model = makeModel(statuses: [.enabled, .requiresApproval], readFlag: { await flag.read() }) { request in
            if case .arm(let seconds, _) = request { return answer(.armed(deadline: t0 + seconds, floorEnabled: true)) }
            return answer(.idle)
        }
        await model.arm(days: 0, hours: 2, minutes: 0, now: t0)
        let refresh = Task { await model.refresh(now: t0 + 30) }
        await flag.untilRead()
        await model.reset(now: t0 + 60)
        await flag.release(.set)
        await refresh.value
        XCTAssertEqual(model.flag, .cleared)
        XCTAssertNil(model.failure)
        XCTAssertFalse(model.resetIncomplete)
    }

    /// No command in between: the refresh's reply is the newest word and lands as before.
    @MainActor func testARefreshWithNoCommandInBetweenStillLands() async {
        let t0 = self.t0
        let state = HeldReply()
        let model = makeModel { _ in await state.reply() }
        let refresh = Task { await model.refresh(now: t0) }
        await state.untilAsked()
        await state.release(answer(.armed(deadline: t0 + 600, floorEnabled: true)))
        await refresh.value
        XCTAssertEqual(model.state, .armed(deadline: t0 + 600, floorEnabled: true))
        XCTAssertEqual(model.registration, .ready)
    }
}

/// The helper's answer: a state, no failure.
private func answer(_ state: KeepAwakeState) -> Result<KeepAwakeReply, KeepAwakeFailure> {
    .success(KeepAwakeReply(state: state, failure: nil))
}
