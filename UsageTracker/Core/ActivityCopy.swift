import Foundation

/// What Dashboard → Activity says beyond its numbers.
///
/// The cards count the days the logs still hold. Claude Code deletes its transcripts
/// after 30 days unless `cleanupPeriodDays` says otherwise, so a Claude year can be
/// three quarters empty through nobody's fault — and an empty grid with no explanation
/// reads as a broken app. The Codex CLI and the Grok CLI document no cleanup, so they
/// get no caption: a warning about something that does not happen is noise.
///
/// Spec: docs/superpowers/specs/2026-09-17-activity-year-retention-design.md
/// § Note under the cards.
enum ActivityCopy {
    static let claudeTranscriptCleanup =
        "Claude Code deletes local transcripts after 30 days by default. " +
        "Set cleanupPeriodDays in ~/.claude/settings.json to keep a year."

    /// Keyed by service id, the same string `DashboardState.selectedService` holds.
    /// nil for every provider whose CLI keeps its logs.
    static func retentionNote(provider: String) -> String? {
        provider == "claude" ? claudeTranscriptCleanup : nil
    }
}
