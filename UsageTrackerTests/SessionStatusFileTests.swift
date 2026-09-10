import XCTest
@testable import Omelette

/// What `status.json` says about chats, and what the version bump means for a build
/// that does not know about them. Everything here is `build`/`sessionEntries`, which are
/// pure, plus one round trip through the file's own encoder and decoder.
/// Spec: docs/superpowers/specs/2026-09-10-sessions-history-design.md § 5, § 6.
final class SessionStatusFileTests: XCTestCase {
    private var directory: URL!
    /// Sunday 2026-09-06 11:20:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_788_693_600)
    private var calendar: Calendar { SessionFixture.calendar }
    private let locale = SessionFixture.locale

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionStatusFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func claude() -> ServiceSnapshot {
        Fixture.snapshot(id: "claude", displayName: "Claude", plan: "Max 5x", state: .ok, at: now)
    }

    private func antigravity() -> ServiceSnapshot {
        Fixture.snapshot(id: "antigravity", displayName: "Antigravity", plan: nil, state: .ok, at: now)
    }

    // MARK: - The version

    func testTheFileIsVersionTwoNow() {
        XCTAssertEqual(StatusSnapshot.currentVersion, 2)
    }

    func testAVersionOneFileIsNoFileAtAll() throws {
        // An `omelette` from 2.4.1 writes version 1; this build must refuse it rather
        // than read a Service that has no chats in it and pretend the list is empty.
        let url = directory.appendingPathComponent("status.json")
        var old = StatusFileWriter.build(services: [claude()], costs: [:], agents: .none, now: now)
        old.version = 1
        try StatusFile.encoder.encode(old).write(to: url)

        XCTAssertNil(StatusFile.load(from: url))
    }

    // MARK: - The entries

    private func session(
        id: String, title: String?, hoursAgo: Double, cost dollars: Double,
        agents: Int = 0, origin: String? = nil, providerID: String = "claude",
        projectSlug: String = "-Users-tester-Projects-alpha"
    ) -> SessionSummary {
        SessionFixture.session(
            id: id, providerID: providerID, title: title, projectSlug: projectSlug, origin: origin,
            firstAt: SessionFixture.at(daysBefore: 3),
            lastAt: SessionFixture.at(hoursBefore: hoursAgo),
            turns: 356,
            tokens: SessionFixture.tokens(input: 41_200_000, cost: SessionFixture.cost(input: dollars)),
            agents: (0..<agents).map { SessionFixture.agent(id: "a\($0)") }
        )
    }

    func testAChatBecomesAnEntryWithEveryFieldTheSpecNames() {
        let snapshot = StatusFileWriter.build(
            services: [claude()],
            costs: ["claude": .init(todayCost: 4.2, weekCost: 31.7, todayTokens: 1_000)],
            sessions: ["claude": [session(id: "s1", title: "Интеграция Blume", hoursAgo: 3, cost: 58.10, agents: 3)]],
            agents: .none,
            now: now, calendar: calendar, locale: locale
        )

        let entry = try? XCTUnwrap(snapshot.services.first?.sessions?.first)
        XCTAssertEqual(entry?.id, "s1")
        XCTAssertEqual(entry?.title, "Интеграция Blume")
        XCTAssertEqual(entry?.project, "Projects / alpha")
        XCTAssertEqual(entry?.lastAt, SessionFixture.at(hoursBefore: 3))
        XCTAssertEqual(entry?.turns, 356)
        XCTAssertEqual(entry?.tokens, 41_200_000)
        XCTAssertEqual(entry?.cost, 58.10)
        XCTAssertEqual(entry?.agents, 3)
        XCTAssertNil(entry?.origin, "Claude reports no originator")
    }

    func testANamelessChatIsNamedBeforeItReachesTheFile() {
        // The CLI cannot see SessionSummary or ProjectName, so the fallback has to be
        // applied here — or the terminal would invent a second spelling of it.
        let snapshot = StatusFileWriter.build(
            services: [claude()], costs: [:],
            sessions: ["claude": [session(id: "s1", title: nil, hoursAgo: 3, cost: 1)]],
            agents: .none, now: now, calendar: calendar, locale: locale
        )

        XCTAssertEqual(snapshot.services.first?.sessions?.first?.title, "Projects / alpha · 3 Sep")
    }

    func testACodexChatKeepsItsOriginAndItsOwnSlugShape() {
        let snapshot = StatusFileWriter.build(
            services: [Fixture.snapshot(id: "codex", displayName: "Codex", plan: nil, state: .ok, at: now)],
            costs: [:],
            sessions: ["codex": [session(
                id: "t1", title: "Installer review", hoursAgo: 2, cost: 3,
                origin: "codex_exec", providerID: "codex",
                projectSlug: "%2FUsers%2Ftester%2FProjects%2Falpha"
            )]],
            agents: .none, now: now, calendar: calendar, locale: locale
        )

        let entry = try? XCTUnwrap(snapshot.services.first?.sessions?.first)
        XCTAssertEqual(entry?.origin, "codex_exec")
        XCTAssertEqual(entry?.project, "Projects / alpha")
    }

    func testTheListIsThePickCappedAtFifteen() {
        var sessions = (1...20).map {
            SessionFixture.simple(id: "recent\($0)", hoursAgo: Double($0), cost: 1)
        }
        sessions += (1...8).map {
            SessionFixture.simple(id: "old\($0)", hoursAgo: 100 + Double($0), cost: 100 - Double($0))
        }

        let entries = StatusFileWriter.sessionEntries(sessions, calendar: calendar, locale: locale)

        XCTAssertEqual(entries.count, StatusFileWriter.maxFileSessions)
        XCTAssertEqual(entries.count, 15)
        XCTAssertEqual(entries.prefix(10).map(\.id), (1...10).map { "recent\($0)" })
        XCTAssertEqual(entries.suffix(5).map(\.id), ["old1", "old2", "old3", "old4", "old5"])
    }

    func testAProviderWithNoChatLogCarriesNoKeyAtAll() {
        // Absent, not an empty array: "no chat log" and "a quiet week" are different
        // answers, the same distinction todayCost already makes.
        let snapshot = StatusFileWriter.build(
            services: [antigravity()], costs: [:], agents: .none, now: now
        )

        XCTAssertNil(snapshot.services.first?.sessions)
        // Only the services: the agents block carries a `sessions` key of its own — the
        // agent list — and that one is always written.
        let text = String(decoding: try! StatusFile.encoder.encode(snapshot.services), as: UTF8.self)
        XCTAssertFalse(text.contains("sessions"), text)
    }

    func testAQuietWeekIsAlsoNoKey() {
        let snapshot = StatusFileWriter.build(
            services: [claude()], costs: [:], sessions: ["claude": []], agents: .none, now: now
        )
        XCTAssertNil(snapshot.services.first?.sessions)
    }

    // MARK: - The round trip

    func testAVersionTwoFileRoundTripsWithItsChats() throws {
        let built = StatusFileWriter.build(
            services: [claude()],
            costs: ["claude": .init(todayCost: 4.2, weekCost: 31.7, todayTokens: 1_000)],
            sessions: ["claude": [session(id: "s1", title: "Интеграция Blume", hoursAgo: 3, cost: 58.10, agents: 3)]],
            agents: .none,
            now: now, calendar: calendar, locale: locale
        )
        let url = directory.appendingPathComponent("status.json")
        try StatusFile.encoder.encode(built).write(to: url)

        let loaded = try XCTUnwrap(StatusFile.load(from: url))

        XCTAssertEqual(loaded, built)
        XCTAssertEqual(loaded.services.first?.sessions?.first?.title, "Интеграция Blume")
    }

    func testAServiceWrittenBeforeChatsExistedStillDecodes() throws {
        // The key is optional precisely so the synthesized decoder tolerates its
        // absence: Swift ignores a property's default value when it synthesizes
        // init(from:), so a non-optional array would make this JSON undecodable.
        let url = directory.appendingPathComponent("status.json")
        let text = """
        {"version":2,"updatedAt":"2026-09-06T11:20:00Z","services":[{"id":"claude","name":"Claude",\
        "state":"ok","retained":false,"windows":[]}],"agents":{"needsYou":0,"working":0,"sessions":[]}}
        """
        try Data(text.utf8).write(to: url)

        let loaded = try XCTUnwrap(StatusFile.load(from: url))
        XCTAssertNil(loaded.services.first?.sessions)
    }

    // MARK: - What the poll gathers

    func testTheGatheredWindowIsSevenDays() {
        XCTAssertEqual(StatusCosts.sessionWindow, 7 * 24 * 3600)
    }
}
