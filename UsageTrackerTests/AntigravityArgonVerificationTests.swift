import XCTest
import CodexBarCore
@testable import Omelette

/// Independent verification of spec 2026-10-16-antigravity-argon § Design (one pure rule,
/// quota-summary path, per-model path) and § Packages "One package" items 1-5. Inputs are
/// built here from CodexBarCore's public initialisers, as the probe would hand them to
/// `AntigravityProvider.buckets(from:)`; none of the executor's fixtures are used.
final class AntigravityArgonVerificationTests: XCTestCase {
    private let week: TimeInterval = 604_800
    private let fiveHours: TimeInterval = 18_000
    private let sumPrefix = "antigravity_antigravity-quota-summary-"

    private let reset5h = Date(timeIntervalSince1970: 1_792_154_766)
    private let resetWeek = Date(timeIntervalSince1970: 1_792_741_566)
    private let resetArgon = Date(timeIntervalSince1970: 1_792_741_544)
    private let reset3p5h = Date(timeIntervalSince1970: 1_792_155_983)
    private let reset3pWeek = Date(timeIntervalSince1970: 1_792_742_783)
    private let readAt = Date(timeIntervalSince1970: 1_792_137_014)

    // MARK: - Builders

    private func summary(_ bucketID: String, _ title: String, _ percent: Double, minutes: Int?,
                         reset: Date?, known: Bool = true) -> NamedRateWindow {
        NamedRateWindow(
            id: "antigravity-quota-summary-" + bucketID,
            title: title,
            window: RateWindow(usedPercent: percent, windowMinutes: minutes, resetsAt: reset, resetDescription: nil),
            usageKnown: known
        )
    }

    private func model(_ id: String, _ title: String, _ percent: Double, reset: Date? = nil,
                       known: Bool = true) -> NamedRateWindow {
        NamedRateWindow(
            id: id,
            title: title,
            window: RateWindow(usedPercent: percent, windowMinutes: nil, resetsAt: reset ?? resetArgon, resetDescription: nil),
            usageKnown: known
        )
    }

    private func usage(primary: RateWindow? = nil, secondary: RateWindow? = nil,
                       _ windows: [NamedRateWindow]) -> CodexBarCore.UsageSnapshot {
        CodexBarCore.UsageSnapshot(
            primary: primary, secondary: secondary, tertiary: nil,
            extraRateWindows: windows.isEmpty ? nil : windows, updatedAt: readAt
        )
    }

    /// Live Pro payload, 2026-10-16: three groups; CodexBarCore titles Argon's weekly "Gemini weekly".
    private var proWindows: [NamedRateWindow] {
        [
            summary("gemini-5h", "Gemini 5-hour", 0.035733, minutes: 300, reset: reset5h),
            summary("gemini-weekly", "Gemini weekly", 0.01021, minutes: 10080, reset: resetWeek),
            summary("gemini-argon-wtu-weekly", "Gemini weekly", 44.32, minutes: 10080, reset: resetArgon),
            summary("3p-5h", "Claude/GPT 5-hour", 0, minutes: 300, reset: reset3p5h),
            summary("3p-weekly", "Claude/GPT weekly", 0, minutes: 10080, reset: reset3pWeek),
        ]
    }

    /// `primary` = worst gemini-titled window (Argon's), `secondary` = worst Claude/GPT one.
    private var pro: CodexBarCore.UsageSnapshot {
        let w = proWindows
        return usage(primary: w[2].window, secondary: w[3].window, w)
    }

    private var ultra: CodexBarCore.UsageSnapshot {
        let w = [
            summary("gemini-5h", "Gemini 5-hour", 12.5, minutes: 300, reset: reset5h),
            summary("gemini-weekly", "Gemini weekly", 30, minutes: 10080, reset: resetWeek),
            summary("3p-5h", "Claude/GPT 5-hour", 0, minutes: 300, reset: reset3p5h),
            summary("3p-weekly", "Claude/GPT weekly", 4, minutes: 10080, reset: reset3pWeek),
        ]
        return usage(primary: w[1].window, secondary: w[3].window, w)
    }

    private func perModel(_ percent: Double, extra: [NamedRateWindow] = []) -> CodexBarCore.UsageSnapshot {
        usage(
            primary: RateWindow(usedPercent: 0.035733, windowMinutes: nil, resetsAt: reset5h, resetDescription: nil),
            secondary: RateWindow(usedPercent: 0, windowMinutes: nil, resetsAt: reset3p5h, resetDescription: nil),
            [
                model("MODEL_PLACEHOLDER_M419", "Gemini 4 Argon (High)", percent),
                model("MODEL_PLACEHOLDER_M418", "Gemini 4 Argon (Medium)", percent),
                model("MODEL_PLACEHOLDER_M417", "Gemini 4 Argon (Low)", percent),
            ] + extra
        )
    }

    private func service(_ buckets: [UsageBucket]) -> ServiceSnapshot {
        Fixture.snapshot(id: "antigravity", displayName: "Antigravity", plan: "Antigravity Google Ai Pro",
                         buckets: buckets, at: readAt)
    }

    private func build(_ u: CodexBarCore.UsageSnapshot) -> [UsageBucket] {
        AntigravityProvider.buckets(from: u)
    }

    // MARK: - Quota-summary path

    func testProPayloadIsFourPoolWindowsPlusArgonAsAPerModelRowInProbeOrder() {
        XCTAssertEqual(build(pro), [
            Fixture.bucket(id: sumPrefix + "gemini-5h", label: "Gemini 5-hour", percent: 0.035733,
                           resetsAt: reset5h, kind: .session, windowLength: fiveHours),
            Fixture.bucket(id: sumPrefix + "gemini-weekly", label: "Gemini weekly", percent: 0.01021,
                           resetsAt: resetWeek, kind: .weekly, windowLength: week),
            Fixture.bucket(id: sumPrefix + "gemini-argon-wtu-weekly", label: "Gemini Argon", percent: 44.32,
                           resetsAt: resetArgon, kind: .modelSpecific, windowLength: week),
            Fixture.bucket(id: sumPrefix + "3p-5h", label: "Claude/GPT 5-hour", percent: 0,
                           resetsAt: reset3p5h, kind: .session, windowLength: fiveHours),
            Fixture.bucket(id: sumPrefix + "3p-weekly", label: "Claude/GPT weekly", percent: 0,
                           resetsAt: reset3pWeek, kind: .weekly, windowLength: week),
        ])
    }

    func testNoAggregateIsEmittedOnTheSummaryPathEvenWhenPrimaryAndSecondaryArePresent() {
        for u in [pro, ultra] {
            let ids = build(u).map(\.id)
            XCTAssertFalse(ids.contains("antigravity_gemini"), "\(ids)")
            XCTAssertFalse(ids.contains("antigravity_claude_gpt"), "\(ids)")
        }
    }

    func testUltraIsExactlyTheFourPoolWindowsAndNoPerModelRow() {
        let b = build(ultra)
        XCTAssertEqual(b.map(\.id), ["gemini-5h", "gemini-weekly", "3p-5h", "3p-weekly"].map { sumPrefix + $0 })
        XCTAssertEqual(b.map(\.kind), [.session, .weekly, .session, .weekly])
        XCTAssertEqual(b.map(\.label), ["Gemini 5-hour", "Gemini weekly", "Claude/GPT 5-hour", "Claude/GPT weekly"])
        XCTAssertEqual(b.map(\.utilization), [12.5, 30, 0, 4])
        XCTAssertFalse(b.contains { $0.kind == .modelSpecific })
    }

    func testOneSummaryWindowIsEnoughToTakeTheSummaryPath() {
        let u = usage(
            primary: RateWindow(usedPercent: 9, windowMinutes: nil, resetsAt: reset5h, resetDescription: nil),
            secondary: RateWindow(usedPercent: 9, windowMinutes: nil, resetsAt: reset5h, resetDescription: nil),
            [summary("3p-weekly", "Claude/GPT weekly", 1, minutes: 10080, reset: reset3pWeek)]
        )
        XCTAssertEqual(build(u).map(\.id), [sumPrefix + "3p-weekly"])
    }

    func testAFuturePerModelPoolIsNamedFromItsStemWithItsOwnWindowLength() {
        let u = usage([
            summary("gemini-zinc-weekly", "Gemini weekly", 3, minutes: 10080, reset: resetArgon),
            summary("gemini-zinc-5h", "Gemini 5-hour", 1, minutes: 300, reset: reset5h),
        ])
        XCTAssertEqual(build(u), [
            Fixture.bucket(id: sumPrefix + "gemini-zinc-weekly", label: "Gemini Zinc", percent: 3,
                           resetsAt: resetArgon, kind: .modelSpecific, windowLength: week),
            Fixture.bucket(id: sumPrefix + "gemini-zinc-5h", label: "Gemini Zinc", percent: 1,
                           resetsAt: reset5h, kind: .modelSpecific, windowLength: fiveHours),
        ])
    }

    func testWordsWithADigitAreKeptWhateverTheirLengthAndShortWordsWithoutOneAreDropped() {
        let u = usage([
            summary("gemini-4-argon-wtu-weekly", "Gemini weekly", 1, minutes: 10080, reset: resetArgon),
            summary("ab1-cd-flash-weekly", "Gemini weekly", 2, minutes: 10080, reset: resetArgon),
        ])
        XCTAssertEqual(build(u).map(\.label), ["Gemini 4 Argon", "Ab1 Flash"])
    }

    func testAStemWithNoWordToKeepIsNamedByEveryWordNeverByTheFlattenedTitle() {
        for cadence in ["weekly", "5h"] {
            let u = usage([summary("xp-wtu-" + cadence, "Gemini weekly", 2, minutes: cadence == "5h" ? 300 : 10080, reset: resetArgon)])
            let b = build(u)
            XCTAssertEqual(b.map(\.label), ["Xp Wtu"], cadence)
            XCTAssertEqual(b.map(\.kind), [.modelSpecific])
        }
    }

    func testTwoPerModelPoolsWithTheSameShortLabelBothUseEveryStemWord() {
        let u = usage([
            summary("gemini-argon-wtu-weekly", "Gemini weekly", 44, minutes: 10080, reset: resetArgon),
            summary("gemini-argon-xp-weekly", "Gemini weekly", 3, minutes: 10080, reset: resetArgon),
        ])
        XCTAssertEqual(build(u).map(\.label), ["Gemini Argon Wtu", "Gemini Argon Xp"])
    }

    func testTwoPerModelPoolsWithDifferentShortLabelsKeepTheShortLabels() {
        let u = usage([
            summary("gemini-argon-wtu-weekly", "Gemini weekly", 44, minutes: 10080, reset: resetArgon),
            summary("gemini-zinc-wtu-weekly", "Gemini weekly", 3, minutes: 10080, reset: resetArgon),
        ])
        XCTAssertEqual(build(u).map(\.label), ["Gemini Argon", "Gemini Zinc"])
    }

    func testOnePoolsFiveHourAndWeeklyWindowsDoNotCountAsACollision() {
        let u = usage([
            summary("gemini-argon-wtu-5h", "Gemini 5-hour", 1, minutes: 300, reset: reset5h),
            summary("gemini-argon-wtu-weekly", "Gemini weekly", 2, minutes: 10080, reset: resetArgon),
        ])
        XCTAssertEqual(build(u).map(\.label), ["Gemini Argon", "Gemini Argon"])
    }

    func testAStemWithoutACadenceSuffixIsStillAPerModelPoolAndAPoolStemStillAPool() {
        let u = usage([
            summary("gemini", "Gemini weekly", 5, minutes: 10080, reset: resetWeek),
            summary("3p", "Claude/GPT weekly", 6, minutes: 10080, reset: reset3pWeek),
            summary("gemini-argon-wtu", "Gemini weekly", 7, minutes: 10080, reset: resetArgon),
        ])
        let b = build(u)
        XCTAssertEqual(b.map(\.kind), [.weekly, .weekly, .modelSpecific])
        XCTAssertEqual(b.map(\.label), ["Gemini weekly", "Claude/GPT weekly", "Gemini Argon"])
    }

    func testAPoolStemIsNotAPrefixMatch() {
        // "gemini-flash" starts with the pool stem but is a different stem: a per-model pool.
        let u = usage([summary("gemini-flash-weekly", "Gemini weekly", 5, minutes: 10080, reset: resetWeek)])
        XCTAssertEqual(build(u).map(\.kind), [.modelSpecific])
        XCTAssertEqual(build(u).map(\.label), ["Gemini Flash"])
    }

    func testADisabledPerModelWindowIsDroppedButStillMarksTheReadingAsASummary() {
        var w = proWindows
        w[2] = summary("gemini-argon-wtu-weekly", "Gemini weekly", 0, minutes: 10080, reset: resetArgon, known: false)
        let b = build(usage(primary: w[0].window, secondary: w[3].window, w))
        XCTAssertEqual(b.count, 4)
        XCTAssertFalse(b.contains { $0.kind == .modelSpecific })
        XCTAssertFalse(b.map(\.id).contains("antigravity_gemini"))
    }

    /// The path is chosen by the window ids ("at least one extra window id passes
    /// isQuotaSummaryWindowID"), not by which of them carry a reading: a summary window with
    /// no remaining fraction still makes the reading a quota summary, so no aggregate returns.
    func testAReadingWhoseOnlySummaryWindowHasNoUsageStillTakesTheSummaryPath() {
        let u = usage(
            primary: RateWindow(usedPercent: 9, windowMinutes: nil, resetsAt: reset5h, resetDescription: nil),
            secondary: RateWindow(usedPercent: 9, windowMinutes: nil, resetsAt: reset5h, resetDescription: nil),
            [summary("gemini-argon-wtu-weekly", "Gemini weekly", 0, minutes: 10080, reset: resetArgon, known: false)]
        )
        XCTAssertEqual(build(u), [])
    }

    func testAMissingResetBecomesDistantFutureOnAPerModelPool() {
        let u = usage([summary("gemini-zinc-weekly", "Gemini weekly", 3, minutes: 10080, reset: nil)])
        XCTAssertEqual(build(u).first?.resetsAt, .distantFuture)
    }

    // MARK: - End-to-end effects of the Pro payload

    func testProHeadlineHeroTileSessionRowsAndSecondaryIgnoreArgon() {
        let s = service(build(pro))
        let g5 = sumPrefix + "gemini-5h"
        XCTAssertEqual(s.headlinePercent, 0.035733, accuracy: 1e-9)
        XCTAssertEqual(WindowRanking.heroBucket(for: s)?.id, g5)
        XCTAssertEqual(WindowRanking.detailHero(for: s)?.id, g5)
        XCTAssertEqual(WindowRanking.tileHero(for: s)?.id, g5)
        XCTAssertEqual(WindowRanking.sessionRows(for: s, hero: WindowRanking.detailHero(for: s)).map(\.label),
                       ["Claude/GPT 5-hour"])
        XCTAssertEqual(WindowRanking.secondaryBucket(for: s)?.id, sumPrefix + "gemini-weekly")
        XCTAssertNotEqual(WindowRanking.secondaryBucket(for: s)?.label, "Gemini Argon")
    }

    func testProAlertsWatchTheFourPoolWindowsOnly() {
        let watched = UsageNotifier.watchableBuckets(for: service(build(pro))).map(\.id)
        XCTAssertEqual(watched, ["gemini-5h", "gemini-weekly", "3p-5h", "3p-weekly"].map { sumPrefix + $0 })
    }

    func testProHeadlineWouldHaveBeenArgonsWithoutTheFix() {
        // Sanity of the fixture: Argon's 44.32 % must be the largest number in the reading.
        let b = build(pro)
        XCTAssertEqual(b.map(\.utilization).max(), 44.32)
        XCTAssertLessThan(service(b).headlinePercent, 1)
    }

    func testUltraHeadlineIsTheWorstPoolWindow() {
        let s = service(build(ultra))
        XCTAssertEqual(s.headlinePercent, 30, accuracy: 1e-9)
        XCTAssertEqual(WindowRanking.heroBucket(for: s)?.id, sumPrefix + "gemini-weekly")
        XCTAssertEqual(WindowRanking.detailHero(for: s)?.id, sumPrefix + "gemini-5h")
    }

    func testAReadingWithNoPoolWindowLetsItsPerModelPoolLeadAsTheLastResort() {
        let a = proWindows[2]
        let s = service(build(usage(primary: a.window, [a])))
        XCTAssertEqual(s.headlinePercent, 44.32, accuracy: 1e-9)
    }

    // MARK: - Per-model path

    func testThe0750ReadingIsTheTwoAggregatesAndOneArgonRow() {
        XCTAssertEqual(build(perModel(6.11776)), [
            Fixture.bucket(id: "antigravity_gemini", label: "Gemini models", percent: 0.035733,
                           resetsAt: reset5h, kind: .other),
            Fixture.bucket(id: "antigravity_claude_gpt", label: "Claude & GPT models", percent: 0,
                           resetsAt: reset3p5h, kind: .other),
            Fixture.bucket(id: "antigravity_model-gemini-4-argon", label: "Gemini 4 Argon", percent: 6.11776,
                           resetsAt: resetArgon, kind: .modelSpecific),
        ])
    }

    func testPerModelHeadlineAndHeroFollowTheAggregatesNotArgon() {
        let s = service(build(perModel(47.443414)))
        XCTAssertEqual(s.headlinePercent, 0.035733, accuracy: 1e-9)
        XCTAssertEqual(WindowRanking.heroBucket(for: s)?.id, "antigravity_gemini")
        XCTAssertEqual(UsageNotifier.watchableBuckets(for: s).map(\.id), ["antigravity_gemini", "antigravity_claude_gpt"])
    }

    func testTheCollapsedRowTakesTheHighestVariantsPercentAndThatVariantsReset() {
        let r1 = Date(timeIntervalSince1970: 1_792_650_000)
        let r2 = Date(timeIntervalSince1970: 1_792_700_000)
        let r3 = Date(timeIntervalSince1970: 1_792_750_000)
        let u = usage([
            model("MODEL_PLACEHOLDER_M419", "Gemini 4 Argon (High)", 7, reset: r1),
            model("MODEL_PLACEHOLDER_M418", "Gemini 4 Argon (Medium)", 9.5, reset: r2),
            model("MODEL_PLACEHOLDER_M417", "Gemini 4 Argon (Low)", 6.12, reset: r3),
        ])
        let b = build(u)
        XCTAssertEqual(b.count, 1)
        XCTAssertEqual(b[0].utilization, 9.5)
        XCTAssertEqual(b[0].resetsAt, r2)
        XCTAssertEqual(b[0].label, "Gemini 4 Argon")
        XCTAssertEqual(b[0].id, "antigravity_model-gemini-4-argon")
        XCTAssertEqual(b[0].kind, .modelSpecific)
    }

    func testAnyTextInTheFinalParenthesesIsTheVariant() {
        let u = usage([
            model("a", "Gemini 4 Argon (Thinking, 1M)", 3),
            model("b", "Gemini 4 Argon (Fast)", 5),
        ])
        let b = build(u)
        XCTAssertEqual(b.map(\.label), ["Gemini 4 Argon"])
        XCTAssertEqual(b.map(\.utilization), [5])
    }

    func testOnlyTheFinalParenthesisIsRemovedAndAMidTitleOneStays() {
        let u = usage([
            model("a", "Gemini (Preview) Pro", 3),
            model("b", "Argon (Low) (High)", 4),
        ])
        let b = build(u)
        XCTAssertEqual(b.map(\.label), ["Gemini (Preview) Pro", "Argon (Low)"])
        XCTAssertEqual(b.map(\.id), ["antigravity_model-gemini-preview-pro", "antigravity_model-argon-low"])
    }

    func testABareTitleThatIsAnotherGroupsStemJoinsThatGroupWhateverTheOrder() {
        for bareFirst in [true, false] {
            var w = [
                model("a", "Gemini 4 Argon (High)", 12.5),
                model("b", "Gemini 4 Argon (Low)", 2),
            ]
            let bare = model("c", "Gemini 4 Argon", 6.12)
            if bareFirst { w.insert(bare, at: 0) } else { w.append(bare) }
            let b = build(usage(w))
            XCTAssertEqual(b.map(\.id), ["antigravity_model-gemini-4-argon"], "bareFirst=\(bareFirst)")
            XCTAssertEqual(b.map(\.utilization), [12.5], "bareFirst=\(bareFirst)")
        }
    }

    func testALoneBareTitleIsItsOwnRowAndASuperstringTitleIsNotMerged() {
        let b = build(usage([
            model("a", "Gemini 4 Argon", 12.5),
            model("b", "Gemini 4 Argon Lite", 3),
        ]))
        XCTAssertEqual(b.map(\.label), ["Gemini 4 Argon", "Gemini 4 Argon Lite"])
        XCTAssertEqual(b.map(\.kind), [.modelSpecific, .modelSpecific])
    }

    func testTheRowIDIsStableAcrossPollsWhateverTheWireIDsAndOrder() {
        let first = build(usage([
            model("MODEL_PLACEHOLDER_M419", "Gemini 4 Argon (High)", 1),
            model("MODEL_PLACEHOLDER_M418", "Gemini 4 Argon (Medium)", 2),
        ]))
        let second = build(usage([
            model("MODEL_PLACEHOLDER_M500", "Gemini 4 Argon (Low)", 1),
            model("MODEL_PLACEHOLDER_M501", "Gemini 4 Argon (High)", 2),
        ]))
        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertEqual(first.map(\.id), ["antigravity_model-gemini-4-argon"])
    }

    func testNamesDifferingOnlyInCaseOrPunctuationAreOneRow() {
        let b = build(usage([
            model("a", "Gemini 4 Argon (High)", 1),
            model("b", "GEMINI-4 argon! (Low)", 2),
        ]))
        XCTAssertEqual(b.count, 1)
        XCTAssertEqual(b.first?.id, "antigravity_model-gemini-4-argon")
        XCTAssertEqual(b.first?.utilization, 2)
    }

    func testAnEmptySlugKeepsTheWireIDAndNeverProducesABareModelPrefix() {
        let b = build(usage([model("w1", "—", 2), model("w2", "(…)", 3)]))
        XCTAssertEqual(b.map(\.id), ["antigravity_w1", "antigravity_w2"])
        XCTAssertFalse(b.map(\.id).contains("antigravity_model-"))
    }

    func testAWindowWithNoHumanNameIsUnnamedModelUnderItsWireIDAndNeverCollapses() {
        let b = build(usage([
            model("MODEL_PLACEHOLDER_M419", "MODEL_PLACEHOLDER_M419", 6),
            model("MODEL_PLACEHOLDER_M418", "model_placeholder_m418", 5),
            model("gemini-9-pro", "gemini-9-pro", 4),
            model("m-1", "Model PLACEHOLDER 7 (Low)", 3),
            model("m-2", "  MODEL_PLACEHOLDER_X  ", 2),
        ]))
        XCTAssertEqual(b.map(\.label), Array(repeating: "Unnamed model", count: 5))
        XCTAssertEqual(b.map(\.id), ["MODEL_PLACEHOLDER_M419", "MODEL_PLACEHOLDER_M418", "gemini-9-pro", "m-1", "m-2"].map { "antigravity_" + $0 })
        XCTAssertEqual(b.map(\.kind), Array(repeating: .modelSpecific, count: 5))
    }

    func testAPlaceholderTitleDoesNotJoinANamedGroup() {
        let b = build(usage([
            model("a", "Gemini 4 Argon (High)", 1),
            model("MODEL_PLACEHOLDER_M9", "MODEL_PLACEHOLDER_M9", 50),
        ]))
        XCTAssertEqual(b.map(\.label), ["Gemini 4 Argon", "Unnamed model"])
        XCTAssertEqual(b.map(\.utilization), [1, 50])
    }

    func testUnbalancedParenthesesLeaveTheTitleWhole() {
        let b = build(usage([
            model("a", "Argon (High", 1),
            model("b", "Argon Foo)", 2),
            model("c", "Argon (Fast (High))", 3),
            model("d", "Argon (Fast (Low))", 4),
        ]))
        XCTAssertEqual(b.map(\.label), ["Argon (High", "Argon Foo)", "Argon"])
        XCTAssertEqual(b.last?.utilization, 4)
    }

    func testAPerModelWindowWithNoUsageIsDropped() {
        let b = build(usage([
            model("a", "Gemini 4 Argon (High)", 100, known: false),
            model("antigravity-gemini", "Gemini Models", 100, known: false),
        ]))
        XCTAssertEqual(b, [])
    }

    func testResetOnlyPoolAndCompactFallbackWindowsKeepTodaysMapping() {
        let fallback = model("antigravity-compact-fallback-MODEL_PLACEHOLDER_M419", "Gemini 4 Argon (High)", 6.11776)
        let pool = model("antigravity-claude-gpt", "Claude and GPT models", 8)
        let b = build(usage([pool, fallback]))
        XCTAssertEqual(b, [
            Fixture.bucket(id: "antigravity_antigravity-claude-gpt", label: "Claude and GPT models", percent: 8,
                           resetsAt: resetArgon, kind: .other),
            Fixture.bucket(id: "antigravity_antigravity-compact-fallback-MODEL_PLACEHOLDER_M419",
                           label: "Gemini 4 Argon (High)", percent: 6.11776, resetsAt: resetArgon, kind: .other),
        ])
    }

    func testTheCompactFallbackStillLeadsTheHeadlineWhenNoPoolIsReported() {
        let fallback = model("antigravity-compact-fallback-MODEL_PLACEHOLDER_M419", "Gemini 4 Argon (High)", 6.11776)
        let s = service(build(usage([fallback])))
        XCTAssertEqual(s.headlinePercent, 6.11776, accuracy: 1e-9)
    }

    func testOnlyAggregatesWhenThereAreNoNamedWindows() {
        let u = usage(
            primary: RateWindow(usedPercent: 12, windowMinutes: 300, resetsAt: reset5h, resetDescription: nil),
            secondary: RateWindow(usedPercent: 3, windowMinutes: 10080, resetsAt: reset3pWeek, resetDescription: nil),
            []
        )
        XCTAssertEqual(build(u), [
            Fixture.bucket(id: "antigravity_gemini", label: "Gemini models", percent: 12, resetsAt: reset5h,
                           kind: .session, windowLength: fiveHours),
            Fixture.bucket(id: "antigravity_claude_gpt", label: "Claude & GPT models", percent: 3, resetsAt: reset3pWeek,
                           kind: .weekly, windowLength: week),
        ])
    }

    func testAnEmptyReadingIsNoBuckets() {
        XCTAssertEqual(build(usage([])), [])
    }

    // MARK: - No codename and no empty label anywhere

    func testNoCodenameAndNoEmptyLabelReachesABucketOnEitherPath() {
        let readings: [CodexBarCore.UsageSnapshot] = [
            pro, ultra, perModel(6.1),
            usage([
                model("MODEL_PLACEHOLDER_M1", "MODEL_PLACEHOLDER_M1", 1),
                model("MODEL_PLACEHOLDER_M2", "Gemini 4 Argon (Low)", 2),
                model("MODEL_PLACEHOLDER_M3", "model placeholder", 3),
            ]),
            usage([summary("xp-wtu-weekly", "Gemini weekly", 1, minutes: 10080, reset: resetArgon)]),
        ]
        for r in readings {
            for b in build(r) {
                XCTAssertFalse(b.label.trimmingCharacters(in: .whitespaces).isEmpty, "empty label on \(b.id)")
                XCTAssertFalse(b.label.lowercased().contains("placeholder"), "codename in label \(b.label)")
                if b.kind == .modelSpecific, !b.id.contains("quota-summary") {
                    XCTAssertFalse(b.id.contains("PLACEHOLDER") && b.label != "Unnamed model", "\(b.id) / \(b.label)")
                }
            }
        }
    }

    func testAWindowWhoseTitleIsEmptyOrBlankNeverGetsAnEmptyLabel() {
        let b = build(usage([
            model("MODEL_PLACEHOLDER_M7", "", 2),
            model("MODEL_PLACEHOLDER_M8", "   ", 3),
        ]))
        for bucket in b {
            XCTAssertFalse(bucket.label.trimmingCharacters(in: .whitespaces).isEmpty,
                           "empty label for \(bucket.id): a window with no human name must read \"Unnamed model\"")
        }
    }

    func testEveryIDInAMixedReadingIsUniqueOnBothPaths() {
        let mixed = usage(
            primary: RateWindow(usedPercent: 1, windowMinutes: nil, resetsAt: reset5h, resetDescription: nil),
            secondary: RateWindow(usedPercent: 1, windowMinutes: nil, resetsAt: reset5h, resetDescription: nil),
            [
                model("w1", "Gemini 4 Argon (High)", 1),
                model("w2", "gemini 4 argon (Low)", 2),
                model("w3", "Gemini 4 Argon", 3),
                model("w4", "—", 1),
                model("w5", "?!", 1),
                model("w6", "w6", 1),
                model("w7", "w7", 1),
            ]
        )
        for r in [mixed, pro, ultra] {
            let ids = build(r).map(\.id)
            XCTAssertEqual(ids.count, Set(ids).count, "\(ids)")
        }
    }
}
