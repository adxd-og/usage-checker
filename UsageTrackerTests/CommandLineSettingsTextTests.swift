import XCTest
@testable import Omelette

/// The Command line section's words. The view reads `~/.claude` and a test cannot;
/// these are the parts a test can hold on to — and the PATH line is the one string a
/// user will paste into a shell, so it is pinned character for character.
final class CommandLineSettingsTextTests: XCTestCase {
    func testThePathLineIsExactlyWhatAShellNeeds() {
        XCTAssertEqual(
            CommandLineSettingsText.pathExportLine,
            #"export PATH="$HOME/Library/Application Support/UsageTracker/bin:$PATH""#
        )
    }

    /// `$HOME` in the copied line, the real path in the row above it. The two have to
    /// name the same directory or the button hands out a line that does not work.
    func testThePathLineNamesTheDirectoryTheSymlinkIsIn() {
        let directory = AgentPaths.cliSymlinkURL.deletingLastPathComponent().path
        XCTAssertTrue(directory.hasSuffix("/Library/Application Support/UsageTracker/bin"), directory)
        XCTAssertTrue(
            CommandLineSettingsText.pathExportLine.contains("$HOME/Library/Application Support/UsageTracker/bin"),
            CommandLineSettingsText.pathExportLine
        )
    }

    /// The line goes through a shell verbatim. If it ever grows an unquoted space it
    /// stops being one argument, and `echo $PATH` shows the damage a week later.
    func testThePathLineSurvivesTheShell() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", CommandLineSettingsText.pathExportLine + #"; printf '%s' "$PATH""#]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin"
        environment["HOME"] = "/Users/tester"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(output, "/Users/tester/Library/Application Support/UsageTracker/bin:/usr/bin")
    }

    func testTheConflictCaptionQuotesTheirCommand() {
        let caption = CommandLineSettingsText.conflictCaption("bash \"$HOME/.claude/statusline-command.sh\"")
        XCTAssertTrue(caption.contains("bash \"$HOME/.claude/statusline-command.sh\""), caption)
    }

    func testTheMCPCaptionsNameTheToolsAndTheRestart() {
        XCTAssertTrue(CommandLineSettingsText.mcpCaption.contains("get_usage"))
        XCTAssertTrue(CommandLineSettingsText.mcpCaption.contains("get_agents"))
        XCTAssertTrue(CommandLineSettingsText.mcpCaption.contains("get_sessions"))
        XCTAssertTrue(CommandLineSettingsText.mcpCaption.lowercased().contains("read-only"))
        for caption in [CommandLineSettingsText.mcpClaudeCaption, CommandLineSettingsText.mcpCodexCaption] {
            XCTAssertTrue(caption.lowercased().contains("restart"), caption)
        }
    }

    /// Rewriting a file Claude Code writes itself is worth saying out loud, and the
    /// backup is the sentence that makes it survivable.
    func testTheClaudeCaptionWarnsAboutRewritingItsStateFile() {
        XCTAssertTrue(CommandLineSettingsText.mcpClaudeCaption.contains("~/.claude.json"))
        XCTAssertTrue(CommandLineSettingsText.mcpClaudeCaption.contains(".claude.json.omelette-backup"))
    }

    /// Half of the line is the session rather than the account, and this caption is the
    /// only place that says so before the user installs it.
    func testTheStatusLineCaptionNamesTheModelAndItsContext() {
        XCTAssertTrue(
            CommandLineSettingsText.statusLineCaption.contains("the model and how full its context is"),
            CommandLineSettingsText.statusLineCaption
        )
    }

    /// Claude Code re-runs the command on events only, so an entry added by hand
    /// without the interval shows a countdown that stopped. The caption is the only
    /// place a hand-writer learns that, and the number in it is read from the
    /// installer so the two cannot drift apart.
    func testTheStatusLineCaptionSaysWhatTheRefreshIntervalIsFor() {
        let caption = CommandLineSettingsText.statusLineCaption
        XCTAssertTrue(
            caption.contains(#""refreshInterval": \#(StatusLineInstaller.refreshInterval)"#),
            caption
        )
        XCTAssertTrue(
            caption.contains("so the countdown keeps ticking while the session is idle"),
            caption
        )
    }

    func testTheCaptionsSayWhatTheThingDoes() {
        XCTAssertTrue(CommandLineSettingsText.statusLineCaption.contains("status"))
        XCTAssertTrue(CommandLineSettingsText.statusLineCaption.contains("~/.claude/settings.json"),
                      "the caption says how to add the status line by hand, like the MCP caption does")
        XCTAssertTrue(CommandLineSettingsText.pathCaption.contains("omelette status"))
        for caption in [CommandLineSettingsText.statusLineCaption, CommandLineSettingsText.pathCaption] {
            XCTAssertFalse(caption.contains("!"), "the app's Settings copy has no exclamation marks")
        }
    }

    // MARK: - The installer row

    /// Spec § Design: no new state is added for an entry missing its refresh
    /// interval — the write action stays where it was, worded as an update.
    func testAnEntryOlderThanThisBuildKeepsTheWriteActionAsUpdate() {
        XCTAssertEqual(CommandLineSettingsText.installButtonTitle(.outdated), "Update")
        XCTAssertTrue(CommandLineSettingsText.installButtonIsEnabled(.outdated))
        XCTAssertTrue(CommandLineSettingsText.showsDisableButton(.outdated),
                      "an update the user did not want is one click from being undone")
    }

    func testTheOtherThreeStatesKeepTheButtonsTheyHad() {
        XCTAssertEqual(CommandLineSettingsText.installButtonTitle(.notInstalled), "Enable")
        XCTAssertTrue(CommandLineSettingsText.installButtonIsEnabled(.notInstalled))
        XCTAssertFalse(CommandLineSettingsText.showsDisableButton(.notInstalled))

        XCTAssertNil(CommandLineSettingsText.installButtonTitle(.installed),
                     "nothing to write over an entry that is already ours")
        XCTAssertTrue(CommandLineSettingsText.showsDisableButton(.installed))

        // Greyed out rather than hidden: the row has to say that writing is the
        // thing that is unavailable, not leave an empty space where it was.
        XCTAssertEqual(CommandLineSettingsText.installButtonTitle(.conflict("theirs")), "Enable")
        XCTAssertFalse(CommandLineSettingsText.installButtonIsEnabled(.conflict("theirs")))
        XCTAssertFalse(CommandLineSettingsText.showsDisableButton(.conflict("theirs")))

        XCTAssertEqual(CommandLineSettingsText.disableButtonTitle, "Disable")
    }

    /// The seam, end to end: a settings.json written before 2.6.0 has our command
    /// and no interval, and the row over it reads "Installed — older than this
    /// build" with an Update button — not "Not installed", and not a conflict.
    func testAStatusLineFromAnOlderBuildOffersAnUpdateButton() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CommandLineSettingsTextTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settingsURL = root.appendingPathComponent("settings.json")
        let cli = "/Users/tester/Library/Application Support/UsageTracker/bin/omelette"
        try Data(#"{"statusLine":{"type":"command","command":"'/Users/tester/Library/Application Support/UsageTracker/bin/omelette' statusline"}}"#.utf8)
            .write(to: settingsURL)

        let status = StatusLineInstaller.status(settingsURL: settingsURL, cliPath: cli)

        XCTAssertEqual(status, .outdated)
        XCTAssertEqual(CommandLineSettingsText.installButtonTitle(status), "Update")
        XCTAssertEqual(AgentsSettingsText.hookStatusLabel(status), "Installed — older than this build")
    }
}
