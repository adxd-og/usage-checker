import XCTest
@testable import Omelette

/// Ids are strings too: a provider's, a window's, a chat's and an agent session's id are
/// cleaned where the file is read, and wherever the tool matches one against something
/// else, both sides are cleaned values: `statusline --provider`, the `provider` argument
/// of `get_sessions`, and the key that pairs the structured half of `get_sessions` with
/// its paragraph.
/// Spec: docs/superpowers/specs/2026-11-23-terminal-strings.md § Design 4.
final class TerminalStringIDsTests: XCTestCase {
    private var directory: URL!
    private var statusURL: URL!

    private let now = TerminalStringFixture.now
    private let calendar = TerminalStringFixture.calendar
    private let locale = TerminalStringFixture.locale

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TerminalStringIDsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        statusURL = directory.appendingPathComponent("status.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func chat(id: String, title: String, hoursAgo: Double) -> StatusSnapshot.SessionEntry {
        StatusSnapshot.SessionEntry(
            id: id, title: title, project: "api", lastAt: now.addingTimeInterval(-hoursAgo * 3600),
            turns: 1, tokens: 900, agents: 0
        )
    }

    private func service(id: String, name: String, chats: [StatusSnapshot.SessionEntry]) -> StatusSnapshot.Service {
        StatusSnapshot.Service(
            id: id, name: name, state: "ok", retained: false, retainedAt: nil, plan: nil,
            windows: [StatusSnapshot.Window(id: "five_hour", label: "Session", percent: 42, kind: "session")],
            sessions: chats
        )
    }

    /// Written as the app writes it, read as the tool reads it.
    private func read(_ services: [StatusSnapshot.Service]) throws -> StatusSnapshot {
        let snapshot = StatusSnapshot(
            version: StatusSnapshot.currentVersion, updatedAt: now, services: services, agents: .none
        )
        try TerminalStringFixture.fileBytes(snapshot).write(to: statusURL, options: [.atomic])
        return try XCTUnwrap(StatusFile.load(from: statusURL))
    }

    private func structured(_ response: String?) throws -> [String: Any] {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((response ?? "").utf8)) as? [String: Any])
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        return try XCTUnwrap(result["structuredContent"] as? [String: Any])
    }

    private func paragraph(_ response: String?) throws -> String {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((response ?? "").utf8)) as? [String: Any])
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return try XCTUnwrap(content.first?["text"] as? String)
    }

    // MARK: - statusline --provider

    func testTheProviderArgumentOfTheStatusLineIsCleaned() {
        XCTAssertEqual(
            CLICommand.parse(["statusline", "--provider", "co\u{200B}dex\u{1B}"]),
            .statusLine(provider: "codex", colour: true)
        )
        XCTAssertEqual(
            CLICommand.parse(["statusline", "--no-color", "--provider", "\u{202E}claude\n"]),
            .statusLine(provider: "claude", colour: false)
        )
        XCTAssertEqual(
            CLICommand.parse(["statusline", "--provider", "codex"]),
            .statusLine(provider: "codex", colour: true),
            "an id with nothing to clean is the id that was typed"
        )
    }

    /// A provider whose id carried removed scalars in the file is found by the id a
    /// person can see and type, and by the id as the file spelled it: both sides of the
    /// comparison are cleaned.
    func testTheStatusLineFindsAProviderByItsCleanedID() throws {
        let loaded = try read([service(id: "co\u{200B}dex\u{9B}", name: "Codex", chats: [])])
        XCTAssertEqual(loaded.services[0].id, "codex")

        for typed in ["codex", "co\u{200B}dex\u{9B}", "\u{1B}codex"] {
            guard case .statusLine(let provider, _) = CLICommand.parse(["statusline", "--provider", typed]) else {
                return XCTFail("not a status line: \(typed.debugDescription)")
            }
            XCTAssertEqual(
                StatusLineText.render(snapshot: loaded, provider: provider, now: now, colour: false, calendar: calendar, locale: locale),
                "◐ 42%", typed.debugDescription
            )
        }
    }

    // MARK: - get_sessions' provider

    /// The same for the tool's argument: the id as the file spelled it, hostile scalars and
    /// all, names the provider whose id reads `codex` once cleaned, and so does `codex`.
    func testGetSessionsMatchesItsProviderArgumentOnCleanedIDs() throws {
        let loaded = try read([
            service(id: "claude", name: "Claude", chats: [chat(id: "c1", title: "Claude chat", hoursAgo: 1)]),
            service(id: "co\u{200B}dex\u{9B}", name: "Codex", chats: [chat(id: "x1", title: "Codex chat", hoursAgo: 2)]),
        ])

        for typed in ["codex", "co\u{200B}dex\u{9B}", "\u{1B}codex\n"] {
            let request = TerminalStringFixture.request(1, tool: "get_sessions", arguments: ["provider": typed])
            let response = MCPServer.handle(request, snapshot: loaded, now: now)

            XCTAssertTrue(try paragraph(response).hasPrefix("Codex · Codex chat · api · "), typed.debugDescription)
            let services = try XCTUnwrap(try structured(response)["services"] as? [[String: Any]])
            XCTAssertEqual(services.map { $0["id"] as? String }, ["codex"], typed.debugDescription)
        }
    }

    /// The argument is echoed when it names no chat. It is the client's own string, and it
    /// is cleaned like the ids it was matched against.
    func testAProviderArgumentThatNamesNoChatIsEchoedCleaned() throws {
        let loaded = try read([service(id: "claude", name: "Claude", chats: [])])
        let typed = "gr\u{1B}]52;c;aGVsbG8=\u{07}ok\u{202E}\r\nnow"

        let response = MCPServer.handle(
            TerminalStringFixture.request(1, tool: "get_sessions", arguments: ["provider": typed]),
            snapshot: loaded, now: now
        )

        XCTAssertTrue(try paragraph(response).hasPrefix("No gr]52;c;aGVsbG8=ok now chats in the last 7 days. Numbers as of "))
        XCTAssertEqual(TerminalStringFixture.removed(in: response ?? ""), [])
        XCTAssertEqual(TerminalStringFixture.removed(in: try paragraph(response)), [])
    }

    // MARK: - The key that pairs the structured half with the paragraph

    /// `sessionsData` picks the chats of the paragraph by `<service id> NUL <chat id>`. A
    /// NUL inside an id would let two different chats share that key (`a NUL b` + `c` and
    /// `a` + `b NUL c`). An id as read holds no NUL, so the key cannot be forged: with a
    /// limit of one, the structured half holds the one chat the paragraph names.
    func testNoIDAsReadCanForgeTheKeyOfAnotherChat() throws {
        let loaded = try read([
            service(id: "a\u{0}b", name: "First", chats: [chat(id: "c", title: "Newer", hoursAgo: 1)]),
            service(id: "a", name: "Second", chats: [chat(id: "b\u{0}c", title: "Older", hoursAgo: 2)]),
        ])
        XCTAssertEqual(loaded.services.map(\.id), ["ab", "a"])
        XCTAssertEqual(loaded.services.compactMap { $0.sessions?.first?.id }, ["c", "bc"])

        let response = MCPServer.handle(
            TerminalStringFixture.request(1, tool: "get_sessions", arguments: ["limit": 1]),
            snapshot: loaded, now: now
        )

        XCTAssertTrue(try paragraph(response).hasPrefix("First · Newer · api · "))
        let services = try XCTUnwrap(try structured(response)["services"] as? [[String: Any]])
        XCTAssertEqual(services.count, 1)
        XCTAssertEqual(services.first?["id"] as? String, "ab")
        XCTAssertEqual((services.first?["sessions"] as? [[String: Any]])?.map { $0["id"] as? String }, ["c"])
    }

    /// Every id of the snapshot, hostile in the file: the structured half of each tool
    /// carries the cleaned id, and the chats it lists are the ones its paragraph lists.
    func testTheStructuredHalfListsTheParagraphsChatsUnderTheirCleanedIDs() throws {
        try TerminalStringFixture.fileBytes(TerminalStringFixture.everyString()).write(to: statusURL, options: [.atomic])
        let loaded = try XCTUnwrap(StatusFile.load(from: statusURL))

        let sessions = MCPServer.handle(TerminalStringFixture.request(1, tool: "get_sessions"), snapshot: loaded, now: now)
        let agents = MCPServer.handle(TerminalStringFixture.request(2, tool: "get_agents"), snapshot: loaded, now: now)
        let usage = MCPServer.handle(TerminalStringFixture.request(3, tool: "get_usage"), snapshot: loaded, now: now)

        let listed = try XCTUnwrap(try structured(sessions)["services"] as? [[String: Any]])
        XCTAssertEqual(listed.map { $0["id"] as? String }, ["[31mservice-id0m service-id", "[31mlive-id0m live-id"])
        XCTAssertEqual(
            listed.flatMap { ($0["sessions"] as? [[String: Any]] ?? []).map { $0["id"] as? String } },
            ["[31mchat-id0m chat-id", "[31mlive-chat0m live-chat"]
        )
        XCTAssertEqual(try paragraph(sessions).components(separatedBy: "\n").count, 2 + 1 + 1, "two chats, the stamp, the qualifier")
        let agentSessions = try XCTUnwrap((try structured(agents)["agents"] as? [String: Any])?["sessions"] as? [[String: Any]])
        XCTAssertEqual(agentSessions.map { $0["id"] as? String }, ["[31magent-id0m agent-id", "[31mquiet-id0m quiet-id"])
        let services = try XCTUnwrap(try structured(usage)["services"] as? [[String: Any]])
        XCTAssertEqual(
            (services.first?["windows"] as? [[String: Any]])?.map { $0["id"] as? String },
            ["[31mwindow-id0m window-id"]
        )
    }

    /// Two ids that differ only by what the rule removes are one id once read. Both chats
    /// are still listed, and nothing traps.
    func testTwoIDsThatCleanToTheSameValueAreBothListed() throws {
        let loaded = try read([service(id: "claude", name: "Claude", chats: [
            chat(id: "same", title: "Plain", hoursAgo: 1),
            chat(id: "sa\u{200B}me", title: "Padded", hoursAgo: 1),
        ])])

        let response = MCPServer.handle(TerminalStringFixture.request(1, tool: "get_sessions"), snapshot: loaded, now: now)

        let lines = try paragraph(response).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(Set(lines.prefix(2).map { String($0.prefix(17)) }), ["Claude · Plain · ", "Claude · Padded ·"])
        let services = try XCTUnwrap(try structured(response)["services"] as? [[String: Any]])
        XCTAssertEqual((services.first?["sessions"] as? [[String: Any]])?.map { $0["id"] as? String }, ["same", "same"])
    }
}
