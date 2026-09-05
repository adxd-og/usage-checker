import XCTest
@testable import Omelette

/// Fixtures are real files in a temp directory. The installer is pure over the
/// URLs it is handed, so nothing here can reach `~/.claude` or `~/.codex`.
final class AgentHooksInstallerTests: XCTestCase {
    private var root: URL!
    private let helper = "/Users/tester/Library/Application Support/UsageTracker/bin/omelette-hook"
    /// What the installer actually writes as the hook `command` (shell-quoted).
    private var quotedHelper: String { AgentHooksInstaller.shellQuoted(helper) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentHooksInstallerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixture helpers

    private var settingsURL: URL { root.appendingPathComponent("settings.json") }
    private var configURL: URL { root.appendingPathComponent("config.toml") }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    private func text(at url: URL) throws -> String {
        String(data: try Data(contentsOf: url), encoding: .utf8) ?? ""
    }

    private func json(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])
    }

    private func hooksJSON(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(try json(at: url)["hooks"] as? [String: Any])
    }

    /// Every command registered under `event`, in the order the file lists them.
    private func commands(_ hooks: [String: Any], _ event: String) -> [String] {
        (hooks[event] as? [[String: Any]] ?? []).flatMap { group in
            (group["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
    }

    /// The single hook object the template registers for `event` at `matcher`.
    private func templateEntry(
        _ template: [String: Any], _ event: String, matcher: String = ""
    ) throws -> [String: Any] {
        let groups = try XCTUnwrap(template[event] as? [[String: Any]], "no groups for \(event)")
        let group = try XCTUnwrap(
            groups.first { ($0["matcher"] as? String) == matcher },
            "no \(matcher.isEmpty ? "empty" : matcher) matcher under \(event)"
        )
        return try XCTUnwrap((group["hooks"] as? [[String: Any]])?.first)
    }

    // MARK: - Template

    func testTemplateRegistersEveryEventWithTheRightBlockingBehaviour() throws {
        let template = AgentHooksInstaller.claudeTemplate(helperPath: helper)

        XCTAssertEqual(Set(template.keys), [
            "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
            "PermissionRequest", "Notification", "Stop", "SessionEnd",
        ])

        for event in ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd"] {
            let entry = try templateEntry(template, event)
            XCTAssertEqual(entry["type"] as? String, "command", event)
            XCTAssertEqual(entry["command"] as? String, AgentHooksInstaller.shellQuoted(helper), event)
            XCTAssertEqual(entry["async"] as? Bool, true, "\(event) must never make Claude Code wait")
            XCTAssertNil(entry["timeout"], "\(event) is fire-and-forget; a timeout would be meaningless")
        }

        // The one synchronous entry, and the only one Claude Code waits on. 150 s is
        // the outer ring of the timeout chain: the app gives up holding at 120 s and
        // the helper at 140 s, so Claude Code's own cap is never the one that fires.
        let permission = try templateEntry(template, "PermissionRequest")
        XCTAssertEqual(permission["timeout"] as? Int, 150)
        XCTAssertNil(permission["async"])

        let notification = try XCTUnwrap(template["Notification"] as? [[String: Any]])
        XCTAssertEqual(notification.compactMap { $0["matcher"] as? String }, ["permission_prompt", "idle_prompt"])
        XCTAssertEqual(try templateEntry(template, "Notification", matcher: "idle_prompt")["async"] as? Bool, true)
    }

    /// The hook `command` goes through `/bin/sh`, and the helper path contains a
    /// space ("Application Support"). This runs the emitted command through a real
    /// shell and checks the path comes out in one piece — the assertion that would
    /// have caught an unquoted path.
    func testTheEmittedCommandSurvivesTheShell() throws {
        let weird = "/Users/o'brien/Library/Application Support/UsageTracker/bin/omelette-hook"
        let entry = try templateEntry(AgentHooksInstaller.claudeTemplate(helperPath: weird), "Stop")
        let command = try XCTUnwrap(entry["command"] as? String)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf '%s' \(command)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: output, as: UTF8.self), weird)
    }

    func testPreviewIsTheJSONWeActuallyWrite() throws {
        let preview = AgentHooksInstaller.claudePreviewJSON(helperPath: helper)
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(preview.utf8)) as? [String: Any]
        )
        XCTAssertNotNil(parsed["hooks"] as? [String: Any])
        XCTAssertTrue(preview.contains(helper), "the preview must show the real helper path, unescaped")
        XCTAssertFalse(preview.contains("\\/"), "escaped slashes make the preview unreadable")
    }

    // MARK: - Install

    func testInstallCreatesAMissingSettingsFile() throws {
        try AgentHooksInstaller.installClaude(settingsURL: settingsURL, helperPath: helper)

        let hooks = try hooksJSON(at: settingsURL)
        XCTAssertEqual(commands(hooks, "SessionStart"), [quotedHelper])
        XCTAssertEqual(commands(hooks, "Notification"), [quotedHelper, quotedHelper])
        XCTAssertEqual(AgentHooksInstaller.claudeStatus(settingsURL: settingsURL, helperPath: helper), .installed)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: AgentHooksInstaller.backupURL(for: settingsURL).path),
            "there was no file to back up"
        )
    }

    func testInstallTreatsABlankFileAsAnEmptyObject() throws {
        try write("   \n", to: settingsURL)

        try AgentHooksInstaller.installClaude(settingsURL: settingsURL, helperPath: helper)

        XCTAssertEqual(AgentHooksInstaller.claudeStatus(settingsURL: settingsURL, helperPath: helper), .installed)
    }

    func testInstallKeepsForeignKeysAndForeignHooks() throws {
        try write("""
        {
          "model": "opus",
          "permissions": { "allow": ["Bash(git status)"] },
          "hooks": {
            "PreToolUse": [
              { "matcher": "Bash", "hooks": [{ "type": "command", "command": "/usr/local/bin/audit" }] }
            ],
            "SessionEnd": [
              { "matcher": "", "hooks": [{ "type": "command", "command": "/usr/local/bin/cleanup" }] }
            ]
          }
        }
        """, to: settingsURL)

        try AgentHooksInstaller.installClaude(settingsURL: settingsURL, helperPath: helper)

        let file = try json(at: settingsURL)
        XCTAssertEqual(file["model"] as? String, "opus")
        XCTAssertNotNil(file["permissions"], "keys we know nothing about survive untouched")
        let hooks = try XCTUnwrap(file["hooks"] as? [String: Any])
        XCTAssertEqual(commands(hooks, "PreToolUse"), ["/usr/local/bin/audit", quotedHelper], "different event, same event — both keep their owner")
        XCTAssertEqual(commands(hooks, "SessionEnd"), ["/usr/local/bin/cleanup", quotedHelper])
        XCTAssertEqual(commands(hooks, "Stop"), [quotedHelper])
        XCTAssertEqual(AgentHooksInstaller.claudeStatus(settingsURL: settingsURL, helperPath: helper), .installed)
    }

    func testAnOlderInstallReadsAsOutdatedAndUpdateReplacesOnlyOurs() throws {
        // What an earlier build wrote: a synchronous PreToolUse sharing a group
        // with a foreign hook, no SessionEnd at all.
        try write("""
        {
          "hooks": {
            "PreToolUse": [
              { "matcher": "", "hooks": [
                  { "type": "command", "command": "/usr/local/bin/audit" },
                  { "type": "command", "command": "\(helper)", "timeout": 3 }
              ] }
            ],
            "Stop": [
              { "matcher": "", "hooks": [{ "type": "command", "command": "\(helper)", "async": true }] }
            ]
          }
        }
        """, to: settingsURL)

        XCTAssertEqual(AgentHooksInstaller.claudeStatus(settingsURL: settingsURL, helperPath: helper), .outdated)

        try AgentHooksInstaller.installClaude(settingsURL: settingsURL, helperPath: helper)

        let hooks = try hooksJSON(at: settingsURL)
        XCTAssertEqual(
            commands(hooks, "PreToolUse"), ["/usr/local/bin/audit", quotedHelper],
            "exactly one copy of ours; the foreign hook that shared the group is still there"
        )
        XCTAssertEqual(commands(hooks, "Stop"), [quotedHelper])
        XCTAssertEqual(AgentHooksInstaller.claudeStatus(settingsURL: settingsURL, helperPath: helper), .installed)
    }

    /// 2.1 registered the permission hook with a 5-second cap, which is far too
    /// short to ask a human anything. The one-time cost of 2.2 is that those
    /// installs must read as outdated so the Agents tab offers **Update** once.
    func testAFiveSecondPermissionHookReadsAsOutdated() throws {
        try AgentHooksInstaller.installClaude(settingsURL: settingsURL, helperPath: helper)
        XCTAssertEqual(AgentHooksInstaller.claudeStatus(settingsURL: settingsURL, helperPath: helper), .installed)

        // Put the entry back the way 2.1 wrote it: same command, old cap.
        var file = try json(at: settingsURL)
        var hooks = try XCTUnwrap(file["hooks"] as? [String: Any])
        var groups = try XCTUnwrap(hooks["PermissionRequest"] as? [[String: Any]])
        var entries = try XCTUnwrap(groups[0]["hooks"] as? [[String: Any]])
        entries[0]["timeout"] = 5
        groups[0]["hooks"] = entries
        hooks["PermissionRequest"] = groups
        file["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: file).write(to: settingsURL)

        XCTAssertEqual(
            AgentHooksInstaller.claudeStatus(settingsURL: settingsURL, helperPath: helper), .outdated,
            "an install from 2.1 has to ask for one Update"
        )

        try AgentHooksInstaller.installClaude(settingsURL: settingsURL, helperPath: helper)

        XCTAssertEqual(AgentHooksInstaller.claudeStatus(settingsURL: settingsURL, helperPath: helper), .installed)
        let hooksAfter = try hooksJSON(at: settingsURL)
        XCTAssertEqual(try templateEntry(hooksAfter, "PermissionRequest")["timeout"] as? Int, 150)
        XCTAssertEqual(
            commands(hooksAfter, "PermissionRequest").count, 1,
            "Update must replace our entry, not add a second one"
        )
    }

    func testStatusDoesNotCareWhereOurEntriesSitInTheFile() throws {
        try AgentHooksInstaller.installClaude(settingsURL: settingsURL, helperPath: helper)
        var file = try json(at: settingsURL)
        var hooks = try XCTUnwrap(file["hooks"] as? [String: Any])
        var stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        stop.insert(["matcher": "", "hooks": [["type": "command", "command": "/usr/local/bin/other"]]], at: 0)
        hooks["Stop"] = stop
        file["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: file).write(to: settingsURL)

        XCTAssertEqual(AgentHooksInstaller.claudeStatus(settingsURL: settingsURL, helperPath: helper), .installed)
    }

    func testUnparsableSettingsAreNeverOverwritten() throws {
        let broken = "{ this is not json"
        try write(broken, to: settingsURL)

        XCTAssertEqual(
            AgentHooksInstaller.claudeStatus(settingsURL: settingsURL, helperPath: helper),
            .conflict(AgentHooksInstaller.unparsableReason)
        )
        XCTAssertThrowsError(try AgentHooksInstaller.installClaude(settingsURL: settingsURL, helperPath: helper)) {
            XCTAssertEqual($0 as? AgentHooksInstaller.Error, .unparsable(self.settingsURL))
        }
        XCTAssertEqual(try text(at: settingsURL), broken, "the file must be byte-identical")
        XCTAssertFalse(FileManager.default.fileExists(atPath: AgentHooksInstaller.backupURL(for: settingsURL).path))
    }

    // MARK: - Remove

    func testRemoveKeepsForeignEntriesAndDropsEmptyEvents() throws {
        try write("""
        {
          "model": "opus",
          "hooks": {
            "PreToolUse": [
              { "matcher": "Bash", "hooks": [{ "type": "command", "command": "/usr/local/bin/audit" }] }
            ]
          }
        }
        """, to: settingsURL)
        try AgentHooksInstaller.installClaude(settingsURL: settingsURL, helperPath: helper)

        try AgentHooksInstaller.removeClaude(settingsURL: settingsURL, helperPath: helper)

        let file = try json(at: settingsURL)
        XCTAssertEqual(file["model"] as? String, "opus")
        let hooks = try XCTUnwrap(file["hooks"] as? [String: Any])
        XCTAssertEqual(Array(hooks.keys), ["PreToolUse"], "every event that was only ours is gone, not left as []")
        XCTAssertEqual(commands(hooks, "PreToolUse"), ["/usr/local/bin/audit"])
        XCTAssertEqual(AgentHooksInstaller.claudeStatus(settingsURL: settingsURL, helperPath: helper), .notInstalled)
    }

    func testRemoveDropsTheHooksKeyWhenNothingElseUsedIt() throws {
        try write(#"{ "model": "opus" }"#, to: settingsURL)
        try AgentHooksInstaller.installClaude(settingsURL: settingsURL, helperPath: helper)

        try AgentHooksInstaller.removeClaude(settingsURL: settingsURL, helperPath: helper)

        let file = try json(at: settingsURL)
        XCTAssertNil(file["hooks"], "an empty hooks object is litter in someone else's file")
        XCTAssertEqual(file["model"] as? String, "opus")
    }

    func testRemoveWithNothingOfOursInstalledDoesNotRewriteTheFile() throws {
        let original = "{\n  \"model\" : \"opus\"\n}\n"
        try write(original, to: settingsURL)

        try AgentHooksInstaller.removeClaude(settingsURL: settingsURL, helperPath: helper)

        XCTAssertEqual(try text(at: settingsURL), original, "nothing of ours was there — do not reformat someone's file")
    }

    func testTheBackupIsTakenOnceAndHoldsTheOriginal() throws {
        let original = #"{ "model": "opus" }"#
        try write(original, to: settingsURL)

        try AgentHooksInstaller.installClaude(settingsURL: settingsURL, helperPath: helper)
        try AgentHooksInstaller.installClaude(settingsURL: settingsURL, helperPath: helper)
        try AgentHooksInstaller.removeClaude(settingsURL: settingsURL, helperPath: helper)

        let backup = AgentHooksInstaller.backupURL(for: settingsURL)
        XCTAssertEqual(backup.lastPathComponent, "settings.json.omelette-backup")
        XCTAssertEqual(
            try text(at: backup), original,
            "the backup must still be the file as it was before Omelette first touched it"
        )
    }

    // MARK: - Codex

    func testNotifyLineIsWrittenToAMissingConfig() throws {
        try AgentHooksInstaller.installCodex(configURL: configURL, helperPath: helper)

        XCTAssertEqual(
            try text(at: configURL),
            AgentHooksInstaller.codexNotifyLine(helperPath: helper) + "\n"
        )
        XCTAssertEqual(AgentHooksInstaller.codexStatus(configURL: configURL, helperPath: helper), .installed)
    }

    func testNotifyLineIsTheExactShapeCodexExpects() {
        XCTAssertEqual(
            AgentHooksInstaller.codexNotifyLine(helperPath: "/tmp/omelette-hook"),
            #"notify = ["/tmp/omelette-hook", "--codex"]"#
        )
        XCTAssertEqual(
            AgentHooksInstaller.codexNotifyLine(helperPath: #"/tmp/we"ird\path"#),
            #"notify = ["/tmp/we\"ird\\path", "--codex"]"#,
            "quotes and backslashes have to survive as TOML escapes"
        )
    }

    func testANotifyInsideATableIsNotOursAndOurLineGoesAboveIt() throws {
        try write("""
        model = "gpt-5"

        [tui]
        notify = ["/usr/local/bin/tui-thing"]
        """, to: configURL)

        XCTAssertEqual(
            AgentHooksInstaller.codexStatus(configURL: configURL, helperPath: helper), .notInstalled,
            "a notify under [tui] belongs to that table"
        )

        try AgentHooksInstaller.installCodex(configURL: configURL, helperPath: helper)

        let lines = try text(at: configURL).components(separatedBy: "\n")
        XCTAssertEqual(lines.first, #"model = "gpt-5""#)
        let ours = try XCTUnwrap(lines.firstIndex(of: AgentHooksInstaller.codexNotifyLine(helperPath: helper)))
        let table = try XCTUnwrap(lines.firstIndex(of: "[tui]"))
        XCTAssertLessThan(ours, table, "our key has to stay top-level")
        XCTAssertTrue(lines.contains(#"notify = ["/usr/local/bin/tui-thing"]"#), "the table's own key is untouched")
        XCTAssertEqual(AgentHooksInstaller.codexStatus(configURL: configURL, helperPath: helper), .installed)
    }

    func testACommentedNotifyIsNotOurs() throws {
        try write("""
        # notify = ["/usr/local/bin/old"]
        model = "gpt-5"
        """, to: configURL)

        XCTAssertEqual(AgentHooksInstaller.codexStatus(configURL: configURL, helperPath: helper), .notInstalled)

        try AgentHooksInstaller.installCodex(configURL: configURL, helperPath: helper)

        let lines = try text(at: configURL).components(separatedBy: "\n")
        XCTAssertEqual(lines.first, #"# notify = ["/usr/local/bin/old"]"#, "the comment stays a comment")
        XCTAssertTrue(lines.contains(AgentHooksInstaller.codexNotifyLine(helperPath: helper)))
    }

    func testSomeoneElsesNotifyIsAConflictAndIsNeverOverwritten() throws {
        let theirs = #"notify = ["/usr/local/bin/other-notifier"]"#
        let original = """
        \(theirs)
        model = "gpt-5"
        """
        try write(original, to: configURL)

        XCTAssertEqual(
            AgentHooksInstaller.codexStatus(configURL: configURL, helperPath: helper),
            .conflict(theirs)
        )
        XCTAssertThrowsError(try AgentHooksInstaller.installCodex(configURL: configURL, helperPath: helper)) {
            XCTAssertEqual($0 as? AgentHooksInstaller.Error, .conflict(theirs))
        }
        XCTAssertEqual(try text(at: configURL), original, "the file must be byte-identical")
    }

    func testAnOlderNotifyOfOursIsUpdatedWhereItStands() throws {
        let stale = #"notify = ["/Users/tester/Library/Application Support/UsageTracker/bin/omelette-hook", "--codex", "--v0"]"#
        try write("""
        model = "gpt-5"
        \(stale)

        [tui]
        theme = "dark"
        """, to: configURL)

        XCTAssertEqual(AgentHooksInstaller.codexStatus(configURL: configURL, helperPath: helper), .outdated)

        try AgentHooksInstaller.installCodex(configURL: configURL, helperPath: helper)

        let lines = try text(at: configURL).components(separatedBy: "\n")
        XCTAssertEqual(lines[1], AgentHooksInstaller.codexNotifyLine(helperPath: helper), "replaced in place")
        XCTAssertFalse(lines.contains(stale))
        XCTAssertTrue(lines.contains("[tui]"))
        XCTAssertTrue(lines.contains(#"theme = "dark""#))
    }

    func testRemoveTakesOurLineAndNothingElse() throws {
        try write("""
        model = "gpt-5"

        [tui]
        notify = ["/usr/local/bin/tui-thing"]
        """, to: configURL)
        try AgentHooksInstaller.installCodex(configURL: configURL, helperPath: helper)

        try AgentHooksInstaller.removeCodex(configURL: configURL, helperPath: helper)

        let after = try text(at: configURL)
        XCTAssertFalse(after.contains(AgentHooksInstaller.codexNotifyLine(helperPath: helper)))
        XCTAssertTrue(after.contains(#"model = "gpt-5""#))
        XCTAssertTrue(after.contains(#"notify = ["/usr/local/bin/tui-thing"]"#), "the [tui] key survives")
        XCTAssertEqual(AgentHooksInstaller.codexStatus(configURL: configURL, helperPath: helper), .notInstalled)
    }

    func testRemoveLeavesSomeoneElsesNotifyAlone() throws {
        let original = "notify = [\"/usr/local/bin/other-notifier\"]\n"
        try write(original, to: configURL)

        try AgentHooksInstaller.removeCodex(configURL: configURL, helperPath: helper)

        XCTAssertEqual(try text(at: configURL), original)
    }

    // MARK: - Codex hooks

    private var hooksURL: URL { root.appendingPathComponent("hooks.json") }

    /// `~/.codex/hooks.json` as it is on a machine that runs rtk — the entry every
    /// merge, update and removal has to leave exactly where it is.
    private static let rtkHooksJSON = """
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

    /// What the installer writes as a Codex hook `command`.
    private var codexHookCommand: String { quotedHelper + " --codex-hook" }

    func testCodexTemplateRegistersTheEventsCodexFires() throws {
        let template = AgentHooksInstaller.codexHooksTemplate(helperPath: helper)

        XCTAssertEqual(Set(template.keys), [
            "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
            "PermissionRequest", "Stop", "SessionEnd",
        ])
        XCTAssertNil(template["Notification"], "Codex has no Notification event")
        XCTAssertEqual(Set(AgentHooksInstaller.codexHookEvents), Set(template.keys))

        for event in ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd"] {
            let entry = try templateEntry(template, event)
            XCTAssertEqual(entry["type"] as? String, "command", event)
            XCTAssertEqual(entry["command"] as? String, codexHookCommand, event)
            XCTAssertEqual(entry["async"] as? Bool, true, "\(event) must never make Codex wait")
            XCTAssertNil(entry["timeout"], event)
        }

        let permission = try templateEntry(template, "PermissionRequest")
        XCTAssertEqual(permission["command"] as? String, codexHookCommand)
        XCTAssertEqual(permission["timeout"] as? Int, 150, "same outer ring as Claude's chain")
        XCTAssertNil(permission["async"])
    }

    func testCodexHooksMergeKeepsTheRtkEntry() throws {
        try write(Self.rtkHooksJSON, to: hooksURL)

        try AgentHooksInstaller.installCodexHooks(hooksURL: hooksURL, helperPath: helper)

        let hooks = try hooksJSON(at: hooksURL)
        XCTAssertEqual(
            commands(hooks, "PreToolUse"), ["rtk hook claude", codexHookCommand],
            "rtk owned this event first and keeps its place"
        )
        XCTAssertEqual(commands(hooks, "PermissionRequest"), [codexHookCommand])
        XCTAssertEqual(commands(hooks, "SessionEnd"), [codexHookCommand])
        XCTAssertEqual(
            AgentHooksInstaller.codexHooksStatus(hooksURL: hooksURL, helperPath: helper), .installed
        )
        XCTAssertEqual(
            try text(at: AgentHooksInstaller.backupURL(for: hooksURL)), Self.rtkHooksJSON,
            "the backup holds hooks.json as rtk left it"
        )
    }

    func testCodexHooksInstallIsIdempotent() throws {
        try write(Self.rtkHooksJSON, to: hooksURL)

        try AgentHooksInstaller.installCodexHooks(hooksURL: hooksURL, helperPath: helper)
        try AgentHooksInstaller.installCodexHooks(hooksURL: hooksURL, helperPath: helper)

        let hooks = try hooksJSON(at: hooksURL)
        XCTAssertEqual(commands(hooks, "PreToolUse"), ["rtk hook claude", codexHookCommand])
        XCTAssertEqual(commands(hooks, "Stop"), [codexHookCommand])
        XCTAssertEqual(
            AgentHooksInstaller.codexHooksStatus(hooksURL: hooksURL, helperPath: helper), .installed
        )
    }

    func testAnOlderCodexHookReadsAsOutdatedAndUpdateReplacesOnlyOurs() throws {
        try write(Self.rtkHooksJSON, to: hooksURL)
        try AgentHooksInstaller.installCodexHooks(hooksURL: hooksURL, helperPath: helper)

        // Put our PermissionRequest entry back the way an earlier build wrote it.
        var file = try json(at: hooksURL)
        var hooks = try XCTUnwrap(file["hooks"] as? [String: Any])
        var groups = try XCTUnwrap(hooks["PermissionRequest"] as? [[String: Any]])
        var entries = try XCTUnwrap(groups[0]["hooks"] as? [[String: Any]])
        entries[0]["timeout"] = 5
        groups[0]["hooks"] = entries
        hooks["PermissionRequest"] = groups
        file["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: file).write(to: hooksURL)

        XCTAssertEqual(
            AgentHooksInstaller.codexHooksStatus(hooksURL: hooksURL, helperPath: helper), .outdated
        )

        try AgentHooksInstaller.installCodexHooks(hooksURL: hooksURL, helperPath: helper)

        let after = try hooksJSON(at: hooksURL)
        XCTAssertEqual(try templateEntry(after, "PermissionRequest")["timeout"] as? Int, 150)
        XCTAssertEqual(commands(after, "PermissionRequest").count, 1, "Update replaces, never adds")
        XCTAssertEqual(commands(after, "PreToolUse"), ["rtk hook claude", codexHookCommand])
    }

    func testRemoveCodexHooksLeavesTheRtkEntry() throws {
        try write(Self.rtkHooksJSON, to: hooksURL)
        try AgentHooksInstaller.installCodexHooks(hooksURL: hooksURL, helperPath: helper)

        try AgentHooksInstaller.removeCodexHooks(hooksURL: hooksURL, helperPath: helper)

        let hooks = try hooksJSON(at: hooksURL)
        XCTAssertEqual(Array(hooks.keys), ["PreToolUse"], "events that were only ours are gone, not left as []")
        XCTAssertEqual(commands(hooks, "PreToolUse"), ["rtk hook claude"])
        XCTAssertEqual(
            AgentHooksInstaller.codexHooksStatus(hooksURL: hooksURL, helperPath: helper), .notInstalled
        )
    }

    func testCodexHooksAreWrittenToAMissingFile() throws {
        XCTAssertEqual(
            AgentHooksInstaller.codexHooksStatus(hooksURL: hooksURL, helperPath: helper), .notInstalled
        )

        try AgentHooksInstaller.installCodexHooks(hooksURL: hooksURL, helperPath: helper)

        let file = try json(at: hooksURL)
        XCTAssertNotNil(file["hooks"] as? [String: Any], "a missing file becomes a hooks object")
        XCTAssertEqual(
            AgentHooksInstaller.codexHooksStatus(hooksURL: hooksURL, helperPath: helper), .installed
        )
    }

    func testUnparsableCodexHooksAreNeverOverwritten() throws {
        let broken = "{ not json at all"
        try write(broken, to: hooksURL)

        XCTAssertEqual(
            AgentHooksInstaller.codexHooksStatus(hooksURL: hooksURL, helperPath: helper),
            .conflict(AgentHooksInstaller.hooksUnparsableReason)
        )
        XCTAssertThrowsError(try AgentHooksInstaller.installCodexHooks(hooksURL: hooksURL, helperPath: helper))
        XCTAssertEqual(try text(at: hooksURL), broken, "the file must be byte-identical")
    }

    func testCodexHooksPreviewIsTheJSONWeActuallyWrite() throws {
        let preview = AgentHooksInstaller.codexHooksPreviewJSON(helperPath: helper)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(preview.utf8)) as? [String: Any])
        XCTAssertNotNil(parsed["hooks"] as? [String: Any])
        XCTAssertTrue(preview.contains("--codex-hook"))
        XCTAssertTrue(preview.contains(helper), "the preview shows the real helper path, unescaped")
    }
}
