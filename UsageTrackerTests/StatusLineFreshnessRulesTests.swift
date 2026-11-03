import XCTest
@testable import Omelette

/// Which status-line readings carry new numbers (spec 2026-11-02 Claude limits from the
/// status line, § Design › App, the freshness state machine, steps 1–5). Step 2 keys on
/// `total_api_duration_ms` alone (session ruling 2026-11-02): it grows only after an API
/// response, while `prompt_id` may move at submit, before one. Pure: readings are built,
/// never read from disk.
final class StatusLineFreshnessRulesTests: XCTestCase {
    /// 2026-09-06 11:20:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_693_600)
    private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
    private let otherPrompt = "9b8c7d6e-5f40-4a3b-9c2d-1e0f9a8b7c6d"

    /// Step 1.
    func testASessionSeenForTheFirstTimeHasNoAge() {
        let session = StatusLineFreshnessRules.advance(nil, with: StatusLineFixture.reading(writtenAt: ago(30)))

        XCTAssertNil(session.asOf, "after a launch, or for a new session, the numbers' age is unknown")
        XCTAssertEqual(session.sessionID, StatusLineFixture.sessionID)
        XCTAssertEqual(session.promptID, StatusLineFixture.promptID)
        XCTAssertEqual(session.totalAPIDurationMs, 18_250)
        XCTAssertEqual(session.writtenAt, ago(30))
        XCTAssertEqual(session.fiveHour, StatusLineFixture.fiveHour)
        XCTAssertEqual(session.sevenDay, StatusLineFixture.sevenDay)
        XCTAssertEqual(session.configDir, StatusLineFixture.configDir)
    }

    /// Step 2: more API time is a new answer from the API, dated by the file that says so.
    func testMoreAPITimeDatesTheReadingByItsFile() {
        let first = StatusLineFreshnessRules.advance(nil, with: StatusLineFixture.reading(writtenAt: ago(120)))

        let moreAPITime = StatusLineFreshnessRules.advance(
            first, with: StatusLineFixture.reading(totalAPIDurationMs: 21_400, writtenAt: ago(45))
        )

        XCTAssertEqual(moreAPITime.asOf, ago(45))
    }

    /// A new prompt id alone may be a prompt just submitted, with the previous answer's
    /// limits still in the payload: it is carried, never a date.
    func testANewPromptIDAloneDatesNothing() {
        let first = StatusLineFreshnessRules.advance(nil, with: StatusLineFixture.reading(writtenAt: ago(120)))
        let dated = StatusLineFreshnessRules.advance(
            first, with: StatusLineFixture.reading(totalAPIDurationMs: 21_400, writtenAt: ago(90))
        )

        let undatedPrompt = StatusLineFreshnessRules.advance(
            first, with: StatusLineFixture.reading(promptID: otherPrompt, writtenAt: ago(60))
        )
        let datedPrompt = StatusLineFreshnessRules.advance(
            dated, with: StatusLineFixture.reading(promptID: otherPrompt, totalAPIDurationMs: 21_400, writtenAt: ago(60))
        )

        XCTAssertNil(undatedPrompt.asOf)
        XCTAssertEqual(undatedPrompt.promptID, otherPrompt, "carried")
        XCTAssertEqual(datedPrompt.asOf, ago(90), "the date stays the API time's")
    }

    /// Step 3: Claude Code's timer re-runs the line with the data it last received.
    func testARerunWithTheSameAPITimeKeepsItsAge() {
        let first = StatusLineFreshnessRules.advance(nil, with: StatusLineFixture.reading(writtenAt: ago(180)))
        let dated = StatusLineFreshnessRules.advance(
            first, with: StatusLineFixture.reading(totalAPIDurationMs: 21_400, writtenAt: ago(120))
        )

        let rerun = StatusLineFreshnessRules.advance(
            dated, with: StatusLineFixture.reading(totalAPIDurationMs: 21_400, writtenAt: ago(60))
        )

        XCTAssertEqual(rerun.asOf, ago(120), "a re-run is not new data")
        XCTAssertEqual(rerun.writtenAt, ago(60), "but it is a new file, which keeps the session alive")
    }

    /// Less API time than before is a counter that started over — a resumed process — and
    /// says nothing about the numbers' age: first sight again.
    func testLessAPITimeStartsTheSessionOver() {
        let dated = StatusLineFreshnessRules.advance(
            StatusLineFreshnessRules.advance(nil, with: StatusLineFixture.reading(writtenAt: ago(180))),
            with: StatusLineFixture.reading(totalAPIDurationMs: 21_400, writtenAt: ago(120))
        )

        let restarted = StatusLineFreshnessRules.advance(
            dated, with: StatusLineFixture.reading(totalAPIDurationMs: 900, writtenAt: ago(60))
        )
        let grownAgain = StatusLineFreshnessRules.advance(
            restarted, with: StatusLineFixture.reading(totalAPIDurationMs: 2_300, writtenAt: ago(30))
        )

        XCTAssertNil(restarted.asOf)
        XCTAssertEqual(grownAgain.asOf, ago(30))
    }

    /// A reading without API time can never be seen to grow, whatever its prompt id.
    func testAReadingWithoutAPITimeIsNeverDated() {
        let bare = StatusLineFixture.reading(promptID: otherPrompt, totalAPIDurationMs: nil, writtenAt: ago(60))
        let firstBare = StatusLineFreshnessRules.advance(nil, with: bare)
        XCTAssertNil(
            StatusLineFreshnessRules.advance(
                firstBare, with: StatusLineFixture.reading(promptID: StatusLineFixture.promptID, totalAPIDurationMs: nil, writtenAt: ago(30))
            ).asOf
        )

        let dated = StatusLineFreshnessRules.advance(
            StatusLineFreshnessRules.advance(nil, with: StatusLineFixture.reading(writtenAt: ago(180))),
            with: StatusLineFixture.reading(totalAPIDurationMs: 21_400, writtenAt: ago(120))
        )
        XCTAssertEqual(dated.asOf, ago(120))
        XCTAssertNil(StatusLineFreshnessRules.advance(dated, with: bare).asOf, "a session that loses its API time loses its date")
        XCTAssertNil(
            StatusLineFreshnessRules.advance(
                firstBare, with: StatusLineFixture.reading(totalAPIDurationMs: 21_400, writtenAt: ago(30))
            ).asOf,
            "API time seen for the first time is a first sight, not a growth"
        )
    }

    /// Two runs of the line renaming out of order leave the older reading on disk.
    func testAnOlderFileChangesNothing() {
        let first = StatusLineFreshnessRules.advance(nil, with: StatusLineFixture.reading(writtenAt: ago(120)))
        let dated = StatusLineFreshnessRules.advance(
            first, with: StatusLineFixture.reading(totalAPIDurationMs: 21_400, writtenAt: ago(60))
        )

        XCTAssertEqual(StatusLineFreshnessRules.advance(dated, with: StatusLineFixture.reading(writtenAt: ago(90))), dated)
    }

    /// Step 4.
    func testAWindowPastItsResetIsNoWindow() {
        let window = StatusLineInput.RateLimits.Window(usedPercent: 99, resetsAt: now)

        XCTAssertNil(StatusLineFreshnessRules.liveWindow(window, now: now), "a reset at now has happened")
        XCTAssertNil(StatusLineFreshnessRules.liveWindow(window, now: now.addingTimeInterval(1)))
        XCTAssertEqual(StatusLineFreshnessRules.liveWindow(window, now: ago(1)), window)
        XCTAssertNil(StatusLineFreshnessRules.liveWindow(nil, now: now))
    }

    /// Step 5: no SessionEnd path in v1; ten minutes without a new file ends a session.
    func testTenMinutesWithoutANewFileEndsTheSession() {
        let known = [
            StatusLineFixture.sessionID: StatusLineFreshnessRules.advance(nil, with: StatusLineFixture.reading(writtenAt: ago(700))),
        ]

        XCTAssertEqual(
            StatusLineFreshnessRules.table(known, readings: [StatusLineFixture.reading(writtenAt: ago(600))], now: now)
                .keys.sorted(),
            [StatusLineFixture.sessionID],
            "ten minutes is still alive"
        )
        XCTAssertTrue(
            StatusLineFreshnessRules.table(known, readings: [StatusLineFixture.reading(writtenAt: ago(601))], now: now).isEmpty
        )
        XCTAssertTrue(
            StatusLineFreshnessRules.table(known, readings: [], now: now).isEmpty,
            "a session whose file is gone is gone"
        )
    }

    func testEachSessionAdvancesOnItsOwn() throws {
        let a = StatusLineFixture.sessionID
        let b = "7c9e6679-7425-40de-944b-e07fc1f90ae7"
        let known = [a: StatusLineFreshnessRules.advance(nil, with: StatusLineFixture.reading(writtenAt: ago(120)))]

        let table = StatusLineFreshnessRules.table(
            known,
            readings: [
                StatusLineFixture.reading(totalAPIDurationMs: 21_400, writtenAt: ago(60)),
                StatusLineFixture.reading(sessionID: b, writtenAt: ago(30)),
            ],
            now: now
        )

        XCTAssertEqual(try XCTUnwrap(table[a]).asOf, ago(60))
        XCTAssertNil(try XCTUnwrap(table[b]).asOf, "first sight of the second session")
    }

    /// A poll and a folder event read the same file: the second read is a no-op.
    func testTheSameFileReadTwiceChangesNothing() {
        let first = StatusLineFreshnessRules.table(
            [:], readings: [StatusLineFixture.reading(writtenAt: ago(120))], now: ago(100)
        )
        let dated = StatusLineFreshnessRules.table(
            first, readings: [StatusLineFixture.reading(totalAPIDurationMs: 21_400, writtenAt: ago(60))], now: ago(50)
        )

        XCTAssertEqual(
            StatusLineFreshnessRules.table(
                dated, readings: [StatusLineFixture.reading(totalAPIDurationMs: 21_400, writtenAt: ago(60))], now: now
            ),
            dated
        )
    }
}
