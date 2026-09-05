import AppKit
import XCTest
@testable import Omelette

@MainActor
final class PermissionBrokerTests: XCTestCase {
    private var directory: URL!
    private var store: AgentSessionStore!
    private var presence: PresenceMonitor!
    private var frontmost: PresenceMonitor.Frontmost? = (1, "com.other.app")   // "the user is elsewhere"
    private var featureEnabled = true
    private var hostVisible = true
    private var peers: [Int32] = []
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let iterm = AgentHostInfo(pid: 4242, bundleID: "com.googlecode.iterm2", tty: "/dev/ttys004")

    // The async overrides are what let a @MainActor test class touch its own
    // properties here; the synchronous ones are nonisolated and warn.
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PermissionBrokerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = AgentSessionStore(historyURL: directory.appendingPathComponent("agent-sessions.jsonl"))
        presence = PresenceMonitor(frontmost: { [weak self] in self?.frontmost }, hostHasVisibleWindow: { [weak self] _ in self?.hostVisible ?? true })
    }

    override func tearDown() async throws {
        for peer in peers { close(peer) }
        peers = []
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeBroker(holdWindow: TimeInterval = PermissionBroker.holdWindow, recheckInterval: TimeInterval = 1) -> PermissionBroker {
        PermissionBroker(store: store, presence: presence, featureEnabled: { [weak self] in self?.featureEnabled ?? true }, holdWindow: holdWindow, recheckInterval: recheckInterval)
    }

    private func event(host: AgentHostInfo? = nil, sessionID: String = "s1", requestID: String = AgentFixture.requestID) -> AgentEvent {
        AgentEvent(source: .claude, kind: .permissionRequested, sessionID: sessionID,
                   cwd: "/Users/tester/Projects/alpha", toolName: "Bash", toolSummary: "Bash: rm -rf build",
                   isSubagent: false, host: host ?? iterm, receivedAt: t0, requestID: requestID)
    }

    /// A reply on a socketpair; the peer end is read to see what was written.
    private func reply(_ requestID: String = AgentFixture.requestID) -> (AgentReply, Int32) {
        let pair = AgentFixture.replyPair(requestID: requestID)
        peers.append(pair.peer)
        return (pair.reply, pair.peer)
    }

    private func line(_ peer: Int32, timeout: TimeInterval = 0.2) -> String? {
        AgentSocketTestClient.readLine(peer, timeout: timeout)
    }

    // MARK: - The timeout chain (spec rule 5)

    func testTheAppGivesUpBeforeTheHelperAndTheHook() {
        // The helper's own 140 s and the hook's 150 s live in other targets and in the
        // installer template; this pins the app-side half of the chain so a later
        // edit cannot quietly make the app the last to give up.
        XCTAssertLessThan(PermissionBroker.holdWindow, AgentEventServer.defaultHoldTimeout)
        XCTAssertLessThan(AgentEventServer.defaultHoldTimeout, 150)
    }

    // MARK: - The pure rule

    func testShouldHoldTable() {
        // (userAtHost, featureEnabled, hasHost) → hold?
        let table: [(Bool, Bool, Bool, Bool)] = [
            (false, true, true, true),     // away, on, known host → hold
            (true, true, true, false),     // at the terminal → release, Claude prompts there
            (false, false, true, false),   // feature off → observe only
            (false, true, false, false),   // no host info (passive / unknown) → release
            (true, false, false, false),
        ]
        for (userAtHost, enabled, hasHost, expected) in table {
            XCTAssertEqual(PermissionBroker.shouldHold(userAtHost: userAtHost, featureEnabled: enabled, hasHost: hasHost), expected,
                           "userAtHost=\(userAtHost) enabled=\(enabled) hasHost=\(hasHost)")
        }
    }

    // MARK: - register

    func testHoldsWhenTheUserIsAwayAndPublishesPending() {
        let broker = makeBroker()
        var announced: [PendingPermission] = []
        broker.onPending = { announced.append($0) }
        let (reply, peer) = reply()

        broker.register(event: event(), reply: reply, session: nil, now: t0)

        XCTAssertEqual(broker.pending.count, 1)
        let request = broker.pending[0]
        XCTAssertEqual(request.id, AgentFixture.requestID)
        XCTAssertEqual(request.sessionID, "claude:s1")
        XCTAssertEqual(request.toolName, "Bash")
        XCTAssertEqual(request.toolSummary, "Bash: rm -rf build")
        XCTAssertEqual(request.receivedAt, t0)
        XCTAssertEqual(request.expiresAt, t0.addingTimeInterval(120))
        XCTAssertEqual(announced, [request])
        XCTAssertEqual(broker.pending(for: "claude:s1"), request)
        XCTAssertFalse(reply.isSettled)
        XCTAssertNil(line(peer), "nothing goes to the helper while held")
    }

    func testAHeldRequestCarriesTheFullTextAsWellAsTheHeadline() {
        let broker = makeBroker()
        let (reply, _) = reply()
        let event = AgentEvent(
            source: .claude, kind: .permissionRequested, sessionID: "s1",
            cwd: "/Users/tester/Projects/alpha", toolName: "Bash",
            toolSummary: "Clear the derived data", toolDetail: "rm -rf build/DerivedData",
            isSubagent: false, host: iterm, receivedAt: t0, requestID: AgentFixture.requestID
        )
        broker.register(event: event, reply: reply, session: nil, now: t0)
        XCTAssertEqual(broker.pending.first?.toolSummary, "Clear the derived data")
        XCTAssertEqual(broker.pending.first?.detail, "rm -rf build/DerivedData")
    }

    func testRegisterBeforeTheStoreKnowsTheSessionStillLandsThePendingID() {
        // Bootstrap order: register, then apply.
        let broker = makeBroker()
        let (reply, _) = reply()
        broker.register(event: event(), reply: reply, session: nil, now: t0)
        XCTAssertTrue(store.sessions.isEmpty)

        store.apply(event(), now: t0)

        XCTAssertEqual(store.sessions.first?.pendingPermissionID, AgentFixture.requestID)
        XCTAssertEqual(store.sessions.first?.state, .needsYou)
    }

    func testPendingIsVisibleInsideOnNeedsYouWhenRegisteredFirst() {
        let broker = makeBroker()
        var seenPending: PendingPermission?? = .none
        store.onNeedsYou = { [broker] session in seenPending = .some(broker.pending(for: session.id)) }
        let (reply, _) = reply()

        broker.register(event: event(), reply: reply, session: nil, now: t0)
        store.apply(event(), now: t0)

        XCTAssertEqual(seenPending??.id, AgentFixture.requestID, "the notifier vetoes the plain banner through pending(for:)")
    }

    func testReleasesAtOnceWhenTheUserIsAtTheHost() {
        frontmost = (4242, "com.googlecode.iterm2")
        let broker = makeBroker()
        var announced = 0
        broker.onPending = { _ in announced += 1 }
        let (reply, peer) = reply()

        broker.register(event: event(), reply: reply, session: nil, now: t0)

        XCTAssertTrue(broker.pending.isEmpty)
        XCTAssertEqual(announced, 0)
        XCTAssertEqual(line(peer), #"{"v":2,"request_id":"0123456789abcdef0123456789abcdef","decision":null}"#)
        XCTAssertEqual(broker.releasedForPresenceCount, 1)
        XCTAssertNil(store.sessions.first?.pendingPermissionID)
    }

    func testHoldsWhenTheHostIsFrontmostButTheScreenIsLocked() {
        frontmost = (4242, "com.googlecode.iterm2")
        presence.setLocked(true)
        let broker = makeBroker()
        let (reply, _) = reply()
        broker.register(event: event(), reply: reply, session: nil, now: t0)
        XCTAssertEqual(broker.pending.count, 1)
    }

    func testFeatureOffReleasesWithoutCountingPresence() {
        featureEnabled = false
        let broker = makeBroker()
        let (reply, peer) = reply()
        broker.register(event: event(), reply: reply, session: nil, now: t0)
        XCTAssertTrue(broker.pending.isEmpty)
        XCTAssertEqual(line(peer), #"{"v":2,"request_id":"0123456789abcdef0123456789abcdef","decision":null}"#)
        XCTAssertEqual(broker.releasedForPresenceCount, 0)
    }

    func testNoHostAnywhereReleases() {
        let broker = makeBroker()
        let (reply, peer) = reply()
        broker.register(event: event(host: AgentHostInfo.none), reply: reply, session: nil, now: t0)
        XCTAssertTrue(broker.pending.isEmpty)
        XCTAssertNotNil(line(peer))
    }

    func testFallsBackToTheStoredSessionHostWhenTheEventHasNone() {
        let broker = makeBroker()
        let session = Fixture.agentSession(sessionID: "s1", host: iterm)
        let (reply, _) = reply()
        broker.register(event: event(host: AgentHostInfo.none), reply: reply, session: session, now: t0)
        XCTAssertEqual(broker.pending.count, 1, "the store remembers the terminal from earlier hooks")
    }

    func testAnEventWithoutARequestIDIsReleasedNotHeld() {
        let broker = makeBroker()
        let reply = AgentReply(requestID: nil)   // v1 helper: the server already answered
        broker.register(event: event(), reply: reply, session: nil, now: t0)
        XCTAssertTrue(broker.pending.isEmpty)
    }

    func testASecondRequestForTheSameSessionExpiresTheFirst() {
        let broker = makeBroker()
        var resolved: [(String, PermissionResolution)] = []
        broker.onResolved = { resolved.append(($0.id, $1)) }
        let first = reply("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        let second = reply("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")

        broker.register(event: event(requestID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"), reply: first.0, session: nil, now: t0)
        broker.register(event: event(requestID: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"), reply: second.0, session: nil, now: t0.addingTimeInterval(1))

        XCTAssertEqual(broker.pending.map(\.id), ["bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"])
        XCTAssertEqual(resolved.map(\.0), ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"])
        XCTAssertEqual(resolved.first?.1, .expired)
        XCTAssertNotNil(line(first.1))
        XCTAssertNil(line(second.1))
    }

    func testPendingIsNewestFirstAcrossSessions() {
        let broker = makeBroker()
        let a = reply("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        let b = reply("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        broker.register(event: event(sessionID: "s1", requestID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"), reply: a.0, session: nil, now: t0)
        broker.register(event: event(sessionID: "s2", requestID: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"), reply: b.0, session: nil, now: t0.addingTimeInterval(1))
        XCTAssertEqual(broker.pending.map(\.sessionID), ["claude:s2", "claude:s1"])
        XCTAssertEqual(broker.pending(for: "claude:s1")?.id, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        XCTAssertNil(broker.pending(for: "claude:s9"))
    }

    // MARK: - answer / release / expiry

    func testAnswerAllowWritesOnceClearsTheStoreAndResolvesAfterRemoval() {
        let broker = makeBroker()
        var resolved: [(PendingPermission, PermissionResolution, Int)] = []
        broker.onResolved = { [broker] request, why in resolved.append((request, why, broker.pending.count)) }
        let (reply, peer) = reply()
        broker.register(event: event(), reply: reply, session: nil, now: t0)
        store.apply(event(), now: t0)
        XCTAssertEqual(store.sessions.first?.pendingPermissionID, AgentFixture.requestID)

        broker.answer(id: AgentFixture.requestID, .allow)
        broker.answer(id: AgentFixture.requestID, .deny)     // duplicate: ignored
        broker.answer(id: "nope", .allow)                     // unknown: ignored

        XCTAssertEqual(line(peer), #"{"v":2,"request_id":"0123456789abcdef0123456789abcdef","decision":"allow"}"#)
        var byte: UInt8 = 0
        XCTAssertEqual(read(peer, &byte, 1), 0, "one line, then EOF")
        XCTAssertTrue(broker.pending.isEmpty)
        XCTAssertEqual(broker.answeredCount, 1)
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.1, .answered(.allow))
        XCTAssertEqual(resolved.first?.2, 0, "onResolved runs after the request left pending")
        XCTAssertNil(store.sessions.first?.pendingPermissionID)
        XCTAssertEqual(store.sessions.first?.state, .needsYou, "the store's state is Claude Code's to change, via the next hook")
    }

    func testDenyIsWrittenAsDeny() {
        let broker = makeBroker()
        let (reply, peer) = reply()
        broker.register(event: event(), reply: reply, session: nil, now: t0)
        broker.answer(id: AgentFixture.requestID, .deny)
        XCTAssertEqual(line(peer), #"{"v":2,"request_id":"0123456789abcdef0123456789abcdef","decision":"deny"}"#)
    }

    func testReleaseWritesNoDecisionAndCountsPresence() {
        let broker = makeBroker()
        var resolved: [PermissionResolution] = []
        broker.onResolved = { resolved.append($1) }
        let (reply, peer) = reply()
        broker.register(event: event(), reply: reply, session: nil, now: t0)

        broker.release(id: AgentFixture.requestID)
        broker.release(id: AgentFixture.requestID)

        XCTAssertEqual(line(peer), #"{"v":2,"request_id":"0123456789abcdef0123456789abcdef","decision":null}"#)
        XCTAssertEqual(resolved, [.releasedForPresence])
        XCTAssertEqual(broker.releasedForPresenceCount, 1)
        XCTAssertTrue(broker.pending.isEmpty)
    }

    func testReleaseAllForSessionLeavesOtherSessionsAlone() {
        let broker = makeBroker()
        let a = reply("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        let b = reply("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        broker.register(event: event(sessionID: "s1", requestID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"), reply: a.0, session: nil, now: t0)
        broker.register(event: event(sessionID: "s2", requestID: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"), reply: b.0, session: nil, now: t0)

        broker.releaseAll(for: "claude:s1")

        XCTAssertEqual(broker.pending.map(\.sessionID), ["claude:s2"])
        XCTAssertNotNil(line(a.1))
        XCTAssertNil(line(b.1))
    }

    func testUnlockingWithTheHostAlreadyInFrontReleasesTheHold() {
        // Locked with iTerm in front: the request is held (spec table). Unlocking
        // puts iTerm back in front, so the hold ends now — not at the 120 s expiry.
        frontmost = (4242, "com.googlecode.iterm2")
        presence.setLocked(true)
        let broker = makeBroker()
        var resolved: [PermissionResolution] = []
        broker.onResolved = { resolved.append($1) }
        let (reply, peer) = reply()
        broker.register(event: event(), reply: reply, session: nil, now: t0)
        XCTAssertEqual(broker.pending.count, 1)

        presence.setLocked(false)

        XCTAssertTrue(broker.pending.isEmpty)
        XCTAssertEqual(resolved, [.releasedForPresence])
        XCTAssertEqual(broker.releasedForPresenceCount, 1)
        XCTAssertEqual(line(peer), #"{"v":2,"request_id":"0123456789abcdef0123456789abcdef","decision":null}"#)
    }

    func testARepeatedRequestIDIsReleasedNotHeldTwice() {
        // 128 random bits never repeat by accident; a repeat is a replay. Overwriting
        // the entry would leave a phantom row in `pending` that nothing can resolve.
        let broker = makeBroker()
        let first = reply()
        let second = reply()
        broker.register(event: event(sessionID: "s1"), reply: first.0, session: nil, now: t0)
        broker.register(event: event(sessionID: "s2"), reply: second.0, session: nil, now: t0)

        XCTAssertEqual(broker.pending.map(\.sessionID), ["claude:s1"])
        XCTAssertNotNil(line(second.1), "the newcomer is released without a decision")
        XCTAssertNil(line(first.1), "the original hold is untouched")

        broker.answer(id: AgentFixture.requestID, .deny)
        XCTAssertTrue(broker.pending.isEmpty, "no phantom row survives the answer")
    }

    func testAMinimisedTerminalIsHeldAndUnminimisingReleasesOnTheRecheck() async throws {
        // iTerm2 is frontmost the whole time; only its window comes and goes.
        frontmost = (4242, "com.googlecode.iterm2")
        hostVisible = false
        let broker = makeBroker(recheckInterval: 0.05)
        var resolved: [PermissionResolution] = []
        broker.onResolved = { resolved.append($1) }
        let (reply, peer) = reply()
        broker.register(event: event(), reply: reply, session: nil, now: t0)
        XCTAssertEqual(broker.pending.count, 1, "no window on screen: the user is not at the terminal")

        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(broker.pending.count, 1, "still hidden: the recheck leaves the hold alone")

        hostVisible = true
        for _ in 0..<40 where !broker.pending.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertTrue(broker.pending.isEmpty, "the terminal is visible again: released without a decision")
        XCTAssertEqual(resolved, [.releasedForPresence])
        XCTAssertEqual(broker.releasedForPresenceCount, 1)
        XCTAssertEqual(line(peer), #"{"v":2,"request_id":"0123456789abcdef0123456789abcdef","decision":null}"#)
    }

    func testActivatingTheHostAppReleasesItsSessions() {
        let broker = makeBroker()
        let mine = AgentHostInfo(pid: 777, bundleID: "com.apple.Terminal", tty: nil)
        let a = reply("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        let b = reply("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        broker.register(event: event(host: mine, sessionID: "s1", requestID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"), reply: a.0, session: nil, now: t0)
        broker.register(event: event(sessionID: "s2", requestID: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"), reply: b.0, session: nil, now: t0)

        presence.onActivation?((777, "com.apple.Terminal"))

        XCTAssertEqual(broker.pending.map(\.sessionID), ["claude:s2"])
        XCTAssertEqual(broker.releasedForPresenceCount, 1)
        XCTAssertNotNil(line(a.1))
    }

    func testExpiryReleasesWithNoDecisionAndReportsExpired() async throws {
        let broker = makeBroker(holdWindow: 0.2)
        var resolved: [(PermissionResolution, Int)] = []
        broker.onResolved = { [broker] _, why in resolved.append((why, broker.pending.count)) }
        let (reply, peer) = reply()
        broker.register(event: event(), reply: reply, session: nil, now: t0)
        store.apply(event(), now: t0)

        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertTrue(broker.pending.isEmpty)
        XCTAssertEqual(broker.expiredCount, 1)
        XCTAssertEqual(resolved.map(\.0), [.expired])
        XCTAssertEqual(resolved.first?.1, 0)
        XCTAssertEqual(line(peer), #"{"v":2,"request_id":"0123456789abcdef0123456789abcdef","decision":null}"#)
        XCTAssertNil(store.sessions.first?.pendingPermissionID)

        broker.answer(id: AgentFixture.requestID, .allow)   // stale click after expiry: ignored
        XCTAssertEqual(broker.answeredCount, 0)
    }

    func testAnsweringCancelsTheExpiry() async throws {
        let broker = makeBroker(holdWindow: 0.2)
        var resolved: [PermissionResolution] = []
        broker.onResolved = { resolved.append($1) }
        let (reply, _) = reply()
        broker.register(event: event(), reply: reply, session: nil, now: t0)
        broker.answer(id: AgentFixture.requestID, .allow)

        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(resolved, [.answered(.allow)])
        XCTAssertEqual(broker.expiredCount, 0)
    }

    func testAHelperThatHangsUpIsResolvedAsExpired() async throws {
        let broker = makeBroker()
        var resolved: [PermissionResolution] = []
        broker.onResolved = { resolved.append($1) }
        let (reply, _) = reply()
        broker.register(event: event(), reply: reply, session: nil, now: t0)

        reply.peerClosed()   // what the server calls when it reads EOF from the helper
        // One main-actor hop away; poll instead of trusting a fixed sleep.
        for _ in 0..<100 where !broker.pending.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertTrue(broker.pending.isEmpty)
        XCTAssertEqual(resolved, [.expired])
        XCTAssertEqual(broker.expiredCount, 1)
    }

    func testNothingIsPersisted() {
        // Spec rule 4: pending requests live in memory only.
        let broker = makeBroker()
        let (reply, _) = reply()
        broker.register(event: event(), reply: reply, session: nil, now: t0)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertEqual(contents, [], "the broker wrote \(contents)")
    }
}
