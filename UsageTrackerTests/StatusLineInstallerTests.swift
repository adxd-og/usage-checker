import XCTest
@testable import Omelette

/// Fixtures are real files in a temp directory. The installer is pure over the URL it
/// is handed, so nothing here can reach `~/.claude`.
final class StatusLineInstallerTests: XCTestCase {
    private var root: URL!
    private let cli = "/Users/tester/Library/Application Support/UsageTracker/bin/omelette"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatusLineInstallerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var settingsURL: URL { root.appendingPathComponent("settings.json") }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    private func json(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])
    }

    private func statusLine(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(try json(at: url)["statusLine"] as? [String: Any])
    }

    private var status: HookInstallStatus {
        StatusLineInstaller.status(settingsURL: settingsURL, cliPath: cli)
    }

    // MARK: - The command

    func testTheCommandIsTheQuotedPathPlusTheSubcommand() {
        XCTAssertEqual(
            StatusLineInstaller.command(cliPath: cli),
            "'/Users/tester/Library/Application Support/UsageTracker/bin/omelette' statusline"
        )
    }

    /// The hook helper's path starts with our marker. Only the subcommand tells them
    /// apart, and mistaking one for the other would have the installer "update" a hook.
    func testAHookCommandIsNeverOurs() {
        let hook = "'/Users/tester/Library/Application Support/UsageTracker/bin/omelette-hook'"
        XCTAssertFalse(StatusLineInstaller.isOurs(hook))
        XCTAssertFalse(StatusLineInstaller.isOurs(hook + " --codex-hook"))
        XCTAssertTrue(StatusLineInstaller.isOurs(StatusLineInstaller.command(cliPath: cli)))
    }

    func testTheEmittedCommandSurvivesTheShell() throws {
        let weird = "/Users/o'brien/Library/Application Support/UsageTracker/bin/omelette"
        let command = StatusLineInstaller.command(cliPath: weird)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Two %s: the shell splits our line into the quoted path and the subcommand,
        // and a single %s would print them back joined with no space between them.
        process.arguments = ["-c", "printf '%s %s' \(command)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: output, as: UTF8.self), weird + " statusline")
    }

    // MARK: - The entry

    /// Claude Code re-runs the command on events — a new assistant message,
    /// /compact, a mode change — and nothing else, so an idle session shows a
    /// countdown that stopped. 60 s is one poll of ours, and the countdown is
    /// minute-granular: anything shorter spends a process to reprint the same line.
    func testTheRefreshIntervalIsSixtySeconds() {
        XCTAssertEqual(StatusLineInstaller.refreshInterval, 60)
    }

    /// The entry an older build wrote: our command, no interval. This is the whole
    /// question the Update button exists to answer.
    func testAnEntryWithoutARefreshIntervalNeedsAnUpdate() {
        let old: [String: Any] = [
            "type": "command",
            "command": StatusLineInstaller.command(cliPath: cli),
        ]
        XCTAssertTrue(StatusLineInstaller.needsUpdate(existing: old))
    }

    func testAnEntryCarryingOurIntervalNeedsNothing() {
        let current: [String: Any] = [
            "type": "command",
            "command": StatusLineInstaller.command(cliPath: cli),
            "refreshInterval": 60,
        ]
        XCTAssertFalse(StatusLineInstaller.needsUpdate(existing: current))
    }

    /// A number someone dialled to their own taste, a string, a boolean, a null:
    /// none of them is the interval this build writes, so all of them are an update.
    func testAnIntervalThatIsNotOursNeedsAnUpdate() {
        let values: [Any] = [5, 300, "60", true, NSNull()]
        for value in values {
            let entry: [String: Any] = [
                "type": "command",
                "command": StatusLineInstaller.command(cliPath: cli),
                "refreshInterval": value,
            ]
            XCTAssertTrue(StatusLineInstaller.needsUpdate(existing: entry), "\(value)")
        }
    }

    /// `desiredEntry` is the only answer to "what do we write": the preview, the
    /// install and the status comparison all read it, so a key added here reaches
    /// all three at once.
    func testTheDesiredEntryIsATypeAndTheQuotedCommand() {
        let entry = StatusLineInstaller.desiredEntry(commandPath: cli)

        XCTAssertEqual(entry["type"] as? String, "command")
        XCTAssertEqual(entry["command"] as? String, StatusLineInstaller.command(cliPath: cli))
    }

    func testThePreviewIsTheJSONWeActuallyWrite() throws {
        let preview = StatusLineInstaller.previewJSON(cliPath: cli)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(preview.utf8)) as? [String: Any])
        let entry = try XCTUnwrap(parsed["statusLine"] as? [String: Any])

        XCTAssertEqual(entry["type"] as? String, "command")
        XCTAssertEqual(entry["command"] as? String, StatusLineInstaller.command(cliPath: cli))
        XCTAssertEqual(entry["refreshInterval"] as? Int, 60)
        XCTAssertTrue(preview.contains(cli), "the preview shows the real path, unescaped")
        XCTAssertFalse(preview.contains("\\/"))
        // "What will be written" is a promise about characters, not about keys:
        // Foundation's pretty printer puts spaces around the colon.
        XCTAssertTrue(preview.contains("\"refreshInterval\" : 60"), preview)
    }

    // MARK: - Install

    func testInstallCreatesAMissingFileWithTheThreeKeys() throws {
        try StatusLineInstaller.install(settingsURL: settingsURL, cliPath: cli)

        let line = try statusLine(at: settingsURL)
        XCTAssertEqual(line.keys.sorted(), ["command", "refreshInterval", "type"])
        XCTAssertEqual(line["type"] as? String, "command")
        XCTAssertEqual(line["command"] as? String, StatusLineInstaller.command(cliPath: cli))
        XCTAssertEqual(line["refreshInterval"] as? Int, 60)
        XCTAssertEqual(status, .installed)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: SettingsFile.backupURL(for: settingsURL).path),
            "there was no file to back up"
        )
    }

    func testInstallKeepsEveryOtherKeyAndBacksTheFileUpOnce() throws {
        try write(#"{"model":"opus","hooks":{"Stop":[]}}"#, to: settingsURL)

        try StatusLineInstaller.install(settingsURL: settingsURL, cliPath: cli)

        let file = try json(at: settingsURL)
        XCTAssertEqual(file["model"] as? String, "opus")
        XCTAssertNotNil(file["hooks"])
        let backup = SettingsFile.backupURL(for: settingsURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertEqual(
            String(decoding: try Data(contentsOf: backup), as: UTF8.self),
            #"{"model":"opus","hooks":{"Stop":[]}}"#,
            "the backup is the file as it was, not as we rewrote it"
        )
    }

    func testAnOlderEntryOfOursIsUpdatedRatherThanDuplicated() throws {
        try StatusLineInstaller.install(settingsURL: settingsURL, cliPath: "/Applications/Old.app/omelette")
        XCTAssertEqual(status, .conflict("'/Applications/Old.app/omelette' statusline"),
                       "a path outside the symlink directory is not ours at all")

        try write(#"{"statusLine":{"type":"command","command":"'/Users/other/Library/Application Support/UsageTracker/bin/omelette' statusline"}}"#, to: settingsURL)
        XCTAssertEqual(status, .outdated, "ours, but pointing at another home")

        try StatusLineInstaller.install(settingsURL: settingsURL, cliPath: cli)
        XCTAssertEqual(status, .installed)
    }

    // MARK: - Update

    /// The entry 2.5.1 wrote: our command, no interval. The row has to offer an
    /// Update, and taking it may not disturb anything else in the file — not the
    /// keys Claude Code owns, not a hooks block belonging to another tool, and not
    /// the backup taken the first time we touched the file.
    func testAnEntryFromBeforeTheRefreshIntervalIsUpdatedInPlace() throws {
        let before = #"""
        {"model":"opus","hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"'/opt/theirs/notify'"}]}]},"statusLine":{"type":"command","command":"'/Users/tester/Library/Application Support/UsageTracker/bin/omelette' statusline"}}
        """#
        try write(before, to: settingsURL)
        let hooksBefore = SettingsFile.canonicalJSON(try XCTUnwrap(json(at: settingsURL)["hooks"] as? [String: Any]))

        XCTAssertTrue(StatusLineInstaller.needsUpdate(existing: try statusLine(at: settingsURL)))
        XCTAssertEqual(status, .outdated, "ours, but written before the interval existed")

        try StatusLineInstaller.install(settingsURL: settingsURL, cliPath: cli)

        XCTAssertEqual(status, .installed)
        XCTAssertEqual(
            SettingsFile.canonicalJSON(try statusLine(at: settingsURL)),
            SettingsFile.canonicalJSON(StatusLineInstaller.desiredEntry(commandPath: cli))
        )
        let file = try json(at: settingsURL)
        XCTAssertEqual(file["model"] as? String, "opus", "a key Claude Code owns")
        XCTAssertEqual(
            SettingsFile.canonicalJSON(try XCTUnwrap(file["hooks"] as? [String: Any])),
            hooksBefore,
            "someone else's hooks block is not ours to rewrite"
        )
        XCTAssertEqual(
            String(decoding: try Data(contentsOf: SettingsFile.backupURL(for: settingsURL)), as: UTF8.self),
            before,
            "the backup is the file as it was before the update"
        )
    }

    /// An interval someone dialled to their own taste is still not the one this build
    /// writes, so the row offers an Update rather than pretending to be current —
    /// and Disable sits next to it for anyone who meant it.
    func testAnIntervalOfTheirOwnIsAnUpdateNotAConflict() throws {
        try write(#"{"statusLine":{"type":"command","command":"'/Users/tester/Library/Application Support/UsageTracker/bin/omelette' statusline","refreshInterval":5}}"#, to: settingsURL)

        XCTAssertEqual(status, .outdated)

        try StatusLineInstaller.install(settingsURL: settingsURL, cliPath: cli)

        XCTAssertEqual(try statusLine(at: settingsURL)["refreshInterval"] as? Int, 60)
        XCTAssertEqual(status, .installed)
    }

    /// A hand-written 60.0 is 60: JSONSerialization hands back an NSNumber and the
    /// double bridges. Nobody should see an Update button over an entry that already
    /// does the right thing.
    func testAnIntervalWrittenAsADecimalIsStillOurs() throws {
        try write(#"{"statusLine":{"type":"command","command":"'/Users/tester/Library/Application Support/UsageTracker/bin/omelette' statusline","refreshInterval":60.0}}"#, to: settingsURL)

        XCTAssertFalse(StatusLineInstaller.needsUpdate(existing: try statusLine(at: settingsURL)))
        XCTAssertEqual(status, .installed)
    }

    /// The section is called "What will be written". It has to be true of the bytes,
    /// not only of the keys.
    func testThePreviewIsTheObjectTheInstallLeavesBehind() throws {
        try StatusLineInstaller.install(settingsURL: settingsURL, cliPath: cli)

        let written = try statusLine(at: settingsURL)
        let previewed = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: Data(StatusLineInstaller.previewJSON(cliPath: cli).utf8))
                as? [String: Any])?["statusLine"] as? [String: Any]
        )
        XCTAssertEqual(SettingsFile.canonicalJSON(written), SettingsFile.canonicalJSON(previewed))
    }

    // MARK: - Conflict

    /// The owner's own settings.json, verbatim. This is the case the Settings tab has
    /// to get right on the machine it ships from.
    func testAForeignStatusLineIsAConflictAndIsNeverOverwritten() throws {
        let theirs = #"bash \"$HOME/.claude/statusline-command.sh\""#
        try write(#"{"statusLine":{"type":"command","command":"\#(theirs)"}}"#, to: settingsURL)

        XCTAssertEqual(status, .conflict("bash \"$HOME/.claude/statusline-command.sh\""))

        XCTAssertThrowsError(try StatusLineInstaller.install(settingsURL: settingsURL, cliPath: cli)) {
            XCTAssertEqual($0 as? StatusLineInstaller.Error, .conflict("bash \"$HOME/.claude/statusline-command.sh\""))
        }
        XCTAssertEqual(
            try statusLine(at: settingsURL)["command"] as? String,
            "bash \"$HOME/.claude/statusline-command.sh\"",
            "their line is exactly where they left it"
        )
    }

    func testAStatusLineWeCannotReadIsARefusalNotAnOverwrite() throws {
        try write(#"{"statusLine":"just a string"}"#, to: settingsURL)

        XCTAssertEqual(status, .conflict(StatusLineInstaller.unreadableReason))
        XCTAssertThrowsError(try StatusLineInstaller.install(settingsURL: settingsURL, cliPath: cli))
    }

    func testAFileThatIsNotJSONIsARefusal() throws {
        try write("{ not json at all", to: settingsURL)

        XCTAssertEqual(status, .conflict(AgentHooksInstaller.unparsableReason))
        XCTAssertThrowsError(try StatusLineInstaller.install(settingsURL: settingsURL, cliPath: cli)) {
            XCTAssertEqual($0 as? StatusLineInstaller.Error, .unparsable(self.settingsURL))
        }
    }

    // MARK: - Remove

    func testRemoveTakesOursAndLeavesTheRest() throws {
        try write(#"{"model":"opus"}"#, to: settingsURL)
        try StatusLineInstaller.install(settingsURL: settingsURL, cliPath: cli)

        try StatusLineInstaller.remove(settingsURL: settingsURL, cliPath: cli)

        let file = try json(at: settingsURL)
        XCTAssertNil(file["statusLine"])
        XCTAssertEqual(file["model"] as? String, "opus")
        XCTAssertEqual(status, .notInstalled)
    }

    func testRemoveLeavesAForeignStatusLineAlone() throws {
        let theirs = #"{"statusLine":{"type":"command","command":"my-script"},"model":"opus"}"#
        try write(theirs, to: settingsURL)

        try StatusLineInstaller.remove(settingsURL: settingsURL, cliPath: cli)

        XCTAssertEqual(try statusLine(at: settingsURL)["command"] as? String, "my-script")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: SettingsFile.backupURL(for: settingsURL).path),
            "a file we did not change is a file we did not back up"
        )
    }

    func testRemoveOnAMissingFileIsQuiet() throws {
        XCTAssertNoThrow(try StatusLineInstaller.remove(settingsURL: settingsURL, cliPath: cli))
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsURL.path))
    }
}
