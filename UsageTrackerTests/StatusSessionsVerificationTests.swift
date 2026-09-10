import XCTest
@testable import Omelette

/// Independent verification of `status.json` v2 (`StatusSnapshot`, `StatusFileWriter`,
/// `StatusText`) against
/// docs/superpowers/specs/2026-09-10-sessions-history-design.md § 5 and § 6: "each
/// service with a cost log gains `sessions: [SessionEntry]`", "`omelette status` gains
/// no new text (kept short)". Written from the spec and the diff, not from
/// `SessionStatusFileTests` or `StatusSnapshotTests` — this file rejects a *hand-written*
/// v1-shaped file (no `sessions` key present at all, as an actual pre-2.5 binary would
/// have written it, rather than a v2 value with its version field overwritten), and
/// checks `StatusText.render` byte-for-byte across two full multi-provider snapshots
/// that differ only in whether `sessions` is populated.
final class StatusSessionsVerificationTests: XCTestCase {
    private var directory: URL!
    /// Sunday 2026-09-06 11:20:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_788_693_600)
    private var calendar: Calendar { SessionFixture.calendar }
    private let locale = SessionFixture.locale

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatusSessionsVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - A real old file, not a re-versioned new one

    /// The spec's version bump exists because "an `omelette` from 2.4.1 has no idea
    /// what a chat is". This writes the literal bytes such a binary would have on disk
    /// — a `Service` object with no `sessions` key in it at all — rather than building a
    /// v2 value and overwriting `version`, so the rejection is proven to be the version
    /// gate and not an accident of which fields happen to be present.
    func testALiteralPre25FileWithNoSessionsKeyAnywhereIsRejectedOnVersionAlone() throws {
        let url = directory.appendingPathComponent("status.json")
        let text = """
        {"version":1,"updatedAt":"2026-09-06T11:20:00Z","services":[{"id":"claude","name":"Claude","state":"ok","retained":false,"windows":[]}],"agents":{"needsYou":0,"working":0,"sessions":[]}}
        """
        try Data(text.utf8).write(to: url)

        XCTAssertNil(StatusFile.load(from: url), "a pre-2.5 file must be refused, not read with an empty chat list")
    }

    // MARK: - Plain text never changes shape because of chats

    private func service(id: String, sessions: [StatusSnapshot.SessionEntry]?) -> StatusSnapshot.Service {
        StatusSnapshot.Service(
            id: id, name: id == "claude" ? "Claude" : "Codex", state: "ok", retained: false, retainedAt: nil,
            plan: id == "claude" ? "Max 5x" : nil,
            windows: [StatusSnapshot.Window(id: "session", label: "Session", percent: 42, resetsAt: now.addingTimeInterval(5_400), kind: "session")],
            todayCost: 4.2, weekCost: 31.7, todayTokens: 1_234_567, apiEquivalent: true,
            sessions: sessions
        )
    }

    private func snapshot(includeSessions: Bool) -> StatusSnapshot {
        let claudeSessions: [StatusSnapshot.SessionEntry]? = includeSessions ? [
            StatusSnapshot.SessionEntry(
                id: "s1", title: "Blume integration", project: "Usage tracker",
                lastAt: now.addingTimeInterval(-3 * 3600), turns: 356, tokens: 41_200_000,
                cost: 58.10, agents: 3, origin: nil
            ),
            StatusSnapshot.SessionEntry(
                id: "s2", title: "Quick fix", project: "Usage tracker",
                lastAt: now.addingTimeInterval(-9 * 3600), turns: 10, tokens: 500,
                cost: nil, agents: 0, origin: nil
            ),
        ] : nil
        let codexSessions: [StatusSnapshot.SessionEntry]? = includeSessions ? [
            StatusSnapshot.SessionEntry(
                id: "t1", title: "Installer review", project: "installer",
                lastAt: now.addingTimeInterval(-1 * 3600), turns: 40, tokens: 900_000,
                cost: 12.5, agents: 1, origin: "codex_exec"
            ),
        ] : nil
        return StatusSnapshot(
            version: StatusSnapshot.currentVersion, updatedAt: now,
            services: [service(id: "claude", sessions: claudeSessions), service(id: "codex", sessions: codexSessions)],
            agents: .none
        )
    }

    func testPlainTextIsByteForByteIdenticalAcrossTwoFullSnapshotsThatDifferOnlyInChats() {
        let withChats = StatusText.render(snapshot: snapshot(includeSessions: true), now: now)
        let withoutChats = StatusText.render(snapshot: snapshot(includeSessions: false), now: now)

        XCTAssertEqual(withChats, withoutChats)
        XCTAssertFalse(withChats.contains("Blume"), withChats)
        XCTAssertFalse(withChats.lowercased().contains("exec"), withChats)
    }

    // MARK: - sessionEntries at a scale bigger than the cap

    func testSessionEntriesKeepsExactlyFifteenOutOfTwentyCandidates() throws {
        let recent = (1...10).map {
            SessionFixture.simple(id: "recent\($0)", hoursAgo: Double($0), cost: 1)
        }
        let old = (1...10).map {
            SessionFixture.simple(id: "old\($0)", hoursAgo: 500 + Double($0), cost: 200 - Double($0))
        }

        let entries = StatusFileWriter.sessionEntries(recent + old, calendar: calendar, locale: locale)

        XCTAssertEqual(entries.count, 15)
        // The five cheapest of the ten old chats must have lost the cut.
        for id in ["old6", "old7", "old8", "old9", "old10"] {
            XCTAssertFalse(entries.contains { $0.id == id }, "\(id) should not have made the top five by cost")
        }
        let top = try XCTUnwrap(entries.first { $0.id == "old1" })
        XCTAssertEqual(top.cost, 199, "old1 is the single most expensive candidate")
    }
}
