import Foundation

/// Where a rate-limit window's numbers came from (spec 2026-11-02 Claude limits from the
/// status line, § Source tag). The app keeps it on `UsageBucket.source`; `status.json`
/// spells it with the raw value (`StatusSnapshot.Window.source`), so the CLI and the MCP
/// server, which cannot see the app's types, read the same spelling. In CLICore because
/// both sides need it.
enum ReadingSource: String, Codable, Equatable, Sendable {
    /// The provider's own usage fetch; for Claude, the OAuth usage endpoint. A window with
    /// no source at all — every record written before the tag, every other provider's —
    /// reads as this.
    case oauth
    /// Claude Code's status line: the limits `brioche statusline` left for the app
    /// (`StatusLineDrop`), newer than the OAuth reading they replaced.
    case statusLine

    /// What a surface says after a window from here: "from Claude Code" for the status
    /// line; nothing for the provider's own fetch, which every surface already assumes.
    var words: String? {
        switch self {
        case .oauth: return nil
        case .statusLine: return "from Claude Code"
        }
    }
}
