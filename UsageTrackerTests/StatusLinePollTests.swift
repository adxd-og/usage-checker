import XCTest
@testable import Omelette

/// What a poll shows once Claude Code's status line is in it (spec 2026-11-02 Claude
/// limits from the status line, § Design › App): retention first, then the status line's
/// two windows. A failing Claude keeps its last-known numbers, dimmed, with the status
/// line's two fresher ones; the next failing poll carries what the status line fed; a
/// healthy OAuth reading newer than the status line's shows as OAuth gave it.
final class StatusLinePollTests: XCTestCase {
    /// 2026-09-06 11:20:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_693_600)
    private var defaultDir: String { StatusLineMergeRules.defaultConfigDir(home: StatusLineFixture.home) }

    private let oauthSession = Fixture.bucket(
        id: "five_hour", label: "Current session", percent: 20,
        resetsAt: StatusLineFixture.fiveHourResetsAt, kind: .session
    )
    private let oauthWeek = Fixture.bucket(
        id: "seven_day", label: "All models", percent: 40,
        resetsAt: StatusLineFixture.sevenDayResetsAt, kind: .weekly
    )
    private let opus = Fixture.bucket(
        id: "seven_day_opus", label: "Opus only", percent: 12,
        resetsAt: StatusLineFixture.sevenDayResetsAt, kind: .modelSpecific
    )

    private func stored() -> [String: LastKnownService] {
        ["claude": LastKnownService(
            from: Fixture.snapshot(
                id: "claude", displayName: "Claude", plan: "Max 20x",
                buckets: [oauthSession, oauthWeek, opus], at: now.addingTimeInterval(-3 * 3600)
            ),
            order: 0
        )]
    }

    private func failingClaude(at date: Date) -> ServiceSnapshot {
        Fixture.snapshot(
            id: "claude", displayName: "Claude", plan: nil, buckets: [],
            state: .error, stateMessage: "Rate limited by usage API", at: date
        )
    }

    private func poll(_ services: [ServiceSnapshot], at date: Date) -> UsageSnapshot {
        UsageSnapshot(services: services, fetchedAt: date, isStale: false, lastError: nil)
    }

    private func fresh() -> [StatusLineFreshnessRules.Session] {
        [StatusLineFreshnessRules.Session(
            sessionID: StatusLineFixture.sessionID,
            promptID: StatusLineFixture.promptID,
            totalAPIDurationMs: 18_250,
            asOf: now.addingTimeInterval(-60),
            writtenAt: now.addingTimeInterval(-60),
            fiveHour: StatusLineFixture.fiveHour,
            sevenDay: StatusLineFixture.sevenDay,
            configDir: StatusLineFixture.configDir
        )]
    }

    func testAFailingClaudeKeepsItsLastKnownNumbersDimmedWithTheStatusLinesTwo() throws {
        let shown = AppState.shownAfterPoll(
            previous: .empty, next: poll([failingClaude(at: now)], at: now), stored: stored(),
            statusLine: fresh(), defaultConfigDir: defaultDir, now: now
        )

        XCTAssertTrue(shown.applied)
        let claude = try XCTUnwrap(shown.snapshot.services.first)
        XCTAssertEqual(claude.state, .error)
        XCTAssertTrue(claude.isRetained, "still dimmed, still its chip")
        XCTAssertEqual(claude.buckets.map(\.id), ["five_hour", "seven_day", "seven_day_opus"])
        XCTAssertEqual(claude.buckets.map(\.utilization), [23.5, 41.2, 12])
        XCTAssertEqual(claude.buckets.map(\.source), [.statusLine, .statusLine, nil])
        XCTAssertEqual(
            claude.buckets.map(\.asOf), [now.addingTimeInterval(-60), now.addingTimeInterval(-60), nil],
            "the fed windows are dated by the reading"
        )
        XCTAssertEqual(claude.fetchedAt, now.addingTimeInterval(-3 * 3600), "retention's date: OAuth's last numbers")
        XCTAssertTrue(shown.snapshot.isStale, "every provider failed")
    }

    func testTheNextFailingPollCarriesWhatTheStatusLineFed() throws {
        let first = AppState.shownAfterPoll(
            previous: .empty, next: poll([failingClaude(at: now)], at: now), stored: stored(),
            statusLine: fresh(), defaultConfigDir: defaultDir, now: now
        )
        let later = now.addingTimeInterval(600)

        let second = AppState.shownAfterPoll(
            previous: first.snapshot, next: poll([failingClaude(at: later)], at: later), stored: stored(),
            statusLine: [], defaultConfigDir: defaultDir, now: later
        )

        XCTAssertFalse(second.applied, "nothing fresh from the status line this time")
        let claude = try XCTUnwrap(second.snapshot.services.first)
        XCTAssertEqual(claude.buckets.map(\.utilization), [23.5, 41.2, 12])
        XCTAssertEqual(claude.buckets.map(\.source), [.statusLine, .statusLine, nil])
    }

    func testAHealthyOAuthReadingNewerThanTheStatusLineShowsAsOAuthGaveIt() {
        let oauth = Fixture.snapshot(
            id: "claude", displayName: "Claude", plan: "Max 20x",
            buckets: [oauthSession, oauthWeek, opus], at: now
        )

        let shown = AppState.shownAfterPoll(
            previous: .empty, next: poll([oauth], at: now), stored: [:],
            statusLine: fresh(), defaultConfigDir: defaultDir, now: now
        )

        XCTAssertFalse(shown.applied)
        XCTAssertEqual(shown.snapshot.services, [oauth])
    }
}
