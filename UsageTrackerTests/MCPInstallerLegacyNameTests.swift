import XCTest
@testable import Omelette

/// The rename (plan 2026-10-31-brioche-rename, R5, R6): an MCP entry written before it is
/// named `omelette` and runs `bin/omelette`. It keeps working and stays ours, a foreign
/// `omelette` is nobody's business, and a write leaves one entry under the new name.
final class MCPInstallerLegacyNameTests: XCTestCase {
    private var root: URL!
    private let cli = "/Users/tester/Library/Application Support/UsageTracker/bin/brioche"
    private let oldCLI = "/Users/tester/Library/Application Support/UsageTracker/bin/omelette"
    private let otherHome = "/Users/other/Library/Application Support/UsageTracker/bin/omelette"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPInstallerLegacyNameTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var claudeURL: URL { root.appendingPathComponent(".claude.json") }
    private var codexURL: URL { root.appendingPathComponent("config.toml") }

    private func text(at url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    private func entry(_ command: String) -> [String: Any] {
        ["type": "stdio", "command": command, "args": ["mcp"]]
    }

    private func writeClaude(_ servers: [String: Any]) throws {
        let file: [String: Any] = ["numStartups": 42, "mcpServers": servers]
        try JSONSerialization.data(withJSONObject: file).write(to: claudeURL)
    }

    private func claudeFile() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: claudeURL)) as? [String: Any])
    }

    private func claudeServers() throws -> [String: Any] {
        try XCTUnwrap(try claudeFile()["mcpServers"] as? [String: Any])
    }

    private var claudeStatus: HookInstallStatus {
        MCPInstaller.claudeStatus(configURL: claudeURL, cliPath: cli)
    }

    private var codexStatus: HookInstallStatus {
        MCPInstaller.codexStatus(configURL: codexURL, cliPath: cli)
    }

    /// A table of a server, as it sits in a real config.
    private func table(_ header: String, command: String) -> String {
        "\(header)\ncommand = \"\(command)\"\nargs = [\"mcp\"]\n\n"
    }

    private func tableCount(_ key: [String], in text: String) -> Int {
        SettingsFile.lines(of: text).filter { MCPInstaller.codexHeaderKey($0) == key }.count
    }

    // MARK: - Claude Code

    func testACompleteOldClaudeEntryReadsAsInstalled() throws {
        try writeClaude(["omelette": entry(oldCLI)])

        XCTAssertEqual(claudeStatus, .installed, "it works; moving it would rename an agent's tools")
    }

    func testAnOldClaudeEntryFromAnotherHomeOffersAnUpdate() throws {
        try writeClaude(["omelette": entry(otherHome)])

        XCTAssertEqual(claudeStatus, .outdated)
    }

    func testAWriteMovesAnOldClaudeEntryWithoutADuplicate() throws {
        try writeClaude(["omelette": entry(oldCLI), "xcode": ["command": "xcrun"]])

        try MCPInstaller.installClaude(configURL: claudeURL, cliPath: cli)

        let servers = try claudeServers()
        XCTAssertNil(servers["omelette"])
        XCTAssertEqual((servers["brioche"] as? [String: Any])?["command"] as? String, cli)
        XCTAssertNotNil(servers["xcode"])
        XCTAssertEqual(try claudeFile()["numStartups"] as? Int, 42)
        XCTAssertEqual(claudeStatus, .installed)
    }

    func testBothNamesOfOursOfferAnUpdateThatLeavesOne() throws {
        try writeClaude(["omelette": entry(oldCLI), "brioche": entry(cli)])
        XCTAssertEqual(claudeStatus, .outdated)

        try MCPInstaller.installClaude(configURL: claudeURL, cliPath: cli)

        let servers = try claudeServers()
        XCTAssertNil(servers["omelette"])
        XCTAssertNotNil(servers["brioche"])
        XCTAssertEqual(claudeStatus, .installed)
    }

    func testAForeignOmeletteNeitherBlocksUsNorGetsTouched() throws {
        try writeClaude(["omelette": entry("/usr/local/bin/omelette")])
        XCTAssertEqual(claudeStatus, .notInstalled)

        try MCPInstaller.installClaude(configURL: claudeURL, cliPath: cli)

        let servers = try claudeServers()
        XCTAssertEqual((servers["omelette"] as? [String: Any])?["command"] as? String, "/usr/local/bin/omelette")
        XCTAssertEqual((servers["brioche"] as? [String: Any])?["command"] as? String, cli)
        XCTAssertEqual(claudeStatus, .installed)
    }

    func testAForeignBriocheIsAConflictAndOurOldEntryStays() throws {
        try writeClaude(["brioche": entry("/opt/homebrew/bin/brioche"), "omelette": entry(oldCLI)])

        XCTAssertEqual(claudeStatus, .conflict("/opt/homebrew/bin/brioche"))
        XCTAssertThrowsError(try MCPInstaller.installClaude(configURL: claudeURL, cliPath: cli))
        XCTAssertNotNil(try claudeServers()["omelette"], "a refused write changes nothing")
    }

    func testRemoveTakesBothNamesOfOursAndPrunesTheMap() throws {
        try writeClaude(["omelette": entry(oldCLI), "brioche": entry(cli)])

        try MCPInstaller.removeClaude(configURL: claudeURL, cliPath: cli)

        XCTAssertNil(try claudeFile()["mcpServers"])
        XCTAssertEqual(try claudeFile()["numStartups"] as? Int, 42)
        XCTAssertEqual(claudeStatus, .notInstalled)
    }

    func testRemoveLeavesAForeignOmeletteAndDoesNotRewriteTheFile() throws {
        try writeClaude(["omelette": entry("/usr/local/bin/omelette")])
        let before = try Data(contentsOf: claudeURL)

        try MCPInstaller.removeClaude(configURL: claudeURL, cliPath: cli)

        XCTAssertEqual(try Data(contentsOf: claudeURL), before)
    }

    // MARK: - Codex

    func testACompleteOldCodexTableReadsAsInstalledHoweverItsHeaderIsSpelled() throws {
        for header in ["[mcp_servers.omelette]", #"[mcp_servers."omelette"] # mine"#, "[ mcp_servers . 'omelette' ]"] {
            try table(header, command: oldCLI).write(to: codexURL, atomically: true, encoding: .utf8)

            XCTAssertEqual(codexStatus, .installed, header)
        }
    }

    func testAnOldCodexTableFromAnotherHomeOffersAnUpdate() throws {
        try table("[mcp_servers.omelette]", command: otherHome).write(to: codexURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(codexStatus, .outdated)
    }

    func testAWriteReplacesAnOldCodexTableWhereItIs() throws {
        let existing = "model = \"gpt-6-astra\"\n\n"
            + table("[mcp_servers.omelette]", command: oldCLI)
            + "[mcp_servers.xcode]\ncommand = \"xcrun\"\n"
        try existing.write(to: codexURL, atomically: true, encoding: .utf8)

        try MCPInstaller.installCodex(configURL: codexURL, cliPath: cli)

        let after = try text(at: codexURL)
        XCTAssertEqual(tableCount(MCPInstaller.legacyCodexKey, in: after), 0, after)
        XCTAssertEqual(tableCount(MCPInstaller.codexKey, in: after), 1, after)
        let ours = try XCTUnwrap(after.range(of: MCPInstaller.codexHeader))
        let theirs = try XCTUnwrap(after.range(of: "[mcp_servers.xcode]"))
        XCTAssertLessThan(ours.lowerBound, theirs.lowerBound, "where the old one stood:\n\(after)")
        XCTAssertTrue(after.hasPrefix("model = \"gpt-6-astra\""), after)
        XCTAssertEqual(codexStatus, .installed)
    }

    func testBothTablesOfOursOfferAnUpdateThatLeavesOneInEitherOrder() throws {
        let old = table("[mcp_servers.omelette]", command: oldCLI)
        let new = table("[mcp_servers.brioche]", command: cli)
        let theirs = "[mcp_servers.xcode]\ncommand = \"xcrun\"\n"
        for existing in [old + new + theirs, new + old + theirs, old + theirs + "\n" + new] {
            try existing.write(to: codexURL, atomically: true, encoding: .utf8)
            XCTAssertEqual(codexStatus, .outdated, existing)

            try MCPInstaller.installCodex(configURL: codexURL, cliPath: cli)

            let after = try text(at: codexURL)
            XCTAssertEqual(tableCount(MCPInstaller.legacyCodexKey, in: after), 0, after)
            XCTAssertEqual(tableCount(MCPInstaller.codexKey, in: after), 1, after)
            XCTAssertTrue(after.contains(theirs.trimmingCharacters(in: .newlines)), after)
            XCTAssertEqual(codexStatus, .installed, after)
        }
    }

    func testAForeignOldTableIsLeftAndOursIsAppended() throws {
        let theirs = table("[mcp_servers.omelette]", command: "/opt/homebrew/bin/omelette")
        try theirs.write(to: codexURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(codexStatus, .notInstalled)

        try MCPInstaller.installCodex(configURL: codexURL, cliPath: cli)

        let after = try text(at: codexURL)
        XCTAssertTrue(after.contains("/opt/homebrew/bin/omelette"), after)
        XCTAssertEqual(tableCount(MCPInstaller.codexKey, in: after), 1, after)
        XCTAssertEqual(codexStatus, .installed)
    }

    /// A sub-table belongs to its parent: left behind, Codex refuses the config.
    func testAnOldTableGoesWithItsSubTable() throws {
        let existing = table("[mcp_servers.omelette]", command: oldCLI) + "[mcp_servers.omelette.env]\nDEBUG = \"1\"\n"
        try existing.write(to: codexURL, atomically: true, encoding: .utf8)

        try MCPInstaller.installCodex(configURL: codexURL, cliPath: cli)

        let after = try text(at: codexURL)
        XCTAssertFalse(after.contains("mcp_servers.omelette"), after)
        XCTAssertEqual(tableCount(MCPInstaller.codexKey, in: after), 1, after)
    }

    func testRemoveTakesBothCodexTablesAndNothingElse() throws {
        let existing = table("[mcp_servers.omelette]", command: oldCLI)
            + "[mcp_servers.xcode]\ncommand = \"xcrun\"\n\n"
            + table("[mcp_servers.brioche]", command: cli)
        try existing.write(to: codexURL, atomically: true, encoding: .utf8)

        try MCPInstaller.removeCodex(configURL: codexURL, cliPath: cli)

        let after = try text(at: codexURL)
        XCTAssertFalse(after.contains("mcp_servers.omelette"), after)
        XCTAssertFalse(after.contains("mcp_servers.brioche"), after)
        XCTAssertTrue(after.contains("[mcp_servers.xcode]"), after)
        XCTAssertEqual(codexStatus, .notInstalled)
    }

    func testACRLFOldTableMovesAndStaysCRLF() throws {
        let crlf = ["model = \"x\"", "", "[mcp_servers.omelette]", "command = \"\(oldCLI)\"", "args = [\"mcp\"]", ""]
            .joined(separator: "\r\n")
        try crlf.write(to: codexURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(codexStatus, .installed)

        try MCPInstaller.installCodex(configURL: codexURL, cliPath: cli)

        let after = try text(at: codexURL)
        XCTAssertEqual(tableCount(MCPInstaller.codexKey, in: after), 1, after)
        XCTAssertEqual(tableCount(MCPInstaller.legacyCodexKey, in: after), 0, after)
        XCTAssertFalse(after.replacingOccurrences(of: "\r\n", with: "").contains("\n"), after)
    }
}
