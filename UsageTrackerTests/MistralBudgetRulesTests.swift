import XCTest
@testable import Omelette

/// Spec 2026-11-10 Mistral provider § Windows: every `_budget` entry is one window, decoded
/// dynamically. `vibe_budget` is the long window "Vibe", `api_budget` a model-scoped "API", any
/// other `x_budget` a model-scoped "X". Each has Mistral's percent clamped to 0…100, its reset,
/// and the dollars of its monthly allowance (used = initial_budget × usage_percentage / 100).
/// The window runs the calendar month before its reset, so pace and the Limits tab read a month.
final class MistralBudgetRulesTests: XCTestCase {
    /// 2026-11-10 12:00 UTC, a Tuesday.
    private let now = Date(timeIntervalSince1970: 1_794_312_000)
    /// 2026-12-01 00:00 UTC: the live answer's `reset_at`.
    private let reset = Date(timeIntervalSince1970: 1_796_083_200)

    private var vibe: MistralBudgetEntry {
        MistralBudgetEntry(
            key: "vibe_budget", usagePercentage: 5.9597507033333335, initialBudget: 300, currency: "USD", resetAt: reset
        )
    }

    private var api: MistralBudgetEntry {
        MistralBudgetEntry(key: "api_budget", usagePercentage: 0, initialBudget: 30, currency: "USD", resetAt: reset)
    }

    func testTheLiveBudgetIsTwoWindowsVibeThenAPI() {
        let buckets = MistralBudgetRules.buckets(from: [api, vibe])
        XCTAssertEqual(buckets.map(\.id), ["mistral_vibe", "mistral_api"])
        XCTAssertEqual(buckets.map(\.label), ["Vibe", "API"])
        XCTAssertEqual(buckets.map(\.kind), [.weekly, .modelSpecific])
        XCTAssertEqual(buckets.map(\.utilization), [5.9597507033333335, 0])
    }

    func testThePercentIsMistralsOwnClampedToTheRange() {
        let over = MistralBudgetRules.bucket(
            from: MistralBudgetEntry(key: "vibe_budget", usagePercentage: 120, initialBudget: 300, currency: "USD")
        )
        XCTAssertEqual(over.utilization, 100)
        XCTAssertEqual(over.allowance?.usedDollars, 360, "pay as you go past the allowance: Mistral's own count")
        let under = MistralBudgetRules.bucket(
            from: MistralBudgetEntry(key: "api_budget", usagePercentage: -3, initialBudget: 30, currency: "USD")
        )
        XCTAssertEqual(under.utilization, 0)
        XCTAssertEqual(under.allowance?.usedDollars, 0)
    }

    func testTheResetIsTheEntrysAndAMissingOneIsNoResetLine() {
        XCTAssertEqual(MistralBudgetRules.bucket(from: vibe).resetsAt, reset)
        let noReset = MistralBudgetRules.bucket(from: MistralBudgetEntry(key: "vibe_budget", usagePercentage: 5))
        XCTAssertEqual(noReset.resetsAt, .distantFuture)
        XCTAssertNil(noReset.windowLength)
        XCTAssertNil(ResetCopy.both(resetsAt: noReset.resetsAt, now: now), "no reset line")
    }

    func testEachWindowCarriesItsAllowanceInDollars() throws {
        let buckets = MistralBudgetRules.buckets(from: [vibe, api])
        let vibeAllowance = try XCTUnwrap(buckets[0].allowance)
        XCTAssertEqual(vibeAllowance.usedDollars, 17.879252, accuracy: 0.000001)
        XCTAssertEqual(vibeAllowance.limitDollars, 300)
        XCTAssertEqual(buckets[1].allowance, CreditPool(usedDollars: 0, limitDollars: 30))
        XCTAssertNil(buckets[0].credit, "an allowance is not a prepaid pool")
    }

    func testNoAllowanceWithoutAPositiveBudgetInUSDollars() {
        let entries = [
            MistralBudgetEntry(key: "vibe_budget", usagePercentage: 5, currency: "USD"),
            MistralBudgetEntry(key: "vibe_budget", usagePercentage: 5, initialBudget: 0, currency: "USD"),
            MistralBudgetEntry(key: "vibe_budget", usagePercentage: 5, initialBudget: 300, currency: "EUR"),
            MistralBudgetEntry(key: "vibe_budget", usagePercentage: 5, initialBudget: 300),
        ]
        for entry in entries {
            XCTAssertNil(MistralBudgetRules.allowance(entry), "\(entry)")
        }
        XCTAssertEqual(
            MistralBudgetRules.allowance(
                MistralBudgetEntry(key: "vibe_budget", usagePercentage: 50, initialBudget: 300, currency: "usd")
            ),
            CreditPool(usedDollars: 150, limitDollars: 300)
        )
    }

    func testAWindowWithAnAllowanceIsStillALimit() {
        let service = Fixture.snapshot(id: "mistral", buckets: MistralBudgetRules.buckets(from: [vibe, api]))
        XCTAssertEqual(service.headlinePercent, 5.9597507033333335, "Vibe leads; the model-scoped API window never does")
        XCTAssertEqual(service.percentWindows.count, 2)
        XCTAssertTrue(service.creditPools.isEmpty)
    }

    func testTheWindowRunsTheCalendarMonthBeforeItsReset() throws {
        XCTAssertEqual(MistralBudgetRules.windowLength(resetsAt: reset), 2_592_000, "November: 30 days")
        XCTAssertEqual(
            MistralBudgetRules.windowLength(resetsAt: Date(timeIntervalSince1970: 1_772_323_200)), 2_419_200,
            "2026-03-01: February's 28 days"
        )
        XCTAssertNil(MistralBudgetRules.windowLength(resetsAt: nil))
        let bucket = MistralBudgetRules.bucket(from: vibe)
        XCTAssertEqual(bucket.windowDuration, 2_592_000)
        XCTAssertEqual(try XCTUnwrap(bucket.elapsedFraction(now: now)), 1 - 1_771_200.0 / 2_592_000, accuracy: 1e-9)
    }

    func testTheDashboardNamesTheVibeWindowAMonth() {
        let service = Fixture.snapshot(id: "mistral", buckets: MistralBudgetRules.buckets(from: [vibe, api]))
        XCTAssertEqual(LimitsRules.span(of: .weekly, in: service), .month)
    }

    func testAnyOtherBudgetKeyBecomesAWindowOfItsOwnAfterVibeAndAPI() {
        let seats = MistralBudgetEntry(key: "team_seats_budget", usagePercentage: 12)
        let alpha = MistralBudgetEntry(key: "alpha_budget", usagePercentage: 1)
        let buckets = MistralBudgetRules.buckets(from: [seats, api, alpha, vibe])
        XCTAssertEqual(buckets.map(\.id), ["mistral_vibe", "mistral_api", "mistral_alpha", "mistral_team_seats"])
        XCTAssertEqual(buckets.map(\.label), ["Vibe", "API", "Alpha", "Team Seats"])
        XCTAssertEqual(buckets.map(\.kind), [.weekly, .modelSpecific, .modelSpecific, .modelSpecific])
        XCTAssertNil(buckets[3].allowance)
        XCTAssertEqual(buckets[3].resetsAt, .distantFuture)
    }

    func testAKeyThatIsNoBudgetOrNamesNothingIsNoWindow() {
        XCTAssertEqual(MistralBudgetRules.name(forKey: "vibe_budget"), "vibe")
        XCTAssertNil(MistralBudgetRules.name(forKey: "_budget"))
        XCTAssertNil(MistralBudgetRules.name(forKey: "usage_percentage"))
        XCTAssertTrue(MistralBudgetRules.buckets(from: [
            MistralBudgetEntry(key: "_budget", usagePercentage: 5),
            MistralBudgetEntry(key: "usage_percentage", usagePercentage: 0),
        ]).isEmpty)
    }
}
