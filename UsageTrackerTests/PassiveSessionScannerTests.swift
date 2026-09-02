import XCTest
@testable import Omelette

/// Fixture trees mimic the real layouts:
///   ~/.claude/projects/<slug>/<session_id>.jsonl
///   ~/.codex/sessions/YYYY/MM/DD/rollout-<stamp>-<uuid>.jsonl
/// Both roots are injected, so nothing here can read the developer's own logs.
final class PassiveSessionScannerTests: XCTestCase {
    private var root: URL!
    private var claudeRoot: URL!
    private var codexRoot: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private let alphaSlug = "-Users-tester-Projects-alpha"
    private let claudeSessionID = "37384099-5d4f-423d-ae8b-0eb0c3308aae"
    private let codexSessionID = "019fd6d6-94a9-7611-a007-3c094955e537"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PassiveScanTests-\(UUID().uuidString)", isDirectory: true)
        claudeRoot = root.appendingPathComponent("claude-projects", isDirectory: true)
        codexRoot = root.appendingPathComponent("codex-sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixture writing

    @discardableResult
    private func write(_ contents: String, to relativePath: String, secondsAgo: TimeInterval) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-secondsAgo)], ofItemAtPath: url.path
        )
        return url
    }

    /// A Claude transcript: preamble records first, `cwd` only on the first message
    /// record — exactly like a real one, where it lands on line 6.
    private func claudeTranscript(cwd: String, sessionID: String) -> String {
        """
        {"type":"last-prompt","leafUuid":"b118ed81-eb23-40e2-8423-f9dc1459a503","sessionId":"\(sessionID)"}
        {"type":"mode","sessionId":"\(sessionID)"}
        {"type":"user","sessionId":"\(sessionID)","cwd":"\(cwd)","uuid":"a1"}
        {"type":"assistant","sessionId":"\(sessionID)","cwd":"/somewhere/else","uuid":"a2"}

        """
    }

    private func codexRollout(cwd: String, sessionID: String) -> String {
        """
        {"timestamp":"2026-08-06T11:30:14.849Z","type":"session_meta","payload":{"session_id":"\(sessionID)","id":"\(sessionID)","cwd":"\(cwd)","originator":"Codex Desktop"}}
        {"timestamp":"2026-08-06T11:30:14.849Z","type":"event_msg","payload":{"type":"task_started"}}

        """
    }

    private func scan(recentWindow: TimeInterval = 30 * 60, workingWindow: TimeInterval = 30) -> [AgentSession] {
        PassiveSessionScanner.scan(
            claudeProjects: claudeRoot, codexSessions: codexRoot,
            now: now, recentWindow: recentWindow, workingWindow: workingWindow
        )
    }

    // MARK: - Claude

    func testAClaudeTranscriptBecomesAnApproximateSession() throws {
        try write(
            claudeTranscript(cwd: "/Users/tester/Projects/alpha", sessionID: claudeSessionID),
            to: "claude-projects/\(alphaSlug)/\(claudeSessionID).jsonl",
            secondsAgo: 300
        )

        let sessions = scan()
        XCTAssertEqual(sessions.count, 1)
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session.id, "claude:\(claudeSessionID)")
        XCTAssertEqual(session.sessionID, claudeSessionID, "the file name IS the session id")
        XCTAssertEqual(session.source, .claude)
        XCTAssertEqual(session.cwd, "/Users/tester/Projects/alpha", "the first record carrying cwd wins")
        XCTAssertEqual(session.projectName, "Projects / alpha")
        XCTAssertEqual(session.state, .idle)
        XCTAssertTrue(session.isApproximate)
        XCTAssertNil(session.host.pid)
        XCTAssertNil(session.activity)
        XCTAssertEqual(session.turns, 0)
        XCTAssertEqual(session.needsYouCount, 0)
        XCTAssertEqual(session.lastEventAt, now.addingTimeInterval(-300))
        XCTAssertEqual(session.stateSince, now.addingTimeInterval(-300))
    }

    func testATranscriptTouchedSecondsAgoIsWorking() throws {
        try write(
            claudeTranscript(cwd: "/Users/tester/Projects/alpha", sessionID: claudeSessionID),
            to: "claude-projects/\(alphaSlug)/\(claudeSessionID).jsonl",
            secondsAgo: 5
        )
        XCTAssertEqual(scan().first?.state, .working)
    }

    func testATranscriptOlderThanTheWindowIsNotASession() throws {
        try write(
            claudeTranscript(cwd: "/Users/tester/Projects/alpha", sessionID: claudeSessionID),
            to: "claude-projects/\(alphaSlug)/\(claudeSessionID).jsonl",
            secondsAgo: 31 * 60
        )
        XCTAssertTrue(scan().isEmpty)
    }

    func testSubagentTranscriptsAreNotSessions() throws {
        // A working machine has ~2,000 of these against ~165 real transcripts:
        // <slug>/<session_id>/subagents/agent-*.jsonl and .../workflows/*/journal.jsonl.
        // The spec ignores subagents, and "journal" is not a session at all.
        try write(
            claudeTranscript(cwd: "/Users/tester/Projects/alpha", sessionID: claudeSessionID),
            to: "claude-projects/\(alphaSlug)/\(claudeSessionID).jsonl",
            secondsAgo: 60
        )
        try write(
            claudeTranscript(cwd: "/Users/tester/Projects/alpha", sessionID: "agent-afbf299881b38acd9"),
            to: "claude-projects/\(alphaSlug)/\(claudeSessionID)/subagents/agent-afbf299881b38acd9.jsonl",
            secondsAgo: 60
        )
        try write(
            claudeTranscript(cwd: "/Users/tester/Projects/alpha", sessionID: "journal"),
            to: "claude-projects/\(alphaSlug)/\(claudeSessionID)/subagents/workflows/wf_9611ae5d/journal.jsonl",
            secondsAgo: 60
        )

        XCTAssertEqual(scan().map(\.sessionID), [claudeSessionID])
    }

    func testNonJSONLSiblingsAreIgnored() throws {
        try write("{}", to: "claude-projects/\(alphaSlug)/\(claudeSessionID).orion.json", secondsAgo: 10)
        XCTAssertTrue(scan().isEmpty)
    }

    func testATranscriptWithoutACwdFallsBackToTheProjectSlug() throws {
        try write(
            "{\"type\":\"last-prompt\",\"sessionId\":\"\(claudeSessionID)\"}\n",
            to: "claude-projects/\(alphaSlug)/\(claudeSessionID).jsonl",
            secondsAgo: 60
        )
        let session = scan().first
        XCTAssertNil(session?.cwd)
        XCTAssertEqual(session?.projectName, "Projects / alpha", "the dash slug is the fallback")
    }

    func testAnUnparseableTranscriptStillProducesASession() throws {
        // Half-written JSON is normal — a poll can land mid-write. We still know the
        // session id from the file name, which is the part the merge needs.
        try write(
            "{\"type\":\"user\",\"cwd\":\"/Users/tester/Proj",
            to: "claude-projects/\(alphaSlug)/\(claudeSessionID).jsonl",
            secondsAgo: 60
        )
        let session = scan().first
        XCTAssertEqual(session?.sessionID, claudeSessionID)
        XCTAssertNil(session?.cwd)
    }

    func testAMissingRootIsNotAnError() {
        let sessions = PassiveSessionScanner.scan(
            claudeProjects: root.appendingPathComponent("nope-claude", isDirectory: true),
            codexSessions: root.appendingPathComponent("nope-codex", isDirectory: true),
            now: now
        )
        XCTAssertTrue(sessions.isEmpty)
    }

    // MARK: - Codex

    func testACodexRolloutBecomesAnApproximateSession() throws {
        try write(
            codexRollout(cwd: "/Users/tester/Projects/beta", sessionID: codexSessionID),
            to: "codex-sessions/2026/09/02/rollout-2026-09-02T10-00-00-\(codexSessionID).jsonl",
            secondsAgo: 10
        )

        let session = try XCTUnwrap(scan().first)
        XCTAssertEqual(session.id, "codex:\(codexSessionID)")
        XCTAssertEqual(session.sessionID, codexSessionID)
        XCTAssertEqual(session.source, .codex)
        XCTAssertEqual(session.cwd, "/Users/tester/Projects/beta")
        XCTAssertEqual(session.projectName, "Projects / beta")
        XCTAssertEqual(session.state, .working)
        XCTAssertTrue(session.isApproximate)
    }

    func testANonRolloutJSONLUnderTheCodexRootIsIgnored() throws {
        try write("{}\n", to: "codex-sessions/2026/09/02/history.jsonl", secondsAgo: 10)
        XCTAssertTrue(scan().isEmpty)
    }

    func testTheThreadIDComesFromTheFileNameWhenTheHeadIsUnreadable() throws {
        try write(
            "not json at all\n",
            to: "codex-sessions/2026/09/02/rollout-2026-09-02T10-00-00-\(codexSessionID).jsonl",
            secondsAgo: 10
        )
        let session = scan().first
        XCTAssertEqual(session?.sessionID, codexSessionID)
        XCTAssertEqual(session?.projectName, "Unknown project")
    }

    func testCodexSessionIDParsing() {
        XCTAssertEqual(
            PassiveSessionScanner.codexSessionID(fileName: "rollout-2026-08-06T14-30-14-019fd6d6-94a9-7611-a007-3c094955e537"),
            "019fd6d6-94a9-7611-a007-3c094955e537"
        )
        XCTAssertNil(PassiveSessionScanner.codexSessionID(fileName: "rollout-2026-08-06T14-30-14-not-a-uuid"))
        XCTAssertNil(PassiveSessionScanner.codexSessionID(fileName: "history"))
    }

    // MARK: - Both roots at once

    func testBothProvidersAreScannedInOnePass() throws {
        try write(
            claudeTranscript(cwd: "/Users/tester/Projects/alpha", sessionID: claudeSessionID),
            to: "claude-projects/\(alphaSlug)/\(claudeSessionID).jsonl",
            secondsAgo: 600
        )
        try write(
            codexRollout(cwd: "/Users/tester/Projects/beta", sessionID: codexSessionID),
            to: "codex-sessions/2026/09/02/rollout-2026-09-02T10-00-00-\(codexSessionID).jsonl",
            secondsAgo: 5
        )

        let sessions = scan()
        XCTAssertEqual(Set(sessions.map(\.id)), ["claude:\(claudeSessionID)", "codex:\(codexSessionID)"])
        XCTAssertEqual(sessions.first(where: { $0.source == .claude })?.state, .idle)
        XCTAssertEqual(sessions.first(where: { $0.source == .codex })?.state, .working)
    }
}
