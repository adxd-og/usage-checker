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

    /// History 07:50:14: the aggregates are built from the pools' own models, so Argon
    /// is not in them; its three effort variants are one row.
    func testThe0750ReadingShowsArgonAsOneRowBesideTheAggregates() {
        XCTAssertEqual(AntigravityProvider.buckets(from: F.perModel0750), [
            Fixture.bucket(id: "antigravity_gemini", label: "Gemini models", percent: 0.035733,
                           resetsAt: F.gemini5hReset, kind: .other),
            Fixture.bucket(id: "antigravity_claude_gpt", label: "Claude & GPT models", percent: 0,
                           resetsAt: F.thirdParty5hReset, kind: .other),
            Fixture.bucket(id: "antigravity_model-gemini-4-argon", label: "Gemini 4 Argon", percent: 6.11776,
                           resetsAt: F.argonWeeklyReset, kind: .modelSpecific),
        ])
    }

    func testTheBusiestVariantGivesTheRowItsPercentAndReset() {
        let highReset = Date(timeIntervalSince1970: 1_792_650_000)
        let mediumReset = Date(timeIntervalSince1970: 1_792_700_000)
        let usage = F.usage(primary: nil, secondary: nil, windows: [
            F.modelWindow(id: "MODEL_PLACEHOLDER_M419", title: "Gemini 4 Argon (High)", percent: 7, resetsAt: highReset),
            F.modelWindow(id: "MODEL_PLACEHOLDER_M418", title: "Gemini 4 Argon (Medium)", percent: 9.5, resetsAt: mediumReset),
            F.modelWindow(id: "MODEL_PLACEHOLDER_M417", title: "Gemini 4 Argon (Low)", percent: 6.12, resetsAt: F.argonWeeklyReset),
        ])
        XCTAssertEqual(AntigravityProvider.buckets(from: usage), [
            Fixture.bucket(id: "antigravity_model-gemini-4-argon", label: "Gemini 4 Argon", percent: 9.5,
                           resetsAt: mediumReset, kind: .modelSpecific),
        ])
    }

    func testTiedVariantsTakeTheFirstListedVariantsReset() {
        let first = Date(timeIntervalSince1970: 1_792_650_000)
        let second = Date(timeIntervalSince1970: 1_792_700_000)
        let usage = F.usage(primary: nil, secondary: nil, windows: [
            F.modelWindow(id: "MODEL_PLACEHOLDER_M419", title: "Gemini 4 Argon (High)", percent: 6.11776, resetsAt: first),
            F.modelWindow(id: "MODEL_PLACEHOLDER_M418", title: "Gemini 4 Argon (Medium)", percent: 6.11776, resetsAt: second),
        ])
        XCTAssertEqual(AntigravityProvider.buckets(from: usage).map(\.resetsAt), [first])
    }

    /// A title without a final parenthesis is its whole name: it merges with nothing that
    /// merely starts the same way.
    func testALoneModelWindowWithoutParenthesesIsItsOwnRow() {
        let usage = F.usage(primary: nil, secondary: nil, windows: [
            F.modelWindow(id: "MODEL_PLACEHOLDER_M420", title: "Gemini 4 Argon", percent: 12.5, resetsAt: F.argonWeeklyReset),
            F.modelWindow(id: "MODEL_PLACEHOLDER_M421", title: "Gemini 4 Argon Lite", percent: 3, resetsAt: F.argonWeeklyReset),
        ])
        XCTAssertEqual(AntigravityProvider.buckets(from: usage), [
            Fixture.bucket(id: "antigravity_model-gemini-4-argon", label: "Gemini 4 Argon", percent: 12.5,
                           resetsAt: F.argonWeeklyReset, kind: .modelSpecific),
            Fixture.bucket(id: "antigravity_model-gemini-4-argon-lite", label: "Gemini 4 Argon Lite", percent: 3,
                           resetsAt: F.argonWeeklyReset, kind: .modelSpecific),
        ])
    }

    /// A bare title that is another group's stem names the same model: it joins that
    /// group, one row at the higher percent of the two (session ruling F3).
    func testABareTitleJoinsTheVariantsOfTheModelItNames() {
        let usage = F.usage(primary: nil, secondary: nil, windows: [
            F.modelWindow(id: "MODEL_PLACEHOLDER_M420", title: "Gemini 4 Argon", percent: 6.12, resetsAt: F.argonWeeklyReset),
            F.modelWindow(id: "MODEL_PLACEHOLDER_M419", title: "Gemini 4 Argon (High)", percent: 12.5, resetsAt: F.geminiWeeklyReset),
        ])
        XCTAssertEqual(AntigravityProvider.buckets(from: usage), [
            Fixture.bucket(id: "antigravity_model-gemini-4-argon", label: "Gemini 4 Argon", percent: 12.5,
                           resetsAt: F.geminiWeeklyReset, kind: .modelSpecific),
        ])
    }

    /// Windows are grouped by the slug their row's id is made of, so two spellings of one
    /// model, differing only in case or punctuation, are one row rather than two rows
    /// sharing an id (session ruling F2). The row keeps the first listed spelling.
    func testTitlesThatDifferOnlyInCaseOrPunctuationAreOneRow() {
        let usage = F.usage(primary: nil, secondary: nil, windows: [
            F.modelWindow(id: "MODEL_PLACEHOLDER_M419", title: "Gemini 4 Argon (High)", percent: 6.12, resetsAt: F.argonWeeklyReset),
            F.modelWindow(id: "MODEL_PLACEHOLDER_M418", title: "gemini-4 argon (Medium)", percent: 9.5, resetsAt: F.argonWeeklyReset),
        ])
        XCTAssertEqual(AntigravityProvider.buckets(from: usage), [
            Fixture.bucket(id: "antigravity_model-gemini-4-argon", label: "Gemini 4 Argon", percent: 9.5,
                           resetsAt: F.argonWeeklyReset, kind: .modelSpecific),
        ])
    }

    /// A title with no letter or digit slugs to nothing: its row keeps the wire id rather
    /// than a bare `antigravity_model-` two such windows would share (session ruling F2).
    func testATitleWithNoLetterOrDigitKeepsItsWireID() {
        let usage = F.usage(primary: nil, secondary: nil, windows: [
            F.modelWindow(id: "MODEL_PLACEHOLDER_M430", title: "—", percent: 2, resetsAt: F.argonWeeklyReset),
            F.modelWindow(id: "MODEL_PLACEHOLDER_M431", title: "(…)", percent: 3, resetsAt: F.argonWeeklyReset),
        ])
        let buckets = AntigravityProvider.buckets(from: usage)
        XCTAssertEqual(buckets.map(\.id), ["antigravity_MODEL_PLACEHOLDER_M430", "antigravity_MODEL_PLACEHOLDER_M431"])
        XCTAssertEqual(buckets.map(\.kind), [.modelSpecific, .modelSpecific])
    }

    /// One reading never carries two buckets with one id, whatever the titles (session
    /// ruling F2): aggregates, variants in several spellings, a bare title, titles with no
    /// letter, and windows with no human name.
    func testEveryBucketIDInAReadingIsUnique() {
        let windows = [
            F.modelWindow(id: "MODEL_PLACEHOLDER_M419", title: "Gemini 4 Argon (High)", percent: 6, resetsAt: F.argonWeeklyReset),
            F.modelWindow(id: "MODEL_PLACEHOLDER_M418", title: "Gemini 4 Argon (Medium)", percent: 6, resetsAt: F.argonWeeklyReset),
            F.modelWindow(id: "MODEL_PLACEHOLDER_M417", title: "gemini 4 argon (Low)", percent: 6, resetsAt: F.argonWeeklyReset),
            F.modelWindow(id: "MODEL_PLACEHOLDER_M420", title: "Gemini 4 Argon", percent: 6, resetsAt: F.argonWeeklyReset),
            F.modelWindow(id: "MODEL_PLACEHOLDER_M421", title: "GEMINI 4 ARGON!", percent: 6, resetsAt: F.argonWeeklyReset),
            F.modelWindow(id: "MODEL_PLACEHOLDER_M430", title: "—", percent: 2, resetsAt: F.argonWeeklyReset),
            F.modelWindow(id: "MODEL_PLACEHOLDER_M431", title: "?!", percent: 2, resetsAt: F.argonWeeklyReset),
            F.modelWindow(id: "MODEL_PLACEHOLDER_M432", title: "MODEL_PLACEHOLDER_M432", percent: 1, resetsAt: F.argonWeeklyReset),
            F.modelWindow(id: "MODEL_PLACEHOLDER_M433", title: "MODEL_PLACEHOLDER_M433", percent: 1, resetsAt: F.argonWeeklyReset),
        ]
        let usage = F.usage(primary: F.perModel0750.primary, secondary: F.perModel0750.secondary, windows: windows)
        let ids = AntigravityProvider.buckets(from: usage).map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate ids in \(ids)")
        XCTAssertEqual(ids.count, 7, "two aggregates, one Argon row, two titles with no letter, two unnamed models")
    }

    /// A window with no human name, its title the wire id or a placeholder, is "Unnamed
    /// model" under its wire id: the codename never reaches a label, and two such windows
    /// stay two rows (session ruling F5).
    func testAWindowWithNoHumanNameIsAnUnnamedModelRow() {
        let usage = F.usage(primary: nil, secondary: nil, windows: [
            F.modelWindow(id: "MODEL_PLACEHOLDER_M419", title: "MODEL_PLACEHOLDER_M419", percent: 6.12, resetsAt: F.argonWeeklyReset),
            F.modelWindow(id: "MODEL_PLACEHOLDER_M418", title: "model_placeholder_m418", percent: 3, resetsAt: F.argonWeeklyReset),
            F.modelWindow(id: "m-417", title: "Model Placeholder (Low)", percent: 1, resetsAt: F.argonWeeklyReset),
        ])
        let buckets = AntigravityProvider.buckets(from: usage)
        XCTAssertEqual(buckets, [
            Fixture.bucket(id: "antigravity_MODEL_PLACEHOLDER_M419", label: "Unnamed model", percent: 6.12,
                           resetsAt: F.argonWeeklyReset, kind: .modelSpecific),
            Fixture.bucket(id: "antigravity_MODEL_PLACEHOLDER_M418", label: "Unnamed model", percent: 3,
                           resetsAt: F.argonWeeklyReset, kind: .modelSpecific),
            Fixture.bucket(id: "antigravity_m-417", label: "Unnamed model", percent: 1,
                           resetsAt: F.argonWeeklyReset, kind: .modelSpecific),
        ])
        XCTAssertFalse(buckets.contains { $0.label.lowercased().contains("placeholder") })
    }

    /// The variant is the trailing balanced parenthesis, nested ones included; a title
    /// whose parenthesis never closes is its whole name (session ruling F6).
    func testTheVariantIsTheTrailingBalancedParenthesis() {
        let usage = F.usage(primary: nil, secondary: nil, windows: [
            F.modelWindow(id: "MODEL_PLACEHOLDER_M440", title: "Argon (Fast (High))", percent: 4, resetsAt: F.argonWeeklyReset),
            F.modelWindow(id: "MODEL_PLACEHOLDER_M441", title: "Argon (Fast (Low))", percent: 2, resetsAt: F.argonWeeklyReset),
            F.modelWindow(id: "MODEL_PLACEHOLDER_M442", title: "Argon (High", percent: 1, resetsAt: F.argonWeeklyReset),
        ])
        XCTAssertEqual(AntigravityProvider.buckets(from: usage), [
            Fixture.bucket(id: "antigravity_model-argon", label: "Argon", percent: 4,
                           resetsAt: F.argonWeeklyReset, kind: .modelSpecific),
            Fixture.bucket(id: "antigravity_model-argon-high", label: "Argon (High", percent: 1,
                           resetsAt: F.argonWeeklyReset, kind: .modelSpecific),
        ])
    }

    /// The probe lists a pool whose models report a reset but no usage as a reset-only
    /// window (`usageKnown: false`, 100% used); it stays out, as today.
    func testAResetOnlyPoolWindowStaysOutAsToday() {
        let resetOnly = F.modelWindow(id: "antigravity-gemini", title: "Gemini Models", percent: 100,
                                      resetsAt: F.gemini5hReset, usageKnown: false)
        let usage = F.usage(primary: nil, secondary: F.perModel0750.secondary, windows: [resetOnly])
        XCTAssertEqual(AntigravityProvider.buckets(from: usage), [
            Fixture.bucket(id: "antigravity_claude_gpt", label: "Claude & GPT models", percent: 0,
                           resetsAt: F.thirdParty5hReset, kind: .other),
        ])
    }

    /// Should a server ever report usage on a pool window, it keeps today's mapping: a
    /// pool, never a per-model row.
    func testAPoolWindowWithUsageKeepsTodaysMapping() {
        let pool = F.modelWindow(id: "antigravity-claude-gpt", title: "Claude and GPT models", percent: 8,
                                 resetsAt: F.thirdParty5hReset)
        XCTAssertEqual(AntigravityProvider.buckets(from: F.usage(primary: nil, secondary: nil, windows: [pool])), [
            Fixture.bucket(id: "antigravity_antigravity-claude-gpt", label: "Claude and GPT models", percent: 8,
                           resetsAt: F.thirdParty5hReset, kind: .other),
        ])
    }

    /// The compact fallback stands in when no pool is reported; it keeps its title, its
    /// id and `.other`, so it still leads the headline.
    func testTheCompactFallbackWindowKeepsTodaysMapping() {
        let fallback = F.modelWindow(id: "antigravity-compact-fallback-MODEL_PLACEHOLDER_M419", title: "Gemini 4 Argon (High)",
                                     percent: 6.11776, resetsAt: F.argonWeeklyReset)
        XCTAssertEqual(AntigravityProvider.buckets(from: F.usage(primary: nil, secondary: nil, windows: [fallback])), [
            Fixture.bucket(id: "antigravity_antigravity-compact-fallback-MODEL_PLACEHOLDER_M419", label: "Gemini 4 Argon (High)",
                           percent: 6.11776, resetsAt: F.argonWeeklyReset, kind: .other),
        ])
    }

    /// History 08:02:22: Argon's variants at 47%, the Gemini pool at 0.04%. On Ultra the
    /// per-model path may still list Argon (spec § Design, known limitation): while a pool
    /// is reported, a per-model row never drives the headline.
    func testWhileAPoolIsReportedPerModelRowsNeverDriveTheHeadline() {
        let service = Fixture.snapshot(id: "antigravity", displayName: "Antigravity", plan: "Antigravity Google Ai Pro",
                                       buckets: AntigravityProvider.buckets(from: F.perModel0802), at: F.readAt)
        XCTAssertEqual(service.headlinePercent, 0.035733, accuracy: 1e-9)
        XCTAssertEqual(WindowRanking.heroBucket(for: service)?.id, "antigravity_gemini")
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
