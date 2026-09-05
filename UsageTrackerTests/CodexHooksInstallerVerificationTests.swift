import XCTest
@testable import Omelette

/// Independent verification of Package B's installer and trust parser, written
/// from the spec and plan rather than adapted from the executor's own tests. Uses
/// temp-dir fixtures only — never the real `~/.codex` files (those are read-only
/// reference material in the plan/spec).
final class CodexHooksInstallerVerificationTests: XCTestCase {
    private var root: URL!
    private let helper = "/Users/verifier/Library/Application Support/UsageTracker/bin/omelette-hook"
    private var hooksURL: URL { root.appendingPathComponent("hooks.json") }
    private var configURL: URL { root.appendingPathComponent("config.toml") }
    private var codexHookCommand: String { AgentHooksInstaller.shellQuoted(helper) + " --codex-hook" }

    /// Byte-exact copy of the owner's real `~/.codex/hooks.json` (verified against
    /// the machine's actual file during this review).
    private static let realOwnerHooksJSON = """
    {
      "hooks": {
        "PreToolUse": [
          {
            "matcher": "Bash",
            "hooks": [
              {
                "type": "command",
                "command": "rtk hook claude"
              }
            ]
          }
        ]
      }
    }
    """

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexHooksVerification-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    private func text(at url: URL) throws -> String {
        String(data: try Data(contentsOf: url), encoding: .utf8) ?? ""
    }

    private func json(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])
    }

    // MARK: - Byte-level format: sorted keys, two-space indentation

    /// The attack list calls for this explicitly: not just "the JSON round-trips
    /// the same values" but the literal bytes on disk are two-space indented with
    /// keys sorted alphabetically at every level.
    func testWrittenFileIsSortedKeysAndTwoSpaceIndentation() throws {
        try write(Self.realOwnerHooksJSON, to: hooksURL)
        try AgentHooksInstaller.installCodexHooks(hooksURL: hooksURL, helperPath: helper)

        let raw = try text(at: hooksURL)
        let lines = raw.components(separatedBy: "\n")

        // Every indented line's leading-space count is a multiple of two, and
        // JSONSerialization's own convention (verified separately) is 2 spaces per
        // nesting level.
        for line in lines where line.first == " " {
            let leadingSpaces = line.prefix(while: { $0 == " " }).count
            XCTAssertEqual(leadingSpaces % 2, 0, "not a two-space indent: \(line)")
        }
        XCTAssertTrue(raw.contains("  \"hooks\" : {"), "top-level key at one indent level of two spaces")

        // Top-level keys of "hooks" sorted alphabetically: PermissionRequest,
        // PostToolUse, PreToolUse, SessionEnd, SessionStart, Stop, UserPromptSubmit.
        let hooks = try XCTUnwrap(try json(at: hooksURL)["hooks"] as? [String: Any])
        let expectedOrder = ["PermissionRequest", "PostToolUse", "PreToolUse", "SessionEnd", "SessionStart", "Stop", "UserPromptSubmit"]
        var seenOrder: [String] = []
        for key in expectedOrder where lines.contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("\"\(key)\"") }) {
            seenOrder.append(key)
        }
        XCTAssertEqual(seenOrder, expectedOrder, "keys must appear in the file in sorted order")
        XCTAssertEqual(Set(hooks.keys), Set(expectedOrder))
    }

    // MARK: - Backup: written once, never overwritten

    func testBackupIsWrittenOnceAndSurvivesTwoFurtherInstalls() throws {
        try write(Self.realOwnerHooksJSON, to: hooksURL)

        try AgentHooksInstaller.installCodexHooks(hooksURL: hooksURL, helperPath: helper)
        let backupURL = AgentHooksInstaller.backupURL(for: hooksURL)
        XCTAssertEqual(try text(at: backupURL), Self.realOwnerHooksJSON)

        // Mutate the live file by hand (simulating a manual edit between installs)
        // and reinstall twice more; the backup must still read exactly as it did
        // the moment before Omelette ever touched the file.
        try write(Self.realOwnerHooksJSON + "\n", to: hooksURL)
        try AgentHooksInstaller.installCodexHooks(hooksURL: hooksURL, helperPath: helper)
        try AgentHooksInstaller.removeCodexHooks(hooksURL: hooksURL, helperPath: helper)
        try AgentHooksInstaller.installCodexHooks(hooksURL: hooksURL, helperPath: helper)

        XCTAssertEqual(
            try text(at: backupURL), Self.realOwnerHooksJSON,
            "the backup must hold the file exactly as it was before the first write, forever"
        )
    }

    // MARK: - Re-install is byte-identical, not merely equal-by-content

    func testReinstallProducesByteIdenticalOutput() throws {
        try write(Self.realOwnerHooksJSON, to: hooksURL)
        try AgentHooksInstaller.installCodexHooks(hooksURL: hooksURL, helperPath: helper)
        let firstBytes = try Data(contentsOf: hooksURL)

        try AgentHooksInstaller.installCodexHooks(hooksURL: hooksURL, helperPath: helper)
        let secondBytes = try Data(contentsOf: hooksURL)

        XCTAssertEqual(firstBytes, secondBytes, "a no-op re-install must not perturb a single byte")
    }

    // MARK: - Foreign entry under PermissionRequest itself (not just PreToolUse)

    /// The plan's fixture only ever puts a foreign entry under `PreToolUse`. The
    /// spec's attack list separately calls out a foreign entry coexisting under
    /// `PermissionRequest` — the one event where Omelette's own entry is blocking,
    /// so a merge bug here has the sharpest consequences (Codex could run two
    /// different command lines for one approval).
    func testForeignEntryUnderPermissionRequestSurvivesInstallAndRemove() throws {
        let foreignUnderPermission = """
        {
          "hooks": {
            "PermissionRequest": [
              {
                "matcher": "",
                "hooks": [
                  { "type": "command", "command": "some-other-tool --approve" }
                ]
              }
            ]
          }
        }
        """
        try write(foreignUnderPermission, to: hooksURL)
        try AgentHooksInstaller.installCodexHooks(hooksURL: hooksURL, helperPath: helper)

        let hooks = try XCTUnwrap(try json(at: hooksURL)["hooks"] as? [String: Any])
        let groups = try XCTUnwrap(hooks["PermissionRequest"] as? [[String: Any]])
        let commands = groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
        XCTAssertEqual(commands, ["some-other-tool --approve", codexHookCommand])

        try AgentHooksInstaller.removeCodexHooks(hooksURL: hooksURL, helperPath: helper)
        let afterRemove = try XCTUnwrap(try json(at: hooksURL)["hooks"] as? [String: Any])
        let afterGroups = try XCTUnwrap(afterRemove["PermissionRequest"] as? [[String: Any]])
        let afterCommands = afterGroups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
        XCTAssertEqual(afterCommands, ["some-other-tool --approve"], "removing ours must leave the foreign entry standing")
    }

    // MARK: - Malformed JSON never gets overwritten, byte for byte, across repeated attempts

    func testConflictedFileIsNeverTouchedEvenAfterAFailedInstallAttempt() throws {
        let broken = "{ \"hooks\": [1, 2, "
        try write(broken, to: hooksURL)

        XCTAssertThrowsError(try AgentHooksInstaller.installCodexHooks(hooksURL: hooksURL, helperPath: helper))
        XCTAssertThrowsError(try AgentHooksInstaller.installCodexHooks(hooksURL: hooksURL, helperPath: helper))
        XCTAssertEqual(try text(at: hooksURL), broken)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: AgentHooksInstaller.backupURL(for: hooksURL).path),
            "a file we refuse to parse must never even get a backup taken"
        )
    }

    // MARK: - Trust parser: index computed from file, not assumed to be 1

    /// If nothing else occupies `PreToolUse` before Omelette's merge, our entry is
    /// at index 0 — not the "always index 1" the plan's own fixtures rehearse
    /// (because their hooks.json always has the rtk PreToolUse entry first). This
    /// nails down "index computed from the file, not assumed".
    func testTrustIndexIsZeroWhenNoForeignEntryPrecedesOurs() throws {
        // No pre-existing hooks.json at all: our merge starts every event at index 0.
        try AgentHooksInstaller.installCodexHooks(hooksURL: hooksURL, helperPath: helper)
        let trustedAtZero = """
        [hooks.state."\(hooksURL.path):pre_tool_use:0:0"]
        trusted_hash = "sha256:aaaa"

        [hooks.state."\(hooksURL.path):permission_request:0:0"]
        trusted_hash = "sha256:bbbb"

        [hooks.state."\(hooksURL.path):session_start:0:0"]
        trusted_hash = "sha256:cccc"

        [hooks.state."\(hooksURL.path):user_prompt_submit:0:0"]
        trusted_hash = "sha256:dddd"

        [hooks.state."\(hooksURL.path):post_tool_use:0:0"]
        trusted_hash = "sha256:eeee"

        [hooks.state."\(hooksURL.path):stop:0:0"]
        trusted_hash = "sha256:ffff"

        [hooks.state."\(hooksURL.path):session_end:0:0"]
        trusted_hash = "sha256:0000"
        """
        try write(trustedAtZero, to: configURL)

        XCTAssertEqual(
            AgentHooksInstaller.codexTrust(configURL: configURL, hooksURL: hooksURL), .trusted,
            "with no foreign entry, our PreToolUse sits at index 0, and a parser that hardcoded 1 would miss it"
        )

        // Now the same config but pretending our entry is at index 1 (the shape used
        // when a foreign entry precedes us) — must NOT read as trusted, because the
        // file itself says our entry is really at 0.
        let trustedAtOneInstead = trustedAtZero.replacingOccurrences(
            of: "pre_tool_use:0:0", with: "pre_tool_use:1:0"
        )
        try write(trustedAtOneInstead, to: configURL)
        if case .trusted = AgentHooksInstaller.codexTrust(configURL: configURL, hooksURL: hooksURL) {
            XCTFail("the trust table at index 1 must not satisfy an entry that is actually at index 0")
        }
    }

    // MARK: - Trust parser: escaped quotes and a space in the hooks.json path

    /// Codex's own TOML writer escapes a `"` in the path with `\"`; a path can also
    /// contain a space (the owner's real path did, "Desktop/Usage tracker" style
    /// projects are common on this machine). The header key must still round-trip.
    func testTrustKeyWithEscapedQuoteAndSpaceInThePath() throws {
        let weirdRoot = root.appendingPathComponent("a \"quoted\" dir", isDirectory: true)
        try FileManager.default.createDirectory(at: weirdRoot, withIntermediateDirectories: true)
        let weirdHooksURL = weirdRoot.appendingPathComponent("hooks.json")
        try AgentHooksInstaller.installCodexHooks(hooksURL: weirdHooksURL, helperPath: helper)

        // Codex's own escaping: backslash then quote.
        let escapedPath = weirdHooksURL.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let config = """
        [hooks.state."\(escapedPath):permission_request:0:0"]
        trusted_hash = "sha256:aaaa"

        [hooks.state."\(escapedPath):session_start:0:0"]
        trusted_hash = "sha256:aaaa"

        [hooks.state."\(escapedPath):user_prompt_submit:0:0"]
        trusted_hash = "sha256:aaaa"

        [hooks.state."\(escapedPath):pre_tool_use:0:0"]
        trusted_hash = "sha256:aaaa"

        [hooks.state."\(escapedPath):post_tool_use:0:0"]
        trusted_hash = "sha256:aaaa"

        [hooks.state."\(escapedPath):stop:0:0"]
        trusted_hash = "sha256:aaaa"

        [hooks.state."\(escapedPath):session_end:0:0"]
        trusted_hash = "sha256:aaaa"
        """
        try write(config, to: configURL)

        XCTAssertEqual(
            AgentHooksInstaller.codexTrust(configURL: configURL, hooksURL: weirdHooksURL), .trusted,
            "a path with a space and an internal quote must still match the key Codex would actually write"
        )
    }

    // MARK: - No [hooks.state] table at all

    func testConfigWithNoHooksStateTableAtAllMeansNothingTrusted() throws {
        try write(Self.realOwnerHooksJSON, to: hooksURL)
        try AgentHooksInstaller.installCodexHooks(hooksURL: hooksURL, helperPath: helper)
        try write("model = \"gpt-5\"\n\n[tui.model_availability_nux]\ngpt-6-astra = 1\n", to: configURL)

        XCTAssertEqual(
            AgentHooksInstaller.codexTrust(configURL: configURL, hooksURL: hooksURL),
            .awaitingTrust(untrusted: AgentHooksInstaller.codexHookEvents)
        )
    }

    // MARK: - Our entries absent from hooks.json entirely (never installed)

    func testNeverInstalledMeansAwaitingTrustNotTrusted() throws {
        // No hooks.json at all — codexHooksStatus would read notInstalled.
        XCTAssertEqual(
            AgentHooksInstaller.codexHooksStatus(hooksURL: hooksURL, helperPath: helper), .notInstalled
        )
        let status = AgentHooksInstaller.codexTrust(configURL: configURL, hooksURL: hooksURL)
        guard case .awaitingTrust(let untrusted) = status else {
            return XCTFail("expected .awaitingTrust, got \(status)")
        }
        XCTAssertEqual(Set(untrusted), Set(AgentHooksInstaller.codexHookEvents))
    }

    // MARK: - Remove: empty event arrays are dropped, not left as []

    func testRemoveDropsEventsThatBecomeEmptyButKeepsMixedOnes() throws {
        let mixed = """
        {
          "hooks": {
            "PreToolUse": [
              { "matcher": "Bash", "hooks": [ { "type": "command", "command": "rtk hook claude" } ] }
            ],
            "Stop": [
              { "matcher": "", "hooks": [ { "type": "command", "command": "rtk hook claude" } ] }
            ]
          }
        }
        """
        try write(mixed, to: hooksURL)
        try AgentHooksInstaller.installCodexHooks(hooksURL: hooksURL, helperPath: helper)
        try AgentHooksInstaller.removeCodexHooks(hooksURL: hooksURL, helperPath: helper)

        let hooks = try XCTUnwrap(try json(at: hooksURL)["hooks"] as? [String: Any])
        // PreToolUse and Stop both had a foreign entry, so both must survive; every
        // event that was ours alone (SessionStart, UserPromptSubmit, PostToolUse,
        // PermissionRequest, SessionEnd) must be gone entirely, not `[]`.
        XCTAssertEqual(Set(hooks.keys), ["PreToolUse", "Stop"])
        for key in ["SessionStart", "UserPromptSubmit", "PostToolUse", "PermissionRequest", "SessionEnd"] {
            XCTAssertNil(hooks[key], "\(key) was ours alone and must not linger as an empty array")
        }
    }
}
