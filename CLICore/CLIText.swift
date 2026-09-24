import Foundation

/// The tool's fixed strings and its exit codes, in one place so a test can hold them.
enum CLIText {
    /// Kept in step with the app's `MARKETING_VERSION` by hand at release time — a
    /// command-line tool has no Info.plist to read it out of, and inventing one to
    /// carry a single string would be a build-setting maze for no gain. The release
    /// task that bumps `project.yml` to 2.4.1 / build 39 bumps this line with it.
    static let version = "2.6.5"

    /// The one sentence for every way the file can be missing: not written yet, too
    /// old, unreadable, from another version. They all mean the same thing to the user.
    static let notRunning = "Omelette is not running or has not polled yet"

    /// The short qualifier for dollars that are an API-list-price equivalent of local
    /// CLI usage rather than a bill. One spelling for `omelette status` and for the
    /// app's notification body (`CostCopy.apiEquivalentSuffix`).
    static let apiEquivalentSuffix = "(API-equivalent)"

    /// `status` found nothing to print.
    static let noDataExitCode: Int32 = 2
    /// Bad arguments. 64 is `EX_USAGE` from sysexits(3), which is what a shell script
    /// checking `$?` expects from a tool that was called wrong.
    static let usageExitCode: Int32 = 64

    static let usage = """
    omelette — Omelette's usage numbers, in the terminal.

    Usage:
      omelette status [--json]              every provider's windows, costs and agents
      omelette statusline [--provider ID]   one line for a status bar (default: claude)
                          [--no-color]
      omelette mcp                          Model Context Protocol server on stdio
      omelette --version
      omelette --help

    When Claude Code pipes its session JSON into `statusline`, the line opens with the
    model and a bar of how full its context window is, coloured for a status bar;
    `--no-color` prints the same line without the escape codes.

    Dollars are what the same tokens would cost at API list prices. On a
    subscription that is not the bill, so `status` marks them "(API-equivalent)"
    and `statusline` puts `≈` in front of them.

    Reads ~/Library/Application Support/UsageTracker/status.json, which Omelette
    writes after every poll. It never starts the app: with Omelette closed, `status`
    exits 2 and `statusline` prints the session's half of the line, or an empty one.
    """
}
