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

    /// A status line someone else owns. Shown with their command so the user can decide
    /// what to do about it — Omelette never overwrites it.
    static func conflictCaption(_ command: String) -> String {
        "`settings.json` already has a status line of its own:\n\(command)"
    }
}
