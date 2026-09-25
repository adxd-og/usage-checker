import Foundation

/// Token counts as the UI prints them ("999", "12.3k", "1.5M", "2.5B"). One implementation,
/// because two views had drifted copies of it.
///
/// In `CLICore/` rather than beside `TokenBreakdown`: `MCPSummary.sessions` prints
/// "41.2M tokens" and the `omelette` target compiles this folder but not
/// `UsageTracker/Core/TokenBreakdown.swift`, which reaches `ModelPricing` and from
/// there most of the app. Moving the six lines is what keeps the terminal and the
/// dashboard from growing a second spelling of the same number.
enum TokenFormat {
    static func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000_000 { return String(format: "%.1fB", Double(n) / 1_000_000_000) }
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }
}
