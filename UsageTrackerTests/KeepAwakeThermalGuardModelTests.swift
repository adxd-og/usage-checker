import XCTest
import ServiceManagement
@testable import Omelette

/// The fake helper's thermal guard, shared with its reply closure: what it holds (every `arm`
/// turns it on, as the engine does), whether it answers with it (`knowsGuard: false` answers as
/// 4.3.0 does), and how many `setThermalGuard` calls and arm replies the transport loses.
private final class FakeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var held: Bool
    private var lostSets = 0
    private var lostArmReplies = 0
    let knowsGuard: Bool

    init(held: Bool = true, knowsGuard: Bool = true) {
        self.held = held
        self.knowsGuard = knowsGuard
    }

    var value: Bool { lock.withLock { held } }
    func loseSets(_ count: Int) { lock.withLock { lostSets = count } }
    func loseArmReplies(_ count: Int) { lock.withLock { lostArmReplies = count } }

    /// An arm turns the guard on; false when its reply is lost (the helper armed all the same).
    func arm() -> Bool {
        lock.withLock {
            held = true
            if lostArmReplies > 0 { lostArmReplies -= 1; return false }
            return true
        }
    }

    /// A `setThermalGuard`; false when the call is lost, and then nothing changed.
    func set(_ value: Bool) -> Bool {
        lock.withLock {
            if lostSets > 0 { lostSets -= 1; return false }
            held = value
            return true
        }
    }
}

/// A reply held until the test releases it, as a slow connection would
/// (`KeepAwakeModelOrderTests`' pattern).
private actor HeldReply {
    private var waiter: CheckedContinuation<Result<KeepAwakeReply, KeepAwakeFailure>, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    private var asked = false

    func reply() async -> Result<KeepAwakeReply, KeepAwakeFailure> {
        asked = true
        arrival?.resume()
        arrival = nil
        return await withCheckedContinuation { waiter = $0 }
    }

    func untilAsked() async {
        if asked { return }
        await withCheckedContinuation { arrival = $0 }
    }

    func release(_ result: Result<KeepAwakeReply, KeepAwakeFailure>) {
        waiter?.resume(returning: result)
        waiter = nil
    }
}

/// The requests the helper received, in order.
private actor RequestLog {
    private(set) var requests: [KeepAwakeRequest] = []
    func append(_ request: KeepAwakeRequest) { requests.append(request) }
}

/// The setting the model reads, changed by the tests.
@MainActor private final class Setting {
    var enabled = true
}

/// Spec 2026-11-19 keep-awake thermal guard, § Settings ("A change while armed reaches the
/// daemon at once, like `setFloor`"), § Daemon ("a daemon that predates the guard is asked
/// nothing new") and § Plan decisions accepted by the session, items 5 and 6 ("The app
/// reconciles after EVERY reply while armed, the poll's included"): one send per disagreeing
/// reply, none while a send is out, none to a helper whose reply has no `thermalGuard`.
final class KeepAwakeThermalGuardModelTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)
    private var armed: KeepAwakeState { .armed(deadline: t0 + 7_200, floorEnabled: true) }

    @MainActor private func makeModel(_ helper: KeepAwakeFakeHelper, _ setting: Setting) -> KeepAwakeModel {
        KeepAwakeModel(
            client: KeepAwakeClient(dependencies: helper.dependencies()),
            floorEnabled: { true },
            rememberDuration: { _ in },
            resetSettings: {},
            thermalGuardEnabled: { setting.enabled }
        )
    }

    /// A ready helper armed for two hours from t0, whose guard is `guardState`: it answers with
    /// the guard as it holds it, and a call the transport loses answers `.helperTimedOut`.
    private func helper(_ guardState: FakeGuard = FakeGuard()) -> KeepAwakeFakeHelper {
        let t0 = self.t0
        return KeepAwakeFakeHelper(statuses: [.enabled]) { request in
            switch request {
            case .arm:
                if !guardState.arm() { return .failure(.helperTimedOut) }
            case .setThermalGuard(let enabled):
                if !guardState.set(enabled) { return .failure(.helperTimedOut) }
            case .disarm, .setFloor, .state:
                break
            }
            let state: KeepAwakeState = request == .disarm
                ? .ended(at: t0 + 60, reason: .cancelled)
                : .armed(deadline: t0 + 7_200, floorEnabled: true)
            return .success(KeepAwakeReply(
                state: state,
                failure: nil,
                thermal: guardState.knowsGuard ? .nominal : nil,
                thermalGuard: guardState.knowsGuard ? guardState.value : nil
            ))
        }
    }

    func testTheClientSendsTheSwitchToAReadyHelperAndReadsWhatItHolds() async {
        let helper = helper()
        let client = KeepAwakeClient(dependencies: helper.dependencies())
        let outcome = await client.setThermalGuard(enabled: false)
        XCTAssertEqual(helper.requests, [.setThermalGuard(enabled: false)])
        XCTAssertEqual(
            outcome,
            KeepAwakeOutcome(registration: .ready, state: .armed(deadline: t0 + 7_200, floorEnabled: true), failure: nil, thermalGuard: false)
        )
    }

    func testAHelperThatIsNotReadyIsNotAskedAboutTheGuard() async {
        let helper = KeepAwakeFakeHelper(statuses: [.requiresApproval])
        let client = KeepAwakeClient(dependencies: helper.dependencies())
        let outcome = await client.setThermalGuard(enabled: false)
        XCTAssertEqual(helper.requests, [])
        XCTAssertEqual(outcome, KeepAwakeOutcome(registration: .requiresApproval, state: nil, failure: nil))
    }

    @MainActor func testApplyLeavesAGuardThatMatchesTheSettingAlone() async {
        let helper = helper()
        let model = makeModel(helper, Setting())
        await model.arm(days: 0, hours: 2, minutes: 0, now: t0)
        XCTAssertEqual(helper.requests, [.arm(seconds: 7_200, floorEnabled: true)])
        XCTAssertEqual(model.helperThermalGuard, true)
    }

    /// Every Apply turns the helper's guard on, so a setting turned off is sent right after it,
    /// from the arm's own reply.
    @MainActor func testApplyTurnsTheHelpersGuardOffWhenTheSettingIsOff() async {
        let helper = helper()
        let setting = Setting()
        setting.enabled = false
        let model = makeModel(helper, setting)
        await model.arm(days: 0, hours: 2, minutes: 0, now: t0)
        XCTAssertEqual(helper.requests, [.arm(seconds: 7_200, floorEnabled: true), .setThermalGuard(enabled: false)])
        XCTAssertEqual(model.helperThermalGuard, false)
        XCTAssertEqual(model.state, armed)
        XCTAssertFalse(model.isWorking)
    }

    /// An update during an armed mode keeps the 4.3.0 helper running: a reply without the field
    /// is never answered with `setThermalGuard`, after Apply, on a flip or on a poll.
    @MainActor func testAHelperBeforeTheGuardIsAskedNothingNew() async {
        let helper = helper(FakeGuard(knowsGuard: false))
        let setting = Setting()
        setting.enabled = false
        let model = makeModel(helper, setting)
        await model.arm(days: 0, hours: 2, minutes: 0, now: t0)
        setting.enabled = true
        await model.thermalGuardChanged(true, now: t0 + 60)
        await model.pollIfNeeded(now: t0 + 120)
        await model.pollIfNeeded(now: t0 + 180)
        XCTAssertEqual(helper.requests, [.arm(seconds: 7_200, floorEnabled: true), .state, .state])
        XCTAssertNil(model.helperThermalGuard)
    }

    @MainActor func testTheSwitchReachesAnArmedHelperAtOnce() async {
        let helper = helper()
        let setting = Setting()
        let model = makeModel(helper, setting)
        await model.arm(days: 0, hours: 2, minutes: 0, now: t0)
        setting.enabled = false
        await model.thermalGuardChanged(false, now: t0 + 60)
        XCTAssertEqual(helper.requests, [.arm(seconds: 7_200, floorEnabled: true), .setThermalGuard(enabled: false)])
        XCTAssertEqual(model.helperThermalGuard, false)
    }

    /// The helper holds the guard off (an earlier mode, a lost switch-on) while Settings has it
    /// on, and the first correction is lost. The next poll's reply sends it again; once they
    /// agree, a poll sends nothing.
    @MainActor func testALostCorrectionIsSentAgainByTheNextPollAndStopsOnceTheyAgree() async {
        let guardState = FakeGuard(held: false)
        guardState.loseSets(1)
        let helper = helper(guardState)
        let model = makeModel(helper, Setting())
        await model.refresh(now: t0)
        XCTAssertEqual(helper.requests, [.state, .setThermalGuard(enabled: true)], "the first correction is lost")
        XCTAssertEqual(model.failure, .helperTimedOut)
        await model.pollIfNeeded(now: t0 + 60)
        XCTAssertEqual(helper.requests, [.state, .setThermalGuard(enabled: true), .state, .setThermalGuard(enabled: true)])
        XCTAssertEqual(model.helperThermalGuard, true)
        await model.pollIfNeeded(now: t0 + 120)
        XCTAssertEqual(
            helper.requests,
            [.state, .setThermalGuard(enabled: true), .state, .setThermalGuard(enabled: true), .state],
            "a poll after agreement sends nothing"
        )
    }

    /// A flip to on lost while armed is sent again at the next poll.
    @MainActor func testASwitchOnLostWhileArmedIsSentAgainAtTheNextPoll() async {
        let guardState = FakeGuard()
        let helper = helper(guardState)
        let setting = Setting()
        let model = makeModel(helper, setting)
        await model.arm(days: 0, hours: 2, minutes: 0, now: t0)
        setting.enabled = false
        await model.thermalGuardChanged(false, now: t0 + 60)
        setting.enabled = true
        guardState.loseSets(1)
        await model.thermalGuardChanged(true, now: t0 + 120)
        XCTAssertFalse(guardState.value, "the switch-on was lost")
        await model.pollIfNeeded(now: t0 + 180)
        XCTAssertEqual(helper.requests, [
            .arm(seconds: 7_200, floorEnabled: true),
            .setThermalGuard(enabled: false),
            .setThermalGuard(enabled: true),
            .state,
            .setThermalGuard(enabled: true),
        ])
        XCTAssertTrue(guardState.value)
        XCTAssertEqual(model.helperThermalGuard, true)
    }

    /// Apply's own reply is lost (the helper armed, with its guard on); the first reply that
    /// arrives brings the "off" setting.
    @MainActor func testAnApplyWhoseReplyWasLostIsCorrectedByTheFirstReplyThatArrives() async {
        let guardState = FakeGuard()
        guardState.loseArmReplies(1)
        let helper = helper(guardState)
        let setting = Setting()
        setting.enabled = false
        let model = makeModel(helper, setting)
        await model.arm(days: 0, hours: 2, minutes: 0, now: t0)
        XCTAssertEqual(model.state, .idle, "the reply was lost")
        XCTAssertEqual(helper.requests, [.arm(seconds: 7_200, floorEnabled: true)])
        await model.pollIfNeeded(now: t0 + 60)
        XCTAssertEqual(helper.requests, [.arm(seconds: 7_200, floorEnabled: true), .state, .setThermalGuard(enabled: false)])
        XCTAssertFalse(guardState.value)
        XCTAssertEqual(model.state, armed)
    }

    /// While a correction is out, a poll whose reply still disagrees sends nothing more.
    @MainActor func testNoSecondSendWhileOneIsOut() async {
        let t0 = self.t0
        let correction = HeldReply()
        let log = RequestLog()
        var dependencies = KeepAwakeFakeHelper(statuses: [.enabled]).dependencies()
        dependencies.send = { request in
            await log.append(request)
            if case .setThermalGuard = request { return await correction.reply() }
            return .success(KeepAwakeReply(state: .armed(deadline: t0 + 7_200, floorEnabled: true), failure: nil, thermal: .nominal, thermalGuard: false))
        }
        let model = KeepAwakeModel(
            client: KeepAwakeClient(dependencies: dependencies),
            floorEnabled: { true },
            rememberDuration: { _ in },
            resetSettings: {},
            thermalGuardEnabled: { true }
        )
        let refresh = Task { await model.refresh(now: t0) }
        await correction.untilAsked()
        await model.pollIfNeeded(now: t0 + 10)
        await correction.release(.success(KeepAwakeReply(state: .armed(deadline: t0 + 7_200, floorEnabled: true), failure: nil, thermal: .nominal, thermalGuard: true)))
        await refresh.value
        let requests = await log.requests
        XCTAssertEqual(requests, [.state, .setThermalGuard(enabled: true), .state])
        XCTAssertEqual(model.helperThermalGuard, true)
    }

    @MainActor func testTheSwitchWhileIdleStaysInSettings() async {
        let helper = helper()
        let model = makeModel(helper, Setting())
        await model.thermalGuardChanged(false, now: t0)
        XCTAssertEqual(helper.requests, [])
    }

    /// Every answer says what the helper holds, so a helper that has since been replaced by the
    /// updated one is known from its next answer.
    @MainActor func testEveryAnswerTellsTheModelWhetherTheHelperKnowsTheGuard() async {
        let helper = helper(FakeGuard(knowsGuard: false))
        let model = makeModel(helper, Setting())
        await model.refresh(now: t0)
        XCTAssertNil(model.helperThermalGuard)
        helper.with { s in
            s.reply = { _ in .success(KeepAwakeReply(state: .idle, failure: nil, thermal: .fair, thermalGuard: true)) }
        }
        await model.refresh(now: t0 + 60)
        XCTAssertEqual(model.helperThermalGuard, true)
    }

    /// A lost reply leaves the helper's state unknown; what it last said of its guard stands.
    @MainActor func testALostReplyKeepsWhatTheHelperLastSaidOfItsGuard() async {
        let helper = helper()
        let model = makeModel(helper, Setting())
        await model.arm(days: 0, hours: 2, minutes: 0, now: t0)
        helper.with { $0.reply = { _ in .failure(.helperTimedOut) } }
        await model.pollIfNeeded(now: t0 + 60)
        XCTAssertEqual(model.helperThermalGuard, true)
    }
}

/// The helper as the ordering tests need it. It takes requests in the order they arrive and
/// keeps a mode and a guard as the engine does: an `arm` starts the mode and turns the guard on,
/// a `setThermalGuard` sets the guard, a `disarm` ends the mode. Each answer says what the
/// helper held right after its own request, and lands at once unless the test holds it back, as
/// a slow connection would; a held answer is an old one by the time it lands.
private actor SlowHelper {
    private let t0: Date
    private var state: KeepAwakeState
    private var guardOn: Bool
    private(set) var requests: [KeepAwakeRequest] = []
    private var heldBack: Set<Int> = []
    private var held: [Int: CheckedContinuation<Void, Never>] = [:]
    private var arrivals: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(t0: Date, state: KeepAwakeState, guardOn: Bool) {
        self.t0 = t0
        self.state = state
        self.guardOn = guardOn
    }

    var guardIsOn: Bool { guardOn }

    /// Holds back the answer to the request at this place in the order of arrival, from 0.
    func holdAnswer(to index: Int) { heldBack.insert(index) }

    /// The mode ended by itself; the app has not heard yet.
    func end(_ ended: KeepAwakeState) { state = ended }

    func send(_ request: KeepAwakeRequest) async -> Result<KeepAwakeReply, KeepAwakeFailure> {
        let index = requests.count
        requests.append(request)
        switch request {
        case .arm(let seconds, let floorEnabled):
            state = .armed(deadline: t0 + seconds, floorEnabled: floorEnabled)
            guardOn = true
        case .disarm:
            if state.isArmed { state = .ended(at: t0 + 60, reason: .cancelled) }
        case .setThermalGuard(let enabled):
            guardOn = enabled
        case .setFloor, .state:
            break
        }
        let reply = KeepAwakeReply(state: state, failure: nil, thermal: .nominal, thermalGuard: guardOn)
        let reached = arrivals.filter { $0.count <= requests.count }
        arrivals.removeAll { $0.count <= requests.count }
        reached.forEach { $0.continuation.resume() }
        if heldBack.contains(index) {
            await withCheckedContinuation { held[index] = $0 }
        }
        return .success(reply)
    }

    /// Returns once this many requests have arrived.
    func untilArrived(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { arrivals.append((count, $0)) }
    }

    /// Lets the held answer land.
    func release(_ index: Int) {
        held.removeValue(forKey: index)?.resume()
    }
}

/// Spec 2026-11-19 keep-awake thermal guard, § Settings and § Plan decisions accepted by the
/// session, item 6, where calls overlap: each XPC call has its own connection, and the
/// correction goes out with no spinner holding the card's buttons, so the switch, Apply, Cancel,
/// Reset and the poll can all land while a `setThermalGuard` is out. One call is out at a time
/// and carries the setting as it reads when it goes out; a switch that moved meanwhile follows
/// when the call returns; an answer a later command overtook brings nothing back; and nothing
/// repeats without a new reply or a new flip.
final class KeepAwakeThermalGuardOrderTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)
    private var armed: KeepAwakeState { .armed(deadline: t0 + 7_200, floorEnabled: true) }

    @MainActor private func makeModel(
        _ setting: Setting,
        send: @escaping @Sendable (KeepAwakeRequest) async -> Result<KeepAwakeReply, KeepAwakeFailure>
    ) -> KeepAwakeModel {
        var dependencies = KeepAwakeFakeHelper(statuses: [.enabled]).dependencies()
        dependencies.send = send
        return KeepAwakeModel(
            client: KeepAwakeClient(dependencies: dependencies),
            floorEnabled: { true },
            rememberDuration: { _ in },
            resetSettings: {},
            thermalGuardEnabled: { setting.enabled }
        )
    }

    @MainActor private func makeModel(_ helper: SlowHelper, _ setting: Setting) -> KeepAwakeModel {
        makeModel(setting) { await helper.send($0) }
    }

    /// A helper armed until t0 + 2 h, its guard as given.
    private func armedHelper(guardOn: Bool) -> SlowHelper {
        SlowHelper(t0: t0, state: armed, guardOn: guardOn)
    }

    // MARK: - The switch while a call is out

    /// The correction is out when the user turns the guard off. Nothing goes out beside it (two
    /// calls on two connections could reach the helper in either order); when it returns, the
    /// setting as it then reads is sent, so the helper ends up as Settings has it.
    @MainActor func testASwitchFlippedWhileACorrectionIsOutIsSentWhenItReturns() async {
        let t0 = self.t0
        let helper = armedHelper(guardOn: false)
        let setting = Setting()
        let model = makeModel(helper, setting)
        await helper.holdAnswer(to: 1)
        let refresh = Task { await model.refresh(now: t0) }
        await helper.untilArrived(2)
        XCTAssertFalse(model.isWorking, "a correction shows no spinner")
        setting.enabled = false
        await model.thermalGuardChanged(false, now: t0 + 1)
        var requests = await helper.requests
        XCTAssertEqual(requests, [.state, .setThermalGuard(enabled: true)], "one call at a time")
        await helper.release(1)
        await refresh.value
        requests = await helper.requests
        XCTAssertEqual(requests, [.state, .setThermalGuard(enabled: true), .setThermalGuard(enabled: false)])
        let guardIsOn = await helper.guardIsOn
        XCTAssertFalse(guardIsOn)
        XCTAssertEqual(model.helperThermalGuard, false)
        XCTAssertEqual(model.state, armed)
    }

    /// Off and on again while a call carrying "on" is out: the setting reads as it was sent, so
    /// nothing follows.
    @MainActor func testASwitchFlippedThereAndBackWhileACallIsOutSendsNothingMore() async {
        let t0 = self.t0
        let helper = armedHelper(guardOn: false)
        let setting = Setting()
        let model = makeModel(helper, setting)
        await helper.holdAnswer(to: 1)
        let refresh = Task { await model.refresh(now: t0) }
        await helper.untilArrived(2)
        setting.enabled = false
        await model.thermalGuardChanged(false, now: t0 + 1)
        setting.enabled = true
        await model.thermalGuardChanged(true, now: t0 + 2)
        await helper.release(1)
        await refresh.value
        let requests = await helper.requests
        XCTAssertEqual(requests, [.state, .setThermalGuard(enabled: true)])
        let guardIsOn = await helper.guardIsOn
        XCTAssertTrue(guardIsOn)
        XCTAssertEqual(model.helperThermalGuard, true)
    }

    // MARK: - The switch and Apply

    /// The switch goes off while the first Apply is out: nothing is armed yet, so the flip sends
    /// nothing, and the arm's reply is held against the setting as it reads when it lands.
    @MainActor func testASwitchFlippedWhileTheFirstApplyIsOutIsBroughtByItsReply() async {
        let t0 = self.t0
        let helper = SlowHelper(t0: t0, state: .idle, guardOn: true)
        let setting = Setting()
        let model = makeModel(helper, setting)
        await helper.holdAnswer(to: 0)
        let applying = Task { await model.arm(days: 0, hours: 2, minutes: 0, now: t0) }
        await helper.untilArrived(1)
        setting.enabled = false
        await model.thermalGuardChanged(false, now: t0 + 1)
        var requests = await helper.requests
        XCTAssertEqual(requests, [.arm(seconds: 7_200, floorEnabled: true)])
        await helper.release(0)
        await applying.value
        requests = await helper.requests
        XCTAssertEqual(requests, [.arm(seconds: 7_200, floorEnabled: true), .setThermalGuard(enabled: false)])
        let guardIsOn = await helper.guardIsOn
        XCTAssertFalse(guardIsOn)
        XCTAssertEqual(model.state, armed)
        XCTAssertFalse(model.isWorking)
    }

    /// The switch goes off while an Apply over an armed mode is out, and the helper takes the
    /// arm first: the switch's answer lands, then the arm's older one, which still says "on".
    /// That reply disagrees with no call out, so the setting is sent once more, and it ends
    /// there.
    @MainActor func testAnApplysOlderAnswerThatLandsAfterTheSwitchsGetsOneMoreSend() async {
        let t0 = self.t0
        let helper = armedHelper(guardOn: true)
        let setting = Setting()
        let model = makeModel(helper, setting)
        await model.refresh(now: t0)
        await helper.holdAnswer(to: 1)
        await helper.holdAnswer(to: 2)
        let applying = Task { await model.arm(days: 0, hours: 4, minutes: 0, now: t0 + 10) }
        await helper.untilArrived(2)
        setting.enabled = false
        let flipping = Task { await model.thermalGuardChanged(false, now: t0 + 11) }
        await helper.untilArrived(3)
        await helper.release(2)
        await flipping.value
        await helper.release(1)
        await applying.value
        let requests = await helper.requests
        XCTAssertEqual(requests, [
            .state,
            .arm(seconds: 14_400, floorEnabled: true),
            .setThermalGuard(enabled: false),
            .setThermalGuard(enabled: false),
        ])
        let guardIsOn = await helper.guardIsOn
        XCTAssertFalse(guardIsOn)
        XCTAssertEqual(model.state, .armed(deadline: t0 + 14_400, floorEnabled: true))
        XCTAssertEqual(model.helperThermalGuard, false)
    }

    /// A correction is out when the user applies a longer mode, and its answer lands last. It
    /// was taken before the arm, so it shows the old deadline: the Apply's reply is the newer
    /// word and stands. The arm turned the guard back on; the next poll's reply says so and the
    /// setting is sent again.
    @MainActor func testACorrectionThatAnswersAfterAnApplyDoesNotBringTheOldDeadlineBack() async {
        let t0 = self.t0
        let helper = armedHelper(guardOn: true)
        let setting = Setting()
        setting.enabled = false
        let model = makeModel(helper, setting)
        await helper.holdAnswer(to: 1)
        let refresh = Task { await model.refresh(now: t0) }
        await helper.untilArrived(2)
        await model.arm(days: 0, hours: 4, minutes: 0, now: t0 + 10)
        await helper.release(1)
        await refresh.value
        var requests = await helper.requests
        XCTAssertEqual(requests, [.state, .setThermalGuard(enabled: false), .arm(seconds: 14_400, floorEnabled: true)])
        XCTAssertEqual(model.state, .armed(deadline: t0 + 14_400, floorEnabled: true))
        await model.pollIfNeeded(now: t0 + 60)
        requests = await helper.requests
        XCTAssertEqual(requests, [
            .state,
            .setThermalGuard(enabled: false),
            .arm(seconds: 14_400, floorEnabled: true),
            .state,
            .setThermalGuard(enabled: false),
        ])
        let guardIsOn = await helper.guardIsOn
        XCTAssertFalse(guardIsOn)
        XCTAssertEqual(model.state, .armed(deadline: t0 + 14_400, floorEnabled: true))
    }

    // MARK: - The mode ending while a call is out

    /// The correction's answer was taken while the mode was armed and lands after the Cancel's.
    @MainActor func testACorrectionThatAnswersAfterACancelDoesNotBringTheModeBack() async {
        let t0 = self.t0
        let helper = armedHelper(guardOn: false)
        let model = makeModel(helper, Setting())
        await helper.holdAnswer(to: 1)
        let refresh = Task { await model.refresh(now: t0) }
        await helper.untilArrived(2)
        await model.cancel(now: t0 + 60)
        await helper.release(1)
        await refresh.value
        let requests = await helper.requests
        XCTAssertEqual(requests, [.state, .setThermalGuard(enabled: true), .disarm])
        XCTAssertEqual(model.state, .ended(at: t0 + 60, reason: .cancelled))
    }

    /// The same for Reset keep awake: the helper is gone, and a late "armed" must not show it.
    @MainActor func testACorrectionThatAnswersAfterAResetDoesNotBringTheModeBack() async {
        let t0 = self.t0
        let helper = armedHelper(guardOn: false)
        let model = makeModel(helper, Setting())
        await helper.holdAnswer(to: 1)
        let refresh = Task { await model.refresh(now: t0) }
        await helper.untilArrived(2)
        await model.reset(now: t0 + 60)
        await helper.release(1)
        await refresh.value
        let requests = await helper.requests
        XCTAssertEqual(requests, [.state, .setThermalGuard(enabled: true), .disarm])
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(model.registration, .notRegistered)
        XCTAssertNil(model.failure)
        XCTAssertFalse(model.needsReconcile)
    }

    /// The helper ended the mode by itself before the switch reached it, and the switch moved
    /// back while that call was out. Its answer shows the end, and a switch with nothing armed
    /// stays in Settings: no call follows.
    @MainActor func testASwitchSentToAModeThatHadEndedShowsTheEndAndIsNotFollowed() async {
        let t0 = self.t0
        let helper = armedHelper(guardOn: true)
        let setting = Setting()
        let model = makeModel(helper, setting)
        await model.refresh(now: t0)
        let ended = KeepAwakeState.ended(at: t0 + 30, reason: .batteryFloor)
        await helper.end(ended)
        await helper.holdAnswer(to: 1)
        setting.enabled = false
        let flipping = Task { await model.thermalGuardChanged(false, now: t0 + 40) }
        await helper.untilArrived(2)
        setting.enabled = true
        await model.thermalGuardChanged(true, now: t0 + 41)
        await helper.release(1)
        await flipping.value
        await model.pollIfNeeded(now: t0 + 60)
        let requests = await helper.requests
        XCTAssertEqual(requests, [.state, .setThermalGuard(enabled: false)])
        XCTAssertEqual(model.state, ended)
        XCTAssertFalse(model.isWorking)
    }

    // MARK: - Replies older than a call

    /// A poll's answer taken before the switch moved lands after the switch's: it is older than
    /// a command and is dropped, so its "on" sends nothing.
    @MainActor func testAPollsAnswerOlderThanTheSwitchsSendsNothing() async {
        let t0 = self.t0
        let helper = armedHelper(guardOn: true)
        let setting = Setting()
        let model = makeModel(helper, setting)
        await model.refresh(now: t0)
        await helper.holdAnswer(to: 1)
        let polling = Task { await model.pollIfNeeded(now: t0 + 10) }
        await helper.untilArrived(2)
        setting.enabled = false
        await model.thermalGuardChanged(false, now: t0 + 11)
        await helper.release(1)
        await polling.value
        let requests = await helper.requests
        XCTAssertEqual(requests, [.state, .state, .setThermalGuard(enabled: false)])
        XCTAssertEqual(model.helperThermalGuard, false)
    }

    // MARK: - No loop

    /// A helper that ignores the switch and always answers "off": each of its state replies gets
    /// one send, and the send's own disagreeing answer gets none.
    @MainActor func testAHelperThatAlwaysAnswersOtherwiseGetsOneSendPerReplyAndNoMore() async {
        let armed = self.armed
        let log = RequestLog()
        let model = makeModel(Setting()) { request in
            await log.append(request)
            return .success(KeepAwakeReply(state: armed, failure: nil, thermal: .nominal, thermalGuard: false))
        }
        await model.refresh(now: t0)
        var requests = await log.requests
        XCTAssertEqual(requests, [.state, .setThermalGuard(enabled: true)])
        await model.pollIfNeeded(now: t0 + 60)
        await model.pollIfNeeded(now: t0 + 120)
        requests = await log.requests
        XCTAssertEqual(requests, [
            .state, .setThermalGuard(enabled: true),
            .state, .setThermalGuard(enabled: true),
            .state, .setThermalGuard(enabled: true),
        ])
        XCTAssertEqual(model.helperThermalGuard, false)
    }

    /// A transport that loses every `setThermalGuard`: each later reply that disagrees gets one
    /// more, and a lost call is not repeated by itself.
    @MainActor func testATransportThatLosesEverySendGetsOneMorePerReply() async {
        let armed = self.armed
        let log = RequestLog()
        let model = makeModel(Setting()) { request in
            await log.append(request)
            if case .setThermalGuard = request { return .failure(.helperTimedOut) }
            return .success(KeepAwakeReply(state: armed, failure: nil, thermal: .nominal, thermalGuard: false))
        }
        await model.refresh(now: t0)
        var requests = await log.requests
        XCTAssertEqual(requests, [.state, .setThermalGuard(enabled: true)])
        XCTAssertEqual(model.helperThermalGuard, false, "a call that brought no reply leaves what the helper last said")
        await model.pollIfNeeded(now: t0 + 60)
        await model.pollIfNeeded(now: t0 + 120)
        requests = await log.requests
        XCTAssertEqual(requests, [
            .state, .setThermalGuard(enabled: true),
            .state, .setThermalGuard(enabled: true),
            .state, .setThermalGuard(enabled: true),
        ])
        XCTAssertEqual(model.state, armed)
    }

    // MARK: - A helper that changed since its last reply

    /// The helper that answered with the guard was replaced by one that predates it (a
    /// downgrade): the flip's call, sent on the strength of the last reply, is lost, the next
    /// reply has no guard, and from then on nothing is asked.
    @MainActor func testAFlipToAHelperReplacedByOneWithoutTheGuardIsTheLastOneSent() async {
        let armed = self.armed
        let helper = KeepAwakeFakeHelper(statuses: [.enabled]) { _ in
            .success(KeepAwakeReply(state: armed, failure: nil, thermal: .nominal, thermalGuard: true))
        }
        let setting = Setting()
        let model = makeModel(setting, send: helper.dependencies().send)
        await model.refresh(now: t0)
        helper.with { s in
            s.reply = { request in
                if case .setThermalGuard = request { return .failure(.helperTimedOut) }
                return .success(KeepAwakeReply(state: armed, failure: nil))
            }
        }
        setting.enabled = false
        await model.thermalGuardChanged(false, now: t0 + 10)
        XCTAssertEqual(helper.requests, [.state, .setThermalGuard(enabled: false)])
        await model.pollIfNeeded(now: t0 + 60)
        XCTAssertNil(model.helperThermalGuard)
        setting.enabled = true
        await model.thermalGuardChanged(true, now: t0 + 70)
        await model.pollIfNeeded(now: t0 + 120)
        XCTAssertEqual(helper.requests, [.state, .setThermalGuard(enabled: false), .state, .state])
        XCTAssertEqual(model.state, armed)
    }
}
