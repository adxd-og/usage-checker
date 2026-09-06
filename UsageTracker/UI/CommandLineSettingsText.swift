import Foundation

/// The Command line section's words, kept apart from the view that shows them — the
/// view reads `~/.claude` and a test cannot.
enum CommandLineSettingsText {
    /// `$HOME` rather than the expanded path: this line goes into a dotfile that is
    /// often shared between machines, and the quotes are what carry it past the space
    /// in "Application Support".
    static let pathExportLine = #"export PATH="$HOME/Library/Application Support/UsageTracker/bin:$PATH""#

    static let pathCaption = "Add that line to ~/.zshrc and open a new terminal; `omelette status` then works from anywhere. Without it, call the tool by the full path above. Omelette keeps the link pointing at itself, so moving or updating the app changes nothing."

    static let statusLineCaption = "Puts Omelette's numbers in Claude Code's status bar: the session window, when it resets, today's cost, and a flag when an agent is waiting for you. Restart Claude Code, or start a new session, to see it."

    static let statusLinePreviewTitle = "What will be written"

    static let mcpCaption = "Lets Claude Code and Codex ask Omelette what your limits are before they start something expensive. Two read-only tools over stdio: `get_usage` (every provider's windows, resets and costs) and `get_agents` (which sessions are working or waiting for you). Nothing is written and nothing leaves your Mac. Or add it yourself: `claude mcp add omelette -- <path> mcp` (the path is shown above), or an `[mcp_servers.omelette]` table in ~/.codex/config.toml."

    static let mcpClaudeCaption = "Adds `omelette` to `mcpServers` in ~/.claude.json — the file Claude Code keeps its own state in, so Omelette rewrites it with sorted keys and keeps the original as .claude.json.omelette-backup. Restart Claude Code to pick it up."

    static let mcpCodexCaption = "Adds an `[mcp_servers.omelette]` table at the end of ~/.codex/config.toml. Other tables are left exactly as they are. Restart Codex to pick it up."

    /// A status line someone else owns. Shown with their command so the user can decide
    /// what to do about it — Omelette never overwrites it.
    static func conflictCaption(_ command: String) -> String {
        "`settings.json` already has a status line of its own:\n\(command)"
    }
}
