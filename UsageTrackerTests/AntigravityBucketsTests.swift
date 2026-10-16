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

    /// Today's mapping, pinned before the rule changes (spec § Packages 1): the two
    /// aggregates, then every window by its length.
    func testTheSummaryPathListsThePoolAggregatesThenEveryWindowByItsLength() {
        XCTAssertEqual(AntigravityProvider.buckets(from: F.ultraSummary), [
            Fixture.bucket(id: "antigravity_gemini", label: "Gemini models", percent: 30,
                           resetsAt: F.geminiWeeklyReset, kind: .weekly, windowLength: week),
            Fixture.bucket(id: "antigravity_claude_gpt", label: "Claude & GPT models", percent: 4,
                           resetsAt: F.thirdPartyWeeklyReset, kind: .weekly, windowLength: week),
        ] + ultraPoolWindows)
    }
}
