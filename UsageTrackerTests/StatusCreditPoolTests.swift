import XCTest
@testable import Omelette

/// Cloud session credits spec § Published data: a credit pool reaches `status.json` with
/// its dollars, and `omelette status`, the status line and `get_usage` read it as money,
/// never as the window to pace against. Every reading starts from the published file —
/// built, encoded, decoded — the way the CLI meets it. UTC and en_GB, as in
/// `StatusTextTests`; `ResetCopy` writes en_GB's morning hours without a leading zero
/// ("Thu 9:59", "5 Nov, 7:59").
final class StatusCreditPoolTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = utc
        c.locale = Locale(identifier: "en_GB")
        return c
    }
    private let locale = Locale(identifier: "en_GB")
    /// Sunday 2026-10-04 12:00 UTC, the day the menu bar showed the pool's 92 %.
    private let now = Date(timeIntervalSince1970: 1_791_115_200)

    /// Claude's buckets as the provider builds them from the live payload.
    private func liveBuckets() throws -> [UsageBucket] {
        try ClaudeOAuthProvider.usage(fromPayload: Data(Fixture.cloudCreditsPayload.utf8)).buckets
    }

    /// The bytes the app would write to `status.json` for Claude with these buckets.
    private func publishedData(_ buckets: [UsageBucket]) throws -> Data {
        let claude = Fixture.snapshot(id: "claude", displayName: "Claude", plan: "Max 5x", buckets: buckets, at: now)
        let built = StatusFileWriter.build(services: [claude], costs: [:], agents: .none, now: now)
        return try StatusFile.encoder.encode(built)
    }

    /// Claude as the CLI reads it back from those bytes.
    private func published(_ buckets: [UsageBucket]) throws -> StatusSnapshot.Service {
        let snapshot = try StatusFile.decoder.decode(StatusSnapshot.self, from: try publishedData(buckets))
        return try XCTUnwrap(snapshot.service(id: "claude"))
    }

    func testACloudSessionCreditPoolIsPublishedWithItsDollars() throws {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try publishedData(try liveBuckets())) as? [String: Any]
        )
        let services = try XCTUnwrap(object["services"] as? [[String: Any]])
        let windows = try XCTUnwrap(services.first?["windows"] as? [[String: Any]])
        let pool = try XCTUnwrap(windows.first { ($0["id"] as? String) == "iguana_necktie" })
        XCTAssertEqual(pool["label"] as? String, "Cloud session credits")
        XCTAssertEqual(pool["percent"] as? Double, 92.368272)
        XCTAssertEqual(pool["usedDollars"] as? Double, 230.92068, "unrounded: the file records what is true")
        XCTAssertEqual(pool["limitDollars"] as? Double, 250)
        let session = try XCTUnwrap(windows.first { ($0["id"] as? String) == "five_hour" })
        XCTAssertNil(session["usedDollars"], "a rate-limit window carries no dollar keys")
        XCTAssertNil(session["limitDollars"])
    }

    func testAWindowFromAFileWrittenBefore302ReadsAsNoCredit() throws {
        // status.json as 3.0.1 wrote this account's pool on 2026-10-04.
        let json = #"{"id": "iguana_necktie", "kind": "other", "label": "Iguana Necktie", "percent": 92.368272, "resetsAt": "2026-11-05T07:59:00Z"}"#
        let window = try StatusFile.decoder.decode(StatusSnapshot.Window.self, from: Data(json.utf8))
        XCTAssertNil(window.usedDollars)
        XCTAssertNil(window.limitDollars)
        XCTAssertFalse(window.isBonusPool, "without its dollars the file cannot say it is money")
        XCTAssertEqual(window.percent, 92.368272)
    }

    func testOmeletteStatusPrintsACreditPoolAsDollarsWithItsExpiry() throws {
        let line = StatusText.serviceLine(
            try published(try liveBuckets()), width: 6, now: now, calendar: calendar, locale: locale
        )
        XCTAssertEqual(
            line,
            "Claude  Current session 7%, resets in 49m · All models 69%, resets in 3d 21h (Thu 9:59) · Cloud session credits $231 / $250, expires 5 Nov, 7:59"
        )
    }

    func testTheStatusLineNeverLeadsWithACreditPool() throws {
        // No session window, so the line falls back to the fullest core window: the
        // weekly at 69 %, not the pool at 92 %.
        let weekly = Fixture.bucket(id: "seven_day", label: "All models", percent: 69, kind: .weekly)
        let service = try published([weekly, Fixture.cloudCredits])
        XCTAssertEqual(StatusLineText.headlineWindow(service)?.id, "seven_day")
    }

    func testGetUsageQuotesTheCreditsAsDollarsAndPacesAgainstThePlansWindows() throws {
        let service = try published(try liveBuckets())
        let snapshot = StatusSnapshot(
            version: StatusSnapshot.currentVersion, updatedAt: now, services: [service], agents: .none
        )
        XCTAssertEqual(
            MCPSummary.serviceSentence(service, now: now, calendar: calendar, locale: locale),
            "Claude (Max 5x): current session 7%, resets in 49m; all models 69%, resets in 3d 21h (Thu 9:59); cloud session credits $231 / $250, expires 5 Nov, 7:59."
        )
        XCTAssertEqual(
            MCPSummary.advice(for: snapshot, now: now, calendar: calendar, locale: locale),
            "Claude's all models window is 69% used and resets in 3d 21h (Thu 9:59), so there is room to work."
        )
    }
}
