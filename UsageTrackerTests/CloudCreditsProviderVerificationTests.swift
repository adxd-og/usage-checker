import XCTest
@testable import Omelette

/// Independent checks of the cloud session credits spec (2026-10-04) § Design "A funded
/// dollar pool is a credit pool", "Labels": the usage payload's decoding, and the
/// persistence round trips (`last-known.json`, `history.jsonl`) that must keep reading
/// files written by 3.0.1.
final class CloudCreditsProviderVerificationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudCreditsProviderVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func buckets(_ json: String) throws -> [UsageBucket] {
        try ClaudeOAuthProvider.usage(fromPayload: Data(json.utf8)).buckets
    }

    private func iso(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)!
    }

    // MARK: - Decoding the live payload

    func testTheLivePayloadsPoolBecomesACreditBucketLabelledCloudSessionCredits() throws {
        let all = try buckets(Fixture.cloudCreditsPayload)
        let pool = try XCTUnwrap(all.first { $0.id == "iguana_necktie" })
        XCTAssertEqual(pool.label, "Cloud session credits")
        XCTAssertEqual(pool.kind, .other)
        XCTAssertEqual(pool.utilization, 92.368272, accuracy: 1e-9)
        XCTAssertEqual(pool.credit, CreditPool(usedDollars: 230.92068, limitDollars: 250))
        XCTAssertTrue(pool.isCreditPool)
        XCTAssertTrue(pool.isBonusPool)
        XCTAssertFalse(pool.isPromotional, "a credit pool is not a promo pool; promo keeps its own substring rule")
        XCTAssertEqual(pool.resetsAt, iso("2026-11-05T07:59:00Z"))
    }

    func testTheDollarFieldsAreWholeDollarsNotCents() throws {
        let pool = try XCTUnwrap(try buckets(Fixture.cloudCreditsPayload).first { $0.isCreditPool })
        let credit = try XCTUnwrap(pool.credit)
        XCTAssertEqual(credit.limitDollars, 250, "250 in the payload is $250, not $2.50")
        XCTAssertEqual(credit.usedDollars, 230.92068, accuracy: 1e-9)
    }

    func testTheRateLimitWindowsStayRateLimitWindows() throws {
        let all = try buckets(Fixture.cloudCreditsPayload)
        for id in ["five_hour", "seven_day"] {
            let window = try XCTUnwrap(all.first { $0.id == id })
            XCTAssertNil(window.credit, "\(id) must not become a credit pool")
            XCTAssertFalse(window.isBonusPool)
        }
        XCTAssertEqual(all.first { $0.id == "five_hour" }?.kind, .session)
        XCTAssertEqual(all.first { $0.id == "seven_day" }?.kind, .weekly)
    }

    func testTheCreditPoolListsAfterThePlansWindows() throws {
        let ids = try buckets(Fixture.cloudCreditsPayload).map(\.id)
        XCTAssertEqual(ids.last, "iguana_necktie")
    }

    func testExtraUsageIsStillInCentsAndStillNotAPool() throws {
        let json = """
        {
          "five_hour": { "utilization": 7.0, "resets_at": "2026-10-04T12:49:59+00:00" },
          "iguana_necktie": {"utilization": 92.4, "resets_at": "2026-11-05T07:59:00+00:00", "limit_dollars": 250, "used_dollars": 231, "remaining_dollars": 19},
          "extra_usage": { "is_enabled": true, "monthly_limit": 5000, "used_credits": 1240, "utilization": 24.8 }
        }
        """
        let usage = try ClaudeOAuthProvider.usage(fromPayload: Data(json.utf8))
        let extra = try XCTUnwrap(usage.extraUsage)
        XCTAssertEqual(extra.monthlyLimit, 50, accuracy: 1e-9, "extra_usage keeps its cents -> dollars conversion")
        XCTAssertEqual(extra.usedCredits, 12.40, accuracy: 1e-9)
        XCTAssertFalse(usage.buckets.contains { $0.id == "extra_usage" })
        XCTAssertEqual(usage.buckets.filter(\.isCreditPool).count, 1)
    }

    // MARK: - Null / missing dollars

    func testAFundedPoolWithNullUsedDollarsIsStillACreditPoolAndNeverAWindow() throws {
        let json = """
        {
          "five_hour": { "utilization": 7.0, "resets_at": "2026-10-04T12:49:59+00:00" },
          "seven_day": { "utilization": 69.0, "resets_at": "2026-10-08T09:59:59+00:00" },
          "iguana_necktie": {"utilization": 40.0, "resets_at": "2026-11-05T07:59:00+00:00", "limit_dollars": 250, "used_dollars": null, "remaining_dollars": 150, "locked_reason": null}
        }
        """
        let all = try buckets(json)
        let pool = try XCTUnwrap(all.first { $0.id == "iguana_necktie" }, "a funded pool must not vanish for want of used_dollars")
        XCTAssertTrue(pool.isCreditPool, "funded + null used_dollars must not fall back to a competing window")
        XCTAssertEqual(pool.label, "Cloud session credits")
        XCTAssertEqual(pool.credit?.limitDollars, 250)
        let used = try XCTUnwrap(pool.credit?.usedDollars)
        XCTAssertGreaterThanOrEqual(used, 0)
        XCTAssertLessThanOrEqual(used, 250)
        // Never leads, whatever its percent.
        let service = Fixture.snapshot(buckets: all)
        XCTAssertEqual(service.headlinePercent, 69, accuracy: 1e-9)
        XCTAssertNotNil(PopoverView.creditRowValue(pool, locale: Locale(identifier: "en_US")))
    }

    func testAFundedPoolWithNoUsedDollarsKeyAtAllIsACreditPoolToo() throws {
        let json = """
        {
          "seven_day": { "utilization": 69.0, "resets_at": "2026-10-08T09:59:59+00:00" },
          "iguana_necktie": {"utilization": 92.0, "resets_at": "2026-11-05T07:59:00+00:00", "limit_dollars": 250, "remaining_dollars": 20}
        }
        """
        let pool = try XCTUnwrap(try buckets(json).first { $0.id == "iguana_necktie" })
        XCTAssertTrue(pool.isCreditPool)
    }

    func testAnUnfundedPoolWithNullDollarsIsNoBucketAtAll() throws {
        // The shape nimbus_quill had on accounts where the pool is not switched on.
        let json = """
        {
          "seven_day": { "utilization": 69.0, "resets_at": "2026-10-08T09:59:59+00:00" },
          "iguana_necktie": {"utilization": 0.0, "resets_at": null, "limit_dollars": null, "used_dollars": null, "remaining_dollars": null, "locked_reason": null}
        }
        """
        XCTAssertEqual(try buckets(json).map(\.id), ["seven_day"])
    }

    func testAZeroOrNegativeLimitIsNoPool() throws {
        for limit in ["0", "-5"] {
            let json = """
            {
              "seven_day": { "utilization": 69.0, "resets_at": "2026-10-08T09:59:59+00:00" },
              "iguana_necktie": {"utilization": 10.0, "resets_at": "2026-11-05T07:59:00+00:00", "limit_dollars": \(limit), "used_dollars": 0}
            }
            """
            XCTAssertEqual(try buckets(json).map(\.id), ["seven_day"], "limit \(limit)")
        }
    }

    func testAFundedPoolAtZeroPercentStillExists() throws {
        // "A pool at 0 % still shows (it is money the account has)."
        let json = """
        {
          "seven_day": { "utilization": 69.0, "resets_at": "2026-10-08T09:59:59+00:00" },
          "iguana_necktie": {"utilization": 0.0, "resets_at": "2026-11-05T07:59:00+00:00", "limit_dollars": 1000, "used_dollars": 0, "remaining_dollars": 1000}
        }
        """
        let pool = try XCTUnwrap(try buckets(json).first { $0.id == "iguana_necktie" })
        XCTAssertEqual(pool.credit, CreditPool(usedDollars: 0, limitDollars: 1000))
        XCTAssertEqual(pool.utilization, 0)
    }

    // MARK: - Labels

    func testAFundedPoolUnderAnUnknownKeyIsLabelledIncludedCreditsNeverACodename() throws {
        let json = """
        {
          "seven_day": { "utilization": 69.0, "resets_at": "2026-10-08T09:59:59+00:00" },
          "walrus_biscuit": {"utilization": 30.0, "resets_at": "2026-11-05T07:59:00+00:00", "limit_dollars": 100, "used_dollars": 30, "remaining_dollars": 70}
        }
        """
        let pool = try XCTUnwrap(try buckets(json).first { $0.id == "walrus_biscuit" })
        XCTAssertEqual(pool.label, "Included credits")
        XCTAssertEqual(pool.kind, .other)
        XCTAssertEqual(pool.credit, CreditPool(usedDollars: 30, limitDollars: 100))
        XCTAssertFalse(pool.label.lowercased().contains("walrus"))
    }

    func testAFundedPoolWhoseKeyLooksLikeAWeeklyWindowIsStillOtherNeverAWeeklyRow() throws {
        // `autoKind` would read "seven_day_*" as a weekly window and the pool would
        // take a row among the weekly limits as well as its own in the spend card.
        let json = """
        {
          "seven_day": { "utilization": 69.0, "resets_at": "2026-10-08T09:59:59+00:00" },
          "seven_day_walrus": {"utilization": 30.0, "resets_at": "2026-11-05T07:59:00+00:00", "limit_dollars": 100, "used_dollars": 30}
        }
        """
        let pool = try XCTUnwrap(try buckets(json).first { $0.id == "seven_day_walrus" })
        XCTAssertEqual(pool.kind, .other)
        XCTAssertEqual(pool.label, "Included credits")
        XCTAssertTrue(pool.isCreditPool)
    }

    func testAnUnfundedUnknownPoolStaysHidden() throws {
        let json = """
        {
          "seven_day": { "utilization": 69.0, "resets_at": "2026-10-08T09:59:59+00:00" },
          "walrus_biscuit": {"utilization": 0.0, "resets_at": null, "limit_dollars": null, "used_dollars": null, "remaining_dollars": null}
        }
        """
        XCTAssertEqual(try buckets(json).map(\.id), ["seven_day"])
    }

    func testTwoFundedUnknownPoolsAreBothCreditPoolsInKeyOrder() throws {
        let json = """
        {
          "seven_day": { "utilization": 69.0, "resets_at": "2026-10-08T09:59:59+00:00" },
          "zeta_pool": {"utilization": 10.0, "resets_at": "2026-11-05T07:59:00+00:00", "limit_dollars": 20, "used_dollars": 2},
          "alpha_pool": {"utilization": 50.0, "resets_at": "2026-11-05T07:59:00+00:00", "limit_dollars": 40, "used_dollars": 20}
        }
        """
        let pools = try buckets(json).filter(\.isCreditPool)
        XCTAssertEqual(pools.map(\.id), ["alpha_pool", "zeta_pool"])
        XCTAssertEqual(pools.map(\.label), ["Included credits", "Included credits"])
    }

    func testAnUnknownNonDollarWindowKeepsItsDerivedLabelAndKind() throws {
        // The label change must not leak onto ordinary unknown windows.
        let json = """
        {
          "seven_day": { "utilization": 69.0, "resets_at": "2026-10-08T09:59:59+00:00" },
          "seven_day_haiku": { "utilization": 5.0, "resets_at": "2026-10-08T09:59:59+00:00" }
        }
        """
        let haiku = try XCTUnwrap(try buckets(json).first { $0.id == "seven_day_haiku" })
        XCTAssertNotEqual(haiku.label, "Included credits")
        XCTAssertNil(haiku.credit)
    }

    func testAPromoNamedFundedPoolStillCountsAsPromoAndCredit() throws {
        let json = """
        {
          "seven_day": { "utilization": 69.0, "resets_at": "2026-10-08T09:59:59+00:00" },
          "seven_day_promotional": {"utilization": 99.0, "resets_at": "2026-11-05T07:59:00+00:00", "limit_dollars": 100, "used_dollars": 99}
        }
        """
        let pool = try XCTUnwrap(try buckets(json).first { $0.id == "seven_day_promotional" })
        XCTAssertTrue(pool.isBonusPool)
        XCTAssertEqual(Fixture.snapshot(buckets: try buckets(json)).headlinePercent, 69, accuracy: 1e-9)
    }

    // MARK: - last-known.json (3.0.1 shape)

    /// A `last-known.json` exactly as 3.0.1 wrote it: no `credit` key, no `windowLength`.
    private let lastKnown301 = """
    {
      "claude": {
        "displayName": "Claude",
        "icon": "sparkles",
        "plan": "Max 5x",
        "buckets": [
          {"id": "five_hour", "label": "Current session", "utilization": 7, "resetsAt": "2026-10-04T12:49:59Z", "kind": "session"},
          {"id": "seven_day", "label": "All models", "utilization": 69, "resetsAt": "2026-10-08T09:59:59Z", "kind": "weekly"},
          {"id": "iguana_necktie", "label": "Iguana Necktie", "utilization": 92.368272, "resetsAt": "2026-11-05T07:59:00Z", "kind": "other"}
        ],
        "weekCost": 12.5,
        "fetchedAt": "2026-10-04T12:00:00Z",
        "order": 0
      }
    }
    """

    func testARetainedCreditPoolFrom301IsDroppedAtLoadAndTheRestIsKept() async throws {
        // 3.0.1 stored the pool as a bare percent window under its codename: restored, it
        // would drive the headline and print the codename until the first good poll.
        let url = directory.appendingPathComponent("last-known.json")
        try Data(lastKnown301.utf8).write(to: url)
        let loaded = await LastKnownStore(fileURL: url).load()
        let claude = try XCTUnwrap(loaded["claude"], "a 3.0.1 file must not be thrown away as undecodable")
        XCTAssertEqual(claude.buckets.map(\.id), ["five_hour", "seven_day"], "the dollar-less pool is dropped, the plan's windows stay")
        XCTAssertTrue(claude.buckets.allSatisfy { $0.credit == nil })
        XCTAssertEqual(claude.plan, "Max 5x")
        XCTAssertEqual(claude.weekCost, 12.5)
        let service = Fixture.snapshot(buckets: claude.buckets, state: .notRunning)
        XCTAssertEqual(service.headlinePercent, 69, accuracy: 1e-9, "no 92 % headline from the old record")
    }

    func testABucketStoredWithItsCreditIsKeptAtLoad() async throws {
        let url = directory.appendingPathComponent("last-known.json")
        let json = lastKnown301.replacingOccurrences(
            of: #""utilization": 92.368272,"#,
            with: #""utilization": 92.368272, "credit": {"usedDollars": 230.92068, "limitDollars": 250},"#
        )
        XCTAssertNotEqual(json, lastKnown301)
        try Data(json.utf8).write(to: url)
        let loaded = await LastKnownStore(fileURL: url).load()
        let claude = try XCTUnwrap(loaded["claude"])
        XCTAssertEqual(claude.buckets.map(\.id), ["five_hour", "seven_day", "iguana_necktie"])
        XCTAssertEqual(claude.buckets.last?.credit, CreditPool(usedDollars: 230.92068, limitDollars: 250))
    }

    func testOnlyBucketsUnderAKnownCreditPoolIDAreDropped() async throws {
        // An unrelated bucket without credit, whatever its id, is untouched; the injected
        // id set decides which keys are pools.
        let url = directory.appendingPathComponent("last-known.json")
        try Data(lastKnown301.utf8).write(to: url)
        let custom = await LastKnownStore(fileURL: url, creditPoolIDs: ["seven_day"]).load()
        XCTAssertEqual(custom["claude"]?.buckets.map(\.id), ["five_hour", "iguana_necktie"])
        let none = await LastKnownStore(fileURL: url, creditPoolIDs: []).load()
        XCTAssertEqual(none["claude"]?.buckets.map(\.id), ["five_hour", "seven_day", "iguana_necktie"])
    }

    func testABucketRecordWithoutCreditDecodesToNilCredit() throws {
        let json = #"{"id": "seven_day", "label": "All models", "utilization": 69, "resetsAt": "2026-10-08T09:59:59Z", "kind": "weekly"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bucket = try decoder.decode(UsageBucket.self, from: Data(json.utf8))
        XCTAssertNil(bucket.credit)
        XCTAssertNil(bucket.windowLength)
    }

    func testACreditPoolSurvivesALastKnownRoundTripUnrounded() async throws {
        let url = directory.appendingPathComponent("last-known.json")
        let service = Fixture.snapshot(
            plan: "Max 5x",
            buckets: [Fixture.bucket(id: "seven_day", label: "All models", percent: 69, kind: .weekly), Fixture.cloudCredits],
            at: Date(timeIntervalSince1970: 1_791_115_200)
        )
        await LastKnownStore(fileURL: url).remember([service])
        let reloaded = await LastKnownStore(fileURL: url).load()
        let pool = try XCTUnwrap(reloaded["claude"]?.buckets.first { $0.id == "iguana_necktie" })
        XCTAssertEqual(pool.credit, CreditPool(usedDollars: 230.92068, limitDollars: 250))
        XCTAssertEqual(pool.label, "Cloud session credits")
        XCTAssertTrue(pool.isBonusPool)
        // Non-credit buckets keep "no credit".
        XCTAssertNil(reloaded["claude"]?.buckets.first { $0.id == "seven_day" }?.credit)
    }

    func testAChangeOnlyInTheDollarsRewritesLastKnown() async throws {
        // Same percent, same label, different dollars: the throttle must not treat it as unchanged.
        let url = directory.appendingPathComponent("last-known.json")
        let weekly = Fixture.bucket(id: "seven_day", label: "All models", percent: 69, kind: .weekly)
        func pool(used: Double) -> UsageBucket {
            Fixture.bucket(
                id: "iguana_necktie", label: "Cloud session credits", percent: 40,
                kind: .other, credit: CreditPool(usedDollars: used, limitDollars: 250)
            )
        }
        let store = LastKnownStore(fileURL: url)
        await store.remember([Fixture.snapshot(buckets: [weekly, pool(used: 100)])])
        await store.remember([Fixture.snapshot(buckets: [weekly, pool(used: 101)])])
        let reloaded = await LastKnownStore(fileURL: url).load()
        XCTAssertEqual(reloaded["claude"]?.buckets.last?.credit?.usedDollars, 101)
    }

    func testTheCreditObjectIsEquatableByItsDollars() {
        let a = Fixture.bucket(id: "p", credit: CreditPool(usedDollars: 1, limitDollars: 250))
        let b = Fixture.bucket(id: "p", credit: CreditPool(usedDollars: 2, limitDollars: 250))
        let c = Fixture.bucket(id: "p")
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(a, a)
    }

    // MARK: - history.jsonl

    func testAHistoryRecordWithNoCreditKeyStillDecodesAndKeepsThePoolsPercent() throws {
        let line = #"{"id": "8F0F7A0E-0000-4000-8000-000000000001", "timestamp": "2026-10-04T12:00:00Z", "fiveHourPercent": 7, "sevenDayPercent": 69, "plan": "Max 5x", "bucketPercents": {"five_hour": 7, "seven_day": 69, "iguana_necktie": 92.368272}, "serviceID": "claude"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(HistoryRecord.self, from: Data(line.utf8))
        XCTAssertEqual(record.percent(for: "iguana_necktie"), 92.368272)
        XCTAssertEqual(record.serviceID, "claude")
    }

    func testAHistoryRecordOfACreditPoolStaysPercentsOnly() throws {
        let service = Fixture.snapshot(buckets: [
            Fixture.bucket(id: "seven_day", label: "All models", percent: 69, kind: .weekly),
            Fixture.cloudCredits,
        ])
        let record = HistoryRecord(from: service, at: Date(timeIntervalSince1970: 1_791_115_200))
        XCTAssertEqual(record.percent(for: "iguana_necktie") ?? -1, 92.368272, accuracy: 1e-9)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let text = String(decoding: try encoder.encode(record), as: UTF8.self)
        XCTAssertFalse(text.contains("credit"), "history.jsonl records percents; the dollars are not part of it: \(text)")
        XCTAssertFalse(text.contains("Dollars"), text)
        // And it round-trips through the same decoder an old line goes through.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(HistoryRecord.self, from: Data(text.utf8)), record)
    }

    func testTheHistoryStoreReadsAnOldLogNextToANewRecord() async throws {
        // The store drops anything older than 90 days against the real clock, so the line
        // is stamped a day ago rather than with a fixed date.
        let stamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-86_400))
        let line = #"{"id": "8F0F7A0E-0000-4000-8000-000000000002", "timestamp": "\#(stamp)", "fiveHourPercent": 7, "sevenDayPercent": 88, "bucketPercents": {"seven_day": 88, "iguana_necktie": 0}, "serviceID": "claude"}"#
        try Data((line + "\n").utf8).write(to: directory.appendingPathComponent("history.jsonl"))
        let store = HistoryStore(directory: directory)
        let records = await store.all(service: "claude")
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.percent(for: "iguana_necktie"), 0)
    }
}
