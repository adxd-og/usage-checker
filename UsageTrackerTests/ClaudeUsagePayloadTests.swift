import XCTest
@testable import Omelette

/// Mirrors what `https://api.anthropic.com/api/oauth/usage` actually returns: legacy
/// top-level windows alongside the modern `limits` array, with the scoped windows
/// existing only in `limits`.
final class ClaudeUsagePayloadTests: XCTestCase {
    private let payload = """
    {
      "five_hour": { "utilization": 11.0, "resets_at": "2026-08-27T18:00:00.000Z" },
      "seven_day": { "utilization": 22.0, "resets_at": "2026-08-30T00:00:00.000Z" },
      "seven_day_opus": { "utilization": 33.0, "resets_at": "2026-08-30T00:00:00.000Z" },
      "limits": [
        { "kind": "session", "group": "session", "percent": 42.0, "resets_at": "2026-08-27T19:30:00.000Z" },
        { "kind": "weekly_all", "group": "weekly", "percent": 18.0, "resets_at": "2026-08-30T00:00:00.000Z" },
        {
          "kind": "weekly_scoped", "group": "weekly", "percent": 61.0,
          "resets_at": "2026-08-30T00:00:00.000Z",
          "scope": { "model": { "id": "claude-fable-5", "display_name": "Fable" } }
        },
        {
          "kind": "weekly_scoped", "group": "weekly", "percent": 7.0,
          "resets_at": "2026-08-30T00:00:00.000Z",
          "scope": { "model": { "id": "claude-omelette-1", "display_name": "omelette" } }
        },
        { "kind": "session", "group": "session", "percent": 99.0, "resets_at": "2026-08-27T19:30:00.000Z" },
        {
          "kind": "weekly_scoped", "group": "weekly", "percent": 13.0,
          "resets_at": "the day after tomorrow",
          "scope": { "model": { "display_name": "Ghost" } }
        }
      ],
      "extra_usage": {
        "is_enabled": true, "monthly_limit": 20000, "used_credits": 15640, "utilization": 0.782
      }
    }
    """

    private func decode() throws -> (buckets: [UsageBucket], extraUsage: ExtraUsage?) {
        try ClaudeOAuthProvider.usage(fromPayload: Data(payload.utf8))
    }

    func testScopedWindowsComeFromLimits() throws {
        let buckets = try decode().buckets
        let session = try XCTUnwrap(buckets.first { $0.id == "five_hour" })
        XCTAssertEqual(session.label, "Current session")
        XCTAssertEqual(session.kind, .session)
        // 42 from `limits`, not the legacy key's 11 — `limits` wins where it speaks.
        XCTAssertEqual(session.utilization, 42.0)

        let fable = try XCTUnwrap(buckets.first { $0.id == "seven_day_fable" })
        XCTAssertEqual(fable.label, "Fable only")
        XCTAssertEqual(fable.kind, .modelSpecific)
        XCTAssertEqual(fable.utilization, 61.0)

        let weekly = try XCTUnwrap(buckets.first { $0.id == "seven_day" })
        XCTAssertEqual(weekly.label, "All models")
        XCTAssertEqual(weekly.kind, .weekly)
        XCTAssertEqual(weekly.utilization, 18.0)
    }

    func testLegacyWindowsNotCoveredByLimitsAreAppendedAfter() throws {
        let buckets = try decode().buckets
        let ids = buckets.map(\.id)

        XCTAssertEqual(
            Array(ids.prefix(4)),
            ["five_hour", "seven_day", "seven_day_fable", "seven_day_omelette"],
            "limits keep their server order and lead"
        )
        XCTAssertEqual(ids.last, "seven_day_opus", "the uncovered legacy window trails")

        let opus = try XCTUnwrap(buckets.first { $0.id == "seven_day_opus" })
        XCTAssertEqual(opus.label, "Opus only")
        XCTAssertEqual(opus.kind, .modelSpecific)
        XCTAssertEqual(opus.utilization, 33.0)
    }

    func testDuplicateLimitEntriesDoNotDuplicateIDs() throws {
        let ids = try decode().buckets.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "ids must stay unique for SwiftUI lists")
        XCTAssertEqual(ids.filter { $0 == "five_hour" }.count, 1)
        // First occurrence wins: the duplicate's 99% must not have replaced 42%.
        XCTAssertEqual(try decode().buckets.first { $0.id == "five_hour" }?.utilization, 42.0)
    }

    func testAMalformedLimitIsDroppedWithoutLosingTheRest() throws {
        let buckets = try decode().buckets
        XCTAssertNil(buckets.first { $0.id == "seven_day_ghost" })
        XCTAssertEqual(buckets.count, 5, "one bad entry must not cost the other windows")
    }

    func testInternalCodenamesAreRenamedForDisplay() throws {
        let designed = try XCTUnwrap(try decode().buckets.first { $0.id == "seven_day_omelette" })
        XCTAssertEqual(designed.label, "Claude Design only")
        XCTAssertFalse(designed.label.lowercased().contains("omelette"))
        XCTAssertEqual(designed.kind, .modelSpecific)
    }

    func testExtraUsageIsReadAsCents() throws {
        let extra = try XCTUnwrap(try decode().extraUsage)
        XCTAssertTrue(extra.isEnabled)
        XCTAssertEqual(extra.monthlyLimit, 200.00, accuracy: 0.0001)
        XCTAssertEqual(extra.usedCredits, 156.40, accuracy: 0.0001)
        XCTAssertEqual(extra.utilization, 78.2, accuracy: 0.0001)
    }

    func testExtraUsageIsNotMistakenForARateWindow() throws {
        // `extra_usage` also carries a `utilization` field; it must not become a bucket.
        XCTAssertNil(try decode().buckets.first { $0.id == "extra_usage" })
    }

    func testAPayloadWithoutLimitsFallsBackToTheLegacyWindows() throws {
        let legacyOnly = """
        {
          "five_hour": { "utilization": 11.0, "resets_at": "2026-08-27T18:00:00.000Z" },
          "seven_day": { "utilization": 22.0, "resets_at": "2026-08-30T00:00:00.000Z" },
          "seven_day_cowork": { "utilization": 5.0, "resets_at": "2026-08-30T00:00:00.000Z" }
        }
        """
        let result = try ClaudeOAuthProvider.usage(fromPayload: Data(legacyOnly.utf8))

        XCTAssertEqual(result.buckets.map(\.id), ["five_hour", "seven_day", "seven_day_cowork"])
        XCTAssertEqual(result.buckets[0].utilization, 11.0)
        XCTAssertEqual(result.buckets[2].label, "Cowork")
        XCTAssertNil(result.extraUsage)
    }
}
