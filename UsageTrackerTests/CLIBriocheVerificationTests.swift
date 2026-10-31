import XCTest
@testable import Omelette

/// Tester's verification of the command as a person meets it (plan 2026-10-31-brioche-rename,
/// Goal, OWNER 7): the real binary run through a link of each name, with the status file
/// pointed at a temp path so the developer's own never matters. Nothing here asks the binary
/// for its own name: both links give the same answers.
final class CLIBriocheVerificationTests: XCTestCase {
    private var directory: URL!
    private var statusURL: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIBriocheVerificationTests-\(UUID().uuidString)", isDirectory: true)
        let bin = directory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try AgentPaths.refreshCLISymlinks(binDirectory: bin, target: AgentPaths.bundledCLIURL)
        statusURL = directory.appendingPathComponent("status.json")   // never written: "not running"
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private struct Run { let status: Int32; let stdout: String; let stderr: String }

    private func run(_ name: String, _ arguments: [String], stdin input: String = "") throws -> Run {
        let process = Process()
        process.executableURL = directory.appendingPathComponent("bin/\(name)")
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment[StatusFile.environmentKey] = statusURL.path
        process.environment = environment
        let stdout = Pipe(), stderr = Pipe(), stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus, stdout: String(decoding: out, as: UTF8.self), stderr: String(decoding: err, as: UTF8.self))
    }

    private let names = ["brioche", "omelette"]

    func testBothLinksReportTheBriocheVersionThatMatchesTheBundle() throws {
        let marketing = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        XCTAssertEqual(CLIText.version, marketing, "the CLI's version must follow MARKETING_VERSION")
        for name in names {
            let result = try run(name, ["--version"])
            XCTAssertEqual(result.status, 0, name)
            XCTAssertEqual(result.stdout, "brioche \(CLIText.version)\n", name)
        }
    }

    func testBothLinksPrintTheSameHelpThatNamesBothCommands() throws {
        let new = try run("brioche", ["--help"])
        let old = try run("omelette", ["--help"])

        XCTAssertEqual(new.status, 0)
        XCTAssertEqual(new.stdout, old.stdout)
        XCTAssertEqual(new.stdout, CLIText.usage + "\n")
        XCTAssertTrue(new.stdout.contains("brioche status"), new.stdout)
        XCTAssertTrue(new.stdout.contains("`omelette`"), "the old command is named so an old setup is understood")
        XCTAssertFalse(new.stdout.contains("Omelette"), new.stdout)
    }

    func testBothLinksSayBriocheIsNotRunningOnStderrWithExitCodeTwo() throws {
        for name in names {
            let result = try run(name, ["status"])
            XCTAssertEqual(result.status, CLIText.noDataExitCode, name)
            XCTAssertEqual(result.stdout, "", name)
            XCTAssertEqual(result.stderr, "Brioche is not running or has not polled yet\n", name)
        }
    }

    func testAnUnknownCommandIsAUsageErrorThatNeverSaysOmelette() throws {
        for name in names {
            let result = try run(name, ["frobnicate"])
            XCTAssertEqual(result.status, CLIText.usageExitCode, name)
            XCTAssertFalse(result.stderr.contains("Omelette"), result.stderr)
            XCTAssertTrue(result.stderr.contains("brioche"), result.stderr)
        }
    }

    func testTheServerNamesItselfBriocheWhicheverLinkStartedIt() throws {
        let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#
        for name in names {
            let result = try run(name, ["mcp"], stdin: initialize + "\n")
            let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any], result.stdout)
            let info = try XCTUnwrap((reply["result"] as? [String: Any])?["serverInfo"] as? [String: Any])
            XCTAssertEqual(info["name"] as? String, "brioche", name)
            XCTAssertEqual(info["version"] as? String, CLIText.version, name)
        }
    }

    func testNothingTheServerSaysToAModelStillNamesOmelette() throws {
        let lines = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_usage","arguments":{}}}"#,
        ]
        for name in names {
            let result = try run(name, ["mcp"], stdin: lines.joined(separator: "\n") + "\n")
            XCTAssertFalse(result.stdout.contains("Omelette"), result.stdout)
            XCTAssertFalse(result.stdout.localizedCaseInsensitiveContains("omelette"), result.stdout)
            XCTAssertTrue(result.stdout.contains("Brioche is not running or has not polled yet."), "the not-running answer: \(result.stdout)")
        }
    }

    func testTheMCPServerRulesSayBriocheInProcessToo() throws {
        let tools = MCPServer.handle(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#, snapshot: nil, now: Date())
        XCTAssertEqual(MCPServer.serverName, "brioche")
        XCTAssertFalse(MCPServer.instructions.contains("Omelette"))
        XCTAssertFalse(try XCTUnwrap(tools).contains("Omelette"))
        XCTAssertTrue(try XCTUnwrap(tools).contains("Brioche"))
    }
}

/// The words the Settings rows and the MCP/CLI rules hand a person: none of them says Omelette
/// as a name any more, and the old command is only ever named as the old command.
final class BriocheCopyVerificationTests: XCTestCase {
    func testNoSettingsCaptionNamesTheAppOmelette() {
        let texts = [
            CommandLineSettingsText.pathCaption,
            CommandLineSettingsText.statusLineCaption,
            CommandLineSettingsText.mcpCaption,
            CommandLineSettingsText.mcpClaudeCaption,
            CommandLineSettingsText.mcpCodexCaption,
            IntegrationsSettingsCopy.claudeHooksHelp,
            IntegrationsSettingsCopy.permissionsTitle,
            IntegrationsSettingsCopy.commandLineFooter,
            IntegrationsSettingsCopy.copyStatusLineCommand,
            IntegrationsSettingsCopy.copyCodexNotifyLine,
            IntegrationsSettingsCopy.commandNote(briocheIsForeign: true)?.text ?? "",
            IntegrationsSettingsCopy.commandNote(briocheIsForeign: true, omeletteIsForeign: true)?.text ?? "",
            MCPInstaller.claudeUnreadableReason,
            MCPInstaller.codexUnreadableTableReason,
            StatusLineInstaller.unreadableReason,
            CLIText.notRunning,
            CLIText.usage,
        ]
        for text in texts {
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(text.contains("Omelette"), text)
        }
    }

    func testTheCaptionsThatMentionTheOldNameSayItIsTheOldName() {
        XCTAssertTrue(CommandLineSettingsText.pathCaption.contains("`brioche status`"))
        XCTAssertTrue(CommandLineSettingsText.mcpClaudeCaption.contains("`brioche`"))
        XCTAssertTrue(CommandLineSettingsText.mcpCodexCaption.contains("[mcp_servers.brioche]"))
        XCTAssertTrue(CommandLineSettingsText.mcpCaption.contains("claude mcp add brioche"))
    }

    func testTheRulesThatReadBriocheForeignAreSilentOtherwise() {
        XCTAssertNil(IntegrationsSettingsCopy.commandNote(briocheIsForeign: false))
        XCTAssertNil(IntegrationsSettingsCopy.commandNote(briocheIsForeign: false, omeletteIsForeign: true))
    }
}
