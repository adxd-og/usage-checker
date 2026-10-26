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
}
