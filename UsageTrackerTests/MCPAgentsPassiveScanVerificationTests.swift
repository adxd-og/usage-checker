import XCTest
@testable import Omelette

/// Independent verification of `fix/3.0-followups` package contract item 6(e): the
/// `get_agents` tool description's claim that "a session without [the Omelette hooks]
/// is read from its CLI's log while it has been active in the last 30 minutes,
/// approximately, and never shows as needing the user" — i.e. `PassiveSessionScanner`'s
/// own `recentWindow` default and its `needsYouCount`/`state` rule. Independent fixture
/// tree from `PassiveSessionScannerTests.swift` and
/// `PassiveSessionScannerVerificationTests.swift` (which covers Codex partition pruning,
/// not this rule).
final class MCPAgentsPassiveScanVerificationTests: XCTestCase {
    private var root: URL!
    private var claudeRoot: URL!
    private var codexRoot: URL!
    private let now = Date(timeIntervalSince1970: 1_900_000_000)
    private let sessionID = "aa11bb22-cc33-dd44-ee55-ff66aa77bb88"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPAgentsPassiveScanVerificationTests-\(UUID().uuidString)", isDirectory: true)
        claudeRoot = root.appendingPathComponent("claude-projects", isDirectory: true)
        codexRoot = root.appendingPathComponent("codex-sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func writeClaudeTranscript(secondsAgo: TimeInterval) throws -> URL {
        let slug = "-Users-tester-Projects-followups"
        let url = claudeRoot.appendingPathComponent(slug, isDirectory: true).appendingPathComponent("\(sessionID).jsonl")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let contents = """
        {"type":"user","sessionId":"\(sessionID)","cwd":"/Users/tester/Projects/followups","uuid":"a1"}

        """
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-secondsAgo)], ofItemAtPath: url.path
        )
        return url
    }

    // MARK: - The default recentWindow is 30 minutes

    func testASessionWrittenTwentyNineMinutesAgoIsStillSeen() throws {
        try writeClaudeTranscript(secondsAgo: 29 * 60)
        let sessions = PassiveSessionScanner.scan(claudeProjects: claudeRoot, codexSessions: codexRoot, now: now)
        XCTAssertEqual(sessions.count, 1, "29 minutes is inside the default 30-minute recentWindow")
    }

    func testASessionWrittenThirtyOneMinutesAgoHasAgedOutOfTheDefaultWindow() throws {
        try writeClaudeTranscript(secondsAgo: 31 * 60)
        let sessions = PassiveSessionScanner.scan(claudeProjects: claudeRoot, codexSessions: codexRoot, now: now)
        XCTAssertTrue(sessions.isEmpty, "31 minutes is outside the default 30-minute recentWindow, so the passive scan must not see it")
    }

    /// The boundary itself: `recentWindow` filters with `mtime >= cutoff` where
    /// `cutoff = now - recentWindow`, so a file exactly 30 minutes old is still the
    /// window's edge case, not just "some time under 31 minutes".
    func testASessionWrittenExactlyThirtyMinutesAgoIsStillAtTheEdgeOfTheWindow() throws {
        try writeClaudeTranscript(secondsAgo: 30 * 60)
        let sessions = PassiveSessionScanner.scan(claudeProjects: claudeRoot, codexSessions: codexRoot, now: now)
        XCTAssertEqual(sessions.count, 1, "the cutoff is inclusive (mtime >= cutoff)")
    }

    // MARK: - A passive session never shows as needing the user

    func testAPassivelyScannedSessionNeverNeedsYouRegardlessOfHowOldItsLastWriteIs() throws {
        // Both within the recentWindow, but on either side of the (much smaller)
        // workingWindow, so one comes back "working" and the other "idle" — neither
        // is ever "needsYou", because a passive scan can only see that bytes were
        // appended, never that the CLI is waiting on a question.
        try writeClaudeTranscript(secondsAgo: 5)
        let working = PassiveSessionScanner.scan(claudeProjects: claudeRoot, codexSessions: codexRoot, now: now)
        let session = try XCTUnwrap(working.first)
        XCTAssertEqual(session.state, .working)
        XCTAssertNotEqual(session.state, .needsYou)
        XCTAssertEqual(session.needsYouCount, 0)
        XCTAssertTrue(session.isApproximate)
    }

    func testAnIdlePassivelyScannedSessionAlsoNeverNeedsYou() throws {
        try writeClaudeTranscript(secondsAgo: 20 * 60)
        let sessions = PassiveSessionScanner.scan(claudeProjects: claudeRoot, codexSessions: codexRoot, now: now)
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session.state, .idle)
        XCTAssertNotEqual(session.state, .needsYou)
        XCTAssertEqual(session.needsYouCount, 0)
    }

    /// `AgentState` has four cases; a passive session's `state` must land on one of the
    /// two `PassiveSessionScanner` can actually justify from an mtime alone.
    func testAPassiveSessionsStateIsAlwaysWorkingOrIdleNeverDoneOrNeedsYou() throws {
        for secondsAgo: TimeInterval in [1, 29, 15 * 60, 29 * 60] {
            try? FileManager.default.removeItem(at: claudeRoot)
            try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
            try writeClaudeTranscript(secondsAgo: secondsAgo)
            let sessions = PassiveSessionScanner.scan(claudeProjects: claudeRoot, codexSessions: codexRoot, now: now)
            let session = try XCTUnwrap(sessions.first, "secondsAgo=\(secondsAgo)")
            XCTAssertTrue([.working, .idle].contains(session.state), "secondsAgo=\(secondsAgo): \(session.state)")
        }
    }
}
