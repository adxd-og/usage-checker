import XCTest
@testable import Omelette

/// An entry of ours in `config.toml` is its table and every sub-table, wherever they stand
/// (whole-branch review of 4.0, Codex P1, ruling of 2026-10-31): TOML lets
/// `[mcp_servers.omelette.env]` sit after another server's table or before its parent, and a
/// sub-table left behind makes Codex refuse the file or run a server we no longer own. A foreign
/// entry's sub-tables are nobody's business.
final class MCPInstallerEntrySectionsTests: XCTestCase {
    private var root: URL!
    private let cli = "/Users/tester/Library/Application Support/UsageTracker/bin/brioche"
    private let oldCLI = "/Users/tester/Library/Application Support/UsageTracker/bin/omelette"
    private let otherHome = "/Users/other/Library/Application Support/UsageTracker/bin/omelette"
    private let foreign = "/opt/homebrew/bin/brioche"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPInstallerEntrySectionsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var claudeURL: URL { root.appendingPathComponent(".claude.json") }
    private var codexURL: URL { root.appendingPathComponent("config.toml") }

    private var codexStatus: HookInstallStatus {
        MCPInstaller.codexStatus(configURL: codexURL, cliPath: cli)
    }

    private var claudeStatus: HookInstallStatus {
        MCPInstaller.claudeStatus(configURL: claudeURL, cliPath: cli)
    }

    private func table(_ header: String, command: String) -> String {
        "\(header)\ncommand = \"\(command)\"\nargs = [\"mcp\"]\n\n"
    }

    private func codexText() throws -> String { try String(contentsOf: codexURL, encoding: .utf8) }

    private func writeCodex(_ text: String) throws { try text.write(to: codexURL, atomically: true, encoding: .utf8) }

    private func count(_ key: [String], in text: String) -> Int {
        SettingsFile.lines(of: text).filter { MCPInstaller.codexHeaderKey($0) == key }.count
    }

    private func writeClaude(_ servers: [String: Any]) throws {
        let file: [String: Any] = ["numStartups": 7, "mcpServers": servers]
        try JSONSerialization.data(withJSONObject: file).write(to: claudeURL)
    }

    private func claudeServers() throws -> [String: Any] {
        let file = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: claudeURL)) as? [String: Any])
        return try XCTUnwrap(file["mcpServers"] as? [String: Any])
    }

    private func entry(_ command: String) -> [String: Any] {
        ["type": "stdio", "command": command, "args": ["mcp"]]
    }

    private let env = "[mcp_servers.omelette.env]\nDEBUG = \"1\"\n\n"
    private let xcode = "[mcp_servers.xcode]\ncommand = \"xcrun\"\n\n"

    // MARK: - Finding the sections

    func testAnEntryIsItsTableAndEverySubTableWhereverTheyStand() {
        let lines = [
            "[mcp_servers.brioche.tools]",      // 0: before its parent
            "a = 1",
            "[mcp_servers.xcode]",              // 2
            "command = \"xcrun\"",
            "[mcp_servers.brioche]",            // 4: the table
            "command = \"x\"",
            "[mcp_servers.xcode.env]",          // 6
            "b = 2",
            #"[ mcp_servers . "brioche" . env ] # ours"#, // 8: after someone else's
            "c = 3",
            "[other]",                          // 10
        ]
        XCTAssertEqual(MCPInstaller.codexEntryRanges(in: lines), [0..<2, 4..<6, 8..<10])
    }

    func testAKeyThatOnlyStartsLikeOursIsNotOurs() {
        let lines = [
            "[mcp_servers.brioche]",
            "command = \"x\"",
            "[mcp_servers.brioche-beta.env]",
            "a = 1",
            "[mcp_servers.briochette]",
            "b = 2",
        ]
        XCTAssertEqual(MCPInstaller.codexEntryRanges(in: lines), [0..<2])
    }

    func testSubTablesWithNoTableAreNobodysEntry() {
        XCTAssertEqual(MCPInstaller.codexEntryRanges(in: ["[mcp_servers.brioche.env]", "a = 1"]), [])
    }

    // MARK: - Install

    func testAnOldTablesSubTableAfterAnotherServersTableFoldsAway() throws {
        try writeCodex(table("[mcp_servers.omelette]", command: oldCLI) + xcode + env)
        XCTAssertEqual(codexStatus, .outdated, "it holds more than this build would write")

        try MCPInstaller.installCodex(configURL: codexURL, cliPath: cli)

        let after = try codexText()
        XCTAssertFalse(after.contains("mcp_servers.omelette"), after)
        XCTAssertFalse(after.contains("DEBUG"), after)
        XCTAssertEqual(count(MCPInstaller.codexKey, in: after), 1, after)
        XCTAssertEqual(count(["mcp_servers", "xcode"], in: after), 1, after)
        XCTAssertEqual(codexStatus, .installed, after)
    }

    func testAnOldTablesSubTableBeforeItsParentFoldsAway() throws {
        try writeCodex(env + xcode + table("[mcp_servers.omelette]", command: oldCLI))
        XCTAssertEqual(codexStatus, .outdated)

        try MCPInstaller.installCodex(configURL: codexURL, cliPath: cli)

        let after = try codexText()
        XCTAssertFalse(after.contains("mcp_servers.omelette"), after)
        XCTAssertFalse(after.contains("DEBUG"), after)
        XCTAssertEqual(count(MCPInstaller.codexKey, in: after), 1, after)
        XCTAssertEqual(codexStatus, .installed, after)
    }

    func testBothOfOursFoldWithTheirSubTablesInAnyPosition() throws {
        let old = table("[mcp_servers.omelette]", command: oldCLI)
        let new = table("[mcp_servers.brioche]", command: cli)
        let newEnv = "[mcp_servers.brioche.env]\nKEEP = \"no\"\n\n"
        for text in [
            old + xcode + env + new + newEnv,
            newEnv + env + xcode + new + old,
            env + new + xcode + newEnv + old,
        ] {
            try writeCodex(text)
            XCTAssertEqual(codexStatus, .outdated, text)

            try MCPInstaller.installCodex(configURL: codexURL, cliPath: cli)

            let after = try codexText()
            XCTAssertFalse(after.contains("mcp_servers.omelette"), after)
            XCTAssertFalse(after.contains("mcp_servers.brioche.env"), after)
            XCTAssertEqual(count(MCPInstaller.codexKey, in: after), 1, after)
            XCTAssertEqual(count(["mcp_servers", "xcode"], in: after), 1, after)
            XCTAssertEqual(codexStatus, .installed, after)
        }
    }

    /// A current table with a sub-table elsewhere is what an adjoining one already was: more than
    /// this build writes, so Update offers to fold it. The status and the write agree.
    func testACurrentTableWithAFarSubTableReadsOutdatedAndAnUpdateCleansIt() throws {
        let newEnv = "[mcp_servers.brioche.env]\nDEBUG = \"1\"\n\n"
        try writeCodex(table("[mcp_servers.brioche]", command: cli) + xcode + newEnv)
        XCTAssertEqual(codexStatus, .outdated)

        try MCPInstaller.installCodex(configURL: codexURL, cliPath: cli)

        let after = try codexText()
        XCTAssertFalse(after.contains("DEBUG"), after)
        XCTAssertEqual(codexStatus, .installed, after)
    }

    func testAForeignOldEntrysSubTablesAreUntouchedInAnyPosition() throws {
        let theirs = table("[mcp_servers.omelette]", command: "/opt/homebrew/bin/omelette")
        for text in [theirs + xcode + env, env + xcode + theirs] {
            try writeCodex(text)
            XCTAssertEqual(codexStatus, .notInstalled, text)

            try MCPInstaller.installCodex(configURL: codexURL, cliPath: cli)

            let after = try codexText()
            XCTAssertTrue(after.contains("[mcp_servers.omelette.env]\nDEBUG = \"1\""), after)
            XCTAssertTrue(after.contains("/opt/homebrew/bin/omelette"), after)
            XCTAssertEqual(codexStatus, .installed, after)

            try MCPInstaller.removeCodex(configURL: codexURL, cliPath: cli)

            let removed = try codexText()
            XCTAssertTrue(removed.contains("[mcp_servers.omelette.env]\nDEBUG = \"1\""), removed)
            XCTAssertTrue(removed.contains("/opt/homebrew/bin/omelette"), removed)
        }
    }

    func testACRLFFileFoldsAFarSubTableAndStaysCRLF() throws {
        let lf = "model = \"m\"\n\n" + env + xcode + table("[mcp_servers.omelette]", command: oldCLI) + "[z]\na = 1\n"
        try writeCodex(lf.replacingOccurrences(of: "\n", with: "\r\n"))
        XCTAssertEqual(codexStatus, .outdated)

        try MCPInstaller.installCodex(configURL: codexURL, cliPath: cli)

        let after = try codexText()
        XCTAssertFalse(after.contains("mcp_servers.omelette"), after)
        XCTAssertEqual(count(MCPInstaller.codexKey, in: after), 1, after)
        XCTAssertFalse(after.replacingOccurrences(of: "\r\n", with: "").contains("\n"), after)
        XCTAssertEqual(codexStatus, .installed, after)
    }

    // MARK: - Remove

    func testRemoveTakesEverySubTableUnderEitherNameInAnyPosition() throws {
        let newEnv = "[mcp_servers.brioche.env]\nB = \"2\"\n\n"
        let old = table("[mcp_servers.omelette]", command: oldCLI)
        let new = table("[mcp_servers.brioche]", command: cli)
        for text in [
            env + xcode + old + newEnv + new,
            old + xcode + env + new + "[z]\na = 1\n\n" + newEnv,
        ] {
            try writeCodex(text)

            try MCPInstaller.removeCodex(configURL: codexURL, cliPath: cli)

            let after = try codexText()
            XCTAssertFalse(after.contains("mcp_servers.omelette"), after)
            XCTAssertFalse(after.contains("mcp_servers.brioche"), after)
            XCTAssertEqual(count(["mcp_servers", "xcode"], in: after), 1, after)
            XCTAssertEqual(codexStatus, .notInstalled, after)
        }
    }

    func testRemoveOnACRLFFileLeavesTheRestByteForByte() throws {
        let lf = env + "[a]\nx = 1\n\n" + table("[mcp_servers.omelette]", command: oldCLI) + "[b]\ny = 2\n"
        try writeCodex(lf.replacingOccurrences(of: "\n", with: "\r\n"))

        try MCPInstaller.removeCodex(configURL: codexURL, cliPath: cli)

        XCTAssertEqual(try codexText(), "[a]\r\nx = 1\r\n\r\n[b]\r\ny = 2\r\n")
    }
}
