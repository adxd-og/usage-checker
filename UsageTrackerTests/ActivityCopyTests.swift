import XCTest
@testable import Omelette

/// The caption under Dashboard → Activity's cost cards.
/// Spec: docs/superpowers/specs/2026-09-17-activity-year-retention-design.md
/// § Note under the cards.
final class ActivityCopyTests: XCTestCase {
    /// Claude Code deletes transcripts after 30 days unless the user says otherwise,
    /// so a Claude year can be three quarters empty through nobody's fault. The
    /// caption names the setting that fixes it.
    func testClaudeCarriesTheTranscriptCleanupNote() {
        XCTAssertEqual(
            ActivityCopy.retentionNote(provider: "claude"),
            "Claude Code deletes local transcripts after 30 days by default. " +
            "Set cleanupPeriodDays in ~/.claude/settings.json to keep a year."
        )
    }

    /// Codex and the Grok CLI document no cleanup of their own: a warning about
    /// something that does not happen is noise. Neither does a provider with no cost
    /// grid at all.
    func testAProviderThatKeepsItsLogsCarriesNoNote() {
        for provider in ["codex", "grok", "gemini", "antigravity", ""] {
            XCTAssertNil(ActivityCopy.retentionNote(provider: provider), provider)
        }
    }

    /// Quota squares are percentages out of Omelette's own history, which no
    /// transcript cleanup can shorten.
    func testTheNoteIsHiddenInQuotaMode() {
        XCTAssertNil(ActivityGridView.retentionNote(provider: "claude", showsQuota: true))
        XCTAssertEqual(
            ActivityGridView.retentionNote(provider: "claude", showsQuota: false),
            ActivityCopy.claudeTranscriptCleanup
        )
        XCTAssertNil(ActivityGridView.retentionNote(provider: "codex", showsQuota: false))
    }
}
