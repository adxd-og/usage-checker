import XCTest
@testable import Omelette

/// Independent verification of `CacheLifeRules`, derived from
/// `docs/superpowers/specs/2026-09-30-statusline-cache-timer.md` § Design "Rule" and
/// § Decisions, plus the session rulings (seconds clamp to at least 1 while warm; a
/// case-sensitive "1h"). Not from `CacheLifeRulesTests`. Focus: the exact threshold
/// instants, sub-second and far-future expiries, and an oracle sweep that must agree
/// with the spec's arithmetic at every half second.
final class CacheLifeRulesVerificationTests: XCTestCase {
    /// Sunday 2026-09-06 11:20:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_788_693_600)

    private func cache(
        expiresIn seconds: TimeInterval?,
        warm: Bool = true,
        ttl: String? = "1h",
        observed: Bool = true
    ) -> StatusLineInput.PromptCache {
        StatusLineInput.PromptCache(
            warm: warm, ttl: ttl,
            expiresAt: seconds.map { now.addingTimeInterval($0) },
            cachingObserved: observed
        )
    }

    private func segment(_ cache: StatusLineInput.PromptCache?) -> CacheLifeSegment? {
        CacheLifeRules.segment(cache: cache, now: now)
    }

    private func want(_ text: String, _ state: CacheLifeState) -> CacheLifeSegment {
        CacheLifeSegment(text: text, state: state)
    }

    // MARK: - Thresholds, to the second

    func testAnHourCacheWithExactlyFiveMinutesLeftIsWarmAndOneSecondLessIsClosing() {
        XCTAssertEqual(segment(cache(expiresIn: 300, ttl: "1h")), want("cache 5m", .warm))
        XCTAssertEqual(segment(cache(expiresIn: 299, ttl: "1h")), want("cache 4m", .closing))
        XCTAssertEqual(
            segment(cache(expiresIn: 299.999, ttl: "1h")), want("cache 4m", .closing),
            "a hair under five minutes is under five minutes"
        )
        XCTAssertEqual(segment(cache(expiresIn: 300.001, ttl: "1h")), want("cache 5m", .warm))
    }

    func testAFiveMinuteCacheWithExactlyOneMinuteLeftIsWarmAndOneSecondLessIsClosing() {
        XCTAssertEqual(segment(cache(expiresIn: 60, ttl: "5m")), want("cache 1m", .warm))
        XCTAssertEqual(segment(cache(expiresIn: 59, ttl: "5m")), want("cache 59s", .closing))
        XCTAssertEqual(segment(cache(expiresIn: 59.999, ttl: "5m")), want("cache 59s", .closing))
        XCTAssertEqual(segment(cache(expiresIn: 60.001, ttl: "5m")), want("cache 1m", .warm))
    }

    func testAFiveMinuteCacheIsWarmAtFourMinutesWhereAnHourCacheIsClosing() {
        XCTAssertEqual(segment(cache(expiresIn: 4 * 60, ttl: "5m")), want("cache 4m", .warm))
        XCTAssertEqual(segment(cache(expiresIn: 4 * 60, ttl: "1h")), want("cache 4m", .closing))
    }

    // MARK: - Expired

    func testZeroAndNegativeRemainingAreColdNotACountdown() {
        for remaining: TimeInterval in [0, -0.001, -1, -60, -3600, -1e9] {
            XCTAssertEqual(
                segment(cache(expiresIn: remaining)), want("cache cold", .expired),
                "remaining \(remaining)"
            )
        }
    }

    func testTheColdTextIsTheOneWordTheHelpUses() {
        XCTAssertEqual(CacheLifeRules.coldText, "cache cold")
    }

    func testAWarmFalseCacheIsColdEvenWithAFutureExpiry() {
        XCTAssertEqual(
            segment(cache(expiresIn: 47 * 60, warm: false)), want("cache cold", .expired)
        )
        XCTAssertEqual(
            segment(cache(expiresIn: 30, warm: false, ttl: "5m")), want("cache cold", .expired)
        )
    }

    func testAWarmCacheWithNoExpiryIsCold() {
        XCTAssertEqual(segment(cache(expiresIn: nil, warm: true)), want("cache cold", .expired))
        XCTAssertEqual(segment(cache(expiresIn: nil, warm: false)), want("cache cold", .expired))
    }

    // MARK: - No segment

    func testNoCacheAtAllIsNoSegment() {
        XCTAssertNil(segment(nil))
    }

    func testCachingNeverObservedIsNoSegmentWhateverElseTheObjectSays() {
        XCTAssertNil(segment(cache(expiresIn: 47 * 60, warm: true, observed: false)))
        XCTAssertNil(segment(cache(expiresIn: 47 * 60, warm: false, observed: false)))
        XCTAssertNil(segment(cache(expiresIn: nil, warm: false, observed: false)))
        XCTAssertNil(segment(cache(expiresIn: -100, warm: true, observed: false)), "not even a cold one")
    }

    // MARK: - Seconds and minutes

    func testUnderAMinuteReadsInWholeSecondsRoundedDown() {
        XCTAssertEqual(segment(cache(expiresIn: 59.9, ttl: "5m")), want("cache 59s", .closing))
        XCTAssertEqual(segment(cache(expiresIn: 40, ttl: "5m")), want("cache 40s", .closing))
        XCTAssertEqual(segment(cache(expiresIn: 1.999, ttl: "5m")), want("cache 1s", .closing))
        XCTAssertEqual(segment(cache(expiresIn: 2, ttl: "5m")), want("cache 2s", .closing))
    }

    func testAWarmCacheNeverReadsZeroSeconds() {
        XCTAssertEqual(segment(cache(expiresIn: 0.2, ttl: "5m")), want("cache 1s", .closing))
        XCTAssertEqual(segment(cache(expiresIn: 0.2, ttl: "1h")), want("cache 1s", .closing))
        XCTAssertEqual(segment(cache(expiresIn: 0.999, ttl: "5m")), want("cache 1s", .closing))
        XCTAssertEqual(segment(cache(expiresIn: 1e-6, ttl: nil)), want("cache 1s", .closing))
    }

    func testMinutesAreWholeAndRoundedDown() {
        XCTAssertEqual(segment(cache(expiresIn: 47 * 60 + 59)), want("cache 47m", .warm))
        XCTAssertEqual(segment(cache(expiresIn: 47 * 60)), want("cache 47m", .warm))
        XCTAssertEqual(segment(cache(expiresIn: 60 * 60)), want("cache 60m", .warm))
        XCTAssertEqual(segment(cache(expiresIn: 119.9, ttl: "5m")), want("cache 1m", .warm))
        XCTAssertEqual(segment(cache(expiresIn: 3599)), want("cache 59m", .warm))
    }

    // MARK: - Unusual expiries

    func testAYear9999ExpiryDoesNotTrapAndIsWarm() throws {
        let year9999 = Date(timeIntervalSince1970: 253_402_300_799)
        let result = try XCTUnwrap(CacheLifeRules.segment(
            cache: StatusLineInput.PromptCache(warm: true, ttl: "1h", expiresAt: year9999, cachingObserved: true),
            now: now
        ))
        XCTAssertEqual(result.state, .warm)
        XCTAssertNotNil(result.text.range(of: #"^cache [0-9]+m$"#, options: .regularExpression), result.text)
    }

    func testTheLargestFiniteExpiryDoesNotTrapAndIsWarm() throws {
        let far = Date(timeIntervalSince1970: Double.greatestFiniteMagnitude)
        let result = try XCTUnwrap(CacheLifeRules.segment(
            cache: StatusLineInput.PromptCache(warm: true, ttl: "5m", expiresAt: far, cachingObserved: true),
            now: now
        ))
        XCTAssertEqual(result.state, .warm)
        XCTAssertTrue(result.text.hasPrefix("cache "), result.text)
        XCTAssertTrue(result.text.hasSuffix("m"), result.text)
        XCTAssertFalse(result.text.contains("inf"), result.text)
        XCTAssertFalse(result.text.contains("nan"), result.text)
    }

    func testDistantFutureAndDistantPastDoNotTrap() throws {
        let future = try XCTUnwrap(CacheLifeRules.segment(
            cache: StatusLineInput.PromptCache(warm: true, ttl: "1h", expiresAt: .distantFuture, cachingObserved: true),
            now: now
        ))
        XCTAssertEqual(future.state, .warm)
        let past = try XCTUnwrap(CacheLifeRules.segment(
            cache: StatusLineInput.PromptCache(warm: true, ttl: "1h", expiresAt: .distantPast, cachingObserved: true),
            now: now
        ))
        XCTAssertEqual(past, want("cache cold", .expired))
        let mostNegative = try XCTUnwrap(CacheLifeRules.segment(
            cache: StatusLineInput.PromptCache(
                warm: true, ttl: "1h", expiresAt: Date(timeIntervalSince1970: -Double.greatestFiniteMagnitude),
                cachingObserved: true
            ),
            now: now
        ))
        XCTAssertEqual(mostNegative, want("cache cold", .expired))
    }

    // MARK: - TTL

    func testTheTTLIsComparedCaseSensitivelyToOneHour() {
        for ttl in ["1H", "1 h", "60m", "2h", "5m", "5M", "", "1h?"] {
            XCTAssertEqual(
                segment(cache(expiresIn: 4 * 60, ttl: ttl)), want("cache 4m", .warm),
                "ttl \(ttl.debugDescription) takes the five-minute thresholds: four minutes is not closing"
            )
            XCTAssertEqual(
                segment(cache(expiresIn: 30, ttl: ttl)), want("cache 30s", .closing),
                "ttl \(ttl.debugDescription): the last minute is closing"
            )
        }
        XCTAssertEqual(segment(cache(expiresIn: 4 * 60, ttl: nil)), want("cache 4m", .warm))
        XCTAssertEqual(segment(cache(expiresIn: 4 * 60, ttl: "1h")), want("cache 4m", .closing))
    }

    // MARK: - Text and colour

    func testTheTextNeverCarriesAnEscapeCode() {
        for remaining in [nil, -5, 0.3, 30, 4 * 60, 47 * 60] as [TimeInterval?] {
            for warm in [true, false] {
                let text = segment(cache(expiresIn: remaining, warm: warm))?.text ?? ""
                XCTAssertFalse(text.contains("\u{1B}"), text)
            }
        }
    }

    func testEachStateHasItsOwnDimColour() {
        XCTAssertEqual(CacheLifeRules.colour(for: .warm), StatusLineText.ANSI.percent)
        XCTAssertEqual(CacheLifeRules.colour(for: .closing), StatusLineText.ANSI.filling)
        XCTAssertEqual(CacheLifeRules.colour(for: .expired), StatusLineText.ANSI.tight)
        XCTAssertEqual(CacheLifeRules.colour(for: .warm), "\u{1B}[2m", "dim")
        XCTAssertEqual(CacheLifeRules.colour(for: .closing), "\u{1B}[2;33m", "dim yellow")
        XCTAssertEqual(CacheLifeRules.colour(for: .expired), "\u{1B}[2;31m", "dim red")
    }

    // MARK: - Oracle sweep

    /// The spec's arithmetic written out independently: minutes rounded down from 60 s,
    /// seconds below it (never 0 while warm), closing under 300 s on "1h" and under 60 s
    /// otherwise, and cold at or below zero.
    func testEveryHalfSecondAgreesWithTheSpecArithmetic() {
        for ttl in ["1h", "5m", "weird"] as [String] {
            var remaining = -2.0
            while remaining <= 3700 {
                let result = segment(cache(expiresIn: remaining, ttl: ttl))
                if remaining <= 0 {
                    XCTAssertEqual(result, want("cache cold", .expired), "ttl \(ttl) remaining \(remaining)")
                } else {
                    let text: String
                    if remaining >= 60 {
                        text = "cache \(Int(remaining / 60))m"
                    } else {
                        text = "cache \(max(1, Int(remaining)))s"
                    }
                    let threshold: TimeInterval = ttl == "1h" ? 300 : 60
                    let state: CacheLifeState = remaining < threshold ? .closing : .warm
                    XCTAssertEqual(result, want(text, state), "ttl \(ttl) remaining \(remaining)")
                }
                remaining += 0.5
            }
        }
    }
}
