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

    func testThePreviewIsTheJSONWeActuallyWrite() throws {
        let preview = StatusLineInstaller.previewJSON(cliPath: cli)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(preview.utf8)) as? [String: Any])

        XCTAssertNotNil(parsed["statusLine"] as? [String: Any])
        XCTAssertTrue(preview.contains(cli), "the preview shows the real path, unescaped")
        XCTAssertFalse(preview.contains("\\/"))
    }

    // MARK: - Install

    func testInstallCreatesAMissingFile() throws {
        try StatusLineInstaller.install(settingsURL: settingsURL, cliPath: cli)

        let line = try statusLine(at: settingsURL)
        XCTAssertEqual(line["type"] as? String, "command")
        XCTAssertEqual(line["command"] as? String, StatusLineInstaller.command(cliPath: cli))
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
