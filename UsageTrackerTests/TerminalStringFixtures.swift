import XCTest
@testable import Omelette

/// What the terminal-strings tests share (spec 2026-11-23 terminal strings): the rule
/// written out a second time, the hostile strings, the snapshots, and every output the
/// tool makes of one file.
enum TerminalStringFixture {
    // MARK: - The rule, written out again

    /// Design 1, from the spec's words and not from the code under test: `Cc`, `Cf` but
    /// U+200C and U+200D, `Zl`, `Zp`.
    static func isRemoved(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator: return true
        case .format: return scalar.value != 0x200C && scalar.value != 0x200D
        default: return false
        }
    }

    /// The scalars of `text` the rule removes, spelled `U+001B`, for a failure message.
    /// `allowingLineFeed` is for an output whose own lines end in one.
    static func removed(in text: String, allowingLineFeed: Bool = false) -> [String] {
        var found: [String] = []
        for scalar in text.unicodeScalars where isRemoved(scalar) {
            if allowingLineFeed, scalar.value == 0x0A { continue }
            let name = "U+" + String(scalar.value, radix: 16, uppercase: true).leftPadded(to: 4)
            if !found.contains(name) { found.append(name) }
        }
        return found
    }

    // MARK: - Hostile strings

    /// One kind of what must not reach a terminal, and what it leaves between two words.
    struct Kind {
        let name: String
        let text: String
        /// What stands between `pre` and `post` once `pre + text + post` is cleaned.
        let leaves: String
    }

    static let kinds: [Kind] = [
        Kind(name: "an ESC CSI sequence", text: "\u{1B}[2J", leaves: "[2J"),
        Kind(name: "OSC 52 ended by BEL", text: "\u{1B}]52;c;aGVsbG8=\u{07}", leaves: "]52;c;aGVsbG8="),
        Kind(name: "OSC 52 ended by ST", text: "\u{1B}]52;c;aGVsbG8=\u{1B}\\", leaves: "]52;c;aGVsbG8=\\"),
        Kind(name: "the C1 CSI", text: "\u{9B}2J", leaves: "2J"),
        Kind(name: "a bidi override", text: "\u{202E}", leaves: ""),
        Kind(name: "the bidi embeddings and marks", text: "\u{202A}\u{202B}\u{202C}\u{202D}\u{200E}\u{200F}\u{061C}", leaves: ""),
        Kind(name: "the bidi isolates", text: "\u{2066}\u{2067}\u{2068}\u{2069}", leaves: ""),
        Kind(name: "a zero-width space", text: "\u{200B}", leaves: ""),
        Kind(name: "a byte-order mark", text: "\u{FEFF}", leaves: ""),
        Kind(name: "a soft hyphen", text: "\u{AD}", leaves: ""),
        Kind(name: "tag characters", text: "\u{E0067}\u{E0062}\u{E007F}", leaves: ""),
        Kind(name: "NUL, backspace and DEL", text: "\u{0}\u{8}\u{7F}", leaves: ""),
        Kind(name: "a carriage return", text: "\r", leaves: " "),
        Kind(name: "a line feed", text: "\n", leaves: " "),
        Kind(name: "CRLF", text: "\r\n", leaves: " "),
        Kind(name: "a tab", text: "\t", leaves: " "),
        Kind(name: "a vertical tab and a form feed", text: "\u{0B}\u{0C}", leaves: " "),
        Kind(name: "NEL", text: "\u{85}", leaves: " "),
        Kind(name: "the line separator", text: "\u{2028}", leaves: " "),
        Kind(name: "the paragraph separator", text: "\u{2029}", leaves: " "),
    ]

    /// Design 3's five in one string: ESC, the C1 CSI, a bidi override, a zero-width space
    /// and a line break, around `word` twice.
    static func hostile(_ word: String) -> String {
        "\u{1B}[31m\(word)\u{9B}0m\u{202E}\u{200B}\n\(word)"
    }

    /// `hostile(word)` as the rule leaves it: the five gone, a space where the line broke.
    static func cleanedHostile(_ word: String) -> String {
        "[31m\(word)0m \(word)"
    }

    static let fiveKinds: [Unicode.Scalar] = ["\u{1B}", "\u{9B}", "\u{202E}", "\u{200B}", "\n"]

    /// A snapshot in which every string is `string(<a word>)`, every optional is set and
    /// every list has an element: the first service, its first window and chat and the
    /// first agent session carry every field the type has. `StatusFileTerminalStringsTests`
    /// checks that claim against the type itself, so a field added later cannot be left out
    /// of this fixture.
    static func everyString(
        _ string: (String) -> String = hostile, at now: Date = TerminalStringFixture.now
    ) -> StatusSnapshot {
        StatusSnapshot(
            version: StatusSnapshot.currentVersion,
            updatedAt: now,
            services: [
                StatusSnapshot.Service(
                    id: string("service-id"), name: string("Provider"), state: string("ok"),
                    retained: true, retainedAt: now.addingTimeInterval(-3600),
                    plan: string("Plan"),
                    windows: [
                        StatusSnapshot.Window(
                            id: string("window-id"), label: string("Label"), percent: 92.4,
                            resetsAt: now.addingTimeInterval(100 * 60), kind: string("session"),
                            usedDollars: 231.2, limitDollars: 250,
                            source: string("statusLine"), asOf: now.addingTimeInterval(-60)
                        ),
                    ],
                    todayCost: 4.2, weekCost: 31.7, todayTokens: 1_234_567, apiEquivalent: true,
                    sessions: [
                        StatusSnapshot.SessionEntry(
                            id: string("chat-id"), title: string("Title"), project: string("Project"),
                            lastAt: now.addingTimeInterval(-3 * 3600),
                            turns: 356, tokens: 41_200_000, cost: 58.1, agents: 3,
                            origin: string("codex_exec"),
                            sessionShare: 12.5, weekShare: 3.1, budgetShare: 1.5
                        ),
                    ]
                ),
                // A live provider with a percent window, so the lines that print a percent,
                // a reset and the advice run on hostile names too.
                StatusSnapshot.Service(
                    id: string("live-id"), name: string("Live"), state: string("ok"),
                    retained: false, retainedAt: nil, plan: string("Live plan"),
                    windows: [
                        StatusSnapshot.Window(
                            id: string("live-window"), label: string("Live label"), percent: 95,
                            resetsAt: now.addingTimeInterval(30 * 60), kind: string("weekly")
                        ),
                    ],
                    todayCost: 1.05, weekCost: nil, todayTokens: nil, apiEquivalent: false,
                    sessions: [
                        StatusSnapshot.SessionEntry(
                            id: string("live-chat"), title: string("Live title"),
                            project: string("Live project"),
                            lastAt: now.addingTimeInterval(-26 * 3600),
                            turns: 1, tokens: 900, cost: nil, agents: 0
                        ),
                    ]
                ),
                // Neither windows nor dollars: the line that prints the state.
                StatusSnapshot.Service(
                    id: string("bare-id"), name: string("Bare"), state: string("error"),
                    retained: false, retainedAt: nil, plan: nil, windows: []
                ),
            ],
            agents: StatusSnapshot.Agents(
                needsYou: 1, working: 1,
                sessions: [
                    StatusSnapshot.Session(
                        id: string("agent-id"), project: string("Agent project"),
                        state: string("needsYou"), activity: string("Activity"),
                        cpuPercent: 12.5, memoryBytes: 123_456_789
                    ),
                    StatusSnapshot.Session(
                        id: string("quiet-id"), project: string("Quiet project"), state: string("working")
                    ),
                ]
            ),
            showsRemaining: true
        )
    }

    // MARK: - Reading a value's strings

    /// Every `String` stored anywhere in `value`, with the path to it, and every gap: an
    /// optional that is nil or a list that is empty on the way through the first element of
    /// each list. Read with `Mirror`, so it follows the type as it is today: a stored
    /// property added to `StatusSnapshot` or to a type inside it is walked without an edit
    /// here.
    static func strings(in value: Any) -> (strings: [(path: String, text: String)], gaps: [String]) {
        var strings: [(path: String, text: String)] = []
        var gaps: [String] = []
        walk(value, path: "snapshot", first: true, strings: &strings, gaps: &gaps)
        return (strings, gaps)
    }

    private static func walk(
        _ value: Any, path: String, first: Bool,
        strings: inout [(path: String, text: String)], gaps: inout [String]
    ) {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let some = mirror.children.first else {
                if first { gaps.append("\(path) is nil") }
                return
            }
            walk(some.value, path: path, first: first, strings: &strings, gaps: &gaps)
            return
        }
        if let text = value as? String {
            strings.append((path, text))
            return
        }
        if value is Date || value is Int || value is Double || value is Bool { return }
        if mirror.displayStyle == .collection {
            if mirror.children.isEmpty, first { gaps.append("\(path) is empty") }
            for (index, child) in mirror.children.enumerated() {
                walk(child.value, path: "\(path)[\(index)]", first: first && index == 0,
                     strings: &strings, gaps: &gaps)
            }
            return
        }
        for child in mirror.children {
            walk(child.value, path: "\(path).\(child.label ?? "?")", first: first,
                 strings: &strings, gaps: &gaps)
        }
    }

    /// Every string of a decoded JSON value: the keys and the values, at any depth.
    static func jsonStrings(_ value: Any) -> [String] {
        if let text = value as? String { return [text] }
        if let list = value as? [Any] { return list.flatMap(jsonStrings) }
        if let object = value as? [String: Any] {
            return object.flatMap { [$0.key] + jsonStrings($0.value) }
        }
        return []
    }

    // MARK: - Files

    /// `snapshot` as the app writes it (`StatusFileWriter.write`): `StatusFile.encoder`'s
    /// bytes and a line feed.
    static func fileBytes(_ snapshot: StatusSnapshot) throws -> Data {
        var data = try StatusFile.encoder.encode(snapshot)
        data.append(0x0A)
        return data
    }

    // MARK: - Outputs

    /// One thing the tool prints, and the shape it must keep.
    struct Output {
        enum Shape {
            /// Plain text of exactly this many lines, each ended by a line feed.
            case lines(Int)
            /// One line of text with no line feed in it.
            case line
            /// A JSON text; line feeds may stand between its tokens and nowhere else.
            case json
            /// One JSON-RPC response on one line. `textLines` is how many lines the tool's
            /// paragraph holds (nil when the response is not a tool's).
            case rpc(textLines: Int?)
        }
        let name: String
        let text: String
        let shape: Shape
    }

    static func request(_ id: Int, tool: String, arguments: [String: Any] = [:]) -> String {
        MCPServer.encode([
            "jsonrpc": "2.0", "id": id, "method": "tools/call",
            "params": ["name": tool, "arguments": arguments],
        ])
    }

    /// The requests an MCP client can make of the three tools, by name: no argument, each
    /// provider id in turn, a provider that names no chat, a limit of one.
    static func requests(for snapshot: StatusSnapshot?) -> [(name: String, line: String, tool: String, arguments: [String: Any])] {
        var calls: [(tool: String, arguments: [String: Any])] = [
            ("get_usage", [:]), ("get_agents", [:]), ("get_sessions", [:]),
            ("get_sessions", ["limit": 1]),
            ("get_sessions", ["provider": hostile("nobody")]),
        ]
        for service in snapshot?.services ?? [] {
            calls.append(("get_sessions", ["provider": service.id, "limit": 15]))
        }
        return calls.enumerated().map { index, call in
            let arguments = call.arguments.keys.sorted().map { "\($0)" }.joined(separator: ",")
            return (
                name: "mcp \(call.tool)(\(arguments)) #\(index)",
                line: request(index + 1, tool: call.tool, arguments: call.arguments),
                tool: call.tool, arguments: call.arguments
            )
        }
    }

    /// How many lines `brioche status` prints for `snapshot`.
    static func statusLines(_ snapshot: StatusSnapshot) -> Int {
        max(1, snapshot.services.count + (StatusText.agentsLine(snapshot.agents) == nil ? 0 : 1))
    }

    /// How many lines a tool's paragraph holds: one, but for `get_sessions`, which is a list.
    static func textLines(tool: String, arguments: [String: Any], snapshot: StatusSnapshot) -> Int {
        guard tool == "get_sessions" else { return 1 }
        let provider = (arguments["provider"] as? String).map(TerminalString.clean)
        let rows = MCPSummary.sessionRows(
            snapshot, provider: provider, limit: MCPSummary.sessionLimit(arguments["limit"])
        )
        guard !rows.isEmpty else { return 1 }
        return rows.count + 1 + (MCPSummary.sessionsQualifier(rows) == nil ? 0 : 1)
    }

    /// Everything the tool prints from the file at `url`, read as `CLIMain` reads it (one
    /// `StatusFile.load` or `StatusFile.read` per command) and rendered by the functions its
    /// commands call: `status`, `status --json`, `statusline` for the default provider and
    /// for each provider in the file, and every MCP request of `requests(for:)`. Empty when
    /// the file does not load.
    static func outputs(of url: URL, now: Date = TerminalStringFixture.now) -> [Output] {
        guard let snapshot = StatusFile.load(from: url), let bytes = StatusFile.read(from: url) else { return [] }
        var outputs = [
            Output(
                name: "status",
                text: StatusText.render(snapshot: snapshot, now: now, calendar: calendar, locale: locale),
                shape: .lines(statusLines(snapshot))
            ),
            Output(name: "status --json", text: String(decoding: bytes, as: UTF8.self), shape: .json),
        ]
        for provider in [StatusLineText.defaultProvider] + snapshot.services.map(\.id) {
            guard case .statusLine(let parsed, _) = CLICommand.parse(["statusline", "--provider", provider]) else { continue }
            outputs.append(Output(
                name: "statusline --provider \(provider.debugDescription)",
                text: StatusLineText.render(
                    snapshot: snapshot, provider: parsed, now: now, colour: false,
                    calendar: calendar, locale: locale
                ),
                shape: .line
            ))
        }
        for request in requests(for: snapshot) {
            guard let response = MCPServer.handle(request.line, snapshot: StatusFile.load(from: url), now: now) else { continue }
            outputs.append(Output(
                name: request.name, text: response,
                shape: .rpc(textLines: textLines(tool: request.tool, arguments: request.arguments, snapshot: snapshot))
            ))
        }
        return outputs
    }

    /// Fails for every scalar the rule removes that `output` holds: raw, or written as a
    /// JSON escape that decodes to one. The only one allowed is the line feed where the
    /// output's own shape puts it: at the end of a line of `status`, between the tokens of
    /// a JSON text, between the rows of a tool's list.
    static func assertNothingRemovedIsPrinted(
        _ output: Output, _ context: String = "", file: StaticString = #filePath, line: UInt = #line
    ) {
        let name = context.isEmpty ? output.name : "\(context): \(output.name)"
        switch output.shape {
        case .lines(let count):
            XCTAssertEqual(removed(in: output.text, allowingLineFeed: true), [], name, file: file, line: line)
            XCTAssertEqual(output.text.unicodeScalars.filter { $0 == "\n" }.count, count,
                           "\(name): a string broke the output into more lines", file: file, line: line)
            XCTAssertTrue(output.text.hasSuffix("\n"), name, file: file, line: line)
        case .line:
            XCTAssertEqual(removed(in: output.text), [], name, file: file, line: line)
        case .json:
            XCTAssertEqual(removed(in: output.text, allowingLineFeed: true), [], name, file: file, line: line)
            guard let object = try? JSONSerialization.jsonObject(with: Data(output.text.utf8)) else {
                return XCTFail("\(name): not JSON", file: file, line: line)
            }
            for text in jsonStrings(object) {
                XCTAssertEqual(removed(in: text), [], "\(name): decoded \(text.debugDescription)", file: file, line: line)
            }
        case .rpc(let textLines):
            XCTAssertEqual(removed(in: output.text), [], name, file: file, line: line)
            guard let object = try? JSONSerialization.jsonObject(with: Data(output.text.utf8)) as? [String: Any] else {
                return XCTFail("\(name): not a JSON object", file: file, line: line)
            }
            var rest = object
            if var result = object["result"] as? [String: Any],
               let content = result["content"] as? [[String: Any]], content.count == 2,
               let paragraph = content[0]["text"] as? String,
               let serialised = content[1]["text"] as? String {
                // The paragraph: a list's rows end in a line feed and nothing else may.
                XCTAssertEqual(removed(in: paragraph, allowingLineFeed: true), [], "\(name): the paragraph", file: file, line: line)
                XCTAssertEqual(paragraph.unicodeScalars.filter { $0 == "\n" }.count + 1, textLines ?? 1,
                               "\(name): a string broke the paragraph into more lines", file: file, line: line)
                // The same data as text: JSON again, read through.
                assertNothingRemovedIsPrinted(
                    Output(name: "\(name): the serialised block", text: serialised, shape: .json),
                    file: file, line: line
                )
                result["content"] = nil
                rest["result"] = result
            } else {
                XCTAssertNil(textLines, "\(name): a tool's answer has two content blocks", file: file, line: line)
            }
            for text in jsonStrings(rest) {
                XCTAssertEqual(removed(in: text), [], "\(name): decoded \(text.debugDescription)", file: file, line: line)
            }
        }
    }
}

private extension String {
    func leftPadded(to length: Int) -> String {
        String(repeating: "0", count: max(0, length - count)) + self
    }
}

extension TerminalStringFixture {
    /// Sunday 2026-09-06 11:20:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_788_693_600)

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }

    static let locale = Locale(identifier: "en_GB")

    /// A snapshot as the app writes one on an ordinary day, with nothing for the rule to
    /// clean: three providers (one live with a status-line window, a weekly one and a credit
    /// pool, one retained, one signed out), chats, and two agent sessions. Its strings hold
    /// what a real one may: a quote, a backslash, a slash, an accent, a dash, a Persian word
    /// shaped by U+200C and an emoji joined by U+200D. `now` is the fixed one for a golden
    /// and the clock's for the built tool, which refuses a snapshot older than ten minutes.
    static func cleanSnapshot(at now: Date = TerminalStringFixture.now) -> StatusSnapshot {
        StatusSnapshot(
            version: StatusSnapshot.currentVersion,
            updatedAt: now,
            services: [
                StatusSnapshot.Service(
                    id: "claude", name: "Claude", state: "ok", retained: false, retainedAt: nil,
                    plan: "Max 5x",
                    windows: [
                        StatusSnapshot.Window(
                            id: "five_hour", label: "Session", percent: 42,
                            resetsAt: now.addingTimeInterval(100 * 60), kind: "session",
                            source: "statusLine", asOf: now.addingTimeInterval(-60)
                        ),
                        StatusSnapshot.Window(
                            id: "seven_day", label: "Weekly", percent: 18.4,
                            resetsAt: now.addingTimeInterval(3 * 86_400), kind: "weekly"
                        ),
                        StatusSnapshot.Window(
                            id: "cloud_credits", label: "Cloud session credits", percent: 92.4,
                            resetsAt: nil, kind: "other", usedDollars: 231.2, limitDollars: 250
                        ),
                    ],
                    todayCost: 4.2, weekCost: 31.7, todayTokens: 1_234_567, apiEquivalent: true,
                    sessions: [
                        StatusSnapshot.SessionEntry(
                            id: "0f3c-a1", title: "Blume integration — \"quoted\" café",
                            project: "Usage tracker", lastAt: now.addingTimeInterval(-3 * 3600),
                            turns: 356, tokens: 41_200_000, cost: 58.1, agents: 3,
                            sessionShare: 12.5, weekShare: 3.1
                        ),
                        StatusSnapshot.SessionEntry(
                            id: "0f3c-b2", title: "می\u{200C}خواهم 👩\u{200D}💻",
                            project: "src/app\\core", lastAt: now.addingTimeInterval(-2 * 86_400),
                            turns: 1, tokens: 900, cost: nil, agents: 0
                        ),
                    ]
                ),
                StatusSnapshot.Service(
                    id: "codex", name: "Codex", state: "notRunning", retained: true,
                    retainedAt: now.addingTimeInterval(-3600), plan: nil,
                    windows: [
                        StatusSnapshot.Window(
                            id: "primary", label: "5h limit", percent: 71,
                            resetsAt: now.addingTimeInterval(30 * 60), kind: "session"
                        ),
                    ],
                    todayCost: 1.05, weekCost: nil, todayTokens: nil, apiEquivalent: false,
                    sessions: [
                        StatusSnapshot.SessionEntry(
                            id: "rollout-7", title: "Nightly sweep", project: "api",
                            lastAt: now.addingTimeInterval(-26 * 3600),
                            turns: 12, tokens: 88_000, cost: 0.42, agents: 0,
                            origin: "codex_exec", budgetShare: 1.5
                        ),
                    ]
                ),
                StatusSnapshot.Service(
                    id: "grok", name: "Grok", state: "notSignedIn", retained: false, retainedAt: nil,
                    plan: nil, windows: []
                ),
            ],
            agents: StatusSnapshot.Agents(
                needsYou: 1, working: 1,
                sessions: [
                    StatusSnapshot.Session(
                        id: "claude:abc", project: "Usage tracker", state: "needsYou",
                        activity: "Remove build artifacts: rm -rf build/",
                        cpuPercent: 12.5, memoryBytes: 123_456_789
                    ),
                    StatusSnapshot.Session(id: "codex:def", project: "api", state: "working"),
                ]
            )
        )
    }
}

extension TerminalStringFixture {
    /// What BASE (90b87e3, before the rule existed) printed for `cleanSnapshot()` at `now` in
    /// `calendar` and `locale`, generated from its sources: a snapshot with nothing to clean
    /// must still print exactly this.
    enum Golden {
        static let statusText = "Claude  Session 42%, resets in 1h 40m (13:00) · Weekly 18%, resets in 3d 0h (Wed 11:20) · Cloud session credits $231 used of $250 · $4.20 today · $31.70 this week (API-equivalent)\nCodex   5h limit 71%, resets in 30m · $1.05 today · (last known 10:20)\nGrok    Sign in needed\nAgents: 1 needs you, 1 working\n"
        static let usageText = "Claude (Max 5x): session 42% from Claude Code at 11:19, resets in 1h 40m (13:00); weekly 18%, resets in 3d 0h (Wed 11:20); cloud session credits $231 used of $250; $4.20 today, $31.70 this week (API-equivalent, not a subscription bill). Codex: 5h limit 71%, resets in 30m; $1.05 today; last known at 10:20; the provider is not reporting now. Grok: sign in needed. Claude's session window is 42% used and resets in 1h 40m (13:00), so there is room to work. Numbers as of 11:20."
        static let agentsText = "1 session needs a decision from you and 1 is working. Usage tracker — needs you: Remove build artifacts: rm -rf build/. api — working. Numbers as of 11:20."
        static let sessionsText = "Claude · Blume integration — \"quoted\" café · Usage tracker · today 8:20 · 356 turns · 41.2M tokens · $58.10 · 3 sub-agents\nCodex · Nightly sweep · api · Sat 9:20 · 12 turns · 88.0k tokens · $0.42 · exec\nClaude · می\u{200C}خواهم 👩\u{200D}💻 · src/app\\core · Fri 11:20 · 1 turn · 900 tokens · —\nNumbers as of 11:20.\nChat costs are API-equivalent: what the same tokens would cost at API list prices, not a subscription bill."
        static let codexSessionsText = "Codex · Nightly sweep · api · Sat 9:20 · 12 turns · 88.0k tokens · $0.42 · exec\nNumbers as of 11:20."
        static let usageData = "{\"services\":[{\"apiEquivalent\":true,\"id\":\"claude\",\"name\":\"Claude\",\"plan\":\"Max 5x\",\"retained\":false,\"sessions\":[{\"agents\":3,\"cost\":58.100000000000001,\"id\":\"0f3c-a1\",\"lastAt\":\"2026-09-06T08:20:00Z\",\"project\":\"Usage tracker\",\"sessionShare\":12.5,\"title\":\"Blume integration — \\\"quoted\\\" café\",\"tokens\":41200000,\"turns\":356,\"weekShare\":3.1000000000000001},{\"agents\":0,\"id\":\"0f3c-b2\",\"lastAt\":\"2026-09-04T11:20:00Z\",\"project\":\"src/app\\\\core\",\"title\":\"می\u{200C}خواهم 👩\u{200D}💻\",\"tokens\":900,\"turns\":1}],\"state\":\"ok\",\"todayCost\":4.2000000000000002,\"todayTokens\":1234567,\"weekCost\":31.699999999999999,\"windows\":[{\"asOf\":\"2026-09-06T11:19:00Z\",\"id\":\"five_hour\",\"kind\":\"session\",\"label\":\"Session\",\"percent\":42,\"resetsAt\":\"2026-09-06T13:00:00Z\",\"source\":\"statusLine\"},{\"id\":\"seven_day\",\"kind\":\"weekly\",\"label\":\"Weekly\",\"percent\":18.399999999999999,\"resetsAt\":\"2026-09-09T11:20:00Z\"},{\"id\":\"cloud_credits\",\"kind\":\"other\",\"label\":\"Cloud session credits\",\"limitDollars\":250,\"percent\":92.400000000000006,\"usedDollars\":231.19999999999999}]},{\"apiEquivalent\":false,\"id\":\"codex\",\"name\":\"Codex\",\"retained\":true,\"retainedAt\":\"2026-09-06T10:20:00Z\",\"sessions\":[{\"agents\":0,\"budgetShare\":1.5,\"cost\":0.41999999999999998,\"id\":\"rollout-7\",\"lastAt\":\"2026-09-05T09:20:00Z\",\"origin\":\"codex_exec\",\"project\":\"api\",\"title\":\"Nightly sweep\",\"tokens\":88000,\"turns\":12}],\"state\":\"notRunning\",\"todayCost\":1.05,\"windows\":[{\"id\":\"primary\",\"kind\":\"session\",\"label\":\"5h limit\",\"percent\":71,\"resetsAt\":\"2026-09-06T11:50:00Z\"}]},{\"id\":\"grok\",\"name\":\"Grok\",\"retained\":false,\"state\":\"notSignedIn\",\"windows\":[]}],\"showsRemaining\":false,\"updatedAt\":\"2026-09-06T11:20:00Z\",\"version\":2}"
        static let agentsData = "{\"agents\":{\"needsYou\":1,\"sessions\":[{\"activity\":\"Remove build artifacts: rm -rf build/\",\"cpuPercent\":12.5,\"id\":\"claude:abc\",\"memoryBytes\":123456789,\"project\":\"Usage tracker\",\"state\":\"needsYou\"},{\"id\":\"codex:def\",\"project\":\"api\",\"state\":\"working\"}],\"working\":1},\"updatedAt\":\"2026-09-06T11:20:00Z\"}"
        static let sessionsData = "{\"services\":[{\"apiEquivalent\":true,\"id\":\"claude\",\"name\":\"Claude\",\"sessions\":[{\"agents\":3,\"cost\":58.100000000000001,\"id\":\"0f3c-a1\",\"lastAt\":\"2026-09-06T08:20:00Z\",\"project\":\"Usage tracker\",\"sessionShare\":12.5,\"title\":\"Blume integration — \\\"quoted\\\" café\",\"tokens\":41200000,\"turns\":356,\"weekShare\":3.1000000000000001},{\"agents\":0,\"id\":\"0f3c-b2\",\"lastAt\":\"2026-09-04T11:20:00Z\",\"project\":\"src/app\\\\core\",\"title\":\"می\u{200C}خواهم 👩\u{200D}💻\",\"tokens\":900,\"turns\":1}]},{\"apiEquivalent\":false,\"id\":\"codex\",\"name\":\"Codex\",\"sessions\":[{\"agents\":0,\"budgetShare\":1.5,\"cost\":0.41999999999999998,\"id\":\"rollout-7\",\"lastAt\":\"2026-09-05T09:20:00Z\",\"origin\":\"codex_exec\",\"project\":\"api\",\"title\":\"Nightly sweep\",\"tokens\":88000,\"turns\":12}]}],\"updatedAt\":\"2026-09-06T11:20:00Z\"}"
        static let claudeStatusLine = "◐ 42% · resets in 1h 40m · ≈$4.20 today · ⚑ 1"
        static let codexStatusLine = "◐ 71% (as of 10:20) · resets in 30m · $1.05 today · ⚑ 1"
    }
}
