import XCTest
@testable import Omelette

/// The chat shares on the wire: spec `docs/superpowers/specs/2026-10-16-limit-analytics.md`
/// § Published data ("`status.json` `sessions[]` entries gain optional `weekShare` and
/// `sessionShare` … older readers ignore them … CLI text unchanged") and § Accounts
/// without percent windows (`budgetShare`; "with no budget nothing is added").
final class StatusSharesWireTests: XCTestCase {
    private var directory: URL!
    /// 2026-09-06 11:20:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_693_600)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatusSharesWireTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func entry(
        id: String, sessionShare: Double? = nil, weekShare: Double? = nil, budgetShare: Double? = nil
    ) -> StatusSnapshot.SessionEntry {
        StatusSnapshot.SessionEntry(
            id: id, title: "Blume integration", project: "Usage tracker",
            lastAt: now.addingTimeInterval(-3 * 3600), turns: 356,
            tokens: 41_200_000, cost: 58.10, agents: 3, origin: nil,
            sessionShare: sessionShare, weekShare: weekShare, budgetShare: budgetShare
        )
    }

    private func snapshot(sessions: [StatusSnapshot.SessionEntry]) -> StatusSnapshot {
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
                            resetsAt: now.addingTimeInterval(100 * 60), kind: "session"
                        ),
                    ],
                    todayCost: 4.2, weekCost: 31.7, todayTokens: 1_234_567, apiEquivalent: true,
                    sessions: sessions
                ),
            ],
            agents: .none
        )
    }

    /// A file as `omelette` 3.0.2 wrote it: the chat has every key it had then and none
    /// of the shares.
    private let fileFrom302 = """
    {
      "agents" : { "needsYou" : 0, "sessions" : [], "working" : 0 },
      "services" : [
        {
          "apiEquivalent" : true,
          "id" : "claude",
          "name" : "Claude",
          "plan" : "Max 5x",
          "retained" : false,
          "sessions" : [
            {
              "agents" : 3,
              "cost" : 58.1,
              "id" : "s1",
              "lastAt" : "2026-09-06T08:20:00Z",
              "project" : "Usage tracker",
              "title" : "Blume integration",
              "tokens" : 41200000,
              "turns" : 356
            }
          ],
          "state" : "ok",
          "todayCost" : 4.2,
          "todayTokens" : 1234567,
          "weekCost" : 31.7,
          "windows" : [
            { "id" : "five_hour", "kind" : "session", "label" : "Session", "percent" : 42, "resetsAt" : "2026-09-06T13:00:00Z" }
          ]
        }
      ],
      "showsRemaining" : false,
      "updatedAt" : "2026-09-06T11:20:00Z",
      "version" : 2
    }
    """

    /// The chat entry as `omelette` 3.0.2 decodes it: every key it knows, none of the
    /// shares.
    private struct EntryAsOf302: Decodable, Equatable {
        let id: String
        let title: String
        let project: String
        let lastAt: Date
        let turns: Int
        let tokens: Int
        let cost: Double?
        let agents: Int
        let origin: String?
    }

    /// The part of the file a 3.0.2 reader needs to reach a chat.
    private struct FileAsOf302: Decodable {
        struct Service: Decodable {
            let id: String
            let sessions: [EntryAsOf302]?
        }
        let version: Int
        let services: [Service]
    }

    func testAFileWrittenBeforeTheSharesOpensWithNoShares() throws {
        let url = directory.appendingPathComponent("status.json")
        try Data(fileFrom302.utf8).write(to: url)

        let loaded = try XCTUnwrap(StatusFile.load(from: url))
        let chat = try XCTUnwrap(loaded.services.first?.sessions?.first)
        XCTAssertEqual(chat.id, "s1")
        XCTAssertEqual(chat.turns, 356)
        XCTAssertEqual(chat.cost, 58.1)
        XCTAssertNil(chat.sessionShare)
        XCTAssertNil(chat.weekShare)
        XCTAssertNil(chat.budgetShare)
    }

    func testSharesRoundTripThroughTheFile() throws {
        let url = directory.appendingPathComponent("status.json")
        let written = snapshot(sessions: [
            entry(id: "s1", sessionShare: 3.3, weekShare: 12.5),
            entry(id: "s2", budgetShare: 2.5),
        ])
        try StatusFile.encoder.encode(written).write(to: url)

        XCTAssertEqual(StatusFile.load(from: url), written)
    }

    func testAShareThatDoesNotApplyIsAnAbsentKeyNotNull() throws {
        let text = String(
            decoding: try StatusFile.encoder.encode(snapshot(sessions: [entry(id: "s1", weekShare: 12.5)])),
            as: UTF8.self
        )

        XCTAssertTrue(text.contains("\"weekShare\" : 12.5"), text)
        XCTAssertFalse(text.contains("sessionShare"), text)
        XCTAssertFalse(text.contains("budgetShare"), text)
        XCTAssertFalse(text.contains("null"), text)
    }

    func testA302ReaderStillOpensAFileWithShares() throws {
        let data = try StatusFile.encoder.encode(snapshot(sessions: [
            entry(id: "s1", sessionShare: 3.3, weekShare: 12.5),
        ]))

        let old = try StatusFile.decoder.decode(FileAsOf302.self, from: data)
        // 3.0.2's `StatusFile.load` opens version 2 and refuses every other.
        XCTAssertEqual(old.version, 2)
        XCTAssertEqual(old.services.first?.sessions, [
            EntryAsOf302(
                id: "s1", title: "Blume integration", project: "Usage tracker",
                lastAt: now.addingTimeInterval(-3 * 3600), turns: 356, tokens: 41_200_000,
                cost: 58.10, agents: 3, origin: nil
            ),
        ])
    }

    func testOmeletteStatusPrintsTheSameWithShares() {
        let plain = snapshot(sessions: [entry(id: "s1")])
        let shared = snapshot(sessions: [entry(id: "s1", sessionShare: 3.3, weekShare: 12.5, budgetShare: 2.5)])

        XCTAssertEqual(
            StatusText.render(snapshot: shared, now: now, calendar: SessionFixture.calendar, locale: SessionFixture.locale),
            StatusText.render(snapshot: plain, now: now, calendar: SessionFixture.calendar, locale: SessionFixture.locale)
        )
    }
}
