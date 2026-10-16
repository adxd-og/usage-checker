import XCTest
import CodexBarCore
@testable import Omelette

/// `AntigravityProvider.buckets(from:)`: the one mapping from the probe's reading to the
/// app's buckets (spec 2026-10-16-antigravity-argon § Design: "One pure rule",
/// "Quota-summary path", "Per-model path"). Every payload is an `AntigravityFixture`,
/// the `UsageSnapshot` the probe built from this Mac's 2026-10-16 readings.
final class AntigravityBucketsTests: XCTestCase {
    private typealias F = AntigravityFixture
    private let week: TimeInterval = 604_800
    private let fiveHours: TimeInterval = 18_000

    /// The Ultra payload's four pool windows: CodexBarCore's titles, kind and length
    /// from each window's minutes.
    private var ultraPoolWindows: [UsageBucket] {
        [
            Fixture.bucket(id: "antigravity_antigravity-quota-summary-gemini-5h", label: "Gemini 5-hour", percent: 12.5,
                           resetsAt: F.gemini5hReset, kind: .session, windowLength: fiveHours),
            Fixture.bucket(id: "antigravity_antigravity-quota-summary-gemini-weekly", label: "Gemini weekly", percent: 30,
                           resetsAt: F.geminiWeeklyReset, kind: .weekly, windowLength: week),
            Fixture.bucket(id: "antigravity_antigravity-quota-summary-3p-5h", label: "Claude/GPT 5-hour", percent: 0,
                           resetsAt: F.thirdParty5hReset, kind: .session, windowLength: fiveHours),
            Fixture.bucket(id: "antigravity_antigravity-quota-summary-3p-weekly", label: "Claude/GPT weekly", percent: 4,
                           resetsAt: F.thirdPartyWeeklyReset, kind: .weekly, windowLength: week),
        ]
    }

    // MARK: - Per-model path (spec § Design "Per-model path")

    /// Today's mapping, pinned before the rule changes (spec § Packages 1): the two pool
    /// aggregates, then each model window as CodexBarCore titles it.
    func testThePerModelPathListsThePoolAggregatesThenEveryModelWindow() {
        XCTAssertEqual(AntigravityProvider.buckets(from: F.perModel0750), [
            Fixture.bucket(id: "antigravity_gemini", label: "Gemini models", percent: 0.035733,
                           resetsAt: F.gemini5hReset, kind: .other),
            Fixture.bucket(id: "antigravity_claude_gpt", label: "Claude & GPT models", percent: 0,
                           resetsAt: F.thirdParty5hReset, kind: .other),
            Fixture.bucket(id: "antigravity_MODEL_PLACEHOLDER_M419", label: "Gemini 4 Argon (High)", percent: 6.11776,
                           resetsAt: F.argonWeeklyReset, kind: .other),
            Fixture.bucket(id: "antigravity_MODEL_PLACEHOLDER_M418", label: "Gemini 4 Argon (Medium)", percent: 6.11776,
                           resetsAt: F.argonWeeklyReset, kind: .other),
            Fixture.bucket(id: "antigravity_MODEL_PLACEHOLDER_M417", label: "Gemini 4 Argon (Low)", percent: 6.11776,
                           resetsAt: F.argonWeeklyReset, kind: .other),
        ])
    }

    // MARK: - Quota-summary path (spec § Design "Quota-summary path")

    /// The live Pro payload: Argon reaches the app as a second "Gemini weekly". The four
    /// pool windows stay as CodexBarCore reports them; Argon is a per-model row named
    /// from its stem, its id unchanged so History keeps its line.
    func testAProPayloadShowsTheFourPoolWindowsAndArgonAsItsOwnRow() {
        XCTAssertEqual(AntigravityProvider.buckets(from: F.proSummary), [
            Fixture.bucket(id: "antigravity_antigravity-quota-summary-gemini-5h", label: "Gemini 5-hour", percent: 0.035733,
                           resetsAt: F.gemini5hReset, kind: .session, windowLength: fiveHours),
            Fixture.bucket(id: "antigravity_antigravity-quota-summary-gemini-weekly", label: "Gemini weekly", percent: 0.01021,
                           resetsAt: F.geminiWeeklyReset, kind: .weekly, windowLength: week),
            Fixture.bucket(id: "antigravity_antigravity-quota-summary-gemini-argon-wtu-weekly", label: "Gemini Argon",
                           percent: 44.32, resetsAt: F.argonWeeklyReset, kind: .modelSpecific, windowLength: week),
            Fixture.bucket(id: "antigravity_antigravity-quota-summary-3p-5h", label: "Claude/GPT 5-hour", percent: 0,
                           resetsAt: F.thirdParty5hReset, kind: .session, windowLength: fiveHours),
            Fixture.bucket(id: "antigravity_antigravity-quota-summary-3p-weekly", label: "Claude/GPT weekly", percent: 0,
                           resetsAt: F.thirdPartyWeeklyReset, kind: .weekly, windowLength: week),
        ])
    }

    func testTheSummaryPathEmitsNoAggregates() {
        for usage in [F.proSummary, F.ultraSummary] {
            let ids = AntigravityProvider.buckets(from: usage).map(\.id)
            XCTAssertFalse(ids.contains("antigravity_gemini"), "the aggregate is the worst window of its family, Argon included")
            XCTAssertFalse(ids.contains("antigravity_claude_gpt"))
        }
    }

    /// Ultra plans have no Argon group: the four pool windows and no per-model row.
    func testAnUltraPayloadIsItsFourPoolWindowsAndNoPerModelRow() {
        let buckets = AntigravityProvider.buckets(from: F.ultraSummary)
        XCTAssertEqual(buckets, ultraPoolWindows)
        XCTAssertFalse(buckets.contains { $0.kind == .modelSpecific })
    }

    /// No model table: any stem that is not a pool's is named by the same rule, words
    /// of four letters or more and words with a digit, each with its own length.
    func testAPoolThatAppearsLaterIsNamedFromItsBucketID() {
        let usage = F.usage(primary: nil, secondary: nil, windows: [
            F.summaryWindow(bucketID: "gemini-zinc-weekly", title: "Gemini weekly", percent: 3,
                            minutes: 10080, resetsAt: F.argonWeeklyReset),
            F.summaryWindow(bucketID: "gemini-5-iron-5h", title: "Gemini 5-hour", percent: 1,
                            minutes: 300, resetsAt: F.gemini5hReset),
        ])
        XCTAssertEqual(AntigravityProvider.buckets(from: usage), [
            Fixture.bucket(id: "antigravity_antigravity-quota-summary-gemini-zinc-weekly", label: "Gemini Zinc", percent: 3,
                           resetsAt: F.argonWeeklyReset, kind: .modelSpecific, windowLength: week),
            Fixture.bucket(id: "antigravity_antigravity-quota-summary-gemini-5-iron-5h", label: "Gemini 5 Iron", percent: 1,
                           resetsAt: F.gemini5hReset, kind: .modelSpecific, windowLength: fiveHours),
        ])
    }

    /// A stem whose every word is short wire jargon is named by all of its words, never by
    /// CodexBarCore's title, which names the family rather than the pool (session ruling F4).
    func testAStemWithNoWordToKeepIsNamedByEveryWord() {
        let usage = F.usage(primary: nil, secondary: nil, windows: [
            F.summaryWindow(bucketID: "xp-wtu-weekly", title: "Gemini weekly", percent: 2,
                            minutes: 10080, resetsAt: F.argonWeeklyReset),
        ])
        XCTAssertEqual(AntigravityProvider.buckets(from: usage), [
            Fixture.bucket(id: "antigravity_antigravity-quota-summary-xp-wtu-weekly", label: "Xp Wtu", percent: 2,
                           resetsAt: F.argonWeeklyReset, kind: .modelSpecific, windowLength: week),
        ])
    }

    /// Two per-model pools whose short names would match both keep every word of their
    /// stems, so neither row reads as the other (session ruling F4). One pool's own
    /// 5-hour and weekly windows share a stem: they are one pool and keep the short name.
    func testTwoPerModelPoolsThatWouldShareANameBothKeepEveryWord() {
        let onePool = F.usage(primary: nil, secondary: nil, windows: [
            F.summaryWindow(bucketID: "gemini-argon-wtu-5h", title: "Gemini 5-hour", percent: 1,
                            minutes: 300, resetsAt: F.gemini5hReset),
            F.summaryWindow(bucketID: "gemini-argon-wtu-weekly", title: "Gemini weekly", percent: 2,
                            minutes: 10080, resetsAt: F.argonWeeklyReset),
        ])
        XCTAssertEqual(AntigravityProvider.buckets(from: onePool).map(\.label), ["Gemini Argon", "Gemini Argon"])

        let twoPools = F.usage(primary: nil, secondary: nil, windows: [
            F.summaryWindow(bucketID: "gemini-argon-wtu-weekly", title: "Gemini weekly", percent: 44.32,
                            minutes: 10080, resetsAt: F.argonWeeklyReset),
            F.summaryWindow(bucketID: "gemini-argon-xp-weekly", title: "Gemini weekly", percent: 3,
                            minutes: 10080, resetsAt: F.argonWeeklyReset),
        ])
        XCTAssertEqual(AntigravityProvider.buckets(from: twoPools), [
            Fixture.bucket(id: "antigravity_antigravity-quota-summary-gemini-argon-wtu-weekly", label: "Gemini Argon Wtu",
                           percent: 44.32, resetsAt: F.argonWeeklyReset, kind: .modelSpecific, windowLength: week),
            Fixture.bucket(id: "antigravity_antigravity-quota-summary-gemini-argon-xp-weekly", label: "Gemini Argon Xp",
                           percent: 3, resetsAt: F.argonWeeklyReset, kind: .modelSpecific, windowLength: week),
        ])
    }

    /// A disabled bucket, or one with no remaining fraction, is no reading; the payload is
    /// still a quota summary, so no aggregate comes back with it.
    func testADisabledSummaryWindowIsDroppedAndTheAggregatesStayAway() {
        var windows = F.proSummaryWindows
        windows[2] = F.summaryWindow(bucketID: "gemini-argon-wtu-weekly", title: "Gemini weekly", percent: 0,
                                     minutes: 10080, resetsAt: F.argonWeeklyReset, usageKnown: false)
        let usage = F.usage(primary: windows[0].window, secondary: windows[3].window, windows: windows)
        XCTAssertEqual(AntigravityProvider.buckets(from: usage).map(\.id), [
            "antigravity_antigravity-quota-summary-gemini-5h",
            "antigravity_antigravity-quota-summary-gemini-weekly",
            "antigravity_antigravity-quota-summary-3p-5h",
            "antigravity_antigravity-quota-summary-3p-weekly",
        ])
    }

    /// CodexBarCore reads `_` as `-` when it finds a bucket's cadence; the pools must not
    /// turn into per-model rows if the server ever spells its ids that way.
    func testAPoolIDSpelledWithUnderscoresIsStillAPool() {
        let usage = F.usage(primary: nil, secondary: nil, windows: [
            F.summaryWindow(bucketID: "gemini_weekly", title: "Gemini weekly", percent: 5,
                            minutes: 10080, resetsAt: F.geminiWeeklyReset),
            F.summaryWindow(bucketID: "3p_5h", title: "Claude/GPT 5-hour", percent: 1,
                            minutes: 300, resetsAt: F.thirdParty5hReset),
        ])
        let buckets = AntigravityProvider.buckets(from: usage)
        XCTAssertEqual(buckets.map(\.kind), [.weekly, .session])
        XCTAssertEqual(buckets.map(\.label), ["Gemini weekly", "Claude/GPT 5-hour"])
    }

    /// Spec § Design "What the user sees": while a pool is reported, the menu bar answers
    /// from the four pool windows; the hero and the tile are Gemini 5-hour, Claude/GPT
    /// 5-hour below it.
    func testWhileAPoolIsReportedArgonNeverDrivesTheHeadlineTheHeroOrTheTile() {
        let service = Fixture.snapshot(id: "antigravity", displayName: "Antigravity", plan: "Antigravity Google Ai Pro",
                                       buckets: AntigravityProvider.buckets(from: F.proSummary), at: F.readAt)
        let gemini5h = "antigravity_antigravity-quota-summary-gemini-5h"
        XCTAssertEqual(service.headlinePercent, 0.035733, accuracy: 1e-9)
        XCTAssertEqual(WindowRanking.heroBucket(for: service)?.id, gemini5h)
        XCTAssertEqual(WindowRanking.detailHero(for: service)?.id, gemini5h)
        XCTAssertEqual(WindowRanking.tileHero(for: service)?.id, gemini5h)
        XCTAssertEqual(
            WindowRanking.sessionRows(for: service, hero: WindowRanking.detailHero(for: service)).map(\.label),
            ["Claude/GPT 5-hour"]
        )
    }

    /// The app-wide fallback stays (session ruling F1): a reading with no pool window has
    /// nothing else to answer with, so its per-model pool leads the headline and the hero,
    /// as its own row rather than through an aggregate.
    func testAReadingWithNoPoolWindowLetsItsPerModelPoolLead() {
        let argon = F.proSummaryWindows[2]
        let usage = F.usage(primary: argon.window, secondary: nil, windows: [argon])
        let service = Fixture.snapshot(id: "antigravity", displayName: "Antigravity", plan: "Antigravity Google Ai Pro",
                                       buckets: AntigravityProvider.buckets(from: usage), at: F.readAt)
        XCTAssertEqual(service.headlinePercent, 44.32, accuracy: 1e-9)
        XCTAssertEqual(WindowRanking.heroBucket(for: service)?.id,
                       "antigravity_antigravity-quota-summary-gemini-argon-wtu-weekly")
    }
}
