import XCTest
@testable import Omelette

/// Independent verification of `MCPInstaller`'s Codex TOML header rule, derived from
/// `docs/superpowers/specs/2026-09-24-2.7.0-hardening.md` § Design "Agents, CLI,
/// scripts (report C)", item 1, and the verification report
/// `docs/superpowers/reviews/2026-09-24-p2-verification-C-agents-cli.md` § 1, not from
/// `MCPInstallerTests`. Focus: the exact three fixtures the astra review ran through
/// Python's `tomllib` (`# comment`, a quoted key, extra brackets/spaces), combined with
/// a CRLF file; the `[[mcp_servers.omelette]]` array-of-tables header, which must never
/// read as ours; and a hand-written `command = "…" # note` value.
final class MCPInstallerVerification2Tests: XCTestCase {
    private var root: URL!
    private let cli = "/Users/tester/Library/Application Support/UsageTracker/bin/omelette"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPInstallerVerification2Tests-\(UUID().uuidString)", isDirectory: true)
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

    /// Every line whose `codexHeaderKey` names our table — the installer's own
    /// normalizer, not a literal-string count, since that is exactly what the bug
    /// this package fixes hid.
    private func ourHeaderCount(in text: String) -> Int {
        SettingsFile.lines(of: text).filter { MCPInstaller.codexHeaderKey($0) == MCPInstaller.codexKey }.count
    }

    // MARK: - The three review fixtures, each on its own

    /// `[mcp_servers.omelette] # Omelette MCP` — a trailing comment outside quotes.
    func testACommentedHeaderIsInstalledAndInstallIsANoOp() throws {
        try write("""
        [mcp_servers.omelette] # Omelette MCP
        command = "\(cli)"
        args = ["mcp"]

        """, to: codexURL)

        XCTAssertEqual(codexStatus, .installed)
        try MCPInstaller.installCodex(configURL: codexURL, cliPath: cli)
        XCTAssertEqual(ourHeaderCount(in: try text(at: codexURL)), 1)
    }

    /// `[mcp_servers."omelette"]` — the key wrapped in a basic string.
    func testAQuotedKeyHeaderIsInstalledAndInstallIsANoOp() throws {
        try write("""
        [mcp_servers."omelette"]
        command = "\(cli)"
        args = ["mcp"]

        """, to: codexURL)

        XCTAssertEqual(codexStatus, .installed)
        try MCPInstaller.installCodex(configURL: codexURL, cliPath: cli)
        XCTAssertEqual(ourHeaderCount(in: try text(at: codexURL)), 1)
    }

    /// `[ mcp_servers.omelette ]` — extra spaces inside the brackets.
    func testASpacedHeaderIsInstalledAndInstallIsANoOp() throws {
        try write("""
        [ mcp_servers.omelette ]
        command = "\(cli)"
        args = ["mcp"]

        """, to: codexURL)

        XCTAssertEqual(codexStatus, .installed)
        try MCPInstaller.installCodex(configURL: codexURL, cliPath: cli)
        XCTAssertEqual(ourHeaderCount(in: try text(at: codexURL)), 1)
    }

    // MARK: - Combined with a CRLF file

    /// A quoted header AND Windows line endings together — the CRLF stripping and the
    /// header parse have to compose, not just each work alone.
    func testAQuotedHeaderInACRLFFileIsInstalledAndInstallLeavesExactlyOneTable() throws {
        let crlf = [
            "model = \"gpt-6-astra\"",
            "",
            "[mcp_servers.\"omelette\"]",
            "command = \"\(cli)\"",
            "args = [\"mcp\"]",
            "",
        ].joined(separator: "\r\n")
        try write(crlf, to: codexURL)

        XCTAssertEqual(codexStatus, .installed, "a CRLF file with a quoted header must still read as ours")

        try MCPInstaller.installCodex(configURL: codexURL, cliPath: cli)

        let after = try text(at: codexURL)
        XCTAssertEqual(ourHeaderCount(in: after), 1, after)
        XCTAssertTrue(after.contains("\r\n"), "install must not rewrite a CRLF file as LF")
        XCTAssertEqual(codexStatus, .installed, "still installed after the no-op write")
    }

    // MARK: - The array-of-tables header never counts as ours

    /// A file with only `[[mcp_servers.omelette]]` (no plain table of ours at all).
    /// `codexIsOurHeader` explicitly excludes the "[[" spelling, so this must read as
    /// not installed, and `installCodex` must append our own table rather than
    /// treating the array header as already-installed or touching it.
    func testAnArrayOfTablesHeaderIsNeverOursSoStatusIsNotInstalled() throws {
        try write("""
        [[mcp_servers.omelette]]
        command = "/usr/local/bin/something-else"

        """, to: codexURL)

        XCTAssertEqual(codexStatus, .notInstalled, "an array of tables sharing our name is not our table")

        try MCPInstaller.installCodex(configURL: codexURL, cliPath: cli)

        let after = try text(at: codexURL)
        XCTAssertTrue(after.contains("[[mcp_servers.omelette]]"), "the array header is left exactly where it is")
        XCTAssertTrue(after.contains("something-else"), "its body is untouched")
        XCTAssertEqual(
            SettingsFile.lines(of: after).filter {
                MCPInstaller.codexHeaderKey($0) == MCPInstaller.codexKey
                    && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("[[")
            }.count,
            1,
            "exactly one real table of ours, appended after the array header"
        )
    }

    // MARK: - A hand-written comment after the command value

    /// `command = "…/omelette" # ours` — the README's own shape for a hand-added
    /// entry. `codexValue` has to strip the comment before comparing, or the table
    /// reads as ours-with-no-command and is refused as a conflict.
    func testAHandWrittenCommandWithATrailingCommentStillMatchesOurs() throws {
        try write("""
        [mcp_servers.omelette]
        command = "\(cli)" # ours
        args = ["mcp"]

        """, to: codexURL)

        XCTAssertEqual(codexStatus, .installed, "the comment must not stop the command from matching ourCommandMarker")

        // installCodex must not throw .conflict on a table it recognises as ours.
        XCTAssertNoThrow(try MCPInstaller.installCodex(configURL: codexURL, cliPath: cli))
    }

    /// The same shape, but the command belongs to someone else: the comment must not
    /// hide that either, and install must refuse rather than overwrite a stranger's
    /// entry.
    func testAForeignCommandWithATrailingCommentIsStillAConflict() throws {
        try write("""
        [mcp_servers.omelette]
        command = "/opt/homebrew/bin/some-other-tool" # not ours
        args = ["mcp"]

        """, to: codexURL)

        guard case .conflict = codexStatus else {
            return XCTFail("expected .conflict, got \(codexStatus)")
        }
        XCTAssertThrowsError(try MCPInstaller.installCodex(configURL: codexURL, cliPath: cli))
    }
}
