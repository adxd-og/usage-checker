import XCTest
@testable import Omelette

/// Which chat entry of `status.json` carries which limit shares, through the real
/// `build`: spec `docs/superpowers/specs/2026-10-16-limit-analytics.md` § Published data
/// ("percent points of the current windows"). The shares may be a poll old by the time
/// they are written, and `build` is the last gate. A share is written only next to the
/// window it was cut for:
/// - never after that window resets;
/// - never next to a window the snapshot reports with another reset;
/// - never under a key the account's current mode does not publish.
final class StatusFileSharesTests: XCTestCase {
    /// 2026-09-06 12:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_696_000)
    private let day: TimeInterval = 86_400
    private let hour: TimeInterval = 3_600

    private var sessionWindow: PublishedShareWindow {
        PublishedShareWindow(field: .session, resetsAt: now.addingTimeInterval(hour))
    }

    private var weekWindow: PublishedShareWindow {
        PublishedShareWindow(field: .week, resetsAt: now.addingTimeInterval(2 * day))
    }

    /// Claude on a subscription. The session resets `sessionReset` seconds from now (an
    /// hour unless a test moves it), and the week resets in two days.
    private func claudeMax(sessionReset: TimeInterval = 3_600) -> ServiceSnapshot {
        Fixture.snapshot(id: "claude", buckets: [
            Fixture.bucket(id: "five_hour", label: "Current session", percent: 9,
                           resetsAt: now.addingTimeInterval(sessionReset), kind: .session),
            Fixture.bucket(id: "seven_day", label: "All models", percent: 40,
                           resetsAt: now.addingTimeInterval(2 * day), kind: .weekly),
        ], at: now)
    }

    /// The shares a gather cut for that session and week: s1 has both, s2 none.
    private var subscriptionShares: PublishedShares {
        PublishedShares(
            windows: [sessionWindow, weekWindow],
            chats: ["s1": ChatShareFields(sessionShare: 3.3, weekShare: 12.5)]
        )
    }

    private var chats: [SessionSummary] {
        [
            SessionFixture.simple(id: "s1", hoursAgo: 1, cost: 10),
            SessionFixture.simple(id: "s2", hoursAgo: 2, cost: 5),
        ]
    }

    /// The entries the file lists per provider.
    private func entries(
        services: [ServiceSnapshot],
        sessions: [String: [SessionSummary]],
        shares: [String: PublishedShares],
        weeklyBudgetUSD: Double = 0
    ) -> [String: [StatusSnapshot.SessionEntry]] {
        let file = StatusFileWriter.build(
            services: services,
            costs: [:],
            sessions: sessions,
            shares: shares,
            weeklyBudgetUSD: weeklyBudgetUSD,
            agents: .none,
            now: now,
            calendar: SessionFixture.calendar,
            locale: SessionFixture.locale
        )
        var out: [String: [StatusSnapshot.SessionEntry]] = [:]
        for service in file.services { out[service.id] = service.sessions ?? [] }
        return out
    }

    func testAChatEntryCarriesItsSharesAndAChatWithoutOneCarriesNone() throws {
        let claude = try XCTUnwrap(entries(
            services: [claudeMax()], sessions: ["claude": chats], shares: ["claude": subscriptionShares]
        )["claude"])
        let s1 = try XCTUnwrap(claude.first { $0.id == "s1" })
        let s2 = try XCTUnwrap(claude.first { $0.id == "s2" })

        XCTAssertEqual(s1.sessionShare, 3.3)
        XCTAssertEqual(s1.weekShare, 12.5)
        XCTAssertNil(s1.budgetShare)
        XCTAssertNil(s2.sessionShare)
        XCTAssertNil(s2.weekShare)
        XCTAssertNil(s2.budgetShare)
    }

    func testOneProvidersSharesNeverReachAnotherProvidersChat() throws {
        // Codex's week resets at the same instant as Claude's: the shares are still
        // Claude's alone.
        let codex = Fixture.snapshot(id: "codex", buckets: [
            Fixture.bucket(id: "codex_weekly", label: "Weekly", percent: 10,
                           resetsAt: now.addingTimeInterval(2 * day), kind: .weekly),
        ], at: now)

        let codexChats = try XCTUnwrap(entries(
            services: [claudeMax(), codex],
            sessions: ["codex": [SessionFixture.simple(id: "s1", hoursAgo: 1, cost: 10, providerID: "codex")]],
            shares: ["claude": subscriptionShares]
        )["codex"])

        XCTAssertEqual(codexChats.map(\.id), ["s1"])
        XCTAssertNil(codexChats.first?.weekShare)
    }

    func testAShareForAChatOffTheListAddsNoEntry() throws {
        let claude = try XCTUnwrap(entries(
            services: [claudeMax()],
            sessions: ["claude": [SessionFixture.simple(id: "s1", hoursAgo: 1, cost: 10)]],
            shares: ["claude": PublishedShares(windows: [weekWindow], chats: ["ghost": ChatShareFields(weekShare: 40)])]
        )["claude"])

        XCTAssertEqual(claude.map(\.id), ["s1"])
        XCTAssertNil(claude.first?.weekShare)
    }

    /// A reset passed. The shares were cut while the session ran to ten minutes ago.
    /// The write comes after that reset, before a poll has brought the next session.
    func testASessionShareCutBeforeAResetIsNotWrittenAfterIt() throws {
        let cutBefore = PublishedShares(
            windows: [PublishedShareWindow(field: .session, resetsAt: now.addingTimeInterval(-600)), weekWindow],
            chats: ["s1": ChatShareFields(sessionShare: 3.3, weekShare: 12.5)]
        )

        let claude = try XCTUnwrap(entries(
            services: [claudeMax(sessionReset: -600)], sessions: ["claude": chats], shares: ["claude": cutBefore]
        )["claude"])
        let s1 = try XCTUnwrap(claude.first { $0.id == "s1" })

        XCTAssertNil(s1.sessionShare)
        XCTAssertEqual(s1.weekShare, 12.5, "the week has not reset")
    }

    /// Another window. The shares were cut for the session that resets in an hour.
    /// The snapshot being written reports a session that resets in two. That reset is
    /// still ahead, so only the window match can drop the share.
    func testAShareOfAWindowTheSnapshotNoLongerReportsIsDropped() throws {
        let claude = try XCTUnwrap(entries(
            services: [claudeMax(sessionReset: 2 * 3_600)], sessions: ["claude": chats],
            shares: ["claude": subscriptionShares]
        )["claude"])
        let s1 = try XCTUnwrap(claude.first { $0.id == "s1" })

        XCTAssertNil(s1.sessionShare)
        XCTAssertEqual(s1.weekShare, 12.5, "the week is the same window")
    }

    /// A mode change: the account is now pay as you go, and no budget share was cut.
    func testSubscriptionSharesWrittenAgainstAPayAsYouGoAccountDropTheSessionAndWeekKeys() throws {
        let api = Fixture.snapshot(id: "claude", plan: nil, buckets: [], weekCost: 400, at: now)

        let claude = try XCTUnwrap(entries(
            services: [api], sessions: ["claude": chats], shares: ["claude": subscriptionShares],
            weeklyBudgetUSD: 500
        )["claude"])
        let s1 = try XCTUnwrap(claude.first { $0.id == "s1" })

        XCTAssertNil(s1.sessionShare)
        XCTAssertNil(s1.weekShare)
        XCTAssertNil(s1.budgetShare, "no budget share was cut")
    }

    func testABudgetShareIsWrittenWhileTheBudgetIsSetAndDroppedOnceItIsCleared() throws {
        let api = Fixture.snapshot(id: "claude", plan: nil, buckets: [], weekCost: 400, at: now)
        let budgetShares = PublishedShares(
            windows: [PublishedShareWindow(field: .budget, resetsAt: nil)],
            chats: ["s1": ChatShareFields(budgetShare: 5)]
        )

        let withBudget = try XCTUnwrap(entries(
            services: [api], sessions: ["claude": chats], shares: ["claude": budgetShares], weeklyBudgetUSD: 500
        )["claude"])
        let cleared = try XCTUnwrap(entries(
            services: [api], sessions: ["claude": chats], shares: ["claude": budgetShares], weeklyBudgetUSD: 0
        )["claude"])

        XCTAssertEqual(withBudget.first { $0.id == "s1" }?.budgetShare, 5)
        XCTAssertNil(cleared.first { $0.id == "s1" }?.budgetShare)
    }

    /// The window a share was cut for never reaches the file: the entry carries the
    /// three share keys and the keys it always had, and the file stays version 2.
    func testTheFileCarriesTheSharesUnderTheirThreeKeysAndNothingOfTheirWindows() throws {
        let file = StatusFileWriter.build(
            services: [claudeMax()], costs: [:], sessions: ["claude": chats],
            shares: ["claude": subscriptionShares],
            agents: .none, now: now, calendar: SessionFixture.calendar, locale: SessionFixture.locale
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: StatusFile.encoder.encode(file)) as? [String: Any]
        )
        let services = try XCTUnwrap(object["services"] as? [[String: Any]])
        let sessions = try XCTUnwrap(services.first?["sessions"] as? [[String: Any]])
        let s1 = try XCTUnwrap(sessions.first { $0["id"] as? String == "s1" })

        XCTAssertEqual(object["version"] as? Int, 2)
        XCTAssertEqual(
            Set(s1.keys),
            ["id", "title", "project", "lastAt", "turns", "tokens", "cost", "agents", "sessionShare", "weekShare"]
        )
    }
}
