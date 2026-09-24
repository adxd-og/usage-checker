import XCTest
@testable import Omelette

/// Both config files, as real files in a temp directory. The installer is pure over
/// the URLs it is handed, so nothing here can reach `~/.claude.json` or `~/.codex`.
final class MCPInstallerTests: XCTestCase {
    private var root: URL!
    private let cli = "/Users/tester/Library/Application Support/UsageTracker/bin/omelette"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPInstallerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var claudeURL: URL { root.appendingPathComponent(".claude.json") }
    private var codexURL: URL { root.appendingPathComponent("config.toml") }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    private func text(at url: URL) throws -> String {
        String(data: try Data(contentsOf: url), encoding: .utf8) ?? ""
    }

    private func json(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])
    }

    private func servers(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(try json(at: url)["mcpServers"] as? [String: Any])
    }

    private var claudeStatus: HookInstallStatus {
        MCPInstaller.claudeStatus(configURL: claudeURL, cliPath: cli)
    }

    private var codexStatus: HookInstallStatus {
        MCPInstaller.codexStatus(configURL: codexURL, cliPath: cli)
    }

    // MARK: - Claude Code

    /// argv, not a shell line: the path is unquoted and `mcp` is its own argument.
    /// The owner's own file spells its other servers `"command": "node"` with the
    /// script path in `args` — this is that shape, not a shell line.
    func testTheClaudeEntryIsArgvNotAShellLine() throws {
        let template = MCPInstaller.claudeTemplate(cliPath: cli)

        XCTAssertEqual(template["type"] as? String, "stdio")
        XCTAssertEqual(template["command"] as? String, cli, "no quoting: this is not a shell line")
        XCTAssertEqual(template["args"] as? [String], ["mcp"])
    }

    func testInstallCreatesAMissingFile() throws {
        try MCPInstaller.installClaude(configURL: claudeURL, cliPath: cli)

        let entry = try XCTUnwrap(try servers(at: claudeURL)["omelette"] as? [String: Any])
        XCTAssertEqual(entry["command"] as? String, cli)
        XCTAssertEqual(claudeStatus, .installed)
    }

    func testInstallKeepsClaudeCodesOwnStateAndItsOtherServers() throws {
        try write(#"{"numStartups":42,"projects":{"/Users/tester":{"trust":true}},"mcpServers":{"xcode":{"type":"stdio","command":"xcrun","args":["mcpbridge"]}}}"#, to: claudeURL)

        try MCPInstaller.installClaude(configURL: claudeURL, cliPath: cli)

        let file = try json(at: claudeURL)
        XCTAssertEqual(file["numStartups"] as? Int, 42)
        XCTAssertNotNil(file["projects"])
        let all = try servers(at: claudeURL)
        XCTAssertEqual((all["xcode"] as? [String: Any])?["command"] as? String, "xcrun")
        XCTAssertNotNil(all["omelette"])
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: SettingsFile.backupURL(for: claudeURL).path),
            "a live state file is exactly the one to back up before rewriting"
        )
    }

    func testAnOmeletteEntryPointingSomewhereElseIsAConflict() throws {
        try write(#"{"mcpServers":{"omelette":{"type":"stdio","command":"/usr/local/bin/omelette","args":["mcp"]}}}"#, to: claudeURL)

        XCTAssertEqual(claudeStatus, .conflict("/usr/local/bin/omelette"))
        XCTAssertThrowsError(try MCPInstaller.installClaude(configURL: claudeURL, cliPath: cli)) {
            XCTAssertEqual($0 as? MCPInstaller.Error, .conflict("/usr/local/bin/omelette"))
        }
        XCTAssertEqual(
            (try servers(at: claudeURL)["omelette"] as? [String: Any])?["command"] as? String,
            "/usr/local/bin/omelette",
            "their entry is exactly where they left it"
        )
    }

    func testAnEntryOfOursFromAnotherHomeIsOutdatedAndUpdatable() throws {
        try write(#"{"mcpServers":{"omelette":{"type":"stdio","command":"/Users/other/Library/Application Support/UsageTracker/bin/omelette","args":["mcp"]}}}"#, to: claudeURL)

        XCTAssertEqual(claudeStatus, .outdated)
        try MCPInstaller.installClaude(configURL: claudeURL, cliPath: cli)
        XCTAssertEqual(claudeStatus, .installed)
    }

    func testRemoveTakesOursAndPrunesAnEmptyMap() throws {
        try write(#"{"numStartups":42}"#, to: claudeURL)
        try MCPInstaller.installClaude(configURL: claudeURL, cliPath: cli)

        try MCPInstaller.removeClaude(configURL: claudeURL, cliPath: cli)

        let file = try json(at: claudeURL)
        XCTAssertEqual(file["numStartups"] as? Int, 42)
        XCTAssertNil(file["mcpServers"], "an empty map is clutter in a file we do not own")
        XCTAssertEqual(claudeStatus, .notInstalled)
    }

    func testRemoveLeavesOtherServersAndAForeignOmeletteAlone() throws {
        try write(#"{"mcpServers":{"xcode":{"command":"xcrun"},"omelette":{"command":"/usr/local/bin/omelette","args":["mcp"]}}}"#, to: claudeURL)

        try MCPInstaller.removeClaude(configURL: claudeURL, cliPath: cli)

        let all = try servers(at: claudeURL)
        XCTAssertNotNil(all["xcode"])
        XCTAssertNotNil(all["omelette"], "not ours, not ours to delete")
    }

    func testAFileThatIsNotJSONIsARefusal() throws {
        try write("{ not json at all", to: claudeURL)

        XCTAssertEqual(claudeStatus, .conflict(MCPInstaller.claudeUnparsableReason))
        XCTAssertThrowsError(try MCPInstaller.installClaude(configURL: claudeURL, cliPath: cli))
    }

    // MARK: - Codex

    func testTheCodexTableIsThreeLines() {
        XCTAssertEqual(MCPInstaller.codexTable(cliPath: cli), [
            "[mcp_servers.omelette]",
            #"command = "/Users/tester/Library/Application Support/UsageTracker/bin/omelette""#,
            #"args = ["mcp"]"#,
        ])
    }

    func testInstallAppendsATopLevelTableAndLeavesEveryOtherOneAlone() throws {
        let existing = """
        model = "gpt-6-astra"

        [mcp_servers.xcode]
        command = "xcrun"
        args = [ "mcpbridge" ]

        """
        try write(existing, to: codexURL)

        try MCPInstaller.installCodex(configURL: codexURL, cliPath: cli)

        let after = try text(at: codexURL)
        XCTAssertTrue(after.hasPrefix("model = \"gpt-6-astra\""), after)
        XCTAssertTrue(after.contains("[mcp_servers.xcode]"), after)
        XCTAssertTrue(after.contains(MCPInstaller.codexPreview(cliPath: cli)), after)
        XCTAssertEqual(codexStatus, .installed)
        XCTAssertTrue(after.hasSuffix("\n"))
    }

    func testInstallIsIdempotentAndUpdatesAnOldPathInPlace() throws {
        try MCPInstaller.installCodex(configURL: codexURL, cliPath: "/Users/other/Library/Application Support/UsageTracker/bin/omelette")
        XCTAssertEqual(codexStatus, .outdated)

        try MCPInstaller.installCodex(configURL: codexURL, cliPath: cli)
        XCTAssertEqual(codexStatus, .installed)

        let before = try text(at: codexURL)
        try MCPInstaller.installCodex(configURL: codexURL, cliPath: cli)
        XCTAssertEqual(try text(at: codexURL), before, "installing twice changes nothing")
        XCTAssertEqual(
            try text(at: codexURL).components(separatedBy: MCPInstaller.codexHeader).count - 1, 1,
            "one table, not two"
        )
    }

    func testAForeignOmeletteTableIsAConflict() throws {
        try write("""
        [mcp_servers.omelette]
        command = "/opt/homebrew/bin/omelette"
        args = ["serve"]

        """, to: codexURL)

        XCTAssertEqual(codexStatus, .conflict("/opt/homebrew/bin/omelette"))
        XCTAssertThrowsError(try MCPInstaller.installCodex(configURL: codexURL, cliPath: cli))
        XCTAssertTrue(try text(at: codexURL).contains("/opt/homebrew/bin/omelette"))
    }

    /// A sub-table belongs to its parent. Removing the server and leaving
    /// `[mcp_servers.omelette.env]` behind would leave Codex with a config it refuses.
    func testTheTableRangeSwallowsItsOwnSubTablesAndStopsAtTheNext() {
        let lines = [
            "[mcp_servers.omelette]",
            "command = \"x\"",
            "",
            "[mcp_servers.omelette.env]",
            "DEBUG = \"1\"",
            "",
            "[mcp_servers.other]",
            "command = \"y\"",
        ]
        XCTAssertEqual(MCPInstaller.codexTableRange(in: lines), 0..<6)
    }

    func testRemoveTakesTheWholeTableAndNothingElse() throws {
        try write("""
        model = "gpt-6-astra"

        [mcp_servers.omelette]
        command = "\(cli)"
        args = ["mcp"]

        [mcp_servers.xcode]
        command = "xcrun"

        """, to: codexURL)

        try MCPInstaller.removeCodex(configURL: codexURL, cliPath: cli)

        let after = try text(at: codexURL)
        XCTAssertFalse(after.contains("mcp_servers.omelette"), after)
        XCTAssertTrue(after.contains("[mcp_servers.xcode]"), after)
        XCTAssertTrue(after.contains("model = \"gpt-6-astra\""), after)
        XCTAssertEqual(codexStatus, .notInstalled)
    }

    func testRemoveLeavesAForeignTableAlone() throws {
        let theirs = """
        [mcp_servers.omelette]
        command = "/opt/homebrew/bin/omelette"

        """
        try write(theirs, to: codexURL)

        try MCPInstaller.removeCodex(configURL: codexURL, cliPath: cli)

        XCTAssertEqual(try text(at: codexURL), theirs)
    }

    func testRemoveOnAMissingFileIsQuiet() throws {
        XCTAssertNoThrow(try MCPInstaller.removeCodex(configURL: codexURL, cliPath: cli))
        XCTAssertFalse(FileManager.default.fileExists(atPath: codexURL.path))
    }

    /// A `config.toml` written by a Windows-side editor, or by a checkout with
    /// `core.autocrlf`, ends every line with "\r\n". `.trimmingCharacters(in:
    /// .whitespaces)` does not remove "\r", so without stripping it the header never
    /// matches, install appends a second table and remove silently does nothing.
    func testACRLFConfigIsReadAndRewrittenAsACRLFConfig() throws {
        let crlf = [
            "model = \"gpt-6-astra\"",
            "",
            "[mcp_servers.omelette]",
            "command = \"/Users/other/Library/Application Support/UsageTracker/bin/omelette\"",
            "args = [\"mcp\"]",
            "",
        ].joined(separator: "\r\n")
        try write(crlf, to: codexURL)

        XCTAssertEqual(codexStatus, .outdated, "ours, only with Windows line endings and an older path")

        try MCPInstaller.installCodex(configURL: codexURL, cliPath: cli)

        XCTAssertEqual(codexStatus, .installed)
        let after = try text(at: codexURL)
        XCTAssertEqual(after.components(separatedBy: MCPInstaller.codexHeader).count - 1, 1, "one table, not two:\n\(after)")
        XCTAssertFalse(after.contains("/Users/other/"), after)
        XCTAssertTrue(after.contains("\r\n"), "a CRLF file stays a CRLF file:\n\(after)")
        XCTAssertFalse(
            after.replacingOccurrences(of: "\r\n", with: "").contains("\n"),
            "no line was rewritten with a bare LF:\n\(after)"
        )

        try MCPInstaller.removeCodex(configURL: codexURL, cliPath: cli)
        XCTAssertFalse(try text(at: codexURL).contains("mcp_servers.omelette"))
        XCTAssertTrue(try text(at: codexURL).contains("model = \"gpt-6-astra\""))
    }

    func testAPathWithAQuoteIsEscapedIntoTheTOMLAndReadBack() throws {
        let weird = #"/Users/o"brien/Library/Application Support/UsageTracker/bin/omelette"#
        try MCPInstaller.installCodex(configURL: codexURL, cliPath: weird)

        let written = try text(at: codexURL)
        XCTAssertTrue(
            written.contains(#"command = "/Users/o\"brien/Library/Application Support/UsageTracker/bin/omelette""#),
            written
        )
        XCTAssertEqual(MCPInstaller.codexStatus(configURL: codexURL, cliPath: weird), .installed)
    }

    // MARK: - Codex: our table, however its header is spelled

    /// Our table as it sits in a real config: a line above it and a blank line after.
    /// `commandSuffix` puts something after the command, a comment for instance.
    private func codexConfig(header: String, commandSuffix: String = "") -> String {
        """
        model = "gpt-6-astra"

        \(header)
        command = "\(cli)"\(commandSuffix)
        args = ["mcp"]

        """
    }

    /// Tables that are ours, counted through the installer's own header rule. A count
    /// of the literal `[mcp_servers.omelette]` would miss the very spellings these
    /// tests are about.
    private func ourTableCount(in text: String) -> Int {
        SettingsFile.lines(of: text).filter { MCPInstaller.codexHeaderKey($0) == MCPInstaller.codexKey }.count
    }

    func testAHeaderKeyIsReadHoweverTOMLSpellsIt() {
        let ours = ["mcp_servers", "omelette"]
        XCTAssertEqual(MCPInstaller.codexKey, ours)
        XCTAssertEqual(MCPInstaller.codexHeaderKey("[mcp_servers.omelette]"), ours)
        XCTAssertEqual(MCPInstaller.codexHeaderKey("[mcp_servers.omelette] # Omelette MCP"), ours)
        XCTAssertEqual(MCPInstaller.codexHeaderKey(#"[mcp_servers."omelette"]"#), ours)
        XCTAssertEqual(MCPInstaller.codexHeaderKey("[mcp_servers.'omelette']"), ours)
        XCTAssertEqual(MCPInstaller.codexHeaderKey("[ mcp_servers.omelette ]"), ours)
        XCTAssertEqual(MCPInstaller.codexHeaderKey("  [mcp_servers . omelette]\r"), ours, "spaces around the dot, CRLF, indentation")
        XCTAssertEqual(MCPInstaller.codexHeaderKey("[mcp_servers.omelette.env]"), ["mcp_servers", "omelette", "env"])
        XCTAssertEqual(MCPInstaller.codexHeaderKey(#"[mcp_servers."a.b"]"#), ["mcp_servers", "a.b"], "a dot inside quotes is part of the name")
        XCTAssertEqual(MCPInstaller.codexHeaderKey(#"[mcp_servers."x#y"] # note"#), ["mcp_servers", "x#y"], "a hash inside quotes is not a comment")
        XCTAssertEqual(MCPInstaller.codexHeaderKey(#"[mcp_servers."say \"hi\""]"#), ["mcp_servers", #"say "hi""#], "an escaped quote does not close the name")
        XCTAssertEqual(MCPInstaller.codexHeaderKey("[[profiles.fast]]"), ["profiles", "fast"], "an array of tables is a header too")
    }

    func testALineThatIsNotAHeaderHasNoKey() {
        XCTAssertNil(MCPInstaller.codexHeaderKey(#"command = "x""#))
        XCTAssertNil(MCPInstaller.codexHeaderKey("# [mcp_servers.omelette]"), "a commented-out header is a comment")
        XCTAssertNil(MCPInstaller.codexHeaderKey(#"  ["a", "b"],"#), "a row of a nested array is not a header")
        XCTAssertNil(MCPInstaller.codexHeaderKey("[mcp_servers.omelette"))
        XCTAssertNil(MCPInstaller.codexHeaderKey("[mcp_servers..omelette]"))
        XCTAssertNil(MCPInstaller.codexHeaderKey(#"[mcp_servers."omelette]"#))
        XCTAssertNil(MCPInstaller.codexHeaderKey("[]"))
        XCTAssertNil(MCPInstaller.codexHeaderKey(""))
    }

    /// The three spellings the 2.7.0 review ran through Python's `tomllib`. Each one is
    /// our table, and each used to read as "not installed" and get a second table
    /// appended — a config Codex refuses to load ("Cannot declare ('mcp_servers',
    /// 'omelette') twice").
    func testOurTableUnderAnyHeaderSpellingIsInstalledAndInstallLeavesItAlone() throws {
        for header in [
            "[mcp_servers.omelette] # Omelette MCP",
            #"[mcp_servers."omelette"]"#,
            "[ mcp_servers.omelette ]",
        ] {
            let existing = codexConfig(header: header)
            try write(existing, to: codexURL)

            XCTAssertEqual(codexStatus, .installed, header)

            try MCPInstaller.installCodex(configURL: codexURL, cliPath: cli)

            let after = try text(at: codexURL)
            XCTAssertEqual(ourTableCount(in: after), 1, "\(header):\n\(after)")
            XCTAssertEqual(after, existing, "\(header): already installed, so the file is left exactly as it was")
        }
    }

    func testAnOlderPathUnderAQuotedHeaderIsUpdatedInPlace() throws {
        try write("""
        [mcp_servers."omelette"] # added by hand
        command = "/Users/other/Library/Application Support/UsageTracker/bin/omelette"
        args = ["mcp"]

        [mcp_servers.xcode]
        command = "xcrun"

        """, to: codexURL)
        XCTAssertEqual(codexStatus, .outdated)

        try MCPInstaller.installCodex(configURL: codexURL, cliPath: cli)

        let after = try text(at: codexURL)
        XCTAssertEqual(codexStatus, .installed)
        XCTAssertEqual(ourTableCount(in: after), 1, after)
        XCTAssertFalse(after.contains("/Users/other/"), after)
        XCTAssertTrue(after.contains("[mcp_servers.xcode]"), after)
    }

    /// The README's own hand-written example ends the command line with
    /// `# full path, no $HOME`. Read with the comment attached, the value ended in
    /// `$HOME`, not a quote, and the table was refused as one "with no command".
    func testACommentAfterTheCommandIsNotPartOfIt() throws {
        XCTAssertEqual(MCPInstaller.codexValue("command", in: [#"command = "/bin/omelette" # ours"#]), "/bin/omelette")
        XCTAssertEqual(
            MCPInstaller.codexValue("command", in: [#"command = "/tmp/#1/omelette"  # ours"#]), "/tmp/#1/omelette",
            "a hash inside the quotes is part of the path"
        )

        let existing = codexConfig(header: "[mcp_servers.omelette]", commandSuffix: "  # full path, no $HOME")
        try write(existing, to: codexURL)

        XCTAssertEqual(codexStatus, .installed)
        try MCPInstaller.installCodex(configURL: codexURL, cliPath: cli)
        XCTAssertEqual(try text(at: codexURL), existing)
    }

    func testRemoveFindsOurTableUnderAnyHeaderSpelling() throws {
        try write(codexConfig(header: "[ mcp_servers.'omelette' ] # Omelette"), to: codexURL)

        try MCPInstaller.removeCodex(configURL: codexURL, cliPath: cli)

        let after = try text(at: codexURL)
        XCTAssertEqual(ourTableCount(in: after), 0, after)
        XCTAssertFalse(after.contains("args"), after)
        XCTAssertTrue(after.contains("model = \"gpt-6-astra\""), after)
        XCTAssertEqual(codexStatus, .notInstalled)
    }

    func testOurTableEndsAtTheNextHeaderHoweverEitherIsSpelled() {
        let lines = [
            #"[mcp_servers."omelette"]"#,
            "command = \"x\"",
            "[ mcp_servers.omelette.env ] # ours too",
            "DEBUG = \"1\"",
            "[[profiles]]",
            "name = \"fast\"",
        ]
        XCTAssertEqual(MCPInstaller.codexTableRange(in: lines), 0..<4)
        XCTAssertNil(
            MCPInstaller.codexTableRange(in: ["[[mcp_servers.omelette]]", "command = \"x\""]),
            "an array of tables that shares the name is not our table"
        )
    }
}
