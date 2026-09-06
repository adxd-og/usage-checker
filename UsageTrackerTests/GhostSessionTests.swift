import XCTest
@testable import Omelette

/// A Claude Code tab closed inside a still-running terminal: the host app is alive,
/// so the two-hour rule never fires and the row used to sit in the popover forever.
/// The tty is what actually died with the tab.
@MainActor
final class GhostSessionTests: XCTestCase {
    private var directory: URL!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhostSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var historyURL: URL { directory.appendingPathComponent("agent-sessions.jsonl") }

    private func session(
        quietFor seconds: TimeInterval,
        pid: Int32? = nil,
        tty: String? = "/dev/ttys004",
        approximate: Bool = false
    ) -> AgentSession {
        AgentSession(
            sessionID: "s1", source: .claude, projectName: "alpha", cwd: "/tmp/alpha",
            state: .idle, stateSince: t0, lastEventAt: t0, startedAt: t0,
            host: AgentHostInfo(pid: pid, bundleID: "com.googlecode.iterm2", tty: tty),
            isApproximate: approximate, turns: 3, needsYouCount: 1
        )
    }

    private func now(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    // MARK: - The rule

    func testAQuietSessionWhoseTTYIsGoneIsAGhost() {
        XCTAssertTrue(AgentSessionStore.isStale(
            session(quietFor: 0, pid: getpid()),
            now: now(AgentSessionStore.ghostAfter + 1),
            ttyAlive: { _ in false }
        ), "the terminal app is alive but nothing holds that tty — the tab is closed")
    }

    func testAQuietSessionWhoseTTYIsStillHeldIsKept() {
        XCTAssertFalse(AgentSessionStore.isStale(
            session(quietFor: 0, pid: getpid()),
            now: now(AgentSessionStore.ghostAfter + 1),
            ttyAlive: { _ in true }
        ))
    }

    func testFiveMinutesIsTheThreshold() {
        XCTAssertEqual(AgentSessionStore.ghostAfter, 5 * 60)
        XCTAssertFalse(AgentSessionStore.isStale(
            session(quietFor: 0, pid: getpid()),
            now: now(AgentSessionStore.ghostAfter - 1),
            ttyAlive: { _ in false }
        ), "a tab that has been quiet four minutes is a tab someone is reading")
    }

    func testASessionWithNoTTYFallsBackToTheTwoHourRule() {
        let noTTY = session(quietFor: 0, pid: getpid(), tty: nil)
        XCTAssertFalse(AgentSessionStore.isStale(noTTY, now: now(AgentSessionStore.ghostAfter + 1), ttyAlive: { _ in false }))
        XCTAssertFalse(AgentSessionStore.isStale(noTTY, now: now(AgentSessionStore.staleAfter + 1), ttyAlive: { _ in false }),
                       "the host process is this test — still alive")
    }

    func testAnEmptyTTYStringIsNoTTYAtAll() {
        XCTAssertFalse(AgentSessionStore.isStale(
            session(quietFor: 0, pid: getpid(), tty: ""),
            now: now(AgentSessionStore.ghostAfter + 1),
            ttyAlive: { _ in false }
        ))
    }

    func testTheOldRuleStillFiresForADeadHost() {
        XCTAssertTrue(AgentSessionStore.isStale(
            session(quietFor: 0, pid: Int32.max, tty: nil),
            now: now(AgentSessionStore.staleAfter + 1),
            ttyAlive: { _ in true }
        ))
    }

    func testTheTTYIsAskedForByPath() {
        final class Asked { var paths: [String] = [] }
        let asked = Asked()
        _ = AgentSessionStore.isStale(
            session(quietFor: 0, pid: getpid(), tty: "/dev/ttys011"),
            now: now(AgentSessionStore.ghostAfter + 1),
            ttyAlive: { asked.paths.append($0); return true }
        )
        XCTAssertEqual(asked.paths, ["/dev/ttys011"])
    }

    // MARK: - pruneStale

    func testAGhostIsPrunedAndArchived() throws {
        let store = AgentSessionStore(historyURL: historyURL)
        store.mergePassive([], now: t0)
        store.apply(
            AgentEvent(source: .claude, kind: .promptSubmitted, sessionID: "s1", cwd: "/tmp/alpha",
                       toolName: nil, toolSummary: nil, isSubagent: false,
                       host: AgentHostInfo(pid: getpid(), bundleID: "com.googlecode.iterm2", tty: "/dev/ttys004"),
                       receivedAt: t0),
            now: t0
        )
        XCTAssertEqual(store.sessions.count, 1)

        store.pruneStale(now: now(AgentSessionStore.ghostAfter + 1), ttyAlive: { _ in false })

        XCTAssertTrue(store.sessions.isEmpty)
        let records = try AgentHistoryStore(fileURL: historyURL).load()
        XCTAssertEqual(records.map(\.id), ["claude:s1"], "a ghost is still a session that ran")
        XCTAssertEqual(records.first?.endedAt, t0, "it ended when it last spoke, not when we noticed")
    }

    // MARK: - The kernel primitive

    func testTheSystemProbeSaysNoForADeviceNobodyCanHaveAsATerminal() {
        // /dev/null exists and is a character device, so `stat` succeeds — no process
        // can have it as a *controlling terminal*, which is what makes it a real
        // negative rather than a missing-file one.
        XCTAssertFalse(AgentSessionStore.systemTTYAlive("/dev/null"))
    }

    func testTheSystemProbeSaysNoForATTYThatDoesNotExist() {
        XCTAssertFalse(AgentSessionStore.systemTTYAlive("/dev/ttys999"))
        XCTAssertFalse(AgentSessionStore.systemTTYAlive("/dev/definitely-not-a-tty"))
    }
}
