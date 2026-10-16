import XCTest
@testable import Omelette

/// The chat shares as an older reader meets them: spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § Published data ("older readers
/// ignore them", "CLI text unchanged"). The shares are additive: take the three keys out
/// of a file that carries them and what is left is the file 3.0.2 would have written.
final class StatusSharesWireVerificationTests: XCTestCase {
    private var directory: URL!
    /// 2026-09-06 12:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_696_000)
    private let day: TimeInterval = 86_400
    private let hour: TimeInterval = 3_600

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatusSharesWireVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let shareKeys: Set<String> = ["sessionShare", "weekShare", "budgetShare"]

    private func claudeMax() -> ServiceSnapshot {
        Fixture.snapshot(id: "claude", buckets: [
            Fixture.bucket(id: "five_hour", label: "Current session", percent: 9,
                           resetsAt: now.addingTimeInterval(hour), kind: .session),
            Fixture.bucket(id: "seven_day", label: "All models", percent: 40,
                           resetsAt: now.addingTimeInterval(2 * day), kind: .weekly),
        ], at: now)
    }

    private func file(withShares: Bool) -> StatusSnapshot {
        let shares = PublishedShares(
            windows: [
                PublishedShareWindow(field: .session, resetsAt: now.addingTimeInterval(hour)),
                PublishedShareWindow(field: .week, resetsAt: now.addingTimeInterval(2 * day)),
            ],
            chats: [
                "s1": ChatShareFields(sessionShare: 3.3, weekShare: 12.5),
                "s2": ChatShareFields(sessionShare: 0, weekShare: 0.1),
            ]
        )
        return StatusFileWriter.build(
            services: [claudeMax()],
            costs: ["claude": StatusFileWriter.CostEntry(todayCost: 4.2, weekCost: 31.7, todayTokens: 1_234_567)],
            sessions: ["claude": [
                SessionFixture.simple(id: "s1", hoursAgo: 1, cost: 10),
                SessionFixture.simple(id: "s2", hoursAgo: 2, cost: 5),
                SessionFixture.simple(id: "s3", hoursAgo: 3, cost: 1),
            ]],
            shares: withShares ? ["claude": shares] : [:],
            agents: .none,
            now: now,
            calendar: SessionFixture.calendar,
            locale: SessionFixture.locale
        )
    }

    /// The file's JSON with every share key taken out of every chat.
    private func objectWithoutShareKeys(_ snapshot: StatusSnapshot) throws -> NSDictionary {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: StatusFile.encoder.encode(snapshot)) as? [String: Any]
        )
        var services = try XCTUnwrap(object["services"] as? [[String: Any]])
        for index in services.indices {
            let sessions = (services[index]["sessions"] as? [[String: Any]]) ?? []
            services[index]["sessions"] = sessions.map { $0.filter { !shareKeys.contains($0.key) } }
        }
        object["services"] = services
        return object as NSDictionary
    }

    func testTakingTheShareKeysOutLeavesTheFileThatWouldHaveBeenWrittenWithoutThem() throws {
        let withShares = try objectWithoutShareKeys(file(withShares: true))
        let without = try objectWithoutShareKeys(file(withShares: false))

        XCTAssertEqual(withShares, without)
    }

    func testTheBuiltFileCarriesSharesOnTheChatsThatHaveThemAndOnNoOther() throws {
        let built = file(withShares: true)
        let sessions = try XCTUnwrap(built.services.first?.sessions)

        XCTAssertEqual(built.version, 2)
        XCTAssertEqual(sessions.first { $0.id == "s1" }?.sessionShare, 3.3)
        XCTAssertEqual(sessions.first { $0.id == "s2" }?.sessionShare, 0, "ran in the window, moved nothing")
        XCTAssertEqual(sessions.first { $0.id == "s2" }?.weekShare, 0.1)
        XCTAssertNil(sessions.first { $0.id == "s3" }?.sessionShare)
        XCTAssertNil(sessions.first { $0.id == "s3" }?.weekShare)
    }

    func testAZeroShareIsWrittenAsZeroNotOmitted() throws {
        let data = try StatusFile.encoder.encode(file(withShares: true))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let services = try XCTUnwrap(object["services"] as? [[String: Any]])
        let sessions = try XCTUnwrap(services.first?["sessions"] as? [[String: Any]])
        let s2 = try XCTUnwrap(sessions.first { $0["id"] as? String == "s2" })
        let s3 = try XCTUnwrap(sessions.first { $0["id"] as? String == "s3" })

        XCTAssertEqual(s2["sessionShare"] as? Double, 0)
        XCTAssertNotNil(s2["sessionShare"])
        XCTAssertNil(s3["sessionShare"], "absent key: the chat did not run in that window")
    }

    // MARK: - Real-shaped files, read back

    /// A file as a build with shares writes it, minus nothing: whole-number shares come
    /// out of `JSONEncoder` as `5` or `5.0`, a zero as `0`.
    private let fileWithWholeAndZeroShares = """
    {
      "agents" : { "needsYou" : 0, "sessions" : [], "working" : 0 },
      "services" : [
        {
          "apiEquivalent" : true,
          "id" : "codex",
          "name" : "Codex",
          "plan" : "Prolite",
          "retained" : false,
          "sessions" : [
            {
              "agents" : 0,
              "budgetShare" : 0,
              "cost" : 8.5,
              "id" : "a",
              "lastAt" : "2026-09-06T08:20:00Z",
              "origin" : "codex-tui",
              "project" : "alpha",
              "title" : "A",
              "tokens" : 1200000,
              "turns" : 12,
              "weekShare" : 5
            },
            {
              "agents" : 1,
              "cost" : 1.5,
              "id" : "b",
              "lastAt" : "2026-09-06T07:20:00Z",
              "origin" : "codex_exec",
              "project" : "alpha",
              "title" : "B",
              "tokens" : 300000,
              "turns" : 3,
              "weekShare" : null
            }
          ],
          "state" : "ok",
          "todayCost" : 1.0,
          "todayTokens" : 100,
          "weekCost" : 10.0,
          "windows" : [
            { "id" : "codex_session", "kind" : "weekly", "label" : "Weekly", "percent" : 10, "resetsAt" : "2026-09-08T12:00:00Z" }
          ]
        }
      ],
      "showsRemaining" : false,
      "updatedAt" : "2026-09-06T12:00:00Z",
      "version" : 2
    }
    """

    func testWholeNumberAndZeroSharesDecodeAsDoublesAndANullIsAbsent() throws {
        let url = directory.appendingPathComponent("status.json")
        try Data(fileWithWholeAndZeroShares.utf8).write(to: url)

        let loaded = try XCTUnwrap(StatusFile.load(from: url))
        let sessions = try XCTUnwrap(loaded.services.first?.sessions)

        XCTAssertEqual(sessions.first { $0.id == "a" }?.weekShare, 5)
        XCTAssertEqual(sessions.first { $0.id == "a" }?.budgetShare, 0, "zero is a share, not a missing one")
        XCTAssertNil(sessions.first { $0.id == "b" }?.weekShare)
    }

    func testAnOlderReaderThatKnowsOnlyTheOldKeysReadsTheBuiltFileWholeAndStrictly() throws {
        // A strict 3.0.2-shaped reader: every key it knew is required, and it decodes the
        // services, windows and chats of the very file a build with shares writes.
        struct Window: Decodable { let id: String; let label: String; let percent: Double; let kind: String? }
        struct Chat: Decodable {
            let id: String; let title: String; let project: String; let lastAt: Date
            let turns: Int; let tokens: Int; let agents: Int
        }
        struct Service: Decodable {
            let id: String; let name: String; let state: String; let retained: Bool
            let windows: [Window]; let sessions: [Chat]?
        }
        struct Old: Decodable { let version: Int; let updatedAt: Date; let services: [Service] }

        let data = try StatusFile.encoder.encode(file(withShares: true))
        let old = try StatusFile.decoder.decode(Old.self, from: data)

        XCTAssertEqual(old.version, 2)
        XCTAssertEqual(old.services.first?.sessions?.map(\.id).sorted(), ["s1", "s2", "s3"])
        XCTAssertEqual(old.services.first?.windows.map(\.id), ["five_hour", "seven_day"])
    }

    func testAnOldFileLoadedAndWrittenBackKeepsNoShareKeys() throws {
        let url = directory.appendingPathComponent("status.json")
        let old = file(withShares: false)
        try StatusFile.encoder.encode(old).write(to: url)

        let loaded = try XCTUnwrap(StatusFile.load(from: url))
        let text = String(decoding: try StatusFile.encoder.encode(loaded), as: UTF8.self)

        XCTAssertEqual(loaded, old)
        XCTAssertFalse(text.contains("Share"), text)
    }

    // MARK: - The CLI text

    func testThePlainStatusAndTheStatusLineStayByteForByteTheSame() {
        let withShares = file(withShares: true)
        let without = file(withShares: false)

        XCTAssertEqual(
            StatusText.render(snapshot: withShares, now: now, calendar: SessionFixture.calendar, locale: SessionFixture.locale),
            StatusText.render(snapshot: without, now: now, calendar: SessionFixture.calendar, locale: SessionFixture.locale)
        )
    }

    func testTheMCPSessionsTextIsTheSameWithAndWithoutShares() {
        XCTAssertEqual(
            MCPSummary.sessions(
                snapshot: file(withShares: true), provider: nil, limit: 10, now: now,
                calendar: SessionFixture.calendar, locale: SessionFixture.locale
            ),
            MCPSummary.sessions(
                snapshot: file(withShares: false), provider: nil, limit: 10, now: now,
                calendar: SessionFixture.calendar, locale: SessionFixture.locale
            )
        )
    }

    func testGetSessionsReturnsAZeroShareAndLeavesOutAnAbsentOne() throws {
        let data = MCPServer.sessionsData(file(withShares: true), provider: "claude", limit: 10)
        let services = try XCTUnwrap(data["services"] as? [[String: Any]])
        let sessions = try XCTUnwrap(services.first?["sessions"] as? [[String: Any]])
        let s2 = try XCTUnwrap(sessions.first { $0["id"] as? String == "s2" })
        let s3 = try XCTUnwrap(sessions.first { $0["id"] as? String == "s3" })

        XCTAssertEqual(s2["sessionShare"] as? Double, 0)
        XCTAssertEqual(s2["weekShare"] as? Double, 0.1)
        XCTAssertNil(s3["sessionShare"])
        XCTAssertNil(s3["weekShare"])
        XCTAssertNil(s3["budgetShare"])
    }

    func testGetSessionsCarriesTheSharesOnlyOfTheChatsItKeepsUnderTheLimit() throws {
        let kept = MCPServer.sessionsData(file(withShares: true), provider: nil, limit: 2)
        let services = try XCTUnwrap(kept["services"] as? [[String: Any]])
        let sessions = try XCTUnwrap(services.first?["sessions"] as? [[String: Any]])

        XCTAssertEqual(sessions.compactMap { $0["id"] as? String }.sorted(), ["s1", "s2"])
        XCTAssertEqual(sessions.first { $0["id"] as? String == "s1" }?["sessionShare"] as? Double, 3.3)

        let none = MCPServer.sessionsData(file(withShares: true), provider: "codex", limit: 10)
        XCTAssertEqual((none["services"] as? [[String: Any]])?.count, 0)
    }
}
