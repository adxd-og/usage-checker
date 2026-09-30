import XCTest
@testable import Omelette

/// Spec 2026-09-30 status line cache timer, § Rule: `CacheLifeRules` turns Claude
/// Code's `prompt_cache` into `cache 47m` / `cache 40s` / `cache cold` and the state
/// that colours it: closing under 5 minutes on a 1-hour cache, under 1 minute on a
/// 5-minute or unknown one; no segment at all when caching was never observed.
final class CacheLifeRulesTests: XCTestCase {
    /// Sunday 2026-09-06 11:20:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_788_693_600)

    private func cache(
        expiresIn seconds: TimeInterval?,
        warm: Bool = true,
        ttl: String? = "1h",
        observed: Bool = true
    ) -> StatusLineInput.PromptCache {
        StatusLineInput.PromptCache(
            warm: warm,
            ttl: ttl,
            expiresAt: seconds.map { now.addingTimeInterval($0) },
            cachingObserved: observed
        )
    }

    private func segment(_ cache: StatusLineInput.PromptCache?) -> CacheLifeSegment? {
        CacheLifeRules.segment(cache: cache, now: now)
    }

    private func expected(_ text: String, _ state: CacheLifeState) -> CacheLifeSegment {
        CacheLifeSegment(text: text, state: state)
    }

    func testAWarmCacheCountsWholeMinutesRoundedDown() {
        XCTAssertEqual(segment(cache(expiresIn: 47 * 60)), expected("cache 47m", .warm))
        XCTAssertEqual(segment(cache(expiresIn: 47 * 60 + 59)), expected("cache 47m", .warm))
        XCTAssertEqual(
            segment(cache(expiresIn: 60 * 60)), expected("cache 60m", .warm),
            "minutes, never hours: the longest TTL is one"
        )
    }

    func testAnHourCacheIsClosingInItsLastFiveMinutes() {
        XCTAssertEqual(segment(cache(expiresIn: 4 * 60, ttl: "1h")), expected("cache 4m", .closing))
        XCTAssertEqual(segment(cache(expiresIn: 4 * 60 + 59, ttl: "1h")), expected("cache 4m", .closing))
        XCTAssertEqual(
            segment(cache(expiresIn: 5 * 60, ttl: "1h")), expected("cache 5m", .warm),
            "five minutes left is not under five"
        )
        XCTAssertEqual(segment(cache(expiresIn: 40, ttl: "1h")), expected("cache 40s", .closing))
    }

    func testAFiveMinuteCacheIsClosingInItsLastMinute() {
        XCTAssertEqual(segment(cache(expiresIn: 40, ttl: "5m")), expected("cache 40s", .closing))
        XCTAssertEqual(segment(cache(expiresIn: 59, ttl: "5m")), expected("cache 59s", .closing))
        XCTAssertEqual(
            segment(cache(expiresIn: 60, ttl: "5m")), expected("cache 1m", .warm),
            "one minute left is not under one"
        )
        XCTAssertEqual(
            segment(cache(expiresIn: 4 * 60, ttl: "5m")), expected("cache 4m", .warm),
            "four minutes is closing only on an hour cache"
        )
    }

    func testAnUnknownTTLTakesTheFiveMinuteThresholds() {
        for ttl in [nil, "2h", "10m"] as [String?] {
            XCTAssertEqual(
                segment(cache(expiresIn: 4 * 60, ttl: ttl)), expected("cache 4m", .warm),
                String(describing: ttl)
            )
            XCTAssertEqual(
                segment(cache(expiresIn: 40, ttl: ttl)), expected("cache 40s", .closing),
                String(describing: ttl)
            )
        }
    }

    /// Still warm with less than a second to go: "0s" would read as gone.
    func testUnderASecondLeftStillReadsAsTime() {
        XCTAssertEqual(segment(cache(expiresIn: 0.4, ttl: "5m")), expected("cache 1s", .closing))
    }

    /// Spec § Decisions: no negative countdown. The useful fact is that the next turn
    /// pays a write, not how long ago the cache went.
    func testAnExpiredCacheIsColdNotANegativeCountdown() {
        XCTAssertEqual(segment(cache(expiresIn: 0)), expected("cache cold", .expired), "expiring now is expired")
        XCTAssertEqual(segment(cache(expiresIn: -1)), expected("cache cold", .expired))
        XCTAssertEqual(segment(cache(expiresIn: -3 * 3600)), expected("cache cold", .expired))
    }

    func testACacheClaudeCodeCallsColdIsCold() {
        XCTAssertEqual(
            segment(cache(expiresIn: 47 * 60, warm: false)), expected("cache cold", .expired),
            "warm false wins over a future expiry"
        )
        XCTAssertEqual(segment(cache(expiresIn: nil, warm: false)), expected("cache cold", .expired))
        XCTAssertEqual(
            segment(cache(expiresIn: nil, warm: true)), expected("cache cold", .expired),
            "no expiry is no time to count"
        )
    }

    /// Spec § Decisions: a provider that never reported cache tokens gets no segment;
    /// a "cold" there would blame a cache nobody saw.
    func testNothingToCountIsNoSegment() {
        XCTAssertNil(segment(nil), "no prompt_cache before the first response")
        XCTAssertNil(segment(cache(expiresIn: 47 * 60, observed: false)))
        XCTAssertNil(segment(cache(expiresIn: nil, warm: false, observed: false)))
    }

    /// The colour is the line's business, applied only when it prints colour.
    func testTheTextCarriesNoColourCodes() {
        let caches = [
            cache(expiresIn: 47 * 60),
            cache(expiresIn: 4 * 60),
            cache(expiresIn: 40, ttl: "5m"),
            cache(expiresIn: -1),
            cache(expiresIn: nil, warm: false),
        ]
        for item in caches {
            let text = segment(item)?.text
            XCTAssertNotNil(text)
            XCTAssertFalse(text?.contains("\u{1B}") ?? true, String(describing: text))
        }
    }

    /// Dim throughout, like the rest of the line: the percent's dim while warm, the
    /// context bar's dim yellow while closing, its dim red once cold.
    func testEachStateHasItsDimColour() {
        XCTAssertEqual(CacheLifeRules.colour(for: .warm), "\u{1B}[2m")
        XCTAssertEqual(CacheLifeRules.colour(for: .closing), "\u{1B}[2;33m")
        XCTAssertEqual(CacheLifeRules.colour(for: .expired), "\u{1B}[2;31m")
    }

    /// Any finite `expires_at` parses, and a status line that trapped on one would
    /// leave Claude Code's bar blank for the session.
    func testAGarbledFarFutureExpiryDoesNotStopTheLine() {
        let far = StatusLineInput.PromptCache(
            warm: true, ttl: "1h", expiresAt: Date(timeIntervalSince1970: 1e300), cachingObserved: true
        )
        let result = segment(far)
        XCTAssertEqual(result?.state, .warm)
        XCTAssertEqual(result?.text.hasPrefix("cache "), true)
        XCTAssertEqual(result?.text.hasSuffix("m"), true)
    }
}
