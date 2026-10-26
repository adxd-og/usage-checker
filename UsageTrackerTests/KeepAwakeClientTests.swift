import XCTest
import ServiceManagement
@testable import Omelette

struct KeepAwakeFakeError: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

/// SMAppService and the XPC replies, faked for `KeepAwakeClient`. Internal, not private:
/// KeepAwakeModelTests drives the model through it.
final class KeepAwakeFakeHelper: @unchecked Sendable {
    struct Storage {
        var statuses: [SMAppService.Status]
        var registerError: (any Error)?
        var registeredBuild: String?
        var reply: @Sendable (KeepAwakeRequest) -> Result<KeepAwakeReply, KeepAwakeFailure>
        var calls: [String] = []
        var requests: [KeepAwakeRequest] = []
        var unregisterError: (any Error)?
        var flags: [KeepAwakeFlagReading] = [.neverSet]
        var adminResult: KeepAwakeFailure?
    }
    private let lock = NSLock()
    private var storage: Storage

    init(
        statuses: [SMAppService.Status],
        registeredBuild: String? = "53",
        reply: @escaping @Sendable (KeepAwakeRequest) -> Result<KeepAwakeReply, KeepAwakeFailure> = { _ in
            .success(KeepAwakeReply(state: .idle, failure: nil))
        }
    ) {
        storage = Storage(statuses: statuses, registeredBuild: registeredBuild, reply: reply)
    }

    func with<T>(_ body: (inout Storage) -> T) -> T { lock.withLock { body(&storage) } }
    var calls: [String] { with { $0.calls } }
    var requests: [KeepAwakeRequest] { with { $0.requests } }

    /// The first of `statuses` while more than one is left, then the last for good.
    private func nextStatus() -> SMAppService.Status {
        with { s in s.statuses.count > 1 ? s.statuses.removeFirst() : s.statuses[0] }
    }

    /// The first of `flags` while more than one is left, then the last for good.
    private func nextFlag() -> KeepAwakeFlagReading {
        with { s in s.flags.count > 1 ? s.flags.removeFirst() : s.flags[0] }
    }

    func dependencies(currentBuild: String = "53") -> KeepAwakeClient.Dependencies {
        KeepAwakeClient.Dependencies(
            status: { self.nextStatus() },
            register: {
                if let error = self.with({ s -> (any Error)? in s.calls.append("register"); return s.registerError }) {
                    throw error
                }
            },
            send: { request in
                self.with { s in
                    s.calls.append("send")
                    s.requests.append(request)
                    return s.reply(request)
                }
            },
            unregister: {
                if let error = self.with({ s -> (any Error)? in s.calls.append("unregister"); return s.unregisterError }) {
                    throw error
                }
            },
            readFlag: { self.with { $0.calls.append("readFlag") }; return self.nextFlag() },
            adminClear: { self.with { s in s.calls.append("adminClear"); return s.adminResult } },
            registeredBuild: { self.with { $0.registeredBuild } },
            setRegisteredBuild: { build in
                self.with { s in
                    s.calls.append("setRegisteredBuild \(build ?? "nil")")
                    s.registeredBuild = build
                }
            },
            currentBuild: currentBuild
        )
    }
}

/// Spec 2026-10-26 § Helper › App side: "registers the daemon on first use, maps SMAppService
/// status to notRegistered / requiresApproval / ready, calls the XPC methods … After an app
/// update the next Apply calls register() again"; § Behaviour › One-time setup.
final class KeepAwakeClientTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)

    func testTheStatusMapsToThreeStates() {
        XCTAssertEqual(KeepAwakeClient.registration(from: .notRegistered), .notRegistered)
        XCTAssertEqual(KeepAwakeClient.registration(from: .requiresApproval), .requiresApproval)
        XCTAssertEqual(KeepAwakeClient.registration(from: .enabled), .ready)
        XCTAssertEqual(KeepAwakeClient.registration(from: .notFound), .notRegistered)
    }

    func testRegisterOnFirstUseAndAgainUnderANewBuild() {
        XCTAssertTrue(KeepAwakeClient.needsRegister(.notRegistered, registeredBuild: nil, currentBuild: "53"))
        XCTAssertTrue(KeepAwakeClient.needsRegister(.ready, registeredBuild: "52", currentBuild: "53"))
        XCTAssertTrue(KeepAwakeClient.needsRegister(.ready, registeredBuild: nil, currentBuild: "53"))
        XCTAssertFalse(KeepAwakeClient.needsRegister(.ready, registeredBuild: "53", currentBuild: "53"))
        XCTAssertFalse(KeepAwakeClient.needsRegister(.requiresApproval, registeredBuild: nil, currentBuild: "53"))
    }

    func testTheFirstApplyRegistersTheHelperAndWaitsForApproval() async {
        let helper = KeepAwakeFakeHelper(statuses: [.notRegistered, .requiresApproval], registeredBuild: nil)
        helper.with { $0.registerError = KeepAwakeFakeError("Operation not permitted") }
        let client = KeepAwakeClient(dependencies: helper.dependencies())
        let outcome = await client.arm(seconds: 7_200, floorEnabled: true)
        XCTAssertEqual(outcome, KeepAwakeOutcome(registration: .requiresApproval, state: nil, failure: nil))
        XCTAssertEqual(helper.calls, ["register", "setRegisteredBuild 53"])
        XCTAssertEqual(helper.requests, [])
    }

    func testOnceApprovedApplyArmsTheHelper() async {
        let t0 = self.t0
        let helper = KeepAwakeFakeHelper(statuses: [.enabled]) { _ in
            .success(KeepAwakeReply(state: .armed(deadline: t0 + 7_200, floorEnabled: true), failure: nil))
        }
        let client = KeepAwakeClient(dependencies: helper.dependencies())
        let outcome = await client.arm(seconds: 7_200, floorEnabled: true)
        XCTAssertEqual(outcome, KeepAwakeOutcome(registration: .ready, state: .armed(deadline: t0 + 7_200, floorEnabled: true), failure: nil))
        XCTAssertEqual(helper.calls, ["send"])
        XCTAssertEqual(helper.requests, [.arm(seconds: 7_200, floorEnabled: true)])
    }

    func testAfterAnUpdateTheNextApplyRegistersAgain() async {
        let helper = KeepAwakeFakeHelper(statuses: [.enabled], registeredBuild: "52")
        helper.with { $0.registerError = KeepAwakeFakeError("Service already registered") }
        let client = KeepAwakeClient(dependencies: helper.dependencies(currentBuild: "53"))
        let outcome = await client.arm(seconds: 60, floorEnabled: false)
        XCTAssertEqual(helper.calls, ["register", "setRegisteredBuild 53", "send"])
        XCTAssertNil(outcome.failure)
    }

    func testARegistrationThatFailsSaysWhy() async {
        let helper = KeepAwakeFakeHelper(statuses: [.notRegistered], registeredBuild: nil)
        helper.with { $0.registerError = KeepAwakeFakeError("boom") }
        let client = KeepAwakeClient(dependencies: helper.dependencies())
        let outcome = await client.arm(seconds: 60, floorEnabled: true)
        XCTAssertEqual(outcome, KeepAwakeOutcome(registration: .notRegistered, state: nil, failure: .registrationFailed(reason: "boom")))
        XCTAssertEqual(helper.requests, [])
    }

    func testAnUnreachableHelperIsAFailureNotAState() async {
        let helper = KeepAwakeFakeHelper(statuses: [.enabled]) { _ in .failure(.helperTimedOut) }
        let client = KeepAwakeClient(dependencies: helper.dependencies())
        let outcome = await client.state()
        XCTAssertEqual(outcome, KeepAwakeOutcome(registration: .ready, state: nil, failure: .helperTimedOut))
    }

    func testStateNeverContactsAHelperThatIsNotReady() async {
        let helper = KeepAwakeFakeHelper(statuses: [.requiresApproval])
        let client = KeepAwakeClient(dependencies: helper.dependencies())
        let outcome = await client.state()
        XCTAssertEqual(outcome, KeepAwakeOutcome(registration: .requiresApproval, state: nil, failure: nil))
        XCTAssertEqual(helper.calls, [])
    }

    func testCancelAndTheFloorReachAReadyHelper() async {
        let helper = KeepAwakeFakeHelper(statuses: [.enabled])
        let client = KeepAwakeClient(dependencies: helper.dependencies())
        _ = await client.disarm()
        _ = await client.setFloor(enabled: false)
        XCTAssertEqual(helper.requests, [.disarm, .setFloor(enabled: false)])
    }

    func testCancelWithoutAHelperHasNothingToEnd() async {
        let helper = KeepAwakeFakeHelper(statuses: [.notRegistered])
        let client = KeepAwakeClient(dependencies: helper.dependencies())
        let outcome = await client.disarm()
        XCTAssertEqual(outcome, KeepAwakeOutcome(registration: .notRegistered, state: nil, failure: nil))
        XCTAssertEqual(helper.requests, [])
    }

    // MARK: - § UI, Reset keep awake; § Behaviour, When the helper cannot run (plan D13).
    // Review C1: the helper is unregistered only once the flag reads clear, so a reset that
    // could not clear leaves a helper that can still clear at its next start.

    func testResetDisarmsReadsTheFlagThenUnregisters() async {
        let helper = KeepAwakeFakeHelper(statuses: [.enabled])
        helper.with { $0.flags = [.cleared] }
        let client = KeepAwakeClient(dependencies: helper.dependencies())
        let outcome = await client.reset()
        XCTAssertEqual(helper.calls, ["send", "readFlag", "unregister", "setRegisteredBuild nil"])
        XCTAssertEqual(helper.requests, [.disarm])
        XCTAssertEqual(outcome, KeepAwakeResetOutcome(registration: .notRegistered, flag: .cleared, failure: nil))
        XCTAssertTrue(outcome.isComplete)
    }

    func testWithTheHelperGoneAndTheFlagSetResetAsksForThePasswordOnce() async {
        let helper = KeepAwakeFakeHelper(statuses: [.notRegistered])
        helper.with { $0.flags = [.set, .cleared] }
        let client = KeepAwakeClient(dependencies: helper.dependencies())
        let outcome = await client.reset()
        XCTAssertEqual(helper.calls, ["readFlag", "adminClear", "readFlag", "setRegisteredBuild nil"])
        XCTAssertEqual(outcome, KeepAwakeResetOutcome(registration: .notRegistered, flag: .cleared, failure: nil))
    }

    func testWithTheHelperGoneAndTheFlagClearResetAsksForNothing() async {
        let helper = KeepAwakeFakeHelper(statuses: [.notRegistered])
        helper.with { $0.flags = [.neverSet] }
        let client = KeepAwakeClient(dependencies: helper.dependencies())
        let outcome = await client.reset()
        XCTAssertEqual(helper.calls, ["readFlag", "setRegisteredBuild nil"])
        XCTAssertEqual(outcome, KeepAwakeResetOutcome(registration: .notRegistered, flag: .neverSet, failure: nil))
    }

    func testAHelperThatCannotClearFallsBackToThePasswordThenUnregisters() async {
        let helper = KeepAwakeFakeHelper(statuses: [.enabled]) { _ in
            .success(KeepAwakeReply(state: .idle, failure: .commandFailed(command: "pmset", status: 1)))
        }
        helper.with { $0.flags = [.set, .cleared] }
        let client = KeepAwakeClient(dependencies: helper.dependencies())
        let outcome = await client.reset()
        XCTAssertEqual(helper.calls, ["send", "readFlag", "adminClear", "readFlag", "unregister", "setRegisteredBuild nil"])
        XCTAssertEqual(outcome, KeepAwakeResetOutcome(registration: .notRegistered, flag: .cleared, failure: nil))
    }

    func testACancelledPasswordLeavesTheFlagAndSaysSo() async {
        let helper = KeepAwakeFakeHelper(statuses: [.notRegistered])
        helper.with { $0.flags = [.set]; $0.adminResult = .adminCancelled }
        let client = KeepAwakeClient(dependencies: helper.dependencies())
        let outcome = await client.reset()
        XCTAssertEqual(helper.calls, ["readFlag", "adminClear", "readFlag"])
        XCTAssertEqual(outcome, KeepAwakeResetOutcome(registration: .notRegistered, flag: .set, failure: .adminCancelled))
        XCTAssertFalse(outcome.isComplete)
    }

    /// C1: disarm fails, the prompt is cancelled — the helper stays, and so does its build.
    func testAFailedDisarmAndACancelledPromptKeepTheHelperRegistered() async {
        let helper = KeepAwakeFakeHelper(statuses: [.enabled]) { _ in .failure(.helperTimedOut) }
        helper.with { $0.flags = [.set]; $0.adminResult = .adminCancelled }
        let client = KeepAwakeClient(dependencies: helper.dependencies())
        let outcome = await client.reset()
        XCTAssertEqual(helper.calls, ["send", "readFlag", "adminClear", "readFlag"])
        XCTAssertEqual(outcome, KeepAwakeResetOutcome(registration: .ready, flag: .set, failure: .adminCancelled))
        XCTAssertFalse(outcome.isComplete)
        XCTAssertEqual(helper.with { $0.registeredBuild }, "53")
    }

    /// C1: the prompt "succeeded" but the flag still reads 1 — no unregister.
    func testAPasswordThatDidNotTakeKeepsTheHelperRegistered() async {
        let helper = KeepAwakeFakeHelper(statuses: [.enabled]) { _ in .failure(.helperUnavailable(reason: "gone")) }
        helper.with { $0.flags = [.set, .set] }
        let client = KeepAwakeClient(dependencies: helper.dependencies())
        let outcome = await client.reset()
        XCTAssertEqual(helper.calls, ["send", "readFlag", "adminClear", "readFlag"])
        XCTAssertEqual(outcome, KeepAwakeResetOutcome(registration: .ready, flag: .set, failure: .readBack(expected: false)))
    }

    /// An unreadable flag is not known to be clear: no prompt (there may be nothing to clear),
    /// and no unregister either.
    func testAnUnreadableFlagKeepsTheHelperRegisteredWithoutAPrompt() async {
        let helper = KeepAwakeFakeHelper(statuses: [.enabled])
        helper.with { $0.flags = [.unreadable] }
        let client = KeepAwakeClient(dependencies: helper.dependencies())
        let outcome = await client.reset()
        XCTAssertEqual(helper.calls, ["send", "readFlag"])
        XCTAssertEqual(outcome, KeepAwakeResetOutcome(registration: .ready, flag: .unreadable, failure: nil))
        XCTAssertFalse(outcome.isComplete)
    }

    func testAHelperAwaitingApprovalIsUnregisteredOnceTheFlagReadsClear() async {
        let helper = KeepAwakeFakeHelper(statuses: [.requiresApproval])
        let client = KeepAwakeClient(dependencies: helper.dependencies())
        _ = await client.reset()
        XCTAssertEqual(helper.calls, ["readFlag", "unregister", "setRegisteredBuild nil"])
        XCTAssertEqual(helper.requests, [])
    }

    func testAnUnregisterThatFailsIsReported() async {
        let helper = KeepAwakeFakeHelper(statuses: [.enabled])
        helper.with { $0.unregisterError = KeepAwakeFakeError("nope"); $0.flags = [.cleared] }
        let client = KeepAwakeClient(dependencies: helper.dependencies())
        let outcome = await client.reset()
        XCTAssertEqual(helper.calls, ["send", "readFlag", "unregister"])
        XCTAssertEqual(outcome, KeepAwakeResetOutcome(registration: .ready, flag: .cleared, failure: .unregisterFailed(reason: "nope")))
        XCTAssertFalse(outcome.isComplete)
    }

    func testThePasswordPromptRunsPmsetAsRoot() {
        XCTAssertEqual(
            KeepAwakeClient.adminClearScript,
            #"do shell script "/usr/bin/pmset -a disablesleep 0" with administrator privileges"#
        )
    }

    func testOsascriptsAnswerSaysWhetherThePasswordWasGiven() {
        XCTAssertNil(KeepAwakeClient.adminClearFailure(status: 0, output: ""))
        XCTAssertEqual(KeepAwakeClient.adminClearFailure(status: 1, output: "0:76: execution error: User canceled. (-128)\n"), .adminCancelled)
        XCTAssertEqual(
            KeepAwakeClient.adminClearFailure(status: 1, output: "0:76: execution error: The administrator user name or password was incorrect. (-60007)\n"),
            .commandFailed(command: "osascript", status: 1)
        )
    }
}
