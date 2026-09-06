import XCTest
@testable import Omelette

/// Independent verification of `MCPInstaller`, derived from
/// `docs/superpowers/specs/2026-09-06-release-2.4.1-design.md` ("Package 1") and the
/// plan's Task 13, not from `MCPInstallerTests`. Focus: the Codex TOML path with a
/// CRLF file (an explicit item on the verification attack list) and the
/// `[mcp_servers.omelette.env]` sub-table end to end through `installCodex` /
/// `removeCodex`, not just the pure `codexTableRange` helper.
final class MCPInstallerVerificationTests: XCTestCase {
    private var root: URL!
    private let cli = "/Users/tester/Library/Application Support/UsageTracker/bin/omelette"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPInstallerVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var codexURL: URL { root.appendingPathComponent("config.toml") }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    private func text(at url: URL) throws -> String {
        String(data: try Data(contentsOf: url), encoding: .utf8) ?? ""
    }

    private var codexStatus: HookInstallStatus {
        MCPInstaller.codexStatus(configURL: codexURL, cliPath: cli)
    }

    // MARK: - CRLF (attack-list item)

    /// A `config.toml` saved by a Windows-style editor, or by Codex itself on a
    /// checkout with `core.autocrlf`, uses "\r\n" line endings throughout. Nothing in
    /// `MCPInstaller` strips "\r" before comparing a line to `codexHeader` or before
    /// reading `command = "…"` — unlike `AgentHooksInstaller.interpretable`, which
    /// explicitly documents "no carriage return from a CRLF file". If our table is
    /// already correctly installed in a CRLF file, status must still read `.installed`,
    /// not silently miss the table and let `installCodex` append a duplicate.
    func testCodexStatusRecognisesAnAlreadyInstalledTableInACRLFFile() throws {
        let existing = [
            "model = \"gpt-6-astra\"",
            "",
            MCPInstaller.codexHeader,
            "command = \"\(cli)\"",
            "args = [\"mcp\"]",
            "",
        ].joined(separator: "\r\n")
        try write(existing, to: codexURL)

        XCTAssertEqual(
            codexStatus, .installed,
            "the table is byte-for-byte what installCodex would write, only with \\r\\n line endings"
        )
    }

    /// Same CRLF file: `installCodex` must recognise the existing table as already
    /// correct and leave the file alone rather than appending a second
    /// `[mcp_servers.omelette]` table.
    func testInstallCodexDoesNotDuplicateTheTableInACRLFFile() throws {
        let existing = [
            "model = \"gpt-6-astra\"",
            "",
            MCPInstaller.codexHeader,
            "command = \"\(cli)\"",
            "args = [\"mcp\"]",
            "",
        ].joined(separator: "\r\n")
        try write(existing, to: codexURL)

        try MCPInstaller.installCodex(configURL: codexURL, cliPath: cli)

        let after = try text(at: codexURL)
        XCTAssertEqual(
            after.components(separatedBy: MCPInstaller.codexHeader).count - 1, 1,
            "installing over an already-correct CRLF table must not add a second one:\n\(after)"
        )
    }

    /// Same CRLF file, an outdated path: `installCodex` must update in place, not
    /// append a second table alongside the untouched CRLF one.
    func testInstallCodexUpdatesAnOutdatedTableInACRLFFileInPlace() throws {
        let existing = [
            MCPInstaller.codexHeader,
            "command = \"/Users/other/Library/Application Support/UsageTracker/bin/omelette\"",
            "args = [\"mcp\"]",
            "",
        ].joined(separator: "\r\n")
        try write(existing, to: codexURL)
        XCTAssertEqual(codexStatus, .outdated, "recognised as ours, just an older path")

        try MCPInstaller.installCodex(configURL: codexURL, cliPath: cli)

        XCTAssertEqual(codexStatus, .installed)
        let after = try text(at: codexURL)
        XCTAssertEqual(
            after.components(separatedBy: "[mcp_servers.omelette]").count - 1, 1,
            "one table after the update, not the old one plus a new one:\n\(after)"
        )
    }

    /// `removeCodex` on the same CRLF file must find and delete the table.
    func testRemoveCodexFindsTheTableInACRLFFile() throws {
        let existing = [
            "model = \"gpt-6-astra\"",
            "",
            MCPInstaller.codexHeader,
            "command = \"\(cli)\"",
            "args = [\"mcp\"]",
            "",
        ].joined(separator: "\r\n")
        try write(existing, to: codexURL)

        try MCPInstaller.removeCodex(configURL: codexURL, cliPath: cli)

        let after = try text(at: codexURL)
        XCTAssertFalse(after.contains("mcp_servers.omelette"), "the table must be gone:\n\(after)")
    }

    // MARK: - [mcp_servers.omelette.env] sub-table, end to end

    /// The pure `codexTableRange` helper is already shown to swallow a sub-table of
    /// its own; this checks the same guarantee holds through the public
    /// `installCodex` / `removeCodex` entry points against a real file, where the
    /// server was hand-configured with an environment variable.
    func testInstallCodexUpdatesInPlaceWithoutOrphaningAnEnvSubTable() throws {
        let existing = """
        model = "gpt-6-astra"

        [mcp_servers.omelette]
        command = "/Users/other/Library/Application Support/UsageTracker/bin/omelette"
        args = ["mcp"]

        [mcp_servers.omelette.env]
        DEBUG = "1"

        [mcp_servers.xcode]
        command = "xcrun"

        """
        try write(existing, to: codexURL)
        XCTAssertEqual(codexStatus, .outdated)

        try MCPInstaller.installCodex(configURL: codexURL, cliPath: cli)

        let after = try text(at: codexURL)
        XCTAssertEqual(codexStatus, .installed)
        XCTAssertTrue(after.contains("[mcp_servers.xcode]"), after)
        XCTAssertTrue(after.contains("command = \"xcrun\""), after)
        // The rewrite replaces the whole range starting at our header, including our
        // own sub-table (which described the *old* invocation) — it must not survive
        // detached from any `[mcp_servers.omelette]` header, which Codex would refuse.
        if after.contains("[mcp_servers.omelette.env]") {
            XCTAssertTrue(
                after.range(of: "[mcp_servers.omelette]")!.lowerBound
                    < after.range(of: "[mcp_servers.omelette.env]")!.lowerBound,
                "an env sub-table must never precede its own parent header:\n\(after)"
            )
        }
    }

    func testRemoveCodexTakesTheEnvSubTableWithIt() throws {
        let existing = """
        [mcp_servers.omelette]
        command = "\(cli)"
        args = ["mcp"]

        [mcp_servers.omelette.env]
        DEBUG = "1"

        [mcp_servers.xcode]
        command = "xcrun"

        """
        try write(existing, to: codexURL)

        try MCPInstaller.removeCodex(configURL: codexURL, cliPath: cli)

        let after = try text(at: codexURL)
        XCTAssertFalse(after.contains("mcp_servers.omelette"), "server and its env sub-table must both be gone:\n\(after)")
        XCTAssertTrue(after.contains("[mcp_servers.xcode]"), "the unrelated table must survive:\n\(after)")
    }
}
