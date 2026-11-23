import XCTest
@testable import Omelette

/// The seam: `StatusFile.read` and `StatusFile.load` hand the tool a snapshot whose every
/// string is cleaned, so nothing `brioche status`, `brioche status --json`, `brioche
/// statusline` or the three MCP tools print holds a character a terminal would act on.
/// Spec: docs/superpowers/specs/2026-11-23-terminal-strings.md § Design 1 (whatever the
/// output), 3 (every string field, by construction) and 5 (nothing else moves).
final class StatusFileTerminalStringsTests: XCTestCase {
    private var directory: URL!
    private var statusURL: URL!

    private let now = TerminalStringFixture.now
    private let calendar = TerminalStringFixture.calendar
    private let locale = TerminalStringFixture.locale

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatusFileTerminalStringsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        statusURL = directory.appendingPathComponent("status.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func publish(_ snapshot: StatusSnapshot) throws {
        try TerminalStringFixture.fileBytes(snapshot).write(to: statusURL, options: [.atomic])
    }

    /// The words `TerminalStringFixture.everyString` passes for the fields that name a value
    /// of the app's own (a state, a window kind, a reading source, an origin). Left alone
    /// where a test wants the provider's and the user's strings hostile and the rest real.
    private let appsOwnWords: Set<String> = [
        "ok", "error", "needsYou", "working", "session", "weekly", "statusLine", "codex_exec",
    ]

    // MARK: - Design 3: every string field

    /// The fixture really holds every string the type has: no optional on the way to one
    /// is nil, no list is empty, and each string carries the five kinds the spec names.
    /// A `String` added to `StatusSnapshot`, or to a type inside it, fails here until the
    /// fixture sets it, and the tests below then read it.
    func testTheHostileFixtureCarriesEveryStringFieldTheSnapshotHas() {
        let found = TerminalStringFixture.strings(in: TerminalStringFixture.everyString())

        XCTAssertEqual(found.gaps, [], "a field the fixture leaves unset is a field no test reads")
        XCTAssertGreaterThanOrEqual(found.strings.count, 32)
        for (path, text) in found.strings {
            for scalar in TerminalStringFixture.fiveKinds {
                XCTAssertTrue(text.unicodeScalars.contains(scalar),
                              "\(path) lacks U+\(String(scalar.value, radix: 16, uppercase: true))")
            }
        }
    }

    /// The snapshot as the tool reads it: every string anywhere in it is what the rule
    /// makes of the string the app wrote, and holds nothing the rule removes.
    func testEveryStringOfASnapshotAsReadIsCleaned() throws {
        let written = TerminalStringFixture.everyString()
        try publish(written)

        let loaded = try XCTUnwrap(StatusFile.load(from: statusURL))

        let before = TerminalStringFixture.strings(in: written).strings
        let after = TerminalStringFixture.strings(in: loaded).strings
        XCTAssertEqual(after.map(\.path), before.map(\.path), "no field is added or lost on the way")
        for (was, becomes) in zip(before, after) {
            XCTAssertEqual(TerminalStringFixture.removed(in: becomes.text), [], becomes.path)
            XCTAssertEqual(becomes.text, TerminalString.clean(was.text), becomes.path)
            XCTAssertFalse(becomes.text.isEmpty, becomes.path)
        }
        XCTAssertEqual(loaded.services[0].name, "[31mProvider0m Provider")
        XCTAssertEqual(loaded.agents.sessions[0].activity, "[31mActivity0m Activity")
    }

    /// Design 5 in one comparison: reading changes the strings and nothing else. The
    /// snapshot as read equals the one the app wrote with each string cleaned: the same
    /// fields, numbers, dates, flags and version.
    func testReadingChangesTheStringsAndNothingElse() throws {
        try publish(TerminalStringFixture.everyString())

        let loaded = try XCTUnwrap(StatusFile.load(from: statusURL))

        XCTAssertEqual(loaded, TerminalStringFixture.everyString { TerminalString.clean(TerminalStringFixture.hostile($0)) })
        XCTAssertEqual(loaded, TerminalStringFixture.everyString(TerminalStringFixture.cleanedHostile))
        XCTAssertEqual(loaded.version, 2)
        XCTAssertEqual(StatusSnapshot.currentVersion, 2)
    }

    /// Every command and every tool, text and JSON: nothing the rule removes is printed,
    /// raw or as a JSON escape, and no string adds a line to an output.
    func testNoOutputHoldsARemovedScalarWhenEveryStringIsHostile() throws {
        try publish(TerminalStringFixture.everyString())

        let outputs = TerminalStringFixture.outputs(of: statusURL)

        // status, status --json, four status lines, five requests and one per provider.
        XCTAssertEqual(outputs.count, 2 + 4 + 5 + 3)
        for output in outputs {
            TerminalStringFixture.assertNothingRemovedIsPrinted(output)
        }
    }

    /// The check above is one that can fail: the same outputs made from the snapshot as the
    /// app wrote it, without the read, hold what the rule removes.
    func testTheSameOutputsFromAnUncleanedSnapshotDoHoldRemovedScalars() {
        let uncleaned = TerminalStringFixture.everyString()

        let status = StatusText.render(snapshot: uncleaned, now: now, calendar: calendar, locale: locale)
        let agents = MCPServer.handle(TerminalStringFixture.request(1, tool: "get_agents"), snapshot: uncleaned, now: now) ?? ""

        XCTAssertEqual(TerminalStringFixture.removed(in: status, allowingLineFeed: true), ["U+001B", "U+009B", "U+202E", "U+200B"])
        XCTAssertEqual(TerminalStringFixture.removed(in: agents), ["U+009B", "U+202E", "U+200B"],
                       "JSONSerialization escapes C0 and nothing above it")
    }

    /// A string in a key this build does not know, as a later app may write one: cleaned in
    /// what `status --json` prints, with no line of code naming the key.
    func testAStringFieldThisBuildDoesNotKnowIsCleanedToo() throws {
        let data = try TerminalStringFixture.fileBytes(TerminalStringFixture.cleanSnapshot())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["laterField"] = TerminalStringFixture.hostile("later")
        object["laterList"] = [["deep": [TerminalStringFixture.hostile("deep")]]]
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            .write(to: statusURL)

        let printed = try XCTUnwrap(StatusFile.read(from: statusURL))

        let read = try XCTUnwrap(JSONSerialization.jsonObject(with: printed) as? [String: Any])
        XCTAssertEqual(read["laterField"] as? String, TerminalStringFixture.cleanedHostile("later"))
        XCTAssertEqual((read["laterList"] as? [[String: [String]]])?.first?["deep"], [TerminalStringFixture.cleanedHostile("deep")])
        TerminalStringFixture.assertNothingRemovedIsPrinted(TerminalStringFixture.Output(
            name: "status --json", text: String(decoding: printed, as: UTF8.self), shape: .json
        ))
        XCTAssertEqual(StatusFile.load(from: statusURL), TerminalStringFixture.cleanSnapshot(),
                       "and the snapshot still loads, the unknown keys ignored as before")
    }

    // MARK: - Design 1: each kind, in each place the review named

    /// Each kind of hostile string in a project, an activity, a chat title, a plan, a
    /// window label, a provider name and every id, the app's own words left real: the
    /// value read is the one the spec describes and no output holds a removed scalar.
    func testEachKindInEachNamedFieldReachesNoOutput() throws {
        for kind in TerminalStringFixture.kinds {
            let appsOwnWords = self.appsOwnWords
            try publish(TerminalStringFixture.everyString { word in
                appsOwnWords.contains(word) ? word : "pre" + kind.text + "post"
            })

            let loaded = try XCTUnwrap(StatusFile.load(from: statusURL), kind.name)
            let expected = "pre" + kind.leaves + "post"
            let service = loaded.services[0]
            XCTAssertEqual(service.id, expected, "a provider's id: \(kind.name)")
            XCTAssertEqual(service.name, expected, "a provider name: \(kind.name)")
            XCTAssertEqual(service.plan, expected, "a plan: \(kind.name)")
            XCTAssertEqual(service.windows[0].id, expected, "a window's id: \(kind.name)")
            XCTAssertEqual(service.windows[0].label, expected, "a window label: \(kind.name)")
            XCTAssertEqual(service.sessions?[0].id, expected, "a chat's id: \(kind.name)")
            XCTAssertEqual(service.sessions?[0].title, expected, "a chat title: \(kind.name)")
            XCTAssertEqual(service.sessions?[0].project, expected, "a chat's project: \(kind.name)")
            XCTAssertEqual(loaded.agents.sessions[0].id, expected, "a session's id: \(kind.name)")
            XCTAssertEqual(loaded.agents.sessions[0].project, expected, "a project: \(kind.name)")
            XCTAssertEqual(loaded.agents.sessions[0].activity, expected, "an activity: \(kind.name)")
            XCTAssertEqual(service.state, "ok")
            XCTAssertEqual(service.windows[0].kind, "session")

            let outputs = TerminalStringFixture.outputs(of: statusURL)
            XCTAssertEqual(outputs.count, 2 + 4 + 5 + 3, kind.name)
            for output in outputs {
                TerminalStringFixture.assertNothingRemovedIsPrinted(output, kind.name)
            }
        }
    }

    /// What the review's own lines print now: the project and the activity of
    /// `get_agents`, the title and the project of `get_sessions`, the plan and the label
    /// of `get_usage`, the name and the label of `brioche status`.
    func testTheLinesTheReviewNamedPrintTheCleanedStrings() throws {
        let appsOwnWords = self.appsOwnWords
        try publish(TerminalStringFixture.everyString { word in
            appsOwnWords.contains(word) ? word : "fix\u{1B}]52;c;aGVsbG8=\u{07}\r\n\(word)\u{202E}"
        })
        let loaded = try XCTUnwrap(StatusFile.load(from: statusURL))

        let agents = MCPSummary.agents(snapshot: loaded, now: now, calendar: calendar, locale: locale)
        let sessions = MCPSummary.sessions(snapshot: loaded, provider: nil, limit: 1, now: now, calendar: calendar, locale: locale)
        let usage = MCPSummary.usage(snapshot: loaded, now: now, calendar: calendar, locale: locale)
        let status = StatusText.render(snapshot: loaded, now: now, calendar: calendar, locale: locale)

        XCTAssertTrue(agents.contains("fix]52;c;aGVsbG8= Agent project — needs you: fix]52;c;aGVsbG8= Activity."), agents)
        XCTAssertTrue(sessions.hasPrefix("fix]52;c;aGVsbG8= Provider · fix]52;c;aGVsbG8= Title · fix]52;c;aGVsbG8= Project · today "), sessions)
        XCTAssertTrue(usage.hasPrefix("fix]52;c;aGVsbG8= Provider (fix]52;c;aGVsbG8= Plan): fix]52;c;agvsbg8= label $231 used of $250"), usage)
        XCTAssertTrue(status.hasPrefix("fix]52;c;aGVsbG8= Provider  fix]52;c;aGVsbG8= Label $231 used of $250"), status)
    }

    // MARK: - Nothing left to show

    /// A string of nothing but removed scalars, and one of joiners alone, in every place a
    /// name is printed: each output shows `?` there and every line keeps its shape.
    func testAStringWithNothingToShowPrintsTheUnseenMarkInEveryOutput() throws {
        for unseen in ["\u{1B}\u{9B}\u{202E}\u{200B}\r\n", "\u{200D}\u{200C}", " \u{200B} "] {
            try publish(StatusSnapshot(
                version: StatusSnapshot.currentVersion,
                updatedAt: now,
                services: [
                    StatusSnapshot.Service(
                        id: unseen, name: unseen, state: "ok", retained: false, retainedAt: nil, plan: unseen,
                        windows: [StatusSnapshot.Window(id: unseen, label: unseen, percent: 42, kind: "session")],
                        sessions: [
                            StatusSnapshot.SessionEntry(
                                id: unseen, title: unseen, project: unseen,
                                lastAt: now.addingTimeInterval(-3 * 3600), turns: 1, tokens: 900, agents: 0
                            ),
                        ]
                    ),
                ],
                agents: StatusSnapshot.Agents(
                    needsYou: 0, working: 1,
                    sessions: [StatusSnapshot.Session(id: unseen, project: unseen, state: "working", activity: unseen)]
                )
            ))
            let name = unseen.debugDescription

            let loaded = try XCTUnwrap(StatusFile.load(from: statusURL), name)

            XCTAssertEqual(
                StatusText.render(snapshot: loaded, now: now, calendar: calendar, locale: locale),
                "?  ? 42%\nAgents: 1 working\n", name
            )
            XCTAssertEqual(
                MCPSummary.usage(snapshot: loaded, now: now, calendar: calendar, locale: locale),
                "? (?): ? 42%. ?'s ? window is 42% used, so there is room to work. Numbers as of 11:20.", name
            )
            XCTAssertEqual(
                MCPSummary.agents(snapshot: loaded, now: now, calendar: calendar, locale: locale),
                "0 sessions need a decision from you and 1 is working. ? — working: ?. Numbers as of 11:20.", name
            )
            XCTAssertEqual(
                MCPSummary.sessions(snapshot: loaded, provider: nil, limit: 10, now: now, calendar: calendar, locale: locale),
                "? · ? · ? · today 8:20 · 1 turn · 900 tokens · —\nNumbers as of 11:20.", name
            )
            XCTAssertEqual(
                StatusLineText.render(snapshot: loaded, provider: "?", now: now, colour: false, calendar: calendar, locale: locale),
                "◐ 42%", name
            )
            let sessions = MCPServer.sessionsData(loaded, provider: nil, limit: 10)
            XCTAssertEqual(MCPServer.encode(sessions), #"{"services":[{"id":"?","name":"?","sessions":[{"agents":0,"id":"?","lastAt":"2026-09-06T08:20:00Z","project":"?","title":"?","tokens":900,"turns":1}]}],"updatedAt":"2026-09-06T11:20:00Z"}"#, name)
            let agents = MCPServer.agentsData(loaded)
            XCTAssertEqual(MCPServer.encode(agents), #"{"agents":{"needsYou":0,"sessions":[{"activity":"?","id":"?","project":"?","state":"working"}],"working":1},"updatedAt":"2026-09-06T11:20:00Z"}"#, name)
            for output in TerminalStringFixture.outputs(of: statusURL) {
                TerminalStringFixture.assertNothingRemovedIsPrinted(output, name)
            }
        }
    }

    /// The app's own empty string is not the rule's doing and is read as it was written.
    func testAnEmptyStringTheAppWroteIsReadEmpty() throws {
        try publish(StatusSnapshot(
            version: StatusSnapshot.currentVersion, updatedAt: now,
            services: [StatusSnapshot.Service(
                id: "claude", name: "Claude", state: "ok", retained: false, retainedAt: nil, plan: "", windows: []
            )],
            agents: StatusSnapshot.Agents(
                needsYou: 0, working: 1,
                sessions: [StatusSnapshot.Session(id: "a", project: "", state: "working", activity: "")]
            )
        ))

        let loaded = try XCTUnwrap(StatusFile.load(from: statusURL))

        XCTAssertEqual(loaded.services[0].plan, "")
        XCTAssertEqual(loaded.agents.sessions[0].project, "")
        XCTAssertEqual(loaded.agents.sessions[0].activity, "")
        XCTAssertEqual(StatusFile.read(from: statusURL), try Data(contentsOf: statusURL))
    }

    // MARK: - Design 5: nothing else moves

    /// A snapshot with nothing to clean: the value read is the value written, `status
    /// --json` prints the file's own bytes, and every renderer prints what it printed
    /// before the rule (`TerminalStringFixture.Golden`, generated from 90b87e3).
    func testACleanSnapshotPrintsExactlyWhatItPrintedBeforeTheRule() throws {
        let written = TerminalStringFixture.cleanSnapshot()
        try publish(written)

        let loaded = try XCTUnwrap(StatusFile.load(from: statusURL))

        XCTAssertEqual(loaded, written)
        XCTAssertEqual(StatusFile.read(from: statusURL), try Data(contentsOf: statusURL))
        typealias Golden = TerminalStringFixture.Golden
        XCTAssertEqual(StatusText.render(snapshot: loaded, now: now, calendar: calendar, locale: locale), Golden.statusText)
        XCTAssertEqual(MCPSummary.usage(snapshot: loaded, now: now, calendar: calendar, locale: locale), Golden.usageText)
        XCTAssertEqual(MCPSummary.agents(snapshot: loaded, now: now, calendar: calendar, locale: locale), Golden.agentsText)
        XCTAssertEqual(
            MCPSummary.sessions(snapshot: loaded, provider: nil, limit: 10, now: now, calendar: calendar, locale: locale),
            Golden.sessionsText
        )
        XCTAssertEqual(
            MCPSummary.sessions(snapshot: loaded, provider: "codex", limit: 10, now: now, calendar: calendar, locale: locale),
            Golden.codexSessionsText
        )
        XCTAssertEqual(MCPServer.encode(MCPServer.usageData(loaded)), Golden.usageData)
        XCTAssertEqual(MCPServer.encode(MCPServer.agentsData(loaded)), Golden.agentsData)
        XCTAssertEqual(MCPServer.encode(MCPServer.sessionsData(loaded, provider: nil, limit: 10)), Golden.sessionsData)
        XCTAssertEqual(
            StatusLineText.render(snapshot: loaded, provider: "claude", now: now, colour: false, calendar: calendar, locale: locale),
            Golden.claudeStatusLine
        )
        XCTAssertEqual(
            StatusLineText.render(snapshot: loaded, provider: "codex", now: now, colour: false, calendar: calendar, locale: locale),
            Golden.codexStatusLine
        )
    }

    /// The whole JSON-RPC line of every request, from the file and from the value the app
    /// wrote: the same bytes.
    func testACleanSnapshotAnswersEveryRequestAsItDidBeforeTheRule() throws {
        let written = TerminalStringFixture.cleanSnapshot()
        try publish(written)

        for request in TerminalStringFixture.requests(for: written) {
            XCTAssertEqual(
                MCPServer.handle(request.line, snapshot: StatusFile.load(from: statusURL), now: now),
                MCPServer.handle(request.line, snapshot: written, now: now),
                request.name
            )
        }
    }

    /// The app's side is not touched: what the writer puts on disk is the encoder's bytes,
    /// hostile strings and all, and a read leaves the file as it was.
    func testTheFileTheAppWritesIsNotCleanedAndAReadDoesNotChangeIt() async throws {
        let hostile = TerminalStringFixture.everyString()
        let writer = StatusFileWriter(fileURL: statusURL, minimumInterval: 0)

        let wrote = await writer.write(hostile, now: now)

        XCTAssertTrue(wrote)
        let onDisk = try Data(contentsOf: statusURL)
        XCTAssertEqual(onDisk, try TerminalStringFixture.fileBytes(hostile))
        XCTAssertEqual(try StatusFile.decoder.decode(StatusSnapshot.self, from: onDisk), hostile,
                       "the file holds the strings as the app had them")
        _ = StatusFile.load(from: statusURL)
        _ = StatusFile.read(from: statusURL)
        XCTAssertEqual(try Data(contentsOf: statusURL), onDisk)
    }

    /// Bytes the cleaning cannot vouch for are no snapshot: the same answer as a file that
    /// is missing or not JSON. Foundation would have decoded both of these.
    func testAFileThatIsNotPlainUTF8JSONIsNoSnapshot() throws {
        let data = try TerminalStringFixture.fileBytes(TerminalStringFixture.cleanSnapshot())

        try (Data([0xEF, 0xBB, 0xBF]) + data).write(to: statusURL)
        XCTAssertNil(StatusFile.load(from: statusURL), "a byte-order mark would be printed by status --json")
        XCTAssertNil(StatusFile.read(from: statusURL))

        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        try XCTUnwrap(text.data(using: .utf16)).write(to: statusURL)
        XCTAssertNil(StatusFile.load(from: statusURL), "UTF-16")
        XCTAssertNil(StatusFile.read(from: statusURL))
    }

    // MARK: - Size

    /// A megabyte of hostile activity and a provider whose name is one character of
    /// 100 000 combining marks: read and printed by every command without a trap, in time
    /// that is the file's size and not its square. No length is cut here.
    func testVeryLargeStringsAreReadAndPrintedInLinearTime() throws {
        let megabyte = String(repeating: "word \u{1B}[0m\u{9B}\n", count: 100_000)
        let giant = "e" + String(repeating: "\u{301}", count: 100_000)
        try publish(StatusSnapshot(
            version: StatusSnapshot.currentVersion, updatedAt: now,
            services: [StatusSnapshot.Service(
                id: "claude", name: "\u{202E}" + giant, state: "ok", retained: false, retainedAt: nil, plan: giant,
                windows: [StatusSnapshot.Window(id: "five_hour", label: giant, percent: 42, kind: "session")]
            )],
            agents: StatusSnapshot.Agents(
                needsYou: 1, working: 0,
                sessions: [StatusSnapshot.Session(id: "a", project: giant, state: "needsYou", activity: megabyte)]
            )
        ))
        XCTAssertGreaterThan(try Data(contentsOf: statusURL).count, 1_500_000)

        let started = Date()
        let loaded = try XCTUnwrap(StatusFile.load(from: statusURL))
        let outputs = TerminalStringFixture.outputs(of: statusURL)
        XCTAssertLessThan(Date().timeIntervalSince(started), 30, "a megabyte is a fraction of a second per read")

        XCTAssertTrue(loaded.agents.sessions[0].activity == Array(repeating: "word [0m", count: 100_000).joined(separator: " "),
                      "each line break left one space and the last one none")
        XCTAssertEqual(loaded.services[0].name.unicodeScalars.count, 100_001)
        XCTAssertEqual(loaded.services[0].name.count, 1, "one character still")
        XCTAssertEqual(outputs.count, 2 + 2 + 5 + 1)
        for output in outputs {
            TerminalStringFixture.assertNothingRemovedIsPrinted(output)
        }
    }
}
