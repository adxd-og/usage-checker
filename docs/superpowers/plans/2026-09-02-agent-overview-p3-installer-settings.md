# Phase 2 · Package 3 — Hook installer, Settings → Agents, onboarding card

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the owner turn Omelette's agent hooks on and off from Settings (and from the welcome tour) with the exact JSON/TOML shown first, foreign configuration never damaged, and a diagnostics block that says whether events are arriving.

**Architecture:** `AgentHooksInstaller` is a pure enum over URLs — no `~` anywhere in it — so every merge/remove rule is covered by XCTest against real temp files. It owns exactly two things in the user's world: Claude hook entries whose `command` contains `UsageTracker/bin/omelette-hook`, and the one top-level `notify` line in `config.toml` that points at the same helper. On top of it sit a new `Settings → Agents` tab (status, Enable/Update/Disable, previews, notification toggles, diagnostics) and one extra onboarding card that offers the Claude half.

**Tech Stack:** Swift 6 (strict concurrency `minimal`), SwiftUI `Form`/`Section` (same shape as the existing Settings tabs), `JSONSerialization` for the Claude merge, hand-rolled line handling for TOML (no TOML dependency), XCTest (`UsageTrackerTests`, `@testable import Omelette`), xcodegen-generated project.

**Spec:** `docs/superpowers/specs/2026-09-02-agent-overview-design.md` (sections "Claude Code hooks", "Codex", "Hook installer", "Settings → Agents", "Onboarding", "Security and privacy"), contract: `docs/superpowers/specs/2026-09-02-agent-overview-interfaces.md`, roadmap: `docs/superpowers/specs/2026-09-02-agent-control-plane-roadmap.md`

## Global Constraints

- Deployment target macOS 14.0; Swift 6 with `SWIFT_STRICT_CONCURRENCY: minimal` (set in `project.yml`). Follow the existing `@StateObject private var settings = SettingsStore.shared` / `@ObservedObject private var state = AppState.shared` pattern from `SettingsView.swift:5-6` rather than inventing concurrency annotations.
- New source files are picked up by xcodegen from `sources: - path: UsageTracker`; run `xcodegen generate` after adding a file and before building. `UsageTracker.xcodeproj/` is generated and gitignored — never `git add` it.
- Build: `xcodebuild -project UsageTracker.xcodeproj -scheme UsageTracker -configuration Debug -derivedDataPath build/DerivedData build`.
  Tests: `xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS=""` (add `-only-testing:UsageTrackerTests/<Class>` for a single class). **The two overrides are mandatory on every `xcodebuild test`** — the hardened runtime from `signing.xcconfig` otherwise hangs the test runner for ~6 min; every test command in the tasks below is to be read with them appended.
- **`AgentDiagnostics` is created by package 1** (`UsageTracker/Agents/AgentDiagnostics.swift`: `@MainActor enum AgentDiagnostics { static weak var server: AgentEventServer? }`, set by `AgentChannel` after `start()`). This package does not declare it; Task 4 only reads it. `AgentChannel.shared.startError` (package 1) is the socket-failure text to show in diagnostics.
- Commits end with the trailer lines
  `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` and
  `Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X`.
- Other sessions may commit the working tree while you work: re-read a file right before editing it; prefer targeted edits over whole-file rewrites.
- **Contract names are frozen.** `AgentHooksInstaller`, `HookInstallStatus`, `AgentPaths`, `AgentEventServer`, `AgentSessionStore`, and the four `@AppStorage` keys come from `2026-09-02-agent-overview-interfaces.md`. Extra members may be added (this plan lists them under "Produces"); nothing there may be renamed.
- **Package dependencies.** Tasks 1–3 depend on nothing outside this package and can land immediately. Tasks 4–5 reference `AgentPaths` and `AgentEventServer` (package 1) and `AgentSessionStore.shared` (package 2) — they compile only once those are merged. Do not create those types here; if the build fails with "cannot find AgentPaths in scope", packages 1/2 are not in yet, and that is the whole reason.
- Hook facts are verified against the Claude Code docs of 2026-09-02 and must not be "improved" while implementing: settings schema `"hooks": { "<Event>": [ { "matcher": "<regex or empty>", "hooks": [ { "type": "command", "command": "<path>", "timeout": <seconds>, "async": true|false } ] } ] }`; user- and project-level hooks merge; the events we register are `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PermissionRequest`, `Notification` (matchers `permission_prompt` and `idle_prompt`), `Stop`, `SessionEnd`; **every entry except `PermissionRequest` carries `"async": true`**, and `PermissionRequest` is the one synchronous entry with `"timeout": 5` so phase 4 can answer it without the user re-installing anything. Codex: `~/.codex/config.toml`, top-level `notify = ["<helper>", "--codex"]`.
- Hooks always reference `AgentPaths.helperSymlinkURL.path` (the App Support symlink), never the path inside the app bundle — moving Omelette.app must not break an installed hook.
- Privacy wording is load-bearing: the helper forwards session id, tool name, tool summary, cwd and host process info. Never write UI copy promising more or less than that.

---

## File structure

```
UsageTracker/Agents/
  AgentHooksInstaller.swift     Claude JSON merge + Codex TOML line, pure over URLs (Tasks 1–2)
UsageTracker/Core/
  Settings.swift                +4 @AppStorage keys, defaults, reset (Task 3)
UsageTracker/UI/
  AgentsSettingsView.swift      the Agents tab + AgentDiagnostics handle (Task 4)
  SettingsView.swift            +1 tab case, +1 tabItem (Task 4)
  OnboardingView.swift          +1 card, totalPages 3 → 4 (Task 5)
UsageTrackerTests/
  AgentHooksInstallerTests.swift  19 tests over temp-file fixtures (Tasks 1–2)
  SettingsStoreTests.swift        +4 lines in the scramble/assert pair, +1 test (Task 3)
```

`UsageTracker/Agents/` does not exist yet — package 1 creates it for `AgentPaths.swift`. If it is missing when Task 1 runs, create the directory; xcodegen picks it up from the existing `sources: - path: UsageTracker` entry with no `project.yml` change.

---

## Task 1: `AgentHooksInstaller` — the Claude half

**Files:**
- Create: `UsageTracker/Agents/AgentHooksInstaller.swift`
- Test: `UsageTrackerTests/AgentHooksInstallerTests.swift`
- Reference (read only): `UsageTracker/Core/HistoryStore.swift:250-270` (the repo's `data.write(to:options:[.atomic])` pattern), `UsageTrackerTests/JSONLAggregatorTests.swift:15-23` (temp-directory setUp/tearDown style)

**Interfaces:**
- Consumes: nothing. This task is standalone Foundation code — no `AgentPaths`, no UI, no app state.
- Produces (contract items marked ✱, the rest are this package's own additions):
  ```swift
  enum HookInstallStatus: Equatable {                                    // ✱
      case installed, outdated, notInstalled
      case conflict(String)
  }

  enum AgentHooksInstaller {
      enum Error: Swift.Error, Equatable {                               // ✱ (+ Equatable, for tests)
          case unparsable(URL)
          case conflict(String)
      }
      static let ourCommandMarker = "UsageTracker/bin/omelette-hook"
      static let unparsableReason: String
      static let unreadableReason: String
      static func backupURL(for url: URL) -> URL                         // "<name>.omelette-backup"
      static func claudeTemplate(helperPath: String) -> [String: Any]    // ✱
      static func claudePreviewJSON(helperPath: String) -> String        // pretty { "hooks": … } for the UI
      static func claudeStatus(settingsURL: URL, helperPath: String) -> HookInstallStatus   // ✱
      static func installClaude(settingsURL: URL, helperPath: String) throws                // ✱
      static func removeClaude(settingsURL: URL, helperPath: String) throws                 // ✱
  }
  ```
  Codex members (`codexNotifyLine`, `codexStatus`, `installCodex`, `removeCodex`) arrive in Task 2, in the same file.

**The exact fragment this task must produce** (`claudePreviewJSON` output, with `<H>` = `AgentPaths.helperSymlinkURL.path`):

```json
{
  "hooks" : {
    "Notification" : [
      { "matcher" : "permission_prompt", "hooks" : [ { "async" : true, "command" : "<H>", "type" : "command" } ] },
      { "matcher" : "idle_prompt",       "hooks" : [ { "async" : true, "command" : "<H>", "type" : "command" } ] }
    ],
    "PermissionRequest" : [ { "matcher" : "", "hooks" : [ { "command" : "<H>", "timeout" : 5, "type" : "command" } ] } ],
    "PostToolUse" :      [ { "matcher" : "", "hooks" : [ { "async" : true, "command" : "<H>", "type" : "command" } ] } ],
    "PreToolUse" :       [ { "matcher" : "", "hooks" : [ { "async" : true, "command" : "<H>", "type" : "command" } ] } ],
    "SessionEnd" :       [ { "matcher" : "", "hooks" : [ { "async" : true, "command" : "<H>", "type" : "command" } ] } ],
    "SessionStart" :     [ { "matcher" : "", "hooks" : [ { "async" : true, "command" : "<H>", "type" : "command" } ] } ],
    "Stop" :             [ { "matcher" : "", "hooks" : [ { "async" : true, "command" : "<H>", "type" : "command" } ] } ],
    "UserPromptSubmit" : [ { "matcher" : "", "hooks" : [ { "async" : true, "command" : "<H>", "type" : "command" } ] } ]
  }
}
```

Two `Notification` entries with literal matchers (not one `permission_prompt|idle_prompt` regex) — chosen so each notification type we listen to is separately visible, separately removable, and free of regex-alternation surprises. Async entries carry no `timeout`: the helper caps itself at 800 ms and Claude Code does not wait for them anyway.

- [ ] **Step 1: Write the failing tests**

```swift
// UsageTrackerTests/AgentHooksInstallerTests.swift
import XCTest
@testable import Omelette

/// Fixtures are real files in a temp directory. The installer is pure over the
/// URLs it is handed, so nothing here can reach `~/.claude` or `~/.codex`.
final class AgentHooksInstallerTests: XCTestCase {
    private var root: URL!
    private let helper = "/Users/tester/Library/Application Support/UsageTracker/bin/omelette-hook"

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
            XCTAssertEqual(entry["command"] as? String, helper, event)
            XCTAssertEqual(entry["async"] as? Bool, true, "\(event) must never make Claude Code wait")
            XCTAssertNil(entry["timeout"], "\(event) is fire-and-forget; a timeout would be meaningless")
        }

        // The one synchronous entry: phase 4 answers it, so it keeps the 5 s cap
        // and no async flag — installing it now means hook config never changes.
        let permission = try templateEntry(template, "PermissionRequest")
        XCTAssertEqual(permission["timeout"] as? Int, 5)
        XCTAssertNil(permission["async"])

        let notification = try XCTUnwrap(template["Notification"] as? [[String: Any]])
        XCTAssertEqual(notification.compactMap { $0["matcher"] as? String }, ["permission_prompt", "idle_prompt"])
        XCTAssertEqual(try templateEntry(template, "Notification", matcher: "idle_prompt")["async"] as? Bool, true)
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
        XCTAssertEqual(commands(hooks, "SessionStart"), [helper])
        XCTAssertEqual(commands(hooks, "Notification"), [helper, helper])
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
        XCTAssertEqual(commands(hooks, "PreToolUse"), ["/usr/local/bin/audit", helper], "different event, same event — both keep their owner")
        XCTAssertEqual(commands(hooks, "SessionEnd"), ["/usr/local/bin/cleanup", helper])
        XCTAssertEqual(commands(hooks, "Stop"), [helper])
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
            commands(hooks, "PreToolUse"), ["/usr/local/bin/audit", helper],
            "exactly one copy of ours; the foreign hook that shared the group is still there"
        )
        XCTAssertEqual(commands(hooks, "Stop"), [helper])
        XCTAssertEqual(AgentHooksInstaller.claudeStatus(settingsURL: settingsURL, helperPath: helper), .installed)
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
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/AgentHooksInstallerTests`
Expected: compile error "cannot find 'AgentHooksInstaller' in scope".

- [ ] **Step 3: Create the file with the Claude half**

```swift
// UsageTracker/Agents/AgentHooksInstaller.swift
import Foundation

/// Where our entries stand in a config file we do not own. `conflict` carries
/// the text to put in front of the user: the foreign `notify` line for Codex,
/// a one-line reason for a `settings.json` we refuse to touch.
enum HookInstallStatus: Equatable {
    case installed
    case outdated
    case notInstalled
    case conflict(String)
}

/// Installs and removes Omelette's entries in the agents' own config files.
///
/// Every function is pure over the URLs it is handed, so the tests run against
/// temp files and nothing here can reach `~/.claude` or `~/.codex` by accident.
/// Two rules hold throughout: we only ever touch entries that carry
/// `ourCommandMarker`, and a file we cannot parse is a refusal, never an
/// overwrite.
enum AgentHooksInstaller {
    enum Error: Swift.Error, Equatable {
        /// The file exists but is not the format it claims to be.
        case unparsable(URL)
        /// Someone else already owns the setting; the payload is their line.
        case conflict(String)
    }

    /// A Claude hook entry is ours when its command contains this. The path is
    /// the App Support symlink, so an old entry still matches after the app moves.
    static let ourCommandMarker = "UsageTracker/bin/omelette-hook"

    /// Status-line text when settings.json is not JSON at all.
    static let unparsableReason = "settings.json isn't valid JSON — fix or move it and try again."
    /// Status-line text when config.toml exists but is not readable UTF-8 text.
    static let unreadableReason = "config.toml can't be read as UTF-8 text."

    /// `~/.claude/settings.json` → `~/.claude/settings.json.omelette-backup`.
    static func backupURL(for url: URL) -> URL {
        url.appendingPathExtension("omelette-backup")
    }

    // MARK: - Claude

    /// The `hooks` fragment we own. Async everywhere so Claude Code never waits
    /// on us; `PermissionRequest` is the single synchronous entry (5 s cap) so
    /// phase 4 can answer it without anyone re-installing hooks. The two
    /// `Notification` entries are literal matchers rather than one alternation,
    /// so each notification type we listen to is separately visible in the file.
    static func claudeTemplate(helperPath: String) -> [String: Any] {
        let fireAndForget: [String: Any] = ["type": "command", "command": helperPath, "async": true]
        let blocking: [String: Any] = ["type": "command", "command": helperPath, "timeout": 5]
        func group(_ matcher: String, _ entry: [String: Any]) -> [String: Any] {
            ["matcher": matcher, "hooks": [entry]]
        }
        return [
            "SessionStart": [group("", fireAndForget)],
            "UserPromptSubmit": [group("", fireAndForget)],
            "PreToolUse": [group("", fireAndForget)],
            "PostToolUse": [group("", fireAndForget)],
            "PermissionRequest": [group("", blocking)],
            "Notification": [group("permission_prompt", fireAndForget), group("idle_prompt", fireAndForget)],
            "Stop": [group("", fireAndForget)],
            "SessionEnd": [group("", fireAndForget)],
        ]
    }

    /// Exactly what the Enable button will merge, for the Settings preview.
    static func claudePreviewJSON(helperPath: String) -> String {
        prettyJSON(["hooks": claudeTemplate(helperPath: helperPath)]) ?? "{}"
    }

    static func claudeStatus(settingsURL: URL, helperPath: String) -> HookInstallStatus {
        guard let hooks = try? hooksObject(in: readSettings(settingsURL), url: settingsURL) else {
            return .conflict(unparsableReason)
        }
        let mine = ourEntries(in: hooks)
        if mine.isEmpty { return .notInstalled }
        return mine == ourEntries(in: claudeTemplate(helperPath: helperPath)) ? .installed : .outdated
    }

    /// Merges the template in, dropping any earlier version of ours first.
    /// Foreign keys, foreign events and foreign entries inside an event we also
    /// use all survive; the file comes back pretty-printed with sorted keys,
    /// which is why the original is copied to `.omelette-backup` beforehand.
    static func installClaude(settingsURL: URL, helperPath: String) throws {
        var settings = try readSettings(settingsURL)
        var hooks = stripOurs(from: try hooksObject(in: settings, url: settingsURL))
        for (event, value) in claudeTemplate(helperPath: helperPath) {
            guard let ours = value as? [[String: Any]] else { continue }
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.append(contentsOf: ours)
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        try writeSettings(settings, to: settingsURL)
    }

    /// Deletes exactly our entries. `helperPath` is part of the shared signature
    /// and deliberately unused: removal keys off `ourCommandMarker`, so an entry
    /// written by an older build with a different path goes too.
    static func removeClaude(settingsURL: URL, helperPath: String) throws {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        var settings = try readSettings(settingsURL)
        let hooks = try hooksObject(in: settings, url: settingsURL)
        guard !ourEntries(in: hooks).isEmpty else { return }   // nothing of ours: do not reformat the file
        let cleaned = stripOurs(from: hooks)
        if cleaned.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = cleaned
        }
        try writeSettings(settings, to: settingsURL)
    }

    // MARK: - Claude internals

    /// Order-independent fingerprint of the entries we own, one string per
    /// entry: "<Event>\u{1}<matcher>\u{1}<hook object as sorted-key JSON>".
    /// Re-serialising through JSONSerialization keeps `true` a boolean and `5`
    /// a number, which `as? Bool` on a bridged NSNumber would not.
    private static func ourEntries(in hooks: [String: Any]) -> [String] {
        var out: [String] = []
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            for group in groups {
                let matcher = group["matcher"] as? String ?? ""
                guard let entries = group["hooks"] as? [[String: Any]] else { continue }
                for entry in entries where isOurs(entry) {
                    out.append("\(event)\u{1}\(matcher)\u{1}\(canonicalJSON(entry))")
                }
            }
        }
        return out.sorted()
    }

    private static func isOurs(_ entry: [String: Any]) -> Bool {
        (entry["command"] as? String)?.contains(ourCommandMarker) == true
    }

    private static func canonicalJSON(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return String(describing: object) }
        return text
    }

    /// Removes every entry of ours, keeping foreign entries — including one that
    /// shares a matcher group with ours — and pruning groups and events left empty.
    private static func stripOurs(from hooks: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else {
                out[event] = value          // a shape we do not understand: leave it exactly as it is
                continue
            }
            var kept: [[String: Any]] = []
            for var group in groups {
                guard let entries = group["hooks"] as? [[String: Any]] else {
                    kept.append(group)
                    continue
                }
                let survivors = entries.filter { !isOurs($0) }
                if survivors.isEmpty { continue }
                group["hooks"] = survivors
                kept.append(group)
            }
            if !kept.isEmpty { out[event] = kept }
        }
        return out
    }

    /// Missing or blank file → `{}`. Anything else that is not a JSON object,
    /// or a file we cannot read, is a refusal.
    private static func readSettings(_ url: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url) else {
            if FileManager.default.fileExists(atPath: url.path) { throw Error.unparsable(url) }
            return [:]
        }
        let blank = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? data.isEmpty
        if blank { return [:] }
        guard let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Error.unparsable(url)
        }
        return dict
    }

    /// The `hooks` object, or a refusal when the key is there but is not one.
    private static func hooksObject(in settings: [String: Any], url: URL) throws -> [String: Any] {
        guard let value = settings["hooks"] else { return [:] }
        guard let hooks = value as? [String: Any] else { throw Error.unparsable(url) }
        return hooks
    }

    private static func writeSettings(_ settings: [String: Any], to url: URL) throws {
        guard let data = prettyJSONData(settings) else { throw Error.unparsable(url) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try backupOnce(url)
        try writeAtomically(data, to: url)
    }

    // MARK: - Shared file plumbing

    /// One-time safety copy next to the file. Never overwritten, so it always
    /// holds the file as it was before Omelette first edited it.
    private static func backupOnce(_ url: URL) throws {
        let backup = backupURL(for: url)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path), !fm.fileExists(atPath: backup.path) else { return }
        try fm.copyItem(at: url, to: backup)
    }

    /// Foundation's `.atomic` is exactly "write a temp file in the same
    /// directory, then rename": a crash or a full disk leaves the previous
    /// config intact instead of a half-written one.
    private static func writeAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
    }

    private static func prettyJSONData(_ object: Any) -> Data? {
        guard var data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return nil }
        data.append(0x0A)          // editors and `git diff` both want the trailing newline
        return data
    }

    private static func prettyJSON(_ object: Any) -> String? {
        prettyJSONData(object).flatMap { String(data: $0.dropLast(), encoding: .utf8) }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/AgentHooksInstallerTests`
Expected: PASS (11 tests).

- [ ] **Step 5: Commit**

```bash
git add UsageTracker/Agents/AgentHooksInstaller.swift UsageTrackerTests/AgentHooksInstallerTests.swift
git commit -m "Agents: hook installer for ~/.claude/settings.json

Merges our eight hook entries without disturbing foreign keys or foreign
hooks, backs the original up once, refuses to write a settings.json it
cannot parse.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

## Task 2: `AgentHooksInstaller` — the Codex half

**Files:**
- Modify: `UsageTracker/Agents/AgentHooksInstaller.swift` (append a `// MARK: - Codex` section before `// MARK: - Shared file plumbing`)
- Test: `UsageTrackerTests/AgentHooksInstallerTests.swift` (append)

**Interfaces:**
- Consumes: `ourCommandMarker`, `unreadableReason`, `backupOnce`, `writeAtomically`, `Error` from Task 1.
- Produces:
  ```swift
  static func codexNotifyLine(helperPath: String) -> String                             // ✱
  static func codexStatus(configURL: URL, helperPath: String) -> HookInstallStatus      // ✱
  static func installCodex(configURL: URL, helperPath: String) throws                   // ✱
  static func removeCodex(configURL: URL, helperPath: String) throws                    // ✱
  ```
  The line is literally `notify = ["<helperPath>", "--codex"]`, with `\` and `"` in the path TOML-escaped.

**The rules, because there is no TOML parser here:**
- "Top level" is everything before the first line whose first non-space character is `[` — a `notify` under `[tui]` is that table's key and is none of our business.
- A line whose first non-space character is `#` is a comment and is skipped.
- A line is the `notify` key when its trimmed form starts with `notify` and the rest, trimmed, starts with `=` (so `notifyme = 1` does not match).
- Found and identical to ours → `installed`. Found, different, but containing `ourCommandMarker` → `outdated`, replaced **in place**. Found and someone else's → `conflict(theirLine)`, and `installCodex` throws rather than writing.
- Absent → insert. Just above the first `[table]` header (followed by a blank line) so the key stays top-level, or at the end when the file has no tables.

- [ ] **Step 1: Write the failing tests**

Append inside `AgentHooksInstallerTests` (before the closing brace):

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/AgentHooksInstallerTests`
Expected: compile error "type 'AgentHooksInstaller' has no member 'installCodex'".

- [ ] **Step 3: Add the Codex section**

Insert into `AgentHooksInstaller`, immediately before `// MARK: - Shared file plumbing`:

```swift
    // MARK: - Codex

    /// The one line we own in config.toml.
    static func codexNotifyLine(helperPath: String) -> String {
        "notify = [\"\(tomlEscaped(helperPath))\", \"--codex\"]"
    }

    static func codexStatus(configURL: URL, helperPath: String) -> HookInstallStatus {
        guard let text = try? readConfig(configURL) else { return .conflict(unreadableReason) }
        guard let found = topLevelNotify(in: text) else { return .notInstalled }
        let line = found.line.trimmingCharacters(in: .whitespaces)
        if line == codexNotifyLine(helperPath: helperPath) { return .installed }
        if line.contains(ourCommandMarker) { return .outdated }
        return .conflict(line)
    }

    /// Adds or refreshes our `notify` line. A `notify` that is someone else's is
    /// a conflict, not something to overwrite — the UI shows their line and ours
    /// side by side instead.
    static func installCodex(configURL: URL, helperPath: String) throws {
        guard let text = try? readConfig(configURL) else { throw Error.conflict(unreadableReason) }
        let ours = codexNotifyLine(helperPath: helperPath)
        var all = lines(of: text)

        if let found = topLevelNotify(in: text) {
            let existing = found.line.trimmingCharacters(in: .whitespaces)
            if existing == ours { return }
            guard existing.contains(ourCommandMarker) else { throw Error.conflict(existing) }
            all[found.index] = ours
        } else {
            while let last = all.last, last.trimmingCharacters(in: .whitespaces).isEmpty { all.removeLast() }
            let index = topLevelInsertIndex(in: all)
            all.insert(contentsOf: index < all.count ? [ours, ""] : [ours], at: index)
        }
        try writeConfig(all, to: configURL)
    }

    /// Removes our line only. A foreign `notify` is left exactly where it is.
    /// `helperPath` is part of the shared signature; ownership is decided by
    /// `ourCommandMarker`, so a line from an older build goes too.
    static func removeCodex(configURL: URL, helperPath: String) throws {
        guard let text = try? readConfig(configURL) else { throw Error.conflict(unreadableReason) }
        guard let found = topLevelNotify(in: text), found.line.contains(ourCommandMarker) else { return }
        var all = lines(of: text)
        all.remove(at: found.index)
        try writeConfig(all, to: configURL)
    }

    // MARK: - Codex internals

    /// The index and raw text of the top-level `notify = …` line, if any.
    /// The top level ends at the first `[table]` (or `[[array]]`) header;
    /// comments never count.
    private static func topLevelNotify(in text: String) -> (index: Int, line: String)? {
        for (index, raw) in lines(of: text).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("[") { return nil }
            guard line.hasPrefix("notify") else { continue }
            let rest = line.dropFirst("notify".count).trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("=") { return (index, raw) }
        }
        return nil
    }

    /// Just before the first table header, so the key stays top-level; the end
    /// of the file when there is no table.
    private static func topLevelInsertIndex(in all: [String]) -> Int {
        for (index, raw) in all.enumerated()
        where raw.trimmingCharacters(in: .whitespaces).hasPrefix("[") {
            return index
        }
        return all.count
    }

    private static func lines(of text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    private static func tomlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Missing file → empty text. An existing file we cannot decode is a
    /// refusal: overwriting it would destroy a config we never read.
    private static func readConfig(_ url: URL) throws -> String {
        guard let data = try? Data(contentsOf: url) else {
            if FileManager.default.fileExists(atPath: url.path) { throw Error.unparsable(url) }
            return ""
        }
        guard let text = String(data: data, encoding: .utf8) else { throw Error.unparsable(url) }
        return text
    }

    private static func writeConfig(_ all: [String], to url: URL) throws {
        var text = all.joined(separator: "\n")
        if !text.hasSuffix("\n") { text += "\n" }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try backupOnce(url)
        try writeAtomically(Data(text.utf8), to: url)
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/AgentHooksInstallerTests`
Expected: PASS (19 tests).

- [ ] **Step 5: Commit**

```bash
git add UsageTracker/Agents/AgentHooksInstaller.swift UsageTrackerTests/AgentHooksInstallerTests.swift
git commit -m "Agents: Codex notify line install/remove without a TOML library

Only the top-level notify key is ours: a notify inside a [table] and a
commented-out one are ignored, someone else's is a conflict we refuse to
overwrite.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

## Task 3: The four agent settings keys

**Files:**
- Modify: `UsageTracker/Core/Settings.swift` (`Defaults` block ~line 45-73, the `@AppStorage` block ~line 75-112, `resetToDefaults()` ~line 122-157)
- Test: `UsageTrackerTests/SettingsStoreTests.swift` (`scrambleEverything` ~line 28-63, `assertAllDefaults` ~line 66-95, plus one new test)

**Interfaces:**
- Consumes: `SettingsStore.Defaults` (the codebase's rule: one place per default, read by both the property wrapper and the reset).
- Produces (all four are contract items):
  ```swift
  @AppStorage("agentsNotifyNeedsYou") var agentsNotifyNeedsYou: Bool = true
  @AppStorage("agentsNeedsYouBypassQuietHours") var agentsNeedsYouBypassQuietHours: Bool = true
  @AppStorage("agentsNotifyDone") var agentsNotifyDone: Bool = false
  @AppStorage("agentsShowInMenuBar") var agentsShowInMenuBar: Bool = true
  ```
  Package 5 (notifications, agents pill) reads these; this task only stores them.

- [ ] **Step 1: Write the failing test**

Append to `SettingsStoreTests`:

```swift
    @MainActor
    func testTheAgentDefaultsAreTheOnesTheAgentsTabPromises() {
        let settings = SettingsStore.shared
        settings.resetToDefaults()

        XCTAssertTrue(settings.agentsNotifyNeedsYou)
        XCTAssertTrue(settings.agentsNeedsYouBypassQuietHours, "a session waiting for approval is the one alert worth waking you")
        XCTAssertFalse(settings.agentsNotifyDone, "a notification per finished turn would be noise")
        XCTAssertTrue(settings.agentsShowInMenuBar)
    }
```

and extend the two existing helpers so a reset that forgets one of the four still fails a test. In `scrambleEverything`, after the `hasSeenOnboarding` line:

```swift
        s.agentsNotifyNeedsYou = !SettingsStore.Defaults.agentsNotifyNeedsYou
        s.agentsNeedsYouBypassQuietHours = !SettingsStore.Defaults.agentsNeedsYouBypassQuietHours
        s.agentsNotifyDone = !SettingsStore.Defaults.agentsNotifyDone
        s.agentsShowInMenuBar = !SettingsStore.Defaults.agentsShowInMenuBar
```

In `assertAllDefaults`, after the `hasSeenOnboarding` assertion:

```swift
        XCTAssertEqual(s.agentsNotifyNeedsYou, SettingsStore.Defaults.agentsNotifyNeedsYou, message)
        XCTAssertEqual(s.agentsNeedsYouBypassQuietHours, SettingsStore.Defaults.agentsNeedsYouBypassQuietHours, message)
        XCTAssertEqual(s.agentsNotifyDone, SettingsStore.Defaults.agentsNotifyDone, message)
        XCTAssertEqual(s.agentsShowInMenuBar, SettingsStore.Defaults.agentsShowInMenuBar, message)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/SettingsStoreTests`
Expected: compile error "value of type 'SettingsStore' has no member 'agentsNotifyNeedsYou'".

- [ ] **Step 3: Add the defaults, the properties and the reset lines**

In `Settings.swift`, inside `enum Defaults`, after `static let hasSeenOnboarding = false`:

```swift
        static let agentsNotifyNeedsYou = true
        static let agentsNeedsYouBypassQuietHours = true
        static let agentsNotifyDone = false
        static let agentsShowInMenuBar = true
```

After the `@AppStorage("hasSeenOnboarding")` property:

```swift
    /// A session stopped and is waiting for a permission decision.
    @AppStorage("agentsNotifyNeedsYou") var agentsNotifyNeedsYou: Bool = Defaults.agentsNotifyNeedsYou
    /// "Needs you" is the one alert worth waking someone: on by default it ignores
    /// quiet hours, because an agent that waits all night has wasted the night.
    @AppStorage("agentsNeedsYouBypassQuietHours") var agentsNeedsYouBypassQuietHours: Bool = Defaults.agentsNeedsYouBypassQuietHours
    /// A session finished its turn. Off by default — it fires on every reply.
    @AppStorage("agentsNotifyDone") var agentsNotifyDone: Bool = Defaults.agentsNotifyDone
    /// The agents pill in the menu bar (count of live sessions).
    @AppStorage("agentsShowInMenuBar") var agentsShowInMenuBar: Bool = Defaults.agentsShowInMenuBar
```

In `resetToDefaults()`, after `hasSeenOnboarding = Defaults.hasSeenOnboarding`:

```swift
        agentsNotifyNeedsYou = Defaults.agentsNotifyNeedsYou
        agentsNeedsYouBypassQuietHours = Defaults.agentsNeedsYouBypassQuietHours
        agentsNotifyDone = Defaults.agentsNotifyDone
        agentsShowInMenuBar = Defaults.agentsShowInMenuBar
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/SettingsStoreTests`
Expected: PASS (5 tests, including the new one).

- [ ] **Step 5: Commit**

```bash
git add UsageTracker/Core/Settings.swift UsageTrackerTests/SettingsStoreTests.swift
git commit -m "Settings: agent notification and menu-bar keys

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

## Task 4: Settings → Agents tab

**Precondition:** packages 1 and 2 are merged (`AgentPaths`, `AgentEventServer`, `AgentSessionStore.shared`). Until then this task does not compile — that is expected, not a bug to work around by stubbing those types.

**Files:**
- Create: `UsageTracker/UI/AgentsSettingsView.swift`
- Modify: `UsageTracker/UI/SettingsView.swift:14-29` (the `Tab` enum) and `:39-56` (the `TabView` body)
- Reference (read only): `UsageTracker/UI/SettingsView.swift:183-235` (Form/Section/Toggle house style), `:293-321` (a Section with a button, a trailing status string and a caption)

**Interfaces:**
- Consumes: `AgentHooksInstaller` (Tasks 1–2), `SettingsStore` (Task 3), `AgentPaths.claudeSettingsURL / codexConfigURL / helperSymlinkURL / socketURL / helperVersion` (package 1), `AgentDiagnostics.server?.receivedCount / droppedCount` and `AgentChannel.shared.startError` (package 1, Task 7), `AgentSessionStore.shared.lastEventAt` (package 2).
- Produces:
  ```swift
  struct AgentsSettingsView: View {}                 // the whole tab
  extension SettingsView.Tab { case agents }         // new case, rawValue "Agents", icon "bolt.horizontal.circle"
  ```
  `AgentDiagnostics` already exists (package 1) — do not redeclare it.

- [ ] **Step 1: Write the view**

```swift
// UsageTracker/UI/AgentsSettingsView.swift
import SwiftUI

/// Settings → Agents: turn the hooks on and off per source, with the exact text
/// that will be written shown before anything is written, plus the alert
/// toggles and enough diagnostics to tell "not installed" from "installed but
/// nothing is arriving".
struct AgentsSettingsView: View {
    @StateObject private var settings = SettingsStore.shared
    @ObservedObject private var sessions = AgentSessionStore.shared

    @State private var claude: HookInstallStatus = .notInstalled
    @State private var codex: HookInstallStatus = .notInstalled
    @State private var claudePreviewShown = false
    @State private var codexPreviewShown = false
    @State private var failure: String?
    @State private var received = 0
    @State private var dropped = 0

    private var helperPath: String { AgentPaths.helperSymlinkURL.path }

    var body: some View {
        Form {
            claudeSection
            codexSection
            if let failure {
                Section {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(failure).font(.caption).textSelection(.enabled)
                    }
                }
            }
            alertsSection
            diagnosticsSection
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshStatus)
        .task { await pollDiagnostics() }
    }

    // MARK: - Sources

    private var claudeSection: some View {
        Section {
            statusRow(claude)
            actionRow(
                status: claude,
                fileURL: AgentPaths.claudeSettingsURL,
                openTitle: "Open settings.json",
                install: { try AgentHooksInstaller.installClaude(settingsURL: AgentPaths.claudeSettingsURL, helperPath: helperPath) },
                remove: { try AgentHooksInstaller.removeClaude(settingsURL: AgentPaths.claudeSettingsURL, helperPath: helperPath) }
            )
            preview(
                isExpanded: $claudePreviewShown,
                text: AgentHooksInstaller.claudePreviewJSON(helperPath: helperPath)
            )
            Text("Eight hooks in `~/.claude/settings.json` call Omelette's helper with the session id, the tool name and the folder — never your prompts or file contents. All but the permission hook are `async`, so Claude Code never waits for us. Omelette rewrites the file with sorted keys and two-space indentation and keeps the original as `settings.json.omelette-backup`.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Claude Code")
        }
    }

    private var codexSection: some View {
        Section {
            statusRow(codex)
            actionRow(
                status: codex,
                fileURL: AgentPaths.codexConfigURL,
                openTitle: "Open config.toml",
                install: { try AgentHooksInstaller.installCodex(configURL: AgentPaths.codexConfigURL, helperPath: helperPath) },
                remove: { try AgentHooksInstaller.removeCodex(configURL: AgentPaths.codexConfigURL, helperPath: helperPath) }
            )
            preview(
                isExpanded: $codexPreviewShown,
                text: AgentHooksInstaller.codexNotifyLine(helperPath: helperPath)
            )
            if case .conflict(let line) = codex {
                VStack(alignment: .leading, spacing: 4) {
                    Text("`config.toml` already has a `notify` of its own:")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(line)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                    Button("Copy Omelette's line") {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(AgentHooksInstaller.codexNotifyLine(helperPath: helperPath), forType: .string)
                    }
                    .buttonStyle(.link)
                }
            }
            Text("Codex reports one event, `agent-turn-complete`, so its sessions show as working or done and never as \"needs you\". The line goes above the first `[table]` so it stays a top-level key.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Codex")
        }
    }

    private func statusRow(_ status: HookInstallStatus) -> some View {
        HStack(spacing: 8) {
            Circle().fill(tint(status)).frame(width: 8, height: 8)
            Text(label(status)).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
        }
    }

    @ViewBuilder
    private func actionRow(
        status: HookInstallStatus,
        fileURL: URL,
        openTitle: String,
        install: @escaping () throws -> Void,
        remove: @escaping () throws -> Void
    ) -> some View {
        HStack {
            switch status {
            case .notInstalled:
                Button("Enable") { run(install) }
            case .outdated:
                Button("Update") { run(install) }
                Button("Disable") { run(remove) }
            case .installed:
                Button("Disable") { run(remove) }
            case .conflict:
                Button("Enable") {}.disabled(true)
            }
            Spacer()
            Button(openTitle) { NSWorkspace.shared.open(fileURL) }
                .disabled(!FileManager.default.fileExists(atPath: fileURL.path))
        }
    }

    private func preview(isExpanded: Binding<Bool>, text: String) -> some View {
        DisclosureGroup("What will be written", isExpanded: isExpanded) {
            ScrollView {
                Text(text)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 170)
        }
    }

    // MARK: - Alerts

    private var alertsSection: some View {
        Section("Alerts") {
            Toggle("Notify when an agent needs you", isOn: $settings.agentsNotifyNeedsYou)
            if settings.agentsNotifyNeedsYou {
                Toggle("Even during quiet hours", isOn: $settings.agentsNeedsYouBypassQuietHours)
            }
            Toggle("Notify when an agent finishes a turn", isOn: $settings.agentsNotifyDone)
            Toggle("Show agents in the menu bar", isOn: $settings.agentsShowInMenuBar)
            Text("\"Needs you\" fires when a session stops for a permission decision — that one ignores quiet hours by default, because an agent that waits all night has wasted the night. Finished-turn alerts fire on every reply, so they start off.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            LabeledContent("Socket") {
                Text(AgentPaths.socketURL.path)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            LabeledContent("Helper", value: "omelette-hook v\(AgentPaths.helperVersion)")
            if let startError = AgentChannel.shared.startError {
                LabeledContent("Socket status") {
                    Text(startError).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            LabeledContent("Events", value: "\(received) received · \(dropped) dropped")
            LabeledContent("Last event", value: lastEventText)
            Text("Received counts messages the helper delivered; dropped counts messages the socket could not decode. Zero received with hooks installed usually means Omelette was restarted after the last session started — the next prompt re-registers it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var lastEventText: String {
        guard let date = sessions.lastEventAt else { return "—" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// The counters live on a plain class, not an ObservableObject, so the tab
    /// re-reads them while it is on screen. `.task` cancels this when it is not.
    private func pollDiagnostics() async {
        while !Task.isCancelled {
            received = AgentDiagnostics.server?.receivedCount ?? 0
            dropped = AgentDiagnostics.server?.droppedCount ?? 0
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    // MARK: - Actions

    private func run(_ action: () throws -> Void) {
        do {
            try action()
            failure = nil
        } catch {
            failure = describe(error)
        }
        refreshStatus()
    }

    private func refreshStatus() {
        claude = AgentHooksInstaller.claudeStatus(settingsURL: AgentPaths.claudeSettingsURL, helperPath: helperPath)
        codex = AgentHooksInstaller.codexStatus(configURL: AgentPaths.codexConfigURL, helperPath: helperPath)
    }

    private func describe(_ error: Swift.Error) -> String {
        guard let installerError = error as? AgentHooksInstaller.Error else {
            return error.localizedDescription
        }
        switch installerError {
        case .unparsable(let url):
            return "\(url.lastPathComponent) isn't valid — Omelette won't overwrite a file it can't read. Fix or move it and try again."
        case .conflict(let line):
            return "Another tool already owns that setting: \(line)"
        }
    }

    private func label(_ status: HookInstallStatus) -> String {
        switch status {
        case .installed: return "Installed"
        case .outdated: return "Installed — older than this build"
        case .notInstalled: return "Not installed"
        case .conflict: return "Can't write — something else owns this"
        }
    }

    private func tint(_ status: HookInstallStatus) -> Color {
        switch status {
        case .installed: return .green
        case .outdated: return .orange
        case .notInstalled: return .secondary
        case .conflict: return .red
        }
    }
}
```

- [ ] **Step 2: Add the tab to `SettingsView`**

In the `Tab` enum, after `case notifications = "Notifications"`:

```swift
        case agents = "Agents"
```

and in the same enum's `icon` switch, after the `.notifications` case:

```swift
            case .agents: return "bolt.horizontal.circle"
```

In `body`, after the `notificationsTab` entry:

```swift
            AgentsSettingsView()
                .tabItem { Label(Tab.agents.rawValue, systemImage: Tab.agents.icon) }
                .tag(Tab.agents)
```

- [ ] **Step 3: Build and open the tab**

Run: `xcodegen generate && xcodebuild -project UsageTracker.xcodeproj -scheme UsageTracker -configuration Debug -derivedDataPath build/DerivedData build && open build/DerivedData/Build/Products/Debug/Omelette.app`
Expected: BUILD SUCCEEDED. Settings shows five tabs (General · Notifications · Agents · Account · Advanced). On Agents: two status lines, "What will be written" expands to the JSON with the real helper path and to the one TOML line, the four toggles, and a Diagnostics block with the socket path and `omelette-hook v1`.

- [ ] **Step 4: Exercise Enable / Update / Disable against a scratch copy**

Do not test against your live `~/.claude/settings.json`. Run this first, then use the buttons and diff:

```bash
cp ~/.claude/settings.json /tmp/settings.json.before 2>/dev/null || echo "no settings.json yet"
```

Click **Enable** under Claude Code, then run:

```bash
python3 - <<'PY'
import json, os
after = json.load(open(os.path.expanduser("~/.claude/settings.json")))
try:
    before = json.load(open("/tmp/settings.json.before"))
except FileNotFoundError:
    before = {}
before.pop("hooks", None)
print("other keys survived:", before == {k: v for k, v in after.items() if k != "hooks"})
print("events:", sorted(after.get("hooks", {})))
PY
ls ~/.claude/settings.json.omelette-backup
```
Expected:
```
other keys survived: True
events: ['Notification', 'PermissionRequest', 'PostToolUse', 'PreToolUse', 'SessionEnd', 'SessionStart', 'Stop', 'UserPromptSubmit']
/Users/<you>/.claude/settings.json.omelette-backup
```
(`ls` fails only when there was no settings.json before — then there was nothing to back up.) The status line reads **Installed** and the button now says **Disable**; clicking it returns the file to `Not installed` with the other keys intact.

- [ ] **Step 5: Commit**

```bash
git add UsageTracker/UI/AgentsSettingsView.swift UsageTracker/UI/SettingsView.swift
git commit -m "Settings: Agents tab — install/remove hooks, previews, diagnostics

Per-source status and Enable/Update/Disable, the exact JSON and TOML behind
a disclosure, the agent alert toggles, and socket/helper/event counters.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

## Task 5: Onboarding card

**Precondition:** same as Task 4 — `AgentPaths` must exist (package 1).

**Files:**
- Modify: `UsageTracker/UI/OnboardingView.swift` (`totalPages` line 14, `content` switch lines 72-79, plus a new page and its helpers)

**Interfaces:**
- Consumes: `AgentHooksInstaller.claudeStatus / installClaude`, `AgentPaths.claudeSettingsURL`, `AgentPaths.helperSymlinkURL`, and the file's own `permissionRow(icon:title:description:)` helper (line 230) — reuse it, do not write a second row style.
- Produces: nothing other tasks depend on.

The three existing cards (welcome, permissions, ready) keep their copy, order and controls. The new card is inserted as page index 2, so "You're all set!" stays last and the dot row picks up the fourth dot from `totalPages` on its own.

- [ ] **Step 1: Add the state, the page count and the switch case**

Change line 14:

```swift
    private let totalPages = 4
```

Add next to the other `@State` properties (after `keychainError`):

```swift
    @State private var agentHooks: HookInstallStatus = .notInstalled
    @State private var agentHooksError: String?
```

and change the `content` switch to:

```swift
    @ViewBuilder
    private var content: some View {
        switch page {
        case 0: welcomePage
        case 1: permissionsPage
        case 2: agentsPage
        default: readyPage
        }
    }
```

- [ ] **Step 2: Add the card and its helpers**

Insert after `permissionsPage`'s closing brace (before `notificationStatusColor`):

```swift
    /// The one card that is an offer rather than a requirement: agent status is
    /// opt-in, works on Claude Code only from here, and is fully reversible in
    /// Settings → Agents (which also handles Codex).
    private var agentsPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Your agents, at a glance")
                .font(.title2.weight(.semibold))

            permissionRow(
                icon: "bolt.horizontal.circle",
                title: "Agent status (optional)",
                description: "Omelette can also show which Claude Code sessions are running, which one is **waiting for your approval**, and take you back to it in one click. Turning this on adds eight hooks to `~/.claude/settings.json` that call a small helper inside Omelette. They send the session id, the tool name and the folder — never your prompts or your files — and Claude Code never waits on them. Settings → Agents shows the exact JSON, adds Codex, and removes all of it again."
            )

            HStack(spacing: 8) {
                Circle()
                    .fill(agentHooksColor)
                    .frame(width: 8, height: 8)
                Text(agentHooksLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(agentHooksButtonLabel) {
                    enableAgentHooks()
                }
                .buttonStyle(.bordered)
                .disabled(agentHooksInstalled)
            }
            .padding(.top, 4)

            if let agentHooksError {
                Text(agentHooksError)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            Spacer()
        }
        .onAppear(perform: refreshAgentHooks)
    }

    private var agentHooksInstalled: Bool {
        if case .installed = agentHooks { return true }
        return false
    }

    private var agentHooksLabel: String {
        switch agentHooks {
        case .installed: return "Hooks installed"
        case .outdated: return "Hooks installed — older than this build"
        case .notInstalled: return "Not enabled"
        case .conflict(let reason): return reason
        }
    }

    private var agentHooksColor: Color {
        switch agentHooks {
        case .installed: return .green
        case .outdated: return .orange
        case .notInstalled: return .secondary
        case .conflict: return .red
        }
    }

    private var agentHooksButtonLabel: String {
        switch agentHooks {
        case .installed: return "Enabled"
        case .outdated: return "Update"
        case .notInstalled, .conflict: return "Enable"
        }
    }

    private func refreshAgentHooks() {
        agentHooks = AgentHooksInstaller.claudeStatus(
            settingsURL: AgentPaths.claudeSettingsURL,
            helperPath: AgentPaths.helperSymlinkURL.path
        )
    }

    private func enableAgentHooks() {
        do {
            try AgentHooksInstaller.installClaude(
                settingsURL: AgentPaths.claudeSettingsURL,
                helperPath: AgentPaths.helperSymlinkURL.path
            )
            agentHooksError = nil
        } catch {
            agentHooksError = "Couldn't write ~/.claude/settings.json: \(error.localizedDescription)"
        }
        refreshAgentHooks()
    }
```

- [ ] **Step 3: Build and replay the tour**

Run: `xcodegen generate && xcodebuild -project UsageTracker.xcodeproj -scheme UsageTracker -configuration Debug -derivedDataPath build/DerivedData build && open build/DerivedData/Build/Products/Debug/Omelette.app`
Then Settings → Advanced → **Replay welcome tour**.
Expected: four dots; card 3 is "Your agents, at a glance" with a grey dot and an **Enable** button; the welcome, permissions and "You're all set!" cards are word-for-word what they were. Pressing Enable turns the dot green, the label to "Hooks installed" and the button to a disabled "Enabled"; Settings → Agents agrees.

- [ ] **Step 4: Commit**

```bash
git add UsageTracker/UI/OnboardingView.swift
git commit -m "Onboarding: one card offering agent status

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

## Task 6: Verification pass (no code)

**Files:** none. Run against the Debug build with packages 1 and 2 present, and record the result in the commit body.

- [ ] **Step 1: Full suite**

Run: `xcodegen generate && xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData`
Expected: PASS, including 19 `AgentHooksInstallerTests` and 5 `SettingsStoreTests`. (Append `CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO` if signing the test host fails locally.)

- [ ] **Step 2: Walk the checklist**

- [ ] Claude: Enable on a settings.json that already has `model`, `permissions` and a foreign `PreToolUse` hook → all three survive, our eight events are added, `settings.json.omelette-backup` appears.
- [ ] Claude: Disable → our entries and the events that held only ours are gone; the foreign hook and the other keys are untouched; status reads "Not installed".
- [ ] Claude: `echo '{ broken' > ~/.claude/settings.json.test-copy` and point nothing at it — instead confirm the unit test `testUnparsableSettingsAreNeverOverwritten` covers this, and that the tab shows the red conflict line if your real file is ever unparsable.
- [ ] Codex: with no `notify` in `~/.codex/config.toml`, Enable → the line is above the first `[table]`; `codex` still starts (`codex --version`).
- [ ] Codex: put `notify = ["/usr/local/bin/whatever"]` at the top by hand → the tab shows the red conflict state, the Enable button is disabled, the existing line is displayed and "Copy Omelette's line" puts our line on the clipboard. Restore the file afterwards.
- [ ] Both preview disclosures show the real `~/Library/Application Support/UsageTracker/bin/omelette-hook` path with unescaped slashes.
- [ ] "Open settings.json" / "Open config.toml" open the file in the default editor; both buttons are disabled when the file does not exist.
- [ ] The four toggles persist across an app restart; Settings → Advanced → "Reset all settings" puts them back to on/on/off/on.
- [ ] Diagnostics: socket path, `omelette-hook v1`, a received count that climbs while a hooked Claude Code session runs, and "Last event" that updates.
- [ ] Onboarding replay shows four cards; the three original ones are unchanged.
- [ ] Light and dark appearance; the tab fits the 520×540 Settings window without clipping (it scrolls).

- [ ] **Step 3: Record the result**

```bash
git commit --allow-empty -m "Agents package 3: verification pass

Installer round trip on a settings.json with foreign keys and hooks, Codex
conflict path, previews, toggles, diagnostics and the onboarding card all
checked by hand; full test suite green.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

## Self-review notes

- **Spec coverage.** Hook installer bullet by bullet: merge preserving everything else (T1 `stripOurs` + install), identification by command path (`ourCommandMarker`), atomic write with a one-time backup (`writeAtomically` / `backupOnce`), `installed`/`outdated`/`notInstalled` recomputed after every action (`refreshStatus` in T4, `refreshAgentHooks` in T5), Codex `notify` written the same way and never overwritten when it is someone else's (T2, plus the conflict block with "Copy Omelette's line" — the spec's "shows the line to paste instead"), removal deleting exactly our entries (T1/T2). Settings → Agents: Enable/Disable per source, JSON/TOML preview, status line, "Open settings.json", notification toggles, diagnostics (events received, dropped, socket path, helper version) — all in T4, with "last event" added from `AgentSessionStore.lastEventAt`. Onboarding: one card with the same Enable button (T5). Security and privacy: "only touches the `hooks` key (Claude) and the `notify` key (Codex); refuses to write when the existing file does not parse" is `hooksObject`, `readSettings`, `readConfig` and the `.unparsable` throw, asserted by `testUnparsableSettingsAreNeverOverwritten` and `testSomeoneElsesNotifyIsAConflictAndIsNeverOverwritten`.
- **Out of scope on purpose.** The event table's *effects* (state machine) belong to package 2; the popover Agents section to package 4; firing the notifications the toggles govern, and the menu-bar pill the fourth toggle governs, to package 5. This package only stores those four keys. No version bump or CHANGELOG entry: phase 2 ships as one release after packages 1–5, and five packages editing the same changelog block in parallel would collide.
- **Interface additions beyond the contract**, all inside this package: `AgentHooksInstaller.ourCommandMarker`, `unparsableReason`, `unreadableReason`, `backupURL(for:)`, `claudePreviewJSON(helperPath:)`, `Error: Equatable`, and `AgentDiagnostics.server` (plus `AgentsSettingsView`, and the `agents` case on `SettingsView.Tab`). Nothing from the interfaces doc is renamed. `AgentDiagnostics.server` is the one thing that needs a line from package 1 — flagged in T4's Interfaces block.
- **Name consistency check.** `AgentHooksInstaller.claudeTemplate(helperPath:)`, `claudeStatus(settingsURL:helperPath:)`, `installClaude(settingsURL:helperPath:)`, `removeClaude(settingsURL:helperPath:)`, `codexNotifyLine(helperPath:)`, `codexStatus(configURL:helperPath:)`, `installCodex(configURL:helperPath:)`, `removeCodex(configURL:helperPath:)` are spelled identically in Tasks 1, 2, 4, 5 and in the tests. `HookInstallStatus` cases are `installed` / `outdated` / `notInstalled` / `conflict(String)` everywhere. The settings keys are the four contract strings, used verbatim in `Settings.swift`, `SettingsStoreTests` and `AgentsSettingsView`.
- **Known risks.** (1) `claudeStatus` compares the full canonical entry set, so *any* future change to the template (a new event, a changed timeout) reads as `outdated` for existing users — intended, and the Update button is one click, but it means the template is a versioned artefact: change it only with a reason. (2) Install rewrites `settings.json` pretty-printed with sorted keys, so a user's own formatting and key order do not survive; the one-time backup and the caption under the section are the mitigation, and `removeClaude` deliberately does nothing (no reformat) when none of our entries are present. (3) The TOML handling is line-based: a `notify` key written as `notify=["x"]` on the same line as an inline table, or a multi-line array, is out of its depth — it would read as `conflict` (safe) rather than being edited. (4) Two `Notification` entries rather than one alternation matcher is a deliberate choice; if Claude Code ever requires a single entry per event this becomes an `outdated` migration, not a break.
