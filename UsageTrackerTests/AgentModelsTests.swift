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

        let nulls = Data(#"{"pid":null,"bundle_id":null,"tty":null}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(AgentHostInfo.self, from: nulls), .none)

        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(host)) as? [String: Any]
        XCTAssertEqual(encoded?["bundle_id"] as? String, "com.googlecode.iterm2")
        XCTAssertNil(encoded?["bundleID"])
    }

    func testEventKindEquality() {
        XCTAssertEqual(AgentEvent.Kind.unknown("SubagentStop"), .unknown("SubagentStop"))
        XCTAssertNotEqual(AgentEvent.Kind.unknown("A"), .unknown("B"))
        XCTAssertNotEqual(AgentEvent.Kind.toolStarted, .toolFinished)
    }
}
