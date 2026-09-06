import XCTest
@testable import Omelette

final class AgentModelsTests: XCTestCase {
    func testSessionIDIsSourceColonSessionID() {
        let now = Date(timeIntervalSince1970: 1_756_800_000)
        let session = AgentSession(
            sessionID: "9f1c2b3a-0000-4000-8000-abcdefabcdef", source: .claude,
            projectName: "Usage tracker", cwd: "/Users/me/Desktop/Usage tracker", state: .idle,
            stateSince: now, lastEventAt: now, startedAt: now
        )
        XCTAssertEqual(session.id, "claude:9f1c2b3a-0000-4000-8000-abcdefabcdef")
        XCTAssertEqual(AgentSession.makeID(source: .codex, sessionID: "thr-9"), "codex:thr-9")
        XCTAssertEqual(session.host, .none)
        XCTAssertFalse(session.isApproximate)
        XCTAssertEqual(session.turns, 0)
        XCTAssertEqual(session.needsYouCount, 0)
    }

    func testStateRankOrdersNeedsYouFirstIdleLast() {
        XCTAssertEqual(AgentState.allCases.sorted { $0.rank < $1.rank }, [.needsYou, .working, .done, .idle])
        XCTAssertEqual(Set(AgentState.allCases.map(\.rank)).count, 4, "ranks must be distinct")
    }

    func testSourceAndStateRawValuesAreStable() {
        // These strings end up in agent-sessions.jsonl (package 2) — renaming a case is a data migration.
        XCTAssertEqual(AgentSource.claude.rawValue, "claude")
        XCTAssertEqual(AgentSource.codex.rawValue, "codex")
        XCTAssertEqual(AgentState.needsYou.rawValue, "needsYou")
    }

    func testHostInfoUsesWireKeys() throws {
        let json = Data(#"{"pid":4242,"bundle_id":"com.googlecode.iterm2","tty":"/dev/ttys004"}"#.utf8)
        let host = try JSONDecoder().decode(AgentHostInfo.self, from: json)
        XCTAssertEqual(host, AgentHostInfo(pid: 4242, bundleID: "com.googlecode.iterm2", tty: "/dev/ttys004"))
        XCTAssertNil(host.cmuxWorkspace, "a terminal that is not cmux carries no cmux ids")

        let nulls = Data(#"{"pid":null,"bundle_id":null,"tty":null}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(AgentHostInfo.self, from: nulls), .none)

        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(host)) as? [String: Any]
        XCTAssertEqual(encoded?["bundle_id"] as? String, "com.googlecode.iterm2")
        XCTAssertNil(encoded?["bundleID"])
        XCTAssertNil(encoded?["cmux_workspace"], "an absent id is absent, not null")
    }

    func testHostInfoDecodesTheCmuxIDs() throws {
        // cmux has no tty or pid addressing: a tab is a workspace and a surface, and
        // the helper reads both out of the shell's own environment.
        let json = Data(#"{"pid":900,"bundle_id":"com.cmuxterm.app","tty":null,"cmux_workspace":"ws-7","cmux_surface":"sf-3","cmux_socket":"/tmp/cmux.sock"}"#.utf8)
        let host = try JSONDecoder().decode(AgentHostInfo.self, from: json)
        XCTAssertEqual(host.bundleID, "com.cmuxterm.app")
        XCTAssertNil(host.tty)
        XCTAssertEqual(host.cmuxWorkspace, "ws-7")
        XCTAssertEqual(host.cmuxSurface, "sf-3")
        XCTAssertEqual(host.cmuxSocket, "/tmp/cmux.sock")

        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(host)) as? [String: Any]
        XCTAssertEqual(encoded?["cmux_workspace"] as? String, "ws-7")
        XCTAssertEqual(encoded?["cmux_surface"] as? String, "sf-3")
        XCTAssertEqual(encoded?["cmux_socket"] as? String, "/tmp/cmux.sock")
    }

    func testEventKindEquality() {
        XCTAssertEqual(AgentEvent.Kind.unknown("SubagentStop"), .unknown("SubagentStop"))
        XCTAssertNotEqual(AgentEvent.Kind.unknown("A"), .unknown("B"))
        XCTAssertNotEqual(AgentEvent.Kind.toolStarted, .toolFinished)
    }

    func testEventAndSessionDefaultTheirPhase4Fields() {
        let now = Date(timeIntervalSince1970: 1_756_800_000)
        let event = AgentEvent(source: .claude, kind: .stop, sessionID: "s", cwd: nil, toolName: nil,
                               toolSummary: nil, isSubagent: false, host: .none, receivedAt: now)
        XCTAssertNil(event.requestID)
        let session = AgentSession(sessionID: "s", source: .claude, projectName: "p", cwd: nil,
                                   state: .idle, stateSince: now, lastEventAt: now, startedAt: now)
        XCTAssertNil(session.pendingPermissionID)
        var copy = session
        copy.pendingPermissionID = "abc"
        XCTAssertNotEqual(copy, session, "the pending id takes part in equality so the popover redraws")
    }
}

final class AgentModelDetailFieldTests: XCTestCase {
    func testTheNewEventFieldsDefaultToNothing() {
        let event = AgentEvent(
            source: .claude, kind: .toolStarted, sessionID: "s", cwd: nil, toolName: "Bash",
            toolSummary: "swift test", isSubagent: false, host: .none, receivedAt: Date()
        )
        XCTAssertNil(event.toolDetail)
        XCTAssertNil(event.attention)
    }

    func testAnEventCarriesADetailAndAnAttention() {
        let event = AgentEvent(
            source: .claude, kind: .toolStarted, sessionID: "s", cwd: nil, toolName: "AskUserQuestion",
            toolSummary: "Question: Tabs or spaces?", toolDetail: "Tabs or spaces?\n• Tabs",
            attention: .question(count: 1, multiSelect: false),
            isSubagent: false, host: .none, receivedAt: Date()
        )
        XCTAssertEqual(event.toolDetail, "Tabs or spaces?\n• Tabs")
        XCTAssertEqual(event.attention, .question(count: 1, multiSelect: false))
    }

    func testTheNewSessionFieldsDefaultToNothing() {
        let session = AgentSession(
            sessionID: "s", source: .claude, projectName: "p", cwd: nil, state: .working,
            stateSince: Date(), lastEventAt: Date(), startedAt: Date()
        )
        XCTAssertNil(session.activityDetail)
        XCTAssertNil(session.attention)
    }

    func testAttentionRoundTripsThroughCoding() throws {
        for attention: AgentAttention in [.plan, .question(count: 3, multiSelect: true)] {
            let data = try JSONEncoder().encode(attention)
            XCTAssertEqual(try JSONDecoder().decode(AgentAttention.self, from: data), attention)
        }
    }
}
