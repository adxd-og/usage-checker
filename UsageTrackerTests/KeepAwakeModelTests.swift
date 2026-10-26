import XCTest
import ServiceManagement
@testable import Omelette

/// Spec 2026-10-26 § Behaviour › Visible ("while armed the app asks the daemon for state() on
/// every poll … and keeps a local countdown"), § Behaviour › Floor switch while armed, § UI
/// (last used values remembered; Reset keep awake); review C1 (an incomplete reset says so),
/// C3 (a helper launchd stopped ended the mode) and C7 (a lost reply is reconciled). The
/// model Package 2's block and marker read.
final class KeepAwakeModelTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)

    /// What the model asked of the settings store.
    @MainActor private final class Prefs {
        var floorEnabled = true
        var remembered: [Int] = []
        var resets = 0
    }

    @MainActor private func makeModel(_ helper: KeepAwakeFakeHelper, _ prefs: Prefs) -> KeepAwakeModel {
        KeepAwakeModel(
            client: KeepAwakeClient(dependencies: helper.dependencies()),
            floorEnabled: { prefs.floorEnabled },
            rememberDuration: { prefs.remembered.append($0) },
            resetSettings: { prefs.resets += 1 }
        )
    }

    /// A ready helper that does what it is asked, relative to t0.
    private func armingHelper(statuses: [SMAppService.Status] = [.enabled]) -> KeepAwakeFakeHelper {
        let t0 = self.t0
        return KeepAwakeFakeHelper(statuses: statuses) { request in
            switch request {
            case .arm(let seconds, let floor):
                return .success(KeepAwakeReply(state: .armed(deadline: t0 + seconds, floorEnabled: floor), failure: nil))
            case .disarm:
                return .success(KeepAwakeReply(state: .ended(at: t0 + 60, reason: .cancelled), failure: nil))
            case .setFloor(let enabled):
                return .success(KeepAwakeReply(state: .armed(deadline: t0 + 7_200, floorEnabled: enabled), failure: nil))
            case .state:
                return .success(KeepAwakeReply(state: .armed(deadline: t0 + 7_200, floorEnabled: true), failure: nil))
            }
        }
    }

    @MainActor func testApplyArmsForTheChosenDurationWithTheFloorSetting() async {
        let helper = armingHelper()
        let prefs = Prefs()
        prefs.floorEnabled = false
        let model = makeModel(helper, prefs)
        await model.arm(days: 0, hours: 2, minutes: 0, now: t0)
        XCTAssertEqual(helper.requests, [.arm(seconds: 7_200, floorEnabled: false)])
        XCTAssertEqual(model.state, .armed(deadline: t0 + 7_200, floorEnabled: false))
        XCTAssertEqual(model.registration, .ready)
        XCTAssertNil(model.failure)
        XCTAssertFalse(model.isWorking)
    }

    @MainActor func testApplyRemembersTheDurationInMinutes() async {
        let prefs = Prefs()
        let model = makeModel(armingHelper(), prefs)
        await model.arm(days: 1, hours: 0, minutes: 30, now: t0)
        XCTAssertEqual(prefs.remembered, [1_470])
    }

    @MainActor func testAZeroDurationIsRefusedWithoutAskingTheHelper() async {
        let helper = armingHelper()
        let prefs = Prefs()
        let model = makeModel(helper, prefs)
        await model.arm(days: 0, hours: 0, minutes: 0, now: t0)
        XCTAssertEqual(model.failure, .invalidDuration)
        XCTAssertEqual(helper.requests, [])
        XCTAssertEqual(prefs.remembered, [])
    }

    @MainActor func testApplyBeforeApprovalSaysSoAndStillRemembersTheDuration() async {
        let helper = KeepAwakeFakeHelper(statuses: [.notRegistered, .requiresApproval], registeredBuild: nil)
        helper.with { $0.registerError = KeepAwakeFakeError("Operation not permitted") }
        let prefs = Prefs()
        let model = makeModel(helper, prefs)
        await model.arm(days: 0, hours: 1, minutes: 0, now: t0)
        XCTAssertEqual(model.registration, .requiresApproval)
        XCTAssertEqual(model.state, .idle)
        XCTAssertNil(model.failure)
        XCTAssertEqual(prefs.remembered, [60])
    }

    @MainActor func testTheFloorSwitchReachesAnArmedHelperAtOnce() async {
        let helper = armingHelper()
        let model = makeModel(helper, Prefs())
        await model.arm(days: 0, hours: 2, minutes: 0, now: t0)
        await model.floorChanged(false, now: t0 + 60)
        XCTAssertEqual(helper.requests.last, .setFloor(enabled: false))
        XCTAssertEqual(model.state, .armed(deadline: t0 + 7_200, floorEnabled: false))
    }

    @MainActor func testTheFloorSwitchWhileIdleStaysInSettings() async {
        let helper = armingHelper()
        let model = makeModel(helper, Prefs())
        await model.floorChanged(false, now: t0)
        XCTAssertEqual(helper.requests, [])
    }

    @MainActor func testThePollAsksTheHelperOnlyWhenNeeded() async {
        let helper = armingHelper()
        let model = makeModel(helper, Prefs())
        await model.pollIfNeeded(now: t0)
        XCTAssertEqual(helper.requests, [])
        await model.arm(days: 0, hours: 2, minutes: 0, now: t0)
        await model.pollIfNeeded(now: t0 + 60)
        XCTAssertEqual(helper.requests, [.arm(seconds: 7_200, floorEnabled: true), .state])
    }

    @MainActor func testAModeTheHelperEndedLeavesOnTheNextPoll() async {
        let start = t0
        let helper = armingHelper()
        let model = makeModel(helper, Prefs())
        await model.arm(days: 0, hours: 2, minutes: 0, now: start)
        helper.with { $0.reply = { _ in .success(KeepAwakeReply(state: .ended(at: start + 600, reason: .batteryFloor), failure: nil)) } }
        await model.pollIfNeeded(now: start + 660)
        XCTAssertEqual(model.state, .ended(at: start + 600, reason: .batteryFloor))
    }

    @MainActor func testWhenTheHelperIsSilentTheCountdownStillEndsTheMode() async {
        let helper = armingHelper()
        let model = makeModel(helper, Prefs())
        await model.arm(days: 0, hours: 0, minutes: 1, now: t0)
        helper.with { $0.reply = { _ in .failure(.helperTimedOut) } }
        await model.pollIfNeeded(now: t0 + 61)
        XCTAssertEqual(model.state, .ended(at: t0 + 60, reason: .deadline))
        XCTAssertEqual(model.failure, .helperTimedOut)
    }

    @MainActor func testCancelAsksTheHelperToEndTheMode() async {
        let helper = armingHelper()
        let model = makeModel(helper, Prefs())
        await model.arm(days: 0, hours: 2, minutes: 0, now: t0)
        await model.cancel(now: t0 + 60)
        XCTAssertEqual(helper.requests.last, .disarm)
        XCTAssertEqual(model.state, .ended(at: t0 + 60, reason: .cancelled))
    }

    @MainActor func testResetPutsTheFeatureBackAndShowsTheFlag() async {
        let helper = armingHelper()
        helper.with { $0.flags = [.cleared] }
        let prefs = Prefs()
        let model = makeModel(helper, prefs)
        await model.arm(days: 0, hours: 2, minutes: 0, now: t0)
        await model.reset(now: t0 + 60)
        XCTAssertEqual(prefs.resets, 1)
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(model.registration, .notRegistered)
        XCTAssertEqual(model.flag, .cleared)
        XCTAssertNil(model.resetFailure)
        XCTAssertFalse(model.resetIncomplete)
    }

    @MainActor func testTheFlagIsReadForTheAdvancedRow() async {
        let helper = armingHelper()
        helper.with { $0.flags = [.set] }
        let model = makeModel(helper, Prefs())
        await model.readFlag()
        XCTAssertEqual(model.flag, .set)
    }

    // MARK: - Review C7: a reply lost to the timeout is reconciled by the poll

    @MainActor func testATimedOutArmIsReconciledOnTheNextPoll() async {
        let start = t0
        let helper = KeepAwakeFakeHelper(statuses: [.enabled]) { request in
            if case .arm = request { return .failure(.helperTimedOut) }
            return .success(KeepAwakeReply(state: .armed(deadline: start + 7_200, floorEnabled: true), failure: nil))
        }
        let model = makeModel(helper, Prefs())
        await model.arm(days: 0, hours: 2, minutes: 0, now: start)
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(model.failure, .helperTimedOut)
        await model.pollIfNeeded(now: start + 60)
        XCTAssertEqual(helper.requests, [.arm(seconds: 7_200, floorEnabled: true), .state])
        XCTAssertEqual(model.state, .armed(deadline: start + 7_200, floorEnabled: true))
        XCTAssertNil(model.failure)
    }

    @MainActor func testOnceTheHelperAnswersTheReconcileStops() async {
        let helper = KeepAwakeFakeHelper(statuses: [.enabled]) { request in
            if case .arm = request { return .failure(.helperUnavailable(reason: "Connection interrupted")) }
            return .success(KeepAwakeReply(state: .idle, failure: nil))
        }
        let model = makeModel(helper, Prefs())
        await model.arm(days: 0, hours: 2, minutes: 0, now: t0)
        await model.pollIfNeeded(now: t0 + 60)
        XCTAssertEqual(model.state, .idle)
        await model.pollIfNeeded(now: t0 + 120)
        XCTAssertEqual(helper.requests, [.arm(seconds: 7_200, floorEnabled: true), .state], "idle and reconciled: no more polls")
    }

    /// C7, completed: the launch refresh is a call like any other; its timeout leaves the
    /// state unknown, so the poll asks again even though the model shows idle.
    @MainActor func testATimedOutLaunchRefreshIsReconciledOnTheNextPoll() async {
        let start = t0
        let helper = KeepAwakeFakeHelper(statuses: [.enabled]) { _ in .failure(.helperTimedOut) }
        let model = makeModel(helper, Prefs())
        await model.refresh(now: start)
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(model.failure, .helperTimedOut)
        helper.with { $0.reply = { _ in .success(KeepAwakeReply(state: .armed(deadline: start + 7_200, floorEnabled: true), failure: nil)) } }
        await model.pollIfNeeded(now: start + 60)
        XCTAssertEqual(helper.requests, [.state, .state])
        XCTAssertEqual(model.state, .armed(deadline: start + 7_200, floorEnabled: true))
        XCTAssertNil(model.failure)
    }

    func testOnlyALostReplyLeavesTheStateUnknown() {
        let unknown: [KeepAwakeFailure] = [.helperTimedOut, .helperUnavailable(reason: "x"), .unreadableReply]
        for failure in unknown {
            XCTAssertTrue(KeepAwakeModel.leavesStateUnknown(failure), "\(failure)")
        }
        let known: [KeepAwakeFailure?] = [
            nil, .invalidDuration, .readBack(expected: true), .commandFailed(command: "pmset", status: 1),
            .notSigned, .registrationFailed(reason: "x"), .unregisterFailed(reason: "x"), .adminCancelled, .flagStillSet,
        ]
        for failure in known {
            XCTAssertFalse(KeepAwakeModel.leavesStateUnknown(failure), "\(String(describing: failure))")
        }
    }

    // MARK: - Review C1, C3 and P1b

    @MainActor func testAResetThatCouldNotClearSaysTheMacIsNotBackToNormal() async {
        let helper = KeepAwakeFakeHelper(statuses: [.enabled]) { _ in .failure(.helperTimedOut) }
        helper.with { $0.flags = [.set]; $0.adminResult = .adminCancelled }
        let prefs = Prefs()
        let model = makeModel(helper, prefs)
        await model.reset(now: t0)
        XCTAssertTrue(model.resetIncomplete)
        XCTAssertEqual(model.registration, .ready)
        XCTAssertEqual(model.flag, .set)
        XCTAssertEqual(model.resetFailure, .adminCancelled)
        XCTAssertEqual(prefs.resets, 1, "the two settings go back either way")
    }

    /// The user switched the background item off while armed: launchd stopped the helper,
    /// which cleared the flag on its way out (Task 9c), so the marker must not wait for the
    /// deadline. The model reads the flag to be sure (P1b): clear → a plain stop.
    @MainActor func testAHelperLaunchdStoppedEndsTheModeOnTheNextPoll() async {
        let helper = armingHelper(statuses: [.enabled, .requiresApproval])
        helper.with { $0.flags = [.cleared] }
        let model = makeModel(helper, Prefs())
        await model.arm(days: 0, hours: 2, minutes: 0, now: t0)
        await model.pollIfNeeded(now: t0 + 600)
        XCTAssertEqual(model.state, .ended(at: t0 + 600, reason: .stopped))
        XCTAssertEqual(model.registration, .requiresApproval)
        XCTAssertEqual(model.flag, .cleared)
        XCTAssertNil(model.failure)
        XCTAssertFalse(model.resetIncomplete)
        XCTAssertEqual(helper.requests, [.arm(seconds: 7_200, floorEnabled: true)])
        XCTAssertEqual(helper.calls.last, "readFlag")
    }

    /// P1b: the stop path could not clear and the job is gone — nothing enforces the flag any
    /// more, so the model must not show a plain stop.
    @MainActor func testAStoppedHelperThatLeftTheFlagSetSaysToReset() async {
        let helper = armingHelper(statuses: [.enabled, .requiresApproval])
        helper.with { $0.flags = [.set] }
        let model = makeModel(helper, Prefs())
        await model.arm(days: 0, hours: 2, minutes: 0, now: t0)
        await model.pollIfNeeded(now: t0 + 600)
        XCTAssertEqual(model.state, .ended(at: t0 + 600, reason: .stopped))
        XCTAssertEqual(model.flag, .set)
        XCTAssertEqual(model.failure, .flagStillSet)
        XCTAssertTrue(model.resetIncomplete)
    }
}
