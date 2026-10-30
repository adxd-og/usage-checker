import AppKit
import XCTest
@testable import Omelette

/// Verification of owner 2026-10-30 (notch-island spec § 3.1): the broker never holds
/// `AskUserQuestion` or `ExitPlanMode`; it releases them at once with no decision; every other
/// tool is held as before.
@MainActor
final class PermissionBrokerQuestionVerificationTests: XCTestCase {
    private var directory: URL!
    private var store: AgentSessionStore!
    private var presence: PresenceMonitor!
    private var frontmost: PresenceMonitor.Frontmost? = (1, "com.other.app")
    private var featureEnabled = true
    private var peers: [Int32] = []
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let iterm = AgentHostInfo(pid: 4242, bundleID: "com.googlecode.iterm2", tty: "/dev/ttys004")
    private let released = #"{"v":2,"request_id":"REQ","decision":null}"#

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PermissionBrokerQuestionVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = AgentSessionStore(historyURL: directory.appendingPathComponent("agent-sessions.jsonl"))
        presence = PresenceMonitor(frontmost: { [weak self] in self?.frontmost }, hostHasVisibleWindow: { _ in true })
    }

    override func tearDown() async throws {
        for peer in peers { close(peer) }
        peers = []
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeBroker() -> PermissionBroker {
        PermissionBroker(store: store, presence: presence, featureEnabled: { [weak self] in self?.featureEnabled ?? true }, holdWindow: 30, recheckInterval: 1)
    }

    private func requestID(_ n: Int) -> String { String(repeating: String(n), count: 32) }

    private func event(tool: String?, id: String, session: String = "s1") -> AgentEvent {
        AgentEvent(
            source: .claude, kind: .permissionRequested, sessionID: session,
            cwd: "/Users/tester/Projects/alpha", toolName: tool, toolSummary: "x",
            isSubagent: false, host: iterm, receivedAt: t0, requestID: id
        )
    }

    private func send(_ broker: PermissionBroker, tool: String?, n: Int, session: String = "s1") -> String? {
        let pair = AgentFixture.replyPair(requestID: requestID(n))
        peers.append(pair.peer)
        broker.register(event: event(tool: tool, id: requestID(n), session: session), reply: pair.reply, session: nil, now: t0)
        return AgentSocketTestClient.readLine(pair.peer, timeout: 0.2)
    }

    // MARK: - isAnswerable

    func testOnlyTheQuestionAndThePlanAreUnanswerable() {
        XCTAssertFalse(PermissionBroker.isAnswerable(toolName: "AskUserQuestion"))
        XCTAssertFalse(PermissionBroker.isAnswerable(toolName: "ExitPlanMode"))
        for tool: String? in ["Bash", "Edit", "Write", "WebFetch", nil, ""] {
            XCTAssertTrue(PermissionBroker.isAnswerable(toolName: tool), "\(tool ?? "nil") is answerable")
        }
    }

    /// Exact match is right: Claude Code's tool names are case-sensitive identifiers, and the store's
    /// `clearsAttention` and the tool summary match them exactly too. A near-miss name is a different
    /// tool (an MCP tool named alike, a future tool) whose Allow / Deny the user may well want.
    func testNearMissNamesAreNotQuestions() {
        for tool in ["askuserquestion", "ASKUSERQUESTION", "exitplanmode", " AskUserQuestion", "ExitPlanMode ", "mcp__x__AskUserQuestion", "AskUserQuestion2"] {
            XCTAssertTrue(PermissionBroker.isAnswerable(toolName: tool), "\(tool)")
        }
    }

    // MARK: - register

    func testBashAndAnUnnamedToolAreStillHeldWhenTheUserIsAway() {
        let broker = makeBroker()
        XCTAssertNil(send(broker, tool: "Bash", n: 1, session: "a"), "held: nothing written")
        XCTAssertNil(send(broker, tool: nil, n: 2, session: "b"), "no tool name: held as before")
        XCTAssertNil(send(broker, tool: "askuserquestion", n: 3, session: "c"), "a case-different name is not special")
        XCTAssertEqual(broker.pending.count, 3)
    }

    func testAQuestionIsReleasedEvenWhenTheFeatureIsOffOrTheUserIsAtTheHost() {
        for (featureOn, userAtHost) in [(true, false), (false, false), (true, true), (false, true)] {
            featureEnabled = featureOn
            frontmost = userAtHost ? (4242, "com.googlecode.iterm2") : (1, "com.other.app")
            let broker = makeBroker()
            for (i, tool) in ["AskUserQuestion", "ExitPlanMode"].enumerated() {
                let sent = send(broker, tool: tool, n: i + 1)
                XCTAssertEqual(sent, released.replacingOccurrences(of: "REQ", with: requestID(i + 1)), "\(tool) feature \(featureOn) atHost \(userAtHost)")
            }
            XCTAssertTrue(broker.pending.isEmpty)
            XCTAssertEqual(broker.releasedForPresenceCount, 0, "a question is the terminal's, not a presence release (atHost \(userAtHost))")
        }
    }

    func testAReleasedQuestionLeavesAnotherHeldRequestOfTheSameSessionAlone() {
        let broker = makeBroker()
        XCTAssertNil(send(broker, tool: "Bash", n: 1))
        XCTAssertEqual(broker.pending.count, 1)

        XCTAssertNotNil(send(broker, tool: "AskUserQuestion", n: 2), "released")

        XCTAssertEqual(broker.pending.map(\.id), [requestID(1)], "the held Bash request is not expired by a question")
    }
}
