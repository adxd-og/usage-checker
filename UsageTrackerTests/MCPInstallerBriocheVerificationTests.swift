import XCTest
@testable import Omelette

/// Tester's verification of the MCP entries under two names (plan 2026-10-31-brioche-rename,
/// R5, R6, Review Focus 2): both orders of the two tables, every spelling of a header, a
/// foreign entry under either name, CRLF, a refused write that changes nothing, and a second
/// install that changes nothing more.
final class MCPInstallerBriocheVerificationTests: XCTestCase {
    private var root: URL!
    private let home = "/Users/tester/Library/Application Support/UsageTracker/bin"
    private var cli: String { home + "/brioche" }
    private var oldCLI: String { home + "/omelette" }
    private let otherHome = "/Users/other/Library/Application Support/UsageTracker/bin/omelette"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPInstallerBriocheVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var claudeURL: URL { root.appendingPathComponent(".claude.json") }
    private var codexURL: URL { root.appendingPathComponent("config.toml") }

    private func entry(_ command: String) -> [String: Any] {
        ["type": "stdio", "command": command, "args": ["mcp"]]
    }

    private func writeClaude(_ servers: [String: Any]) throws {
        let file: [String: Any] = ["numStartups": 7, "mcpServers": servers]
        try JSONSerialization.data(withJSONObject: file).write(to: claudeURL)
    }

    private func claudeServers() throws -> [String: Any] {
        let file = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: claudeURL)) as? [String: Any])
        return try XCTUnwrap(file["mcpServers"] as? [String: Any])
    }

    private func command(_ servers: [String: Any], _ key: String) -> String? {
        (servers[key] as? [String: Any])?["command"] as? String
    }

    private func claudeStatus(_ path: String? = nil) -> HookInstallStatus {
        MCPInstaller.claudeStatus(configURL: claudeURL, cliPath: path ?? cli)
    }

    private func codexStatus(_ path: String? = nil) -> HookInstallStatus {
        MCPInstaller.codexStatus(configURL: codexURL, cliPath: path ?? cli)
    }

    private func table(_ header: String, command: String, extra: String = "") -> String {
        "\(header)\ncommand = \"\(command)\"\nargs = [\"mcp\"]\n\(extra)\n"
    }

    private func codexText() throws -> String { try String(contentsOf: codexURL, encoding: .utf8) }

    private func writeCodex(_ text: String) throws { try text.write(to: codexURL, atomically: true, encoding: .utf8) }

    private func count(_ key: [String], in text: String) -> Int {
        SettingsFile.lines(of: text).filter { MCPInstaller.codexHeaderKey($0) == key }.count
    }

    /// The command of the one table with this key (the first, if the file is wrong).
    private func tableCommand(_ key: [String], in text: String) -> String? {
        let lines = SettingsFile.lines(of: text)
        guard let range = MCPInstaller.codexTableRange(in: lines, key: key) else { return nil }
        return MCPInstaller.codexValue("command", in: Array(lines[range]))
    }

    // MARK: - Claude Code

    func testASecondClaudeInstallChangesNothing() throws {
        try writeClaude(["omelette": entry(oldCLI)])
        try MCPInstaller.installClaude(configURL: claudeURL, cliPath: cli)
        let first = try Data(contentsOf: claudeURL)

        try MCPInstaller.installClaude(configURL: claudeURL, cliPath: cli)

        XCTAssertEqual(try Data(contentsOf: claudeURL), first)
        XCTAssertEqual(claudeStatus(), .installed)
    }

    func testTheFirstWriteKeepsTheOriginalUnderTheBackupNameThatDidNotChange() throws {
        try writeClaude(["omelette": entry(oldCLI)])
        let original = try Data(contentsOf: claudeURL)

        try MCPInstaller.installClaude(configURL: claudeURL, cliPath: cli)

        let backup = claudeURL.deletingLastPathComponent().appendingPathComponent(".claude.json.omelette-backup")
        XCTAssertEqual(try Data(contentsOf: backup), original)
    }

    func testAnOldEntryWithAnotherShapeOffersAnUpdateAndTheUpdateFixesIt() throws {
        try writeClaude(["omelette": ["command": oldCLI]])   // no type, no args
        XCTAssertEqual(claudeStatus(), .outdated)

        try MCPInstaller.installClaude(configURL: claudeURL, cliPath: cli)

        let servers = try claudeServers()
        XCTAssertNil(servers["omelette"])
        XCTAssertEqual(servers["brioche"] as? NSDictionary, entry(cli) as NSDictionary)
    }

    func testWhenBriocheIsTakenANewSetupIsWrittenAsBriocheKeyRunningTheOldLink() throws {
        // `usableCLILink` hands the installers bin/omelette when bin/brioche is another tool's.
        try writeClaude([:])

        try MCPInstaller.installClaude(configURL: claudeURL, cliPath: oldCLI)

        XCTAssertEqual(command(try claudeServers(), "brioche"), oldCLI)
        XCTAssertEqual(claudeStatus(oldCLI), .installed)
    }

    func testAnOldEntryReadsAsInstalledForTheOldLinkToo() throws {
        try writeClaude(["omelette": entry(oldCLI)])

        XCTAssertEqual(claudeStatus(oldCLI), .installed)
    }

    func testAnOldEntryWrittenForAnotherHomeIsOursEvenThoughItIsOutdated() throws {
        try writeClaude(["omelette": entry(otherHome)])

        try MCPInstaller.installClaude(configURL: claudeURL, cliPath: cli)

        let servers = try claudeServers()
        XCTAssertNil(servers["omelette"])
        XCTAssertEqual(command(servers, "brioche"), cli)
    }

    func testRemoveTakesOnlyOursWhenBriocheIsForeign() throws {
        try writeClaude(["brioche": entry("/opt/homebrew/bin/brioche"), "omelette": entry(oldCLI)])

        try MCPInstaller.removeClaude(configURL: claudeURL, cliPath: cli)

        let servers = try claudeServers()
        XCTAssertNil(servers["omelette"])
        XCTAssertEqual(command(servers, "brioche"), "/opt/homebrew/bin/brioche")
    }

    func testRemoveTakesOnlyBriocheWhenOmeletteIsForeign() throws {
        try writeClaude(["brioche": entry(cli), "omelette": entry("/usr/local/bin/omelette")])

        try MCPInstaller.removeClaude(configURL: claudeURL, cliPath: cli)

        let servers = try claudeServers()
        XCTAssertNil(servers["brioche"])
        XCTAssertEqual(command(servers, "omelette"), "/usr/local/bin/omelette")
    }

    func testAnOurBriocheNextToAForeignOmeletteReadsAsInstalledAndSurvivesAnInstall() throws {
        try writeClaude(["brioche": entry(cli), "omelette": entry("/usr/local/bin/omelette")])
        XCTAssertEqual(claudeStatus(), .installed)

        try MCPInstaller.installClaude(configURL: claudeURL, cliPath: cli)

        XCTAssertEqual(command(try claudeServers(), "omelette"), "/usr/local/bin/omelette")
        XCTAssertEqual(claudeStatus(), .installed)
    }

    func testAnOldEntryWithoutACommandIsNobodysBusiness() throws {
        try writeClaude(["omelette": ["type": "stdio"]])
        XCTAssertEqual(claudeStatus(), .notInstalled)

        try MCPInstaller.installClaude(configURL: claudeURL, cliPath: cli)

        XCTAssertNotNil(try claudeServers()["omelette"])
        XCTAssertEqual(command(try claudeServers(), "brioche"), cli)
    }

    func testABriocheEntryWithoutACommandRefusesAWriteAndNothingIsWritten() throws {
        try writeClaude(["brioche": ["type": "stdio"], "omelette": entry(oldCLI)])
        let before = try Data(contentsOf: claudeURL)

        XCTAssertEqual(claudeStatus(), .installed, "the old entry works; Disable has to reach it")
        XCTAssertThrowsError(try MCPInstaller.installClaude(configURL: claudeURL, cliPath: cli))
        XCTAssertEqual(try Data(contentsOf: claudeURL), before)
    }

    func testACommandIsOursWhenItNamesTheBinFolderWhicheverLinkItRuns() throws {
        // As before the rename: a command is ours when it names the bin folder, whichever link.
        XCTAssertTrue(MCPInstaller.isOurCommand(oldCLI))
        XCTAssertTrue(MCPInstaller.isOurCommand(cli))
        XCTAssertFalse(MCPInstaller.isOurCommand("/opt/homebrew/bin/brioche"))
        XCTAssertFalse(MCPInstaller.isOurCommand("/usr/local/bin/omelette"))
        XCTAssertFalse(MCPInstaller.isOurCommand("/Users/tester/Library/Application Support/UsageTracker/brioche"))
    }

    // MARK: - Codex

    func testEveryHeaderSpellingOfBothNamesIsReadAndMovedWithoutADuplicate() throws {
        let oldHeaders = ["[mcp_servers.omelette]", #"[mcp_servers."omelette"]"#, "[mcp_servers.'omelette']  # mine",
                          "[ mcp_servers . omelette ]", "  [mcp_servers.omelette]"]
        let newHeaders = ["[mcp_servers.brioche]", #"[mcp_servers."brioche"]"#, "[ mcp_servers . 'brioche' ] # note"]
        for old in oldHeaders {
            try writeCodex("model = \"m\"\n\n" + table(old, command: oldCLI))
            XCTAssertEqual(codexStatus(), .installed, old)
            try MCPInstaller.installCodex(configURL: codexURL, cliPath: cli)
            var after = try codexText()
            XCTAssertEqual(count(MCPInstaller.legacyCodexKey, in: after), 0, "\(old)\n\(after)")
            XCTAssertEqual(count(MCPInstaller.codexKey, in: after), 1, "\(old)\n\(after)")
            XCTAssertEqual(codexStatus(), .installed, after)

            for new in newHeaders {
                try writeCodex(table(old, command: oldCLI) + table(new, command: cli))
                XCTAssertEqual(codexStatus(), .outdated, "\(old) + \(new)")
                try MCPInstaller.installCodex(configURL: codexURL, cliPath: cli)
                after = try codexText()
                XCTAssertEqual(count(MCPInstaller.legacyCodexKey, in: after), 0, "\(old) + \(new)\n\(after)")
                XCTAssertEqual(count(MCPInstaller.codexKey, in: after), 1, "\(old) + \(new)\n\(after)")
                XCTAssertEqual(codexStatus(), .installed, after)
            }
        }
    }

    func testAStaleBriocheTableAndAnOldOneFoldIntoOneWithTheRightCommandInEitherOrder() throws {
        let stale = table("[mcp_servers.brioche]", command: "/Users/other/Library/Application Support/UsageTracker/bin/brioche")
        let old = table("[mcp_servers.omelette]", command: oldCLI)
        let tail = "[mcp_servers.xcode]\ncommand = \"xcrun\"\n"
        for text in [stale + old + tail, old + stale + tail, old + tail + "\n" + stale, tail + "\n" + stale + old] {
            try writeCodex(text)
            XCTAssertEqual(codexStatus(), .outdated, text)

            try MCPInstaller.installCodex(configURL: codexURL, cliPath: cli)

            let after = try codexText()
            XCTAssertEqual(count(MCPInstaller.legacyCodexKey, in: after), 0, after)
            XCTAssertEqual(count(MCPInstaller.codexKey, in: after), 1, after)
            XCTAssertEqual(tableCommand(MCPInstaller.codexKey, in: after), cli, after)
            XCTAssertEqual(count(["mcp_servers", "xcode"], in: after), 1, after)
            XCTAssertEqual(codexStatus(), .installed, after)
        }
    }

    func testSubTablesOfBothFoldAwayWithTheirParentsInEitherOrder() throws {
        let old = table("[mcp_servers.omelette]", command: oldCLI, extra: "[mcp_servers.omelette.env]\nA = \"1\"\n")
        let new = table("[mcp_servers.brioche]", command: cli, extra: "[mcp_servers.brioche.env]\nB = \"2\"\n")
        let tail = "[other]\nx = 1\n"
        for text in [old + new + tail, new + old + tail, old + tail + new] {
            try writeCodex(text)

            try MCPInstaller.installCodex(configURL: codexURL, cliPath: cli)

            let after = try codexText()
            XCTAssertFalse(after.contains("mcp_servers.omelette"), after)
            XCTAssertEqual(count(MCPInstaller.codexKey, in: after), 1, after)
            XCTAssertEqual(count(["other"], in: after), 1, after)
            XCTAssertFalse(after.contains("A = \"1\""), "the old table's own sub-table goes with it:\n\(after)")
            XCTAssertEqual(codexStatus(), .installed, after)
        }
    }

    func testASecondInstallChangesNothingAndNeitherDoesOneOnACleanBrioche() throws {
        try writeCodex("model = \"m\"\n\n" + table("[mcp_servers.omelette]", command: oldCLI) + "[x]\ny = 1\n")
        try MCPInstaller.installCodex(configURL: codexURL, cliPath: cli)
        let first = try Data(contentsOf: codexURL)

        try MCPInstaller.installCodex(configURL: codexURL, cliPath: cli)

        XCTAssertEqual(try Data(contentsOf: codexURL), first)
    }

    func testAForeignBriocheTableRefusesAWriteAroundOurOldOne() throws {
        let text = table("[mcp_servers.omelette]", command: oldCLI) + table("[mcp_servers.brioche]", command: "/opt/homebrew/bin/brioche")
        try writeCodex(text)

        XCTAssertEqual(codexStatus(), .installed, "the old table works; Disable has to reach it")
        XCTAssertThrowsError(try MCPInstaller.installCodex(configURL: codexURL, cliPath: cli))

        XCTAssertEqual(try codexText(), text)
    }

    func testRemoveTakesOnlyOursFromCodexWhenBriocheIsForeign() throws {
        let foreign = table("[mcp_servers.brioche]", command: "/opt/homebrew/bin/brioche")
        try writeCodex(table("[mcp_servers.omelette]", command: oldCLI) + foreign)

        try MCPInstaller.removeCodex(configURL: codexURL, cliPath: cli)

        let after = try codexText()
        XCTAssertEqual(count(MCPInstaller.legacyCodexKey, in: after), 0, after)
        XCTAssertEqual(tableCommand(MCPInstaller.codexKey, in: after), "/opt/homebrew/bin/brioche", after)
    }

    func testRemoveTakesBriocheFromCodexAndLeavesAForeignOmelette() throws {
        try writeCodex(table("[mcp_servers.brioche]", command: cli) + table("[mcp_servers.omelette]", command: "/opt/homebrew/bin/omelette"))

        try MCPInstaller.removeCodex(configURL: codexURL, cliPath: cli)

        let after = try codexText()
        XCTAssertEqual(count(MCPInstaller.codexKey, in: after), 0, after)
        XCTAssertEqual(tableCommand(MCPInstaller.legacyCodexKey, in: after), "/opt/homebrew/bin/omelette", after)
    }

    func testRemovingBothAdjacentTablesInEitherOrderLeavesTheRestByteForByte() throws {
        let before = "model = \"m\"\n\n[a]\nx = 1\n\n"
        let after = "[b]\ny = 2\n"
        let old = table("[mcp_servers.omelette]", command: oldCLI)
        let new = table("[mcp_servers.brioche]", command: cli)
        for pair in [old + new, new + old] {
            try writeCodex(before + pair + after)

            try MCPInstaller.removeCodex(configURL: codexURL, cliPath: cli)

            let text = try codexText()
            XCTAssertTrue(text.hasPrefix("model = \"m\"\n\n[a]\nx = 1\n"), text)
            XCTAssertTrue(text.hasSuffix("[b]\ny = 2\n"), text)
            XCTAssertFalse(text.contains("mcp_servers"), text)
        }
    }

    func testAnArrayOfTablesNamedOmeletteIsNotOurTable() throws {
        let text = "[[mcp_servers.omelette]]\ncommand = \"\(oldCLI)\"\nargs = [\"mcp\"]\n"
        try writeCodex(text)

        XCTAssertEqual(codexStatus(), .notInstalled)
        try MCPInstaller.removeCodex(configURL: codexURL, cliPath: cli)
        XCTAssertEqual(try codexText(), text)
    }

    func testAnOldTableWithoutACommandIsNobodysBusinessAndIsLeft() throws {
        let broken = "[mcp_servers.omelette]\nargs = [\"mcp\"]\n\n"
        try writeCodex(broken)
        XCTAssertEqual(codexStatus(), .notInstalled)

        try MCPInstaller.installCodex(configURL: codexURL, cliPath: cli)

        let after = try codexText()
        XCTAssertTrue(after.contains(broken.trimmingCharacters(in: .whitespacesAndNewlines)), after)
        XCTAssertEqual(count(MCPInstaller.codexKey, in: after), 1, after)
    }

    func testWhenBriocheIsTakenANewCodexSetupIsBriocheRunningTheOldLinkAndReadsInstalled() throws {
        try writeCodex("model = \"m\"\n")

        try MCPInstaller.installCodex(configURL: codexURL, cliPath: oldCLI)

        let after = try codexText()
        XCTAssertEqual(tableCommand(MCPInstaller.codexKey, in: after), oldCLI, after)
        XCTAssertEqual(codexStatus(oldCLI), .installed)
    }

    func testAnOldTableReadsAsInstalledForTheOldLinkToo() throws {
        try writeCodex(table("[mcp_servers.omelette]", command: oldCLI))

        XCTAssertEqual(codexStatus(oldCLI), .installed)
    }

    func testCRLFWithBothTablesInEitherOrderFoldsIntoOneAndStaysCRLF() throws {
        func crlf(_ header: String, _ command: String) -> [String] {
            [header, "command = \"\(command)\"", "args = [\"mcp\"]", ""]
        }
        for order in [0, 1] {
            let old = crlf("[mcp_servers.omelette]", oldCLI)
            let new = crlf("[mcp_servers.brioche]", "/Users/other/Library/Application Support/UsageTracker/bin/brioche")
            let lines = ["model = \"x\"", ""] + (order == 0 ? old + new : new + old) + ["[t]", "k = 1", ""]
            try writeCodex(lines.joined(separator: "\r\n"))

            try MCPInstaller.installCodex(configURL: codexURL, cliPath: cli)

            let after = try codexText()
            XCTAssertEqual(count(MCPInstaller.codexKey, in: after), 1, after)
            XCTAssertEqual(count(MCPInstaller.legacyCodexKey, in: after), 0, after)
            XCTAssertEqual(tableCommand(MCPInstaller.codexKey, in: after), cli, after)
            // `SettingsFile.writeText` (untouched by the rename) adds one bare LF to a text that ends
            // in CRLF, because Swift reads "\r\n" as one character and `hasSuffix("\n")` is false.
            // That is older than the rename and reported; here only the lines we move must be CRLF.
            var body = after
            if body.hasSuffix("\r\n\n") { body = String(body.dropLast("\r\n\n".count)) + "\r\n" }
            XCTAssertFalse(body.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "a bare LF crept in:\n\(after.debugDescription)")
        }
    }
}
