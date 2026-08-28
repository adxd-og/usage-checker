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

    private func extraUsage(_ json: String) throws -> ExtraUsage {
        try XCTUnwrap(
            ClaudeOAuthProvider.usage(fromPayload: Data("{\"extra_usage\":\(json)}".utf8)).extraUsage
        )
    }

    func testTheUsedOverLimitRatioBeatsTheReportedUtilization() throws {
        // In the account above the two happen to agree (15640/20000 == 0.782), which
        // makes that test blind to which one is being read. Here they disagree, and the
        // ratio has to win — it is what the "$100.00 / $200" text beside the bar says.
        let extra = try extraUsage(
            #"{"is_enabled": true, "monthly_limit": 20000, "used_credits": 10000, "utilization": 0.782}"#
        )
        XCTAssertEqual(extra.utilization, 50.0, accuracy: 0.0001)
        XCTAssertEqual(extra.usedCredits, 100.0, accuracy: 0.0001)
        XCTAssertEqual(extra.monthlyLimit, 200.0, accuracy: 0.0001)
    }

    func testWithoutALimitTheReportedFractionIsScaledToPercent() throws {
        let extra = try extraUsage(
            #"{"is_enabled": true, "monthly_limit": 0, "used_credits": 10000, "utilization": 0.782}"#
        )
        XCTAssertEqual(extra.utilization, 78.2, accuracy: 0.0001)
    }

    func testALegacyWindowsUtilizationIsAlreadyAPercent() throws {
        // 1.0 means one percent. Reading it as a 0–1 fraction turned a barely-touched
        // window into a full one.
        let payload = """
        {
          "five_hour": { "utilization": 1.0 },
          "seven_day": { "used_percentage": 22 }
        }
        """
        let buckets = try ClaudeOAuthProvider.usage(fromPayload: Data(payload.utf8)).buckets
        XCTAssertEqual(buckets.first { $0.id == "five_hour" }?.utilization, 1.0)
        // `used_percentage` is the older field name and stands in when there is no
        // `utilization` at all.
        XCTAssertEqual(buckets.first { $0.id == "seven_day" }?.utilization, 22.0)
    }

    // MARK: - Dollar pools and the spend object

    /// The shapes the live payload actually carries next to the rate windows: five
    /// codename keys that are null on this account, a dollar-denominated pool that
    /// isn't switched on, and the usage-credits `spend` object.
    private let noiseAroundTheWindows = """
    {
      "five_hour": { "utilization": 11.0, "resets_at": "2026-08-27T18:00:00.000Z" },
      "tangelo": null,
      "iguana_necktie": null,
      "cinder_cove": null,
      "amber_ladder": null,
      "juniper_tide": null,
      "nimbus_quill": {
        "utilization": 0.0, "resets_at": null,
        "limit_dollars": null, "used_dollars": null, "remaining_dollars": null
      },
      "spend": {
        "used": { "amount_minor": 0, "currency": "USD", "exponent": 2 },
        "limit": null, "percent": 0, "enabled": false, "can_purchase_credits": false
      }
    }
    """

    func testCodenameKeysAndAnUnfundedDollarPoolProduceNoBuckets() throws {
        let buckets = try ClaudeOAuthProvider.usage(fromPayload: Data(noiseAroundTheWindows.utf8)).buckets
        XCTAssertEqual(buckets.map(\.id), ["five_hour"], "only the real window survives")
        XCTAssertNil(
            buckets.first { $0.id == "nimbus_quill" },
            "a dollar pool with no limit is not a 0% rate window — it showed as 'Nimbus Quill 0%'"
        )
        XCTAssertNil(buckets.first { $0.id == "spend" })
    }

    func testAFundedDollarPoolBecomesItsOwnWindow() throws {
        let payload = """
        {
          "five_hour": { "utilization": 11.0, "resets_at": "2026-08-27T18:00:00.000Z" },
          "nimbus_quill": {
            "utilization": 24, "resets_at": null,
            "limit_dollars": 5000, "used_dollars": 1200, "remaining_dollars": 3800
          }
        }
        """
        let buckets = try ClaudeOAuthProvider.usage(fromPayload: Data(payload.utf8)).buckets
        let pool = try XCTUnwrap(buckets.first { $0.id == "nimbus_quill" })
        XCTAssertEqual(pool.utilization, 24)
        XCTAssertEqual(pool.label, "Nimbus Quill")
        XCTAssertEqual(pool.kind, .other)
        XCTAssertEqual(pool.resetsAt, .distantFuture)
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
