import Foundation

/// Marks the Claude Code that Omelette starts to renew a sign-in (spec 2026-10-25 § Design ›
/// Package 2, What the probe is allowed to do). Claude Code hands its environment to the hooks
/// it runs, so `omelette-hook` sees the mark and reports nothing: that start is not an agent
/// session. Foundation only; the hook helper compiles this file by path (project.yml).
enum ClaudeRenewalMarker {
    static let environmentKey = "OMELETTE_CLAUDE_RENEWAL"
    static let value = "1"

    static func isRenewal(environment: [String: String]) -> Bool {
        environment[environmentKey] == value
    }
}
