import XCTest
@testable import Omelette

/// Verification of the freshness state machine (spec 2026-11-02 Claude limits from the
/// status line, § Design › App, steps 1–5), driven through whole sequences of loads the
/// way the store drives them: `table(_:readings:now:)`. Fixed epoch, no disk.
final class StatusLineFreshnessVerificationTests: XCTestCase {
    /// 2026-09-06 11:20:00 UTC.
    private let base = Date(timeIntervalSince1970: 1_788_693_600)
    private func at(_ seconds: TimeInterval) -> Date { base.addingTimeInterval(seconds) }
    private let sid = StatusLineFixture.sessionID

    private func load(
        _ known: [String: StatusLineFreshnessRules.Session],
        _ readings: [StatusLineDrop.Reading],
        now: Date
    ) -> [String: StatusLineFreshnessRules.Session] {
        StatusLineFreshnessRules.table(known, readings: readings, now: now)
    }

    /// Step 1, 2, 3 and the restart, as one run of a session: first sight, growth, the
    /// timer re-run, a counter that goes down, and growth after the restart.
    func testASessionsWholeRunOfCounters() {
        var t = load([:], [StatusLineFixture.reading(totalAPIDurationMs: 1000, writtenAt: at(0))], now: at(1))
        XCTAssertNil(t[sid]?.asOf, "first sight")

        t = load(t, [StatusLineFixture.reading(totalAPIDurationMs: 2000, writtenAt: at(60))], now: at(61))
        XCTAssertEqual(t[sid]?.asOf, at(60), "grew: dated by that file")

        t = load(t, [StatusLineFixture.reading(totalAPIDurationMs: 2000, writtenAt: at(120))], now: at(121))
        XCTAssertEqual(t[sid]?.asOf, at(60), "timer re-run keeps the age")

        t = load(t, [StatusLineFixture.reading(totalAPIDurationMs: 500, writtenAt: at(180))], now: at(181))
        XCTAssertNil(t[sid]?.asOf, "a counter that went down restarts the session")

        t = load(t, [StatusLineFixture.reading(totalAPIDurationMs: 500, writtenAt: at(240))], now: at(241))
        XCTAssertNil(t[sid]?.asOf, "same counter after the restart is still undated")

        t = load(t, [StatusLineFixture.reading(totalAPIDurationMs: 900, writtenAt: at(300))], now: at(301))
        XCTAssertEqual(t[sid]?.asOf, at(300), "growth after the restart dates again")
    }

    /// The prompt id never dates a reading, in either direction: a new prompt over the
    /// same counter keeps the old age; a new prompt over a grown counter is dated by the
    /// counter.
    func testThePromptIDNeverDatesAReading() {
        var t = load([:], [StatusLineFixture.reading(promptID: "p1", totalAPIDurationMs: 1000, writtenAt: at(0))], now: at(1))
        t = load(t, [StatusLineFixture.reading(promptID: "p1", totalAPIDurationMs: 2000, writtenAt: at(60))], now: at(61))
        t = load(t, [StatusLineFixture.reading(promptID: "p2", totalAPIDurationMs: 2000, writtenAt: at(120))], now: at(121))
        XCTAssertEqual(t[sid]?.asOf, at(60), "new prompt, same counter: still the earlier answer's age")
        XCTAssertEqual(t[sid]?.promptID, "p2", "carried")

        t = load(t, [StatusLineFixture.reading(promptID: nil, totalAPIDurationMs: 2000, writtenAt: at(180))], now: at(181))
        XCTAssertEqual(t[sid]?.asOf, at(60), "a missing prompt id changes nothing either")

        t = load(t, [StatusLineFixture.reading(promptID: "p2", totalAPIDurationMs: 3000, writtenAt: at(240))], now: at(241))
        XCTAssertEqual(t[sid]?.asOf, at(240))
    }

    /// A reading without the counter is never dated, and it makes the session forget
    /// the counter: when it comes back, that is first sight again.
    func testAMissingCounterNeverDatesAndTheCounterReturnsAsFirstSight() {
        var t = load([:], [StatusLineFixture.reading(totalAPIDurationMs: 1000, writtenAt: at(0))], now: at(1))
        t = load(t, [StatusLineFixture.reading(totalAPIDurationMs: 2000, writtenAt: at(60))], now: at(61))
        XCTAssertEqual(t[sid]?.asOf, at(60))

        t = load(t, [StatusLineFixture.reading(totalAPIDurationMs: nil, writtenAt: at(120))], now: at(121))
        XCTAssertNil(t[sid]?.asOf, "no counter, no age")
        XCTAssertNil(StatusLineMergeRules.winner(Array(t.values), defaultConfigDir: StatusLineFixture.configDir, now: at(121)))

        t = load(t, [StatusLineFixture.reading(totalAPIDurationMs: 3000, writtenAt: at(180))], now: at(181))
        XCTAssertNil(t[sid]?.asOf, "the counter is back: first sight of it, nothing to compare")
    }

    /// A first-ever reading with no counter at all.
    func testAFirstReadingWithoutACounterIsUndated() {
        let t = load([:], [StatusLineFixture.reading(totalAPIDurationMs: nil, writtenAt: at(0))], now: at(1))
        XCTAssertNil(t[sid]?.asOf)
        XCTAssertNil(t[sid]?.totalAPIDurationMs)
    }

    /// Step 5's edge: the newest file's `written_at` exactly ten minutes back is still a
    /// session; a second more is gone. Another session is untouched either way.
    func testEvictionIsByTheNewestFilesWrittenAtAndLeavesOthersAlone() {
        let old = StatusLineFixture.reading(sessionID: "old", totalAPIDurationMs: 1, writtenAt: at(0))
        let young = StatusLineFixture.reading(sessionID: "young", totalAPIDurationMs: 1, writtenAt: at(500))
        XCTAssertEqual(Set(load([:], [old, young], now: at(600)).keys), ["old", "young"], "exactly ten minutes: kept")
        XCTAssertEqual(Set(load([:], [old, young], now: at(601)).keys), ["young"])
    }

    /// An evicted session that comes back is a new session: its counter is not
    /// remembered, so a bigger one is first sight, not growth.
    func testAnEvictedSessionComesBackAsFirstSight() {
        var t = load([:], [StatusLineFixture.reading(totalAPIDurationMs: 1000, writtenAt: at(0))], now: at(1))
        t = load(t, [StatusLineFixture.reading(totalAPIDurationMs: 2000, writtenAt: at(60))], now: at(61))
        XCTAssertEqual(t[sid]?.asOf, at(60))

        t = load(t, [StatusLineFixture.reading(totalAPIDurationMs: 2000, writtenAt: at(60))], now: at(700))
        XCTAssertNil(t[sid], "no new file for ten minutes: gone")

        t = load(t, [StatusLineFixture.reading(totalAPIDurationMs: 9000, writtenAt: at(720))], now: at(721))
        XCTAssertNil(t[sid]?.asOf)
    }

    /// A session whose file is gone from the folder leaves the table.
    func testASessionWithoutAFileIsDropped() {
        var t = load([:], [StatusLineFixture.reading(totalAPIDurationMs: 1000, writtenAt: at(0))], now: at(1))
        t = load(t, [], now: at(2))
        XCTAssertTrue(t.isEmpty)
    }

    /// The window past its reset: `resetsAt == now` is already over.
    func testAWindowIsLiveOnlyBeforeItsReset() {
        let w = StatusLineInput.RateLimits.Window(usedPercent: 10, resetsAt: at(100))
        XCTAssertEqual(StatusLineFreshnessRules.liveWindow(w, now: at(99.9)), w)
        XCTAssertNil(StatusLineFreshnessRules.liveWindow(w, now: at(100)))
        XCTAssertNil(StatusLineFreshnessRules.liveWindow(w, now: at(101)))
        XCTAssertNil(StatusLineFreshnessRules.liveWindow(nil, now: at(0)))
    }

    /// Two sessions advance independently inside one load, and the windows a session
    /// carries are its newest file's.
    func testSessionsAdvanceIndependentlyAndCarryTheNewestWindows() {
        let a1 = StatusLineFixture.reading(sessionID: "a", totalAPIDurationMs: 1, writtenAt: at(0))
        let b1 = StatusLineFixture.reading(sessionID: "b", totalAPIDurationMs: 1, writtenAt: at(0))
        var t = load([:], [a1, b1], now: at(1))
        let newer = StatusLineInput.RateLimits.Window(usedPercent: 77, resetsAt: StatusLineFixture.fiveHourResetsAt)
        let a2 = StatusLineFixture.reading(sessionID: "a", totalAPIDurationMs: 5, fiveHour: newer, writtenAt: at(60))
        let b2 = StatusLineFixture.reading(sessionID: "b", totalAPIDurationMs: 1, writtenAt: at(60))
        t = load(t, [a2, b2], now: at(61))
        XCTAssertEqual(t["a"]?.asOf, at(60))
        XCTAssertEqual(t["a"]?.fiveHour, newer)
        XCTAssertNil(t["b"]?.asOf, "b's counter did not move")
    }
}
