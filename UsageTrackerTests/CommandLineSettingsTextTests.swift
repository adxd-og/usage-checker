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

    func testTheCaptionsSayWhatTheThingDoes() {
        XCTAssertTrue(CommandLineSettingsText.statusLineCaption.contains("status"))
        XCTAssertTrue(CommandLineSettingsText.pathCaption.contains("omelette status"))
        for caption in [CommandLineSettingsText.statusLineCaption, CommandLineSettingsText.pathCaption] {
            XCTAssertFalse(caption.contains("!"), "the app's Settings copy has no exclamation marks")
        }
    }
}
