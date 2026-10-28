import Foundation

/// The environment every run of Claude Code from Omelette starts in (spec 2026-10-25 § Design ›
/// Package 2, The environment): without the variables that would point it at another sign-in or
/// make it think it runs inside another session, so it reads and writes the plain
/// `Claude Code-credentials` item.
enum ClaudeCLIEnvironment {
    /// Removed by name; `ANTHROPIC_*` goes by its prefix.
    static let scrubbedKeys = [
        "CLAUDE_CONFIG_DIR",
        "CLAUDE_SECURESTORAGE_CONFIG_DIR",
        "CLAUDE_CODE_OAUTH_TOKEN",
        "CLAUDECODE",
    ]
    static let scrubbedPrefix = "ANTHROPIC_"
}
