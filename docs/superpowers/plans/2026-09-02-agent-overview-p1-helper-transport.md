# Agent Overview — Package 1: Helper + Transport Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the `omelette-hook` helper inside `Omelette.app/Contents/Helpers/`, a Unix-socket server in the app that decodes hook payloads into `AgentEvent`, and the launch-time wiring (symlink refresh, server start) — ending at an `onEvent: (AgentEvent) -> Void` callback with a log-only consumer.

**Architecture:** A tiny Foundation-only command-line tool (`HookHelper/`) reads a Claude hook payload from stdin or a Codex payload from `--codex`, wraps it in the v1 wire envelope with host-process info (parent-chain walk via `sysctl`/`proc_pidpath`), and writes one line to `~/Library/Application Support/UsageTracker/agent.sock` with hard 300/500/800 ms caps, always exiting 0. In the app, `AgentEventServer` (POSIX sockets on a private serial queue, socket file 0600, 64 KB cap, one JSON line per connection) decodes with `AgentEventDecoder` → `AgentEvent` and forwards on the main queue. `AgentPaths` owns every path; `AppDelegate` refreshes the `bin/omelette-hook` symlink and starts the server at launch.

**Tech Stack:** Swift 6 (strict concurrency `minimal`), Foundation + Darwin (POSIX sockets, `sysctl`, `libproc`), XCTest (`UsageTrackerTests`, `@testable import Omelette`), xcodegen 2.45.4 (`type: tool` target embedded via a Copy Files phase), macOS 14 floor.

**Spec:** `docs/superpowers/specs/2026-09-02-agent-overview-design.md` (sections "Data sources", "omelette-hook", "AgentEventServer", "Tool summary", "Security and privacy", "Packages"); binding contract: `docs/superpowers/specs/2026-09-02-agent-overview-interfaces.md`; roadmap: `docs/superpowers/specs/2026-09-02-agent-control-plane-roadmap.md`. Phase 1 (`docs/superpowers/plans/2026-09-02-design-system-popover.md`) is assumed merged.

## Global Constraints

- Deployment target macOS 14.0; `SWIFT_VERSION` 6.0 with `SWIFT_STRICT_CONCURRENCY: minimal` (project-level, inherited by every target including the new tool). No `nonisolated(unsafe)` unless an existing pattern needs it; no top-level mutable globals in `main.swift`.
- The interfaces doc is a **binding contract**: type names, file paths and signatures below are used exactly; additions are listed under "Produces" and never rename a contract item.
- New source files are picked up by xcodegen from `sources:` (`UsageTracker/`, `UsageTrackerTests/`, `HookHelper/`); run `xcodegen generate` after adding files and before building. `UsageTracker.xcodeproj/` is generated and gitignored — never `git add` it. `signing.xcconfig` is gitignored and must not be committed.
- Build: `xcodebuild -project UsageTracker.xcodeproj -scheme UsageTracker -configuration Debug -derivedDataPath build/DerivedData build`.
  Tests: `xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS=""` (add `-only-testing:UsageTrackerTests/<Class>` for a single class). **The two overrides are mandatory on every `xcodebuild test`**: `signing.xcconfig` enables the hardened runtime, which blocks the `DYLD_INSERT_LIBRARIES` injection XCTest needs, and the runner hangs ~6 min otherwise (verified in phase 1). Every `xcodebuild test` command written in the tasks below is to be read with these two overrides appended. Note for Task 6 Step 7: with the overrides the embedded helper is signed without the runtime flag in *test* builds only; the plain `build` and the release export keep it.
- When this package runs in a git worktree, copy `signing.xcconfig` from the main checkout first (it is gitignored) and use a worktree-local `-derivedDataPath`.
- Helper invariants (spec): exit code always 0; never blocks longer than 800 ms in total (300 ms connect + 500 ms optional reply); never writes to stdout; never logs or persists a payload. The helper links Foundation only — no AppKit, no SwiftUI.
- Server invariants (spec): socket file mode 0600 in the user's App Support dir; JSON only; ≤ 64 KB per message; parsed into fixed types; malformed input is dropped and counted; nothing received is ever executed or persisted.
- Wire format v1 exactly as in the interfaces doc: `v`, `source`, `helper_version`, `received_at` (Double seconds), `host` (`pid`, `bundle_id`, `tty`, any may be null), `payload` (raw hook JSON). Reply `{"v":1,"decision":null}` on one line.
- Logging goes through `NSLog("[UT] …")` like the rest of the app; log lines may carry event kind and a session-id prefix, never `tool_input`, `cwd` contents or summaries.
- Commits end with the trailer lines
  `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` and
  `Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X`.
- Other sessions may commit the working tree while you work: re-read a file right before editing it; prefer targeted edits over whole-file rewrites.
- No release in this plan: no version bump, no CHANGELOG entry (the phase-2 release package owns those). The owner runs `scripts/build_dmg.sh` / `notarize_dmg.sh` after the whole phase.

---

## Decisions locked in this plan

**Transport: POSIX sockets on both sides, not Network.framework.**
`NWListener` can bind a Unix path (`NWParameters.requiredLocalEndpoint = .unix(path:)`) but (a) creates the socket file with the process umask and offers no way to set its mode or unlink a stale file, (b) leaves the file behind on cancel, (c) pulls the Network framework's worker threads into a helper whose whole life is ~20 ms and whose deadlines are specified in milliseconds, and (d) the unix-path route is barely documented. `socket/bind/chmod/listen` + a `DispatchSourceRead` is ~120 lines, gives 0600 before `listen()` (so no window with a wider mode), exact `poll` deadlines, and one client implementation shared by the helper and the tests.

**Host detection without AppKit.** The helper walks the parent chain with `sysctl(CTL_KERN, KERN_PROC, KERN_PROC_PID)` (`kinfo_proc.kp_eproc.e_ppid`, `e_tdev`) and `proc_pidpath`, and reads the bundle id with `Bundle(path:)` of the first `.app` component of that path. Verified on this machine: `proc_pidinfo(PROC_PIDTBSDINFO)` returns nothing for the root-owned `login` process and would cut the walk there; `sysctl` walks `zsh → login → iTermServer → iTerm2 (com.googlecode.iterm2)` in 3 ms. A helper `.app` nested in another app (VS Code's `Code Helper (Plugin).app`) resolves to the outer app because the first `.app/` in the path wins; the reported `pid` is the outermost ancestor with the same bundle id (the Electron main process), which is what `NSRunningApplication(processIdentifier:)` wants in package 4.

**Embedding.** xcodegen `copy: {destination: wrapper, subpath: Contents/Helpers}` on the target dependency — validated with xcodegen 2.45.4 in a scratch copy of the project: it emits an `Embed Dependencies` `PBXCopyFilesBuildPhase` with `dstSubfolderSpec = 1` (wrapper), `dstPath = Contents/Helpers` and `ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy)`, no entry in the app's "Link Binary With Libraries" phase. `SKIP_INSTALL = YES` on the tool keeps `xcodebuild archive` from placing it under `Products/usr/local/bin`, which would turn the archive into a "Generic Xcode Archive" that `-exportArchive` (in `scripts/build_dmg.sh`) refuses. Hardened runtime, timestamp and identity come from `signing.xcconfig` (project-level `configFiles`, inherited by the tool); the Developer ID export re-signs nested code under `Contents/Helpers`.

**Oversized payloads.** A `Write` tool's `tool_input.content` can exceed 64 KB. Rather than let the app drop the whole event (and miss the `working` transition), the helper shrinks `tool_input` to the keys the app summarises (`command`, `file_path`, `notebook_path`, `pattern`, each ≤ 1024 chars) plus `"_omelette_truncated": true` when the envelope would exceed 64 KB; if still too large it sends nothing. The app-side cap stays exactly 64 KB.

**Two Omelette instances.** `start()` unlinks whatever is at the socket path — the last launched instance wins (the owner runs a login copy and a dev build side by side; the one just launched is the one being tested).

**Ownership across packages (orchestrator decision, see `…-plan-review.md`).** This package owns creating and starting the server for the app's lifetime through `AgentChannel` (Task 7). Package 2 later replaces the log-only consumer by assigning `AgentChannel.shared.onEvent` — one line in `AppState.bootstrap()`, nothing else moves. `AgentDiagnostics` (a `@MainActor enum` holding `static weak var server`) is created here so Settings → Agents (package 3) can read the counters; package 3 only extends it.

## File structure

```
HookHelper/                                  new xcodegen target OmeletteHook (type: tool, product omelette-hook)
  main.swift                                 entry: watchdog, read payload, build envelope, send, exit 0
  HostProcess.swift                          parent-chain walk → pid / bundle id / tty
  SocketClient.swift                         POSIX connect(300 ms) → write line → optional reply(500 ms)
UsageTracker/Agents/
  AgentPaths.swift                           every path + constants + refreshHelperSymlink()
  AgentModels.swift                          AgentSource, AgentState, AgentHostInfo, AgentEvent, AgentSession
  AgentToolSummary.swift                     "Bash: xcodegen generate" (≤ 80 chars of detail)
  AgentEventDecoder.swift                    wire line → AgentEvent (version/size/field checks)
  AgentEventServer.swift                     POSIX Unix-socket listener, 0600, 64 KB, per-line, main-queue callback
UsageTracker/UsageTrackerApp.swift           AppDelegate: symlink refresh + server start + log-only consumer
project.yml                                  OmeletteHook target + embed dependency
UsageTrackerTests/
  AgentFixtures.swift                        exact hook/notify JSON shapes + POSIX test client
  AgentPathsTests.swift
  AgentModelsTests.swift
  AgentToolSummaryTests.swift
  AgentEventDecoderTests.swift
  AgentEventServerTests.swift
  OmeletteHookEndToEndTests.swift            spawns the built helper against a temp socket
```

Task order: 1 → 2 → 3 → 4 → 5 → 6 → 7. Tasks 1–4 are pure and fast; 5 needs 4; 6 needs 5 (its tests use the server); 7 needs 1, 5, 6.

---

### Task 1: `AgentPaths` — locations, constants, symlink refresh

**Files:**
- Create: `UsageTracker/Agents/AgentPaths.swift`
- Test: `UsageTrackerTests/AgentPathsTests.swift`

**Interfaces:**
- Consumes: nothing new. Mirrors how `HistoryStore.swift:107` and `ModelsDevPricing.swift:27` resolve `~/Library/Application Support/UsageTracker`.
- Produces (contract + additions):
  ```swift
  enum AgentPaths {
      static var appSupportURL: URL            // addition: ~/Library/Application Support/UsageTracker
      static var socketURL: URL                // …/agent.sock
      static var helperSymlinkURL: URL         // …/bin/omelette-hook
      static var bundledHelperURL: URL         // Bundle.main/Contents/Helpers/omelette-hook
      static var historyURL: URL               // …/agent-sessions.jsonl
      static var claudeSettingsURL: URL        // ~/.claude/settings.json
      static var claudeProjectsURL: URL        // ~/.claude/projects
      static var codexConfigURL: URL           // ~/.codex/config.toml
      static var codexSessionsURL: URL         // ~/.codex/sessions
      static let helperVersion = 1
      static let wireVersion = 1
      static let helperName = "omelette-hook"                 // addition
      static let socketEnvironmentKey = "OMELETTE_AGENT_SOCKET" // addition: helper override, used by tests
      static let maxSocketPathBytes = 103                     // addition: sizeof(sockaddr_un.sun_path) - NUL
      @discardableResult
      static func refreshHelperSymlink(link: URL = helperSymlinkURL, target: URL = bundledHelperURL) throws -> Bool // addition; true when (re)created
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
// UsageTrackerTests/AgentPathsTests.swift
import XCTest
@testable import Omelette

final class AgentPathsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentPathsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeTarget(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        return url
    }

    func testConstantsMatchTheContract() {
        XCTAssertEqual(AgentPaths.helperVersion, 1)
        XCTAssertEqual(AgentPaths.wireVersion, 1)
        XCTAssertEqual(AgentPaths.helperName, "omelette-hook")
        XCTAssertEqual(AgentPaths.socketURL.lastPathComponent, "agent.sock")
        XCTAssertEqual(AgentPaths.socketURL.deletingLastPathComponent().lastPathComponent, "UsageTracker")
        XCTAssertEqual(AgentPaths.helperSymlinkURL.pathComponents.suffix(3), ["UsageTracker", "bin", "omelette-hook"])
        XCTAssertEqual(AgentPaths.bundledHelperURL.pathComponents.suffix(3), ["Contents", "Helpers", "omelette-hook"])
        XCTAssertEqual(AgentPaths.historyURL.lastPathComponent, "agent-sessions.jsonl")
        XCTAssertEqual(AgentPaths.claudeSettingsURL.pathComponents.suffix(2), [".claude", "settings.json"])
        XCTAssertEqual(AgentPaths.claudeProjectsURL.pathComponents.suffix(2), [".claude", "projects"])
        XCTAssertEqual(AgentPaths.codexConfigURL.pathComponents.suffix(2), [".codex", "config.toml"])
        XCTAssertEqual(AgentPaths.codexSessionsURL.pathComponents.suffix(2), [".codex", "sessions"])
    }

    func testSocketPathFitsInSockaddrUn() {
        // sun_path is 104 bytes including the NUL; a longer path cannot be bound at all.
        XCTAssertLessThanOrEqual(AgentPaths.socketURL.path.utf8.count, AgentPaths.maxSocketPathBytes,
                                 "home directory too long for a Unix socket at \(AgentPaths.socketURL.path)")
    }

    func testRefreshCreatesTheLinkAndItsDirectory() throws {
        let target = try makeTarget("omelette-hook")
        let link = root.appendingPathComponent("bin/omelette-hook")

        let changed = try AgentPaths.refreshHelperSymlink(link: link, target: target)

        XCTAssertTrue(changed)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
    }

    func testRefreshIsIdempotent() throws {
        let target = try makeTarget("omelette-hook")
        let link = root.appendingPathComponent("bin/omelette-hook")
        _ = try AgentPaths.refreshHelperSymlink(link: link, target: target)

        let changed = try AgentPaths.refreshHelperSymlink(link: link, target: target)

        XCTAssertFalse(changed)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
    }

    func testRefreshRepointsALinkToAnOldCopy() throws {
        let old = try makeTarget("old-hook")
        let new = try makeTarget("new-hook")
        let link = root.appendingPathComponent("bin/omelette-hook")
        _ = try AgentPaths.refreshHelperSymlink(link: link, target: old)

        let changed = try AgentPaths.refreshHelperSymlink(link: link, target: new)

        XCTAssertTrue(changed)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), new.path)
    }

    func testRefreshReplacesADanglingLinkAndARegularFile() throws {
        let target = try makeTarget("omelette-hook")
        let link = root.appendingPathComponent("bin/omelette-hook")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Dangling: the app the link pointed at was deleted.
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: root.appendingPathComponent("gone").path)
        XCTAssertTrue(try AgentPaths.refreshHelperSymlink(link: link, target: target))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)

        // Regular file where the link should be (someone copied the binary by hand).
        try FileManager.default.removeItem(at: link)
        try Data("stale".utf8).write(to: link)
        XCTAssertTrue(try AgentPaths.refreshHelperSymlink(link: link, target: target))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/AgentPathsTests`
Expected: compile error "cannot find 'AgentPaths' in scope".

- [ ] **Step 3: Create `AgentPaths`**

```swift
// UsageTracker/Agents/AgentPaths.swift
import Foundation

/// Every on-disk location the agent overview touches, so the helper, the socket
/// server, the hook installer and the passive scanner can never drift apart.
enum AgentPaths {
    /// ~/Library/Application Support/UsageTracker — the directory `HistoryStore` and
    /// `ModelsDevPricing` already use.
    static var appSupportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("UsageTracker", isDirectory: true)
    }

    /// ~/Library/Application Support/UsageTracker/agent.sock
    static var socketURL: URL { appSupportURL.appendingPathComponent("agent.sock") }

    /// ~/Library/Application Support/UsageTracker/bin/omelette-hook (symlink → bundle helper).
    /// Hook configs reference this path, so moving or updating the app breaks nothing.
    static var helperSymlinkURL: URL {
        appSupportURL.appendingPathComponent("bin", isDirectory: true).appendingPathComponent(helperName)
    }

    /// Omelette.app/Contents/Helpers/omelette-hook
    static var bundledHelperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(helperName)")
    }

    /// ~/Library/Application Support/UsageTracker/agent-sessions.jsonl
    static var historyURL: URL { appSupportURL.appendingPathComponent("agent-sessions.jsonl") }

    static var claudeSettingsURL: URL { home.appendingPathComponent(".claude/settings.json") }
    static var claudeProjectsURL: URL { home.appendingPathComponent(".claude/projects", isDirectory: true) }
    static var codexConfigURL: URL { home.appendingPathComponent(".codex/config.toml") }
    static var codexSessionsURL: URL { home.appendingPathComponent(".codex/sessions", isDirectory: true) }

    static let helperVersion = 1
    static let wireVersion = 1
    static let helperName = "omelette-hook"
    /// Set in the helper's environment to redirect it to another socket (tests use a temp path).
    static let socketEnvironmentKey = "OMELETTE_AGENT_SOCKET"
    /// `sockaddr_un.sun_path` holds 104 bytes including the terminating NUL.
    static let maxSocketPathBytes = 103

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Points `link` at `target`, creating `bin/` as needed. Idempotent: a link that
    /// already resolves to `target` is left untouched (returns false). A regular file,
    /// a dangling link or a link to an older copy of the app is replaced (returns true).
    @discardableResult
    static func refreshHelperSymlink(link: URL = helperSymlinkURL, target: URL = bundledHelperURL) throws -> Bool {
        let fm = FileManager.default
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let current = try? fm.destinationOfSymbolicLink(atPath: link.path), current == target.path {
            return false
        }
        // `fileExists` follows symlinks (false for a dangling one); `attributesOfItem`
        // uses lstat, so together they see every kind of leftover.
        if fm.fileExists(atPath: link.path) || (try? fm.attributesOfItem(atPath: link.path)) != nil {
            try fm.removeItem(at: link)
        }
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        return true
    }
}
```

- [ ] **Step 4: Regenerate the project, run the tests**

Run: `xcodegen generate && xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/AgentPathsTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add UsageTracker/Agents/AgentPaths.swift UsageTrackerTests/AgentPathsTests.swift
git commit -m "Agents: AgentPaths with helper symlink refresh

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

### Task 2: `AgentModels` — source, state, host info, event, session

**Files:**
- Create: `UsageTracker/Agents/AgentModels.swift`
- Test: `UsageTrackerTests/AgentModelsTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces (contract, plus the additions marked):
  ```swift
  enum AgentSource: String, Codable, Sendable { case claude, codex }
  enum AgentState: String, Codable, Sendable, CaseIterable { case needsYou, working, done, idle; var rank: Int }
  struct AgentHostInfo: Codable, Equatable, Sendable {
      var pid: Int32?; var bundleID: String?; var tty: String?
      static let none: AgentHostInfo                                   // addition
      // Codable keys: "pid", "bundle_id", "tty" (wire spelling)         // addition
  }
  struct AgentEvent: Equatable, Sendable { enum Kind …; let source, kind, sessionID, cwd, toolName, toolSummary, isSubagent, host, receivedAt }
  struct AgentSession: Identifiable, Equatable, Sendable {
      let id: String; let sessionID: String; let source: AgentSource; var projectName: String; var cwd: String?
      var state: AgentState; var activity: String?; var stateSince: Date; var lastEventAt: Date; var startedAt: Date
      var host: AgentHostInfo; var isApproximate: Bool; var turns: Int; var needsYouCount: Int
      static func makeID(source: AgentSource, sessionID: String) -> String   // addition: "\(source.rawValue):\(sessionID)"
      init(sessionID:source:projectName:cwd:state:activity:stateSince:lastEventAt:startedAt:host:isApproximate:turns:needsYouCount:) // addition: composes `id`
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
// UsageTrackerTests/AgentModelsTests.swift
import XCTest
@testable import Omelette

final class AgentModelsTests: XCTestCase {
    func testSessionIDIsSourceColonSessionID() {
        let now = Date(timeIntervalSince1970: 1_756_800_000)
        let session = AgentSession(
            sessionID: "9f1c2b3a-0000-4000-8000-abcdefabcdef", source: .claude,
            projectName: "Usage tracker", cwd: "/Users/me/Desktop/Usage tracker", state: .idle,
            stateSince: now, lastEventAt: now, startedAt: now
        )
        XCTAssertEqual(session.id, "claude:9f1c2b3a-0000-4000-8000-abcdefabcdef")
        XCTAssertEqual(AgentSession.makeID(source: .codex, sessionID: "thr-9"), "codex:thr-9")
        XCTAssertEqual(session.host, .none)
        XCTAssertFalse(session.isApproximate)
        XCTAssertEqual(session.turns, 0)
        XCTAssertEqual(session.needsYouCount, 0)
    }

    func testStateRankOrdersNeedsYouFirstIdleLast() {
        XCTAssertEqual(AgentState.allCases.sorted { $0.rank < $1.rank }, [.needsYou, .working, .done, .idle])
        XCTAssertEqual(Set(AgentState.allCases.map(\.rank)).count, 4, "ranks must be distinct")
    }

    func testSourceAndStateRawValuesAreStable() {
        // These strings end up in agent-sessions.jsonl (package 2) — renaming a case is a data migration.
        XCTAssertEqual(AgentSource.claude.rawValue, "claude")
        XCTAssertEqual(AgentSource.codex.rawValue, "codex")
        XCTAssertEqual(AgentState.needsYou.rawValue, "needsYou")
    }

    func testHostInfoUsesWireKeys() throws {
        let json = Data(#"{"pid":4242,"bundle_id":"com.googlecode.iterm2","tty":"/dev/ttys004"}"#.utf8)
        let host = try JSONDecoder().decode(AgentHostInfo.self, from: json)
        XCTAssertEqual(host, AgentHostInfo(pid: 4242, bundleID: "com.googlecode.iterm2", tty: "/dev/ttys004"))

        let nulls = Data(#"{"pid":null,"bundle_id":null,"tty":null}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(AgentHostInfo.self, from: nulls), .none)

        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(host)) as? [String: Any]
        XCTAssertEqual(encoded?["bundle_id"] as? String, "com.googlecode.iterm2")
        XCTAssertNil(encoded?["bundleID"])
    }

    func testEventKindEquality() {
        XCTAssertEqual(AgentEvent.Kind.unknown("SubagentStop"), .unknown("SubagentStop"))
        XCTAssertNotEqual(AgentEvent.Kind.unknown("A"), .unknown("B"))
        XCTAssertNotEqual(AgentEvent.Kind.toolStarted, .toolFinished)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/AgentModelsTests`
Expected: compile error "cannot find 'AgentSession' in scope".

- [ ] **Step 3: Create the models**

```swift
// UsageTracker/Agents/AgentModels.swift
import Foundation

enum AgentSource: String, Codable, Sendable {
    case claude, codex
}

enum AgentState: String, Codable, Sendable, CaseIterable {
    case needsYou, working, done, idle

    /// Sort/grouping order: needsYou < working < done < idle
    var rank: Int {
        switch self {
        case .needsYou: return 0
        case .working: return 1
        case .done: return 2
        case .idle: return 3
        }
    }
}

/// The terminal / IDE process a session runs under, as reported by the helper.
struct AgentHostInfo: Codable, Equatable, Sendable {
    var pid: Int32?
    var bundleID: String?
    var tty: String?

    static let none = AgentHostInfo(pid: nil, bundleID: nil, tty: nil)

    /// Wire spelling (`host` object of the helper envelope).
    enum CodingKeys: String, CodingKey {
        case pid
        case bundleID = "bundle_id"
        case tty
    }
}

/// What the app reacts to. Decoded from the wire message; `kind` is derived from
/// `payload.hook_event_name` (+ `notification_type`) for Claude and from `payload.type`
/// for Codex.
struct AgentEvent: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case sessionStart, promptSubmitted, toolStarted, toolFinished
        case permissionRequested, notificationPermission, notificationIdle
        case stop, sessionEnd
        case codexTurnComplete
        case unknown(String)
    }

    let source: AgentSource
    let kind: Kind
    let sessionID: String            // Claude session_id / Codex thread-id
    let cwd: String?
    let toolName: String?
    let toolSummary: String?         // AgentToolSummary.make(toolName:toolInput:)
    let isSubagent: Bool             // payload has agent_id
    let host: AgentHostInfo
    let receivedAt: Date
}

struct AgentSession: Identifiable, Equatable, Sendable {
    let id: String                   // "\(source.rawValue):\(sessionID)"
    let sessionID: String
    let source: AgentSource
    var projectName: String          // ProjectName(...) of cwd, or last path component (package 2 fills it)
    var cwd: String?
    var state: AgentState
    var activity: String?            // last tool summary
    var stateSince: Date
    var lastEventAt: Date
    var startedAt: Date
    var host: AgentHostInfo
    var isApproximate: Bool          // true for passive-scan sessions
    var turns: Int
    var needsYouCount: Int

    static func makeID(source: AgentSource, sessionID: String) -> String {
        "\(source.rawValue):\(sessionID)"
    }

    init(
        sessionID: String,
        source: AgentSource,
        projectName: String,
        cwd: String?,
        state: AgentState,
        activity: String? = nil,
        stateSince: Date,
        lastEventAt: Date,
        startedAt: Date,
        host: AgentHostInfo = .none,
        isApproximate: Bool = false,
        turns: Int = 0,
        needsYouCount: Int = 0
    ) {
        self.id = Self.makeID(source: source, sessionID: sessionID)
        self.sessionID = sessionID
        self.source = source
        self.projectName = projectName
        self.cwd = cwd
        self.state = state
        self.activity = activity
        self.stateSince = stateSince
        self.lastEventAt = lastEventAt
        self.startedAt = startedAt
        self.host = host
        self.isApproximate = isApproximate
        self.turns = turns
        self.needsYouCount = needsYouCount
    }
}
```

- [ ] **Step 4: Regenerate the project, run the tests**

Run: `xcodegen generate && xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/AgentModelsTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add UsageTracker/Agents/AgentModels.swift UsageTrackerTests/AgentModelsTests.swift
git commit -m "Agents: source, state, host info, event and session models

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

### Task 3: `AgentToolSummary` — "Tool: detail", detail capped at 80 characters

**Files:**
- Create: `UsageTracker/Agents/AgentToolSummary.swift`
- Test: `UsageTrackerTests/AgentToolSummaryTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces (contract):
  ```swift
  enum AgentToolSummary {
      static func make(toolName: String?, toolInput: [String: Any]?) -> String?   // nil when no detail
      static let maxDetailLength = 80   // length of the detail part, including a trailing "…" when cut
  }
  ```
  Detail rules (spec): `command` for Bash; basename of `file_path` for Edit / Write / Read (also MultiEdit, and `notebook_path` for NotebookEdit); `pattern` for Grep / Glob; otherwise nil. Whitespace runs (including newlines) collapse to one space before the cap.

- [ ] **Step 1: Write the failing tests**

```swift
// UsageTrackerTests/AgentToolSummaryTests.swift
import XCTest
@testable import Omelette

final class AgentToolSummaryTests: XCTestCase {
    func testBashUsesTheCommand() {
        XCTAssertEqual(AgentToolSummary.make(toolName: "Bash", toolInput: ["command": "xcodegen generate", "description": "Regenerate"]),
                       "Bash: xcodegen generate")
    }

    func testFileToolsUseTheBasename() {
        let input: [String: Any] = ["file_path": "/Users/me/Desktop/Usage tracker/UsageTracker/UI/PopoverView.swift", "old_string": "a", "new_string": "b"]
        XCTAssertEqual(AgentToolSummary.make(toolName: "Edit", toolInput: input), "Edit: PopoverView.swift")
        XCTAssertEqual(AgentToolSummary.make(toolName: "Write", toolInput: ["file_path": "/tmp/WalletView.swift", "content": "…"]), "Write: WalletView.swift")
        XCTAssertEqual(AgentToolSummary.make(toolName: "Read", toolInput: ["file_path": "/tmp/PopoverView.swift"]), "Read: PopoverView.swift")
        XCTAssertEqual(AgentToolSummary.make(toolName: "MultiEdit", toolInput: ["file_path": "/tmp/A.swift", "edits": []]), "MultiEdit: A.swift")
        XCTAssertEqual(AgentToolSummary.make(toolName: "NotebookEdit", toolInput: ["notebook_path": "/tmp/n.ipynb"]), "NotebookEdit: n.ipynb")
    }

    func testSearchToolsUseThePattern() {
        XCTAssertEqual(AgentToolSummary.make(toolName: "Grep", toolInput: ["pattern": "usageStatusColor", "path": "/tmp"]), "Grep: usageStatusColor")
        XCTAssertEqual(AgentToolSummary.make(toolName: "Glob", toolInput: ["pattern": "**/*.swift"]), "Glob: **/*.swift")
    }

    func testNoDetailMeansNil() {
        XCTAssertNil(AgentToolSummary.make(toolName: "WebFetch", toolInput: ["url": "https://example.com"]))
        XCTAssertNil(AgentToolSummary.make(toolName: "Bash", toolInput: nil))
        XCTAssertNil(AgentToolSummary.make(toolName: "Bash", toolInput: ["command": "   \n"]))
        XCTAssertNil(AgentToolSummary.make(toolName: "Bash", toolInput: ["command": 42]))
        XCTAssertNil(AgentToolSummary.make(toolName: nil, toolInput: ["command": "ls"]))
        XCTAssertNil(AgentToolSummary.make(toolName: "", toolInput: ["command": "ls"]))
    }

    func testWhitespaceCollapsesToOneLine() {
        XCTAssertEqual(AgentToolSummary.make(toolName: "Bash", toolInput: ["command": "  cd /tmp &&\n\n  ls   -la\t"]),
                       "Bash: cd /tmp && ls -la")
    }

    func testDetailIsCutAt80CharactersWithAnEllipsis() throws {
        let command = String(repeating: "x", count: 200)
        let summary = try XCTUnwrap(AgentToolSummary.make(toolName: "Bash", toolInput: ["command": command]))
        let detail = String(summary.dropFirst("Bash: ".count))
        XCTAssertEqual(detail.count, AgentToolSummary.maxDetailLength)
        XCTAssertTrue(detail.hasSuffix("…"))
        XCTAssertEqual(String(detail.dropLast()), String(repeating: "x", count: 79))
    }

    func testExactly80CharactersIsNotCut() throws {
        let command = String(repeating: "y", count: 80)
        XCTAssertEqual(AgentToolSummary.make(toolName: "Bash", toolInput: ["command": command]), "Bash: \(command)")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/AgentToolSummaryTests`
Expected: compile error "cannot find 'AgentToolSummary' in scope".

- [ ] **Step 3: Implement**

```swift
// UsageTracker/Agents/AgentToolSummary.swift
import Foundation

/// One line describing what a tool call is about: "Bash: xcodegen generate",
/// "Edit: WalletView.swift", "Grep: usageStatusColor". Lives in memory only — it is
/// derived from `tool_input`, which is never persisted.
enum AgentToolSummary {
    /// Length of the detail part; a longer detail is cut to 79 characters plus "…".
    static let maxDetailLength = 80

    /// nil when the tool is unknown, the input lacks the relevant key, or the detail is blank.
    static func make(toolName: String?, toolInput: [String: Any]?) -> String? {
        guard let toolName, !toolName.isEmpty, let toolInput else { return nil }
        guard let raw = detail(toolName: toolName, toolInput: toolInput) else { return nil }
        // Multi-line shell commands must not break the single-row UI.
        let collapsed = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return "\(toolName): \(cap(collapsed))"
    }

    private static func detail(toolName: String, toolInput: [String: Any]) -> String? {
        switch toolName {
        case "Bash":
            return toolInput["command"] as? String
        case "Edit", "Write", "Read", "MultiEdit":
            return (toolInput["file_path"] as? String).map { ($0 as NSString).lastPathComponent }
        case "NotebookEdit":
            return (toolInput["notebook_path"] as? String).map { ($0 as NSString).lastPathComponent }
        case "Grep", "Glob":
            return toolInput["pattern"] as? String
        default:
            return nil
        }
    }

    private static func cap(_ detail: String) -> String {
        guard detail.count > maxDetailLength else { return detail }
        return String(detail.prefix(maxDetailLength - 1)) + "…"
    }
}
```

- [ ] **Step 4: Regenerate the project, run the tests**

Run: `xcodegen generate && xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/AgentToolSummaryTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add UsageTracker/Agents/AgentToolSummary.swift UsageTrackerTests/AgentToolSummaryTests.swift
git commit -m "Agents: tool summary with 80-char detail cap

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

### Task 4: `AgentEventDecoder` — wire line → `AgentEvent`, with fixtures for every event

**Files:**
- Create: `UsageTracker/Agents/AgentEventDecoder.swift`
- Create: `UsageTrackerTests/AgentFixtures.swift` (fixture JSON — the POSIX test client is added to this file in Task 5)
- Test: `UsageTrackerTests/AgentEventDecoderTests.swift`

**Interfaces:**
- Consumes: `AgentPaths.wireVersion`, `AgentSource`, `AgentHostInfo`, `AgentEvent`, `AgentToolSummary.make(toolName:toolInput:)`.
- Produces (contract + additions):
  ```swift
  enum AgentEventDecoder {
      static let maxLineBytes = 64 * 1024                       // addition
      static func decode(_ line: Data) throws -> AgentEvent
      enum Error: Swift.Error, Equatable { case notJSON, unsupportedVersion(Int), missingField(String), tooLarge }   // Equatable is an addition
  }
  // Tests:
  enum AgentFixture {
      static func claude(_ event: String, sessionID: String = "sess-1", cwd: String = "/Users/me/Desktop/Usage tracker", extra: String = "") -> String
      static let codexTurnComplete: String
      static func envelope(source: String = "claude", payload: String, v: Int = 1, receivedAt: Double = 1_756_800_000.123, host: String = AgentFixture.hostJSON) -> Data
      static let hostJSON: String
  }
  ```
  Kind mapping: `SessionStart→sessionStart`, `UserPromptSubmit→promptSubmitted`, `PreToolUse→toolStarted`, `PostToolUse→toolFinished`, `PermissionRequest→permissionRequested`, `Notification` + `notification_type` `permission_prompt→notificationPermission` / `idle_prompt→notificationIdle` / other → `unknown("Notification:<type>")`, `Stop→stop`, `SessionEnd→sessionEnd`, any other name → `unknown(name)`; Codex `type == "agent-turn-complete"→codexTurnComplete`, other → `unknown(type)`.

- [ ] **Step 1: Write the fixtures**

The shapes below are the documented hook stdin JSON (common fields `session_id`, `transcript_path`, `cwd`, `permission_mode`, `hook_event_name`; per-event extras) and the Codex `notify` argument (kebab-case).

```swift
// UsageTrackerTests/AgentFixtures.swift
import Foundation
@testable import Omelette

/// The exact JSON the agents hand the helper, and the envelope the helper wraps it in.
enum AgentFixture {
    static let hostJSON = #"{"pid":4242,"bundle_id":"com.googlecode.iterm2","tty":"/dev/ttys004"}"#

    /// One Claude Code hook payload. `extra` is appended verbatim inside the object
    /// (leading comma included by this function).
    static func claude(
        _ event: String,
        sessionID: String = "sess-1",
        cwd: String = "/Users/me/Desktop/Usage tracker",
        extra: String = ""
    ) -> String {
        let tail = extra.isEmpty ? "" : "," + extra
        return #"{"session_id":"\#(sessionID)","transcript_path":"/Users/me/.claude/projects/-Users-me-Desktop-Usage-tracker/\#(sessionID).jsonl","cwd":"\#(cwd)","permission_mode":"default","hook_event_name":"\#(event)"\#(tail)}"#
    }

    static let sessionStart = claude("SessionStart", extra: #""source":"startup""#)
    static let userPromptSubmit = claude("UserPromptSubmit", extra: #""prompt":"fix the ring""#)
    static let preToolUseBash = claude("PreToolUse", extra: #""tool_name":"Bash","tool_input":{"command":"xcodegen generate","description":"Regenerate the project"},"tool_use_id":"toolu_01""#)
    static let postToolUseBash = claude("PostToolUse", extra: #""tool_name":"Bash","tool_input":{"command":"xcodegen generate"},"tool_response":{"stdout":"ok","stderr":"","interrupted":false},"tool_use_id":"toolu_01""#)
    static let permissionRequestEdit = claude("PermissionRequest", extra: #""tool_name":"Edit","tool_input":{"file_path":"/Users/me/Desktop/Usage tracker/UsageTracker/UI/WalletView.swift","old_string":"a","new_string":"b"},"tool_use_id":"toolu_02""#)
    static let notificationPermission = claude("Notification", extra: #""message":"Claude needs your permission to use Bash","notification_type":"permission_prompt""#)
    static let notificationIdle = claude("Notification", extra: #""message":"Claude is waiting for your input","notification_type":"idle_prompt""#)
    static let notificationOther = claude("Notification", extra: #""message":"Auth expired","notification_type":"auth_success""#)
    static let stop = claude("Stop", extra: #""stop_hook_active":false"#)
    static let sessionEnd = claude("SessionEnd", extra: #""reason":"exit""#)
    static let subagentPreToolUse = claude("PreToolUse", extra: #""agent_id":"agent-7","agent_type":"Explore","tool_name":"Grep","tool_input":{"pattern":"AgentEvent"}"#)
    static let unknownEvent = claude("SubagentStop", extra: #""agent_id":"agent-7""#)

    /// Codex `notify` argument: kebab-case keys, only `agent-turn-complete` exists today.
    static let codexTurnComplete = #"{"type":"agent-turn-complete","thread-id":"thr-9","turn-id":"turn-2","cwd":"/Users/me/Desktop/Orion Gate","input-messages":["ship it"],"last-assistant-message":"Done."}"#

    static func envelope(
        source: String = "claude",
        payload: String,
        v: Int = 1,
        receivedAt: Double = 1_756_800_000.123,
        host: String = AgentFixture.hostJSON
    ) -> Data {
        Data(#"{"v":\#(v),"source":"\#(source)","helper_version":1,"received_at":\#(receivedAt),"host":\#(host),"payload":\#(payload)}"#.utf8)
    }
}
```

- [ ] **Step 2: Write the failing tests**

```swift
// UsageTrackerTests/AgentEventDecoderTests.swift
import XCTest
@testable import Omelette

final class AgentEventDecoderTests: XCTestCase {
    private func decode(_ payload: String, source: String = "claude") throws -> AgentEvent {
        try AgentEventDecoder.decode(AgentFixture.envelope(source: source, payload: payload))
    }

    // MARK: Claude events

    func testSessionStart() throws {
        let event = try decode(AgentFixture.sessionStart)
        XCTAssertEqual(event.source, .claude)
        XCTAssertEqual(event.kind, .sessionStart)
        XCTAssertEqual(event.sessionID, "sess-1")
        XCTAssertEqual(event.cwd, "/Users/me/Desktop/Usage tracker")
        XCTAssertNil(event.toolName)
        XCTAssertNil(event.toolSummary)
        XCTAssertFalse(event.isSubagent)
        XCTAssertEqual(event.host, AgentHostInfo(pid: 4242, bundleID: "com.googlecode.iterm2", tty: "/dev/ttys004"))
        XCTAssertEqual(event.receivedAt.timeIntervalSince1970, 1_756_800_000.123, accuracy: 0.001)
    }

    func testUserPromptSubmit() throws {
        XCTAssertEqual(try decode(AgentFixture.userPromptSubmit).kind, .promptSubmitted)
    }

    func testPreToolUseCarriesTheToolSummary() throws {
        let event = try decode(AgentFixture.preToolUseBash)
        XCTAssertEqual(event.kind, .toolStarted)
        XCTAssertEqual(event.toolName, "Bash")
        XCTAssertEqual(event.toolSummary, "Bash: xcodegen generate")
    }

    func testPostToolUse() throws {
        let event = try decode(AgentFixture.postToolUseBash)
        XCTAssertEqual(event.kind, .toolFinished)
        XCTAssertEqual(event.toolName, "Bash")
        XCTAssertEqual(event.toolSummary, "Bash: xcodegen generate")
    }

    func testPermissionRequest() throws {
        let event = try decode(AgentFixture.permissionRequestEdit)
        XCTAssertEqual(event.kind, .permissionRequested)
        XCTAssertEqual(event.toolSummary, "Edit: WalletView.swift")
    }

    func testNotificationVariants() throws {
        XCTAssertEqual(try decode(AgentFixture.notificationPermission).kind, .notificationPermission)
        XCTAssertEqual(try decode(AgentFixture.notificationIdle).kind, .notificationIdle)
        XCTAssertEqual(try decode(AgentFixture.notificationOther).kind, .unknown("Notification:auth_success"))
    }

    func testStopAndSessionEnd() throws {
        XCTAssertEqual(try decode(AgentFixture.stop).kind, .stop)
        XCTAssertEqual(try decode(AgentFixture.sessionEnd).kind, .sessionEnd)
    }

    func testSubagentEventsAreFlagged() throws {
        let event = try decode(AgentFixture.subagentPreToolUse)
        XCTAssertTrue(event.isSubagent)
        XCTAssertEqual(event.kind, .toolStarted)
        XCTAssertEqual(event.toolSummary, "Grep: AgentEvent")
    }

    func testUnknownHookEventKeepsItsName() throws {
        XCTAssertEqual(try decode(AgentFixture.unknownEvent).kind, .unknown("SubagentStop"))
    }

    // MARK: Codex

    func testCodexTurnComplete() throws {
        let event = try decode(AgentFixture.codexTurnComplete, source: "codex")
        XCTAssertEqual(event.source, .codex)
        XCTAssertEqual(event.kind, .codexTurnComplete)
        XCTAssertEqual(event.sessionID, "thr-9")
        XCTAssertEqual(event.cwd, "/Users/me/Desktop/Orion Gate")
        XCTAssertNil(event.toolName)
        XCTAssertFalse(event.isSubagent)
    }

    func testCodexUnknownType() throws {
        let event = try decode(#"{"type":"agent-approval-needed","thread-id":"thr-9"}"#, source: "codex")
        XCTAssertEqual(event.kind, .unknown("agent-approval-needed"))
    }

    // MARK: Envelope validation

    func testNullHostFieldsDecodeAsNil() throws {
        let data = AgentFixture.envelope(payload: AgentFixture.stop, host: #"{"pid":null,"bundle_id":null,"tty":null}"#)
        XCTAssertEqual(try AgentEventDecoder.decode(data).host, .none)
        let missing = Data(#"{"v":1,"source":"claude","helper_version":1,"received_at":1,"payload":\#(AgentFixture.stop)}"#.utf8)
        XCTAssertEqual(try AgentEventDecoder.decode(missing).host, .none)
    }

    func testRejectsNonJSON() {
        XCTAssertThrowsError(try AgentEventDecoder.decode(Data("not json\n".utf8))) { error in
            XCTAssertEqual(error as? AgentEventDecoder.Error, .notJSON)
        }
        XCTAssertThrowsError(try AgentEventDecoder.decode(Data("[1,2,3]".utf8))) { error in
            XCTAssertEqual(error as? AgentEventDecoder.Error, .notJSON)
        }
    }

    func testRejectsOtherWireVersions() {
        XCTAssertThrowsError(try AgentEventDecoder.decode(AgentFixture.envelope(payload: AgentFixture.stop, v: 2))) { error in
            XCTAssertEqual(error as? AgentEventDecoder.Error, .unsupportedVersion(2))
        }
        let noVersion = Data(#"{"source":"claude","payload":\#(AgentFixture.stop)}"#.utf8)
        XCTAssertThrowsError(try AgentEventDecoder.decode(noVersion)) { error in
            XCTAssertEqual(error as? AgentEventDecoder.Error, .missingField("v"))
        }
    }

    func testRejectsMissingFields() {
        func assertMissing(_ data: Data, _ field: String, line: UInt = #line) {
            XCTAssertThrowsError(try AgentEventDecoder.decode(data), line: line) { error in
                XCTAssertEqual(error as? AgentEventDecoder.Error, .missingField(field), line: line)
            }
        }
        assertMissing(Data(#"{"v":1,"payload":{}}"#.utf8), "source")
        assertMissing(AgentFixture.envelope(source: "gemini", payload: AgentFixture.stop), "source")
        assertMissing(Data(#"{"v":1,"source":"claude"}"#.utf8), "payload")
        assertMissing(AgentFixture.envelope(payload: #"{"session_id":"s","cwd":"/x"}"#), "hook_event_name")
        assertMissing(AgentFixture.envelope(payload: #"{"hook_event_name":"Stop","cwd":"/x"}"#), "session_id")
        assertMissing(AgentFixture.envelope(payload: #"{"hook_event_name":"Stop","session_id":""}"#), "session_id")
        assertMissing(AgentFixture.envelope(source: "codex", payload: #"{"thread-id":"t"}"#), "type")
        assertMissing(AgentFixture.envelope(source: "codex", payload: #"{"type":"agent-turn-complete"}"#), "thread-id")
    }

    func testRejectsLinesOver64KB() {
        let padding = String(repeating: "p", count: 64 * 1024)
        let big = AgentFixture.envelope(payload: AgentFixture.claude("Stop", extra: #""pad":"\#(padding)""#))
        XCTAssertGreaterThan(big.count, AgentEventDecoder.maxLineBytes)
        XCTAssertThrowsError(try AgentEventDecoder.decode(big)) { error in
            XCTAssertEqual(error as? AgentEventDecoder.Error, .tooLarge)
        }
        // Exactly at the cap is fine: pad a valid envelope with trailing spaces (JSON allows them).
        var atCap = AgentFixture.envelope(payload: AgentFixture.stop)
        atCap.append(Data(String(repeating: " ", count: AgentEventDecoder.maxLineBytes - atCap.count).utf8))
        XCTAssertEqual(atCap.count, AgentEventDecoder.maxLineBytes)
        XCTAssertNoThrow(try AgentEventDecoder.decode(atCap))
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/AgentEventDecoderTests`
Expected: compile error "cannot find 'AgentEventDecoder' in scope".

- [ ] **Step 4: Implement the decoder**

`JSONSerialization` rather than `JSONDecoder`: the envelope has a fixed shape but `payload` is whatever the agent sent, and the summary needs `tool_input` as `[String: Any]`. Every field is still pulled into a fixed type; nothing dynamic survives past this function.

```swift
// UsageTracker/Agents/AgentEventDecoder.swift
import Foundation

/// Turns one wire line from `omelette-hook` into an `AgentEvent`.
enum AgentEventDecoder {
    /// Spec cap per message. The server enforces it while reading; this is the
    /// second line of defence for callers that hand over a whole buffer.
    static let maxLineBytes = 64 * 1024

    enum Error: Swift.Error, Equatable {
        case notJSON
        case unsupportedVersion(Int)
        case missingField(String)
        case tooLarge
    }

    /// Parses one wire line. Throws `AgentEventDecoder.Error` on malformed input.
    static func decode(_ line: Data) throws -> AgentEvent {
        guard line.count <= maxLineBytes else { throw Error.tooLarge }
        guard let object = try? JSONSerialization.jsonObject(with: line),
              let envelope = object as? [String: Any] else { throw Error.notJSON }
        guard let version = envelope["v"] as? Int else { throw Error.missingField("v") }
        guard version == AgentPaths.wireVersion else { throw Error.unsupportedVersion(version) }
        guard let sourceRaw = envelope["source"] as? String,
              let source = AgentSource(rawValue: sourceRaw) else { throw Error.missingField("source") }
        guard let payload = envelope["payload"] as? [String: Any] else { throw Error.missingField("payload") }

        let receivedAt = (envelope["received_at"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? Date()
        let host = decodeHost(envelope["host"] as? [String: Any])

        switch source {
        case .claude: return try claudeEvent(payload: payload, host: host, receivedAt: receivedAt)
        case .codex: return try codexEvent(payload: payload, host: host, receivedAt: receivedAt)
        }
    }

    private static func decodeHost(_ object: [String: Any]?) -> AgentHostInfo {
        guard let object else { return .none }
        return AgentHostInfo(
            pid: (object["pid"] as? Int).flatMap { Int32(exactly: $0) },
            bundleID: object["bundle_id"] as? String,
            tty: object["tty"] as? String
        )
    }

    private static func claudeEvent(payload: [String: Any], host: AgentHostInfo, receivedAt: Date) throws -> AgentEvent {
        guard let name = payload["hook_event_name"] as? String else { throw Error.missingField("hook_event_name") }
        guard let sessionID = payload["session_id"] as? String, !sessionID.isEmpty else { throw Error.missingField("session_id") }
        let toolName = payload["tool_name"] as? String
        let toolInput = payload["tool_input"] as? [String: Any]

        let kind: AgentEvent.Kind
        switch name {
        case "SessionStart": kind = .sessionStart
        case "UserPromptSubmit": kind = .promptSubmitted
        case "PreToolUse": kind = .toolStarted
        case "PostToolUse": kind = .toolFinished
        case "PermissionRequest": kind = .permissionRequested
        case "Notification":
            switch payload["notification_type"] as? String {
            case "permission_prompt": kind = .notificationPermission
            case "idle_prompt": kind = .notificationIdle
            case let other: kind = .unknown("Notification:\(other ?? "")")
            }
        case "Stop": kind = .stop
        case "SessionEnd": kind = .sessionEnd
        default: kind = .unknown(name)
        }

        let agentID = payload["agent_id"] as? String
        return AgentEvent(
            source: .claude,
            kind: kind,
            sessionID: sessionID,
            cwd: payload["cwd"] as? String,
            toolName: toolName,
            toolSummary: AgentToolSummary.make(toolName: toolName, toolInput: toolInput),
            isSubagent: !(agentID ?? "").isEmpty,
            host: host,
            receivedAt: receivedAt
        )
    }

    private static func codexEvent(payload: [String: Any], host: AgentHostInfo, receivedAt: Date) throws -> AgentEvent {
        guard let type = payload["type"] as? String else { throw Error.missingField("type") }
        guard let threadID = payload["thread-id"] as? String, !threadID.isEmpty else { throw Error.missingField("thread-id") }
        return AgentEvent(
            source: .codex,
            kind: type == "agent-turn-complete" ? .codexTurnComplete : .unknown(type),
            sessionID: threadID,
            cwd: payload["cwd"] as? String,
            toolName: nil,
            toolSummary: nil,
            isSubagent: false,
            host: host,
            receivedAt: receivedAt
        )
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/AgentEventDecoderTests`
Expected: PASS (16 tests).

- [ ] **Step 6: Commit**

```bash
git add UsageTracker/Agents/AgentEventDecoder.swift UsageTrackerTests/AgentFixtures.swift UsageTrackerTests/AgentEventDecoderTests.swift
git commit -m "Agents: wire-line decoder with fixtures for every hook event

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

### Task 5: `AgentEventServer` — POSIX Unix-socket listener

**Files:**
- Create: `UsageTracker/Agents/AgentEventServer.swift`
- Modify: `UsageTrackerTests/AgentFixtures.swift` (append the POSIX test client and a temp-socket helper)
- Test: `UsageTrackerTests/AgentEventServerTests.swift`

**Interfaces:**
- Consumes: `AgentEventDecoder.decode(_:)`, `AgentEvent`, `AgentPaths.maxSocketPathBytes`.
- Produces (contract + additions):
  ```swift
  final class AgentEventServer: @unchecked Sendable {
      init(socketURL: URL, onEvent: @escaping @Sendable (AgentEvent) -> Void)
      func start() throws          // unlinks a stale socket file, binds, chmod 0600, listens
      func stop()                  // cancels the listener, closes the fd, unlinks the file
      private(set) var receivedCount: Int   // diagnostics — mutated and read on the main queue only
      private(set) var droppedCount: Int
      let socketURL: URL                                        // addition
      static let maxMessageBytes = 64 * 1024                    // addition
      static let connectionTimeout: TimeInterval = 1.0          // addition: per connection, read side
      static let reply: Data                                    // addition: {"v":1,"decision":null}\n
      enum Error: Swift.Error, Equatable { case pathTooLong(Int), alreadyStarted, posix(call: String, errno: Int32) } // addition
  }
  // Tests (AgentFixtures.swift):
  enum AgentSocketTestClient {
      @discardableResult static func send(_ line: Data, to path: String, replyTimeout: TimeInterval = 1) -> String?
      @discardableResult static func send(_ line: String, to path: String, replyTimeout: TimeInterval = 1) -> String?
  }
  extension AgentFixture { static func temporarySocketURL() -> URL }
  ```
  Threading: accept + reads run on one private serial queue (messages are handed over in accept order, so two rapid hooks from one session cannot be reordered); `onEvent` and both counters run on the main queue. `stop()` is synchronous and must be called by the owner (not from `deinit`).

- [ ] **Step 1: Add the POSIX test client and temp-socket helper**

Append to `UsageTrackerTests/AgentFixtures.swift`:

```swift
extension AgentFixture {
    /// A short, unique socket path in the per-user temp dir (`sun_path` holds 103 chars).
    static func temporarySocketURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("om-\(UUID().uuidString.prefix(8)).sock")
    }
}

/// A blocking POSIX client mirroring what `omelette-hook` does: connect, write the
/// bytes, optionally wait for one reply line, close. Returns the reply without its
/// newline, or nil when the connection fails, nothing is written, or no reply arrives
/// within `replyTimeout` (pass 0 to not wait).
enum AgentSocketTestClient {
    @discardableResult
    static func send(_ line: Data, to path: String, replyTimeout: TimeInterval = 1) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { buffer in
                _ = path.withCString { strlcpy(buffer, $0, capacity) }
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }

        let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == line.count, replyTimeout > 0 else { return nil }

        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, Int32(replyTimeout * 1000)) > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(fd, &buffer, buffer.count)
        guard count > 0 else { return nil }
        return String(decoding: buffer[0..<count], as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    @discardableResult
    static func send(_ line: String, to path: String, replyTimeout: TimeInterval = 1) -> String? {
        send(Data(line.utf8), to: path, replyTimeout: replyTimeout)
    }
}
```

- [ ] **Step 2: Write the failing tests**

```swift
// UsageTrackerTests/AgentEventServerTests.swift
import XCTest
@testable import Omelette

final class AgentEventServerTests: XCTestCase {
    private var socketURL: URL!
    private var server: AgentEventServer?

    override func setUp() {
        socketURL = AgentFixture.temporarySocketURL()
        XCTAssertLessThanOrEqual(socketURL.path.utf8.count, AgentPaths.maxSocketPathBytes)
    }

    override func tearDown() {
        server?.stop()
        server = nil
        try? FileManager.default.removeItem(at: socketURL)
    }

    /// One wire line: envelope + "\n".
    private func line(_ payload: String, source: String = "claude") -> Data {
        AgentFixture.envelope(source: source, payload: payload) + Data([0x0A])
    }

    private func startServer(onEvent: @escaping @Sendable (AgentEvent) -> Void = { _ in }) throws -> AgentEventServer {
        let server = AgentEventServer(socketURL: socketURL, onEvent: onEvent)
        try server.start()
        self.server = server
        return server
    }

    /// Counters and the callback are delivered on the main queue, which only runs
    /// while the test lets it: spin until `condition` holds or `timeout` passes.
    private func waitOnMain(timeout: TimeInterval = 2, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private func mode(of url: URL) throws -> mode_t {
        var info = stat()
        guard stat(url.path, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return info.st_mode
    }

    func testDeliversDecodedEventsOnTheMainQueueAndReplies() throws {
        final class Box: @unchecked Sendable { var events: [AgentEvent] = []; var onMain = false }
        let box = Box()
        let delivered = expectation(description: "event delivered")
        let server = try startServer { event in
            box.events.append(event)
            box.onMain = Thread.isMainThread
            delivered.fulfill()
        }

        let reply = AgentSocketTestClient.send(line(AgentFixture.preToolUseBash), to: socketURL.path)

        wait(for: [delivered], timeout: 2)
        XCTAssertEqual(reply, #"{"v":1,"decision":null}"#)
        XCTAssertTrue(box.onMain)
        XCTAssertEqual(box.events.map(\.kind), [.toolStarted])
        XCTAssertEqual(box.events.first?.toolSummary, "Bash: xcodegen generate")
        XCTAssertEqual(box.events.first?.host.bundleID, "com.googlecode.iterm2")
        XCTAssertEqual(server.receivedCount, 1)
        XCTAssertEqual(server.droppedCount, 0)
    }

    func testCodexLineIsDecodedToo() throws {
        final class Box: @unchecked Sendable { var kinds: [AgentEvent.Kind] = [] }
        let box = Box()
        let delivered = expectation(description: "codex event")
        _ = try startServer { event in box.kinds.append(event.kind); delivered.fulfill() }

        AgentSocketTestClient.send(line(AgentFixture.codexTurnComplete, source: "codex"), to: socketURL.path)

        wait(for: [delivered], timeout: 2)
        XCTAssertEqual(box.kinds, [.codexTurnComplete])
    }

    func testSocketFileIsASocketOwnedOnlyByTheUser() throws {
        _ = try startServer()
        let mode = try mode(of: socketURL)
        XCTAssertEqual(mode & S_IFMT, S_IFSOCK)
        XCTAssertEqual(mode & 0o777, 0o600)
    }

    func testReplacesAStaleFileAtTheSocketPathAndRefusesADoubleStart() throws {
        try Data("stale".utf8).write(to: socketURL)
        let server = try startServer()
        XCTAssertEqual(try mode(of: socketURL) & S_IFMT, S_IFSOCK)
        XCTAssertThrowsError(try server.start()) { error in
            XCTAssertEqual(error as? AgentEventServer.Error, .alreadyStarted)
        }
    }

    func testMessageWithoutTrailingNewlineIsAcceptedAtEOF() throws {
        let delivered = expectation(description: "event")
        _ = try startServer { _ in delivered.fulfill() }

        let reply = AgentSocketTestClient.send(AgentFixture.envelope(payload: AgentFixture.stop), to: socketURL.path)

        wait(for: [delivered], timeout: 2)
        XCTAssertEqual(reply, #"{"v":1,"decision":null}"#)
    }

    func testDropsMalformedEmptyAndOversizedMessages() throws {
        final class Box: @unchecked Sendable { var count = 0 }
        let box = Box()
        let server = try startServer { _ in box.count += 1 }

        AgentSocketTestClient.send("not json\n", to: socketURL.path, replyTimeout: 0)
        AgentSocketTestClient.send(Data(), to: socketURL.path, replyTimeout: 0)
        let padding = String(repeating: "p", count: 70 * 1024)
        AgentSocketTestClient.send(line(AgentFixture.claude("Stop", extra: #""pad":"\#(padding)""#)), to: socketURL.path, replyTimeout: 0)

        XCTAssertTrue(waitOnMain { server.droppedCount == 3 }, "dropped: \(server.droppedCount)")
        XCTAssertEqual(server.receivedCount, 0)
        XCTAssertEqual(box.count, 0)
        // Still serving after the bad clients.
        let delivered = expectation(description: "good event after bad ones")
        let good = try XCTUnwrap(AgentSocketTestClient.send(line(AgentFixture.stop), to: socketURL.path))
        XCTAssertEqual(good, #"{"v":1,"decision":null}"#)
        _ = waitOnMain { server.receivedCount == 1 }
        delivered.fulfill()
        wait(for: [delivered], timeout: 1)
        XCTAssertEqual(server.receivedCount, 1)
    }

    func testRapidClientsArriveInOrder() throws {
        final class Box: @unchecked Sendable { var ids: [String] = [] }
        let box = Box()
        let server = try startServer { event in box.ids.append(event.sessionID) }
        let expected = (0..<25).map { "s\($0)" }

        let sender = Thread {
            for id in expected {
                AgentSocketTestClient.send(self.line(AgentFixture.claude("UserPromptSubmit", sessionID: id)), to: self.socketURL.path, replyTimeout: 1)
            }
        }
        sender.start()

        XCTAssertTrue(waitOnMain(timeout: 10) { server.receivedCount == expected.count }, "received \(server.receivedCount)")
        XCTAssertEqual(box.ids, expected)
    }

    func testStopRemovesTheSocketFileAndRefusesConnections() throws {
        let server = try startServer()
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
        XCTAssertNil(AgentSocketTestClient.send(line(AgentFixture.stop), to: socketURL.path, replyTimeout: 0.2))
        // stop() twice is harmless.
        server.stop()
    }

    func testOverlongPathIsReportedNotBound() {
        let long = FileManager.default.temporaryDirectory.appendingPathComponent(String(repeating: "x", count: 120) + ".sock")
        let server = AgentEventServer(socketURL: long) { _ in }
        XCTAssertThrowsError(try server.start()) { error in
            XCTAssertEqual(error as? AgentEventServer.Error, .pathTooLong(long.path.utf8.count))
        }
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/AgentEventServerTests`
Expected: compile error "cannot find 'AgentEventServer' in scope".

- [ ] **Step 4: Implement the server**

```swift
// UsageTracker/Agents/AgentEventServer.swift
import Foundation

/// Listens on a Unix domain socket for one-line JSON messages from `omelette-hook`.
///
/// POSIX sockets rather than Network.framework: `NWListener` cannot set the socket
/// file's mode, does not unlink a stale file and leaves the file behind on cancel;
/// here the file is `chmod 0600` before `listen()`, so there is never a moment when
/// another local user could connect. One connection carries one message: read until
/// "\n" / EOF / 64 KB / 1 s, decode, answer with the one-line reply, close.
///
/// Threading: accept and reads run on `queue` (serial — hooks from one session are
/// handed over in accept order); `onEvent` and both counters run on the main queue.
/// The owner calls `stop()`; it is deliberately not called from `deinit`.
final class AgentEventServer: @unchecked Sendable {
    enum Error: Swift.Error, Equatable {
        case pathTooLong(Int)
        case alreadyStarted
        case posix(call: String, errno: Int32)
    }

    /// Spec cap per message. Anything longer is dropped without decoding.
    static let maxMessageBytes = 64 * 1024
    /// Read budget per connection. The helper writes immediately after connecting;
    /// a client that stalls longer than this is counted as dropped.
    static let connectionTimeout: TimeInterval = 1.0
    /// Sent after every message; the helper reads it only for PermissionRequest and
    /// ignores its content in phase 2 (phase 4 will carry a decision here).
    static let reply = Data("{\"v\":1,\"decision\":null}\n".utf8)

    let socketURL: URL
    private let onEvent: @Sendable (AgentEvent) -> Void
    private let queue = DispatchQueue(label: "com.usagetracker.agent-socket")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    /// Diagnostics (Settings → Agents, package 3). Main queue only.
    private(set) var receivedCount = 0
    private(set) var droppedCount = 0

    init(socketURL: URL, onEvent: @escaping @Sendable (AgentEvent) -> Void) {
        self.socketURL = socketURL
        self.onEvent = onEvent
    }

    /// Unlinks a stale socket file, binds, chmod 0600, listens. Synchronous: clients
    /// can connect as soon as this returns.
    func start() throws {
        try queue.sync { try startOnQueue() }
    }

    func stop() {
        queue.sync {
            guard let source = acceptSource else { return }
            source.cancel()           // the cancel handler closes the fd
            acceptSource = nil
            listenFD = -1
            unlink(socketURL.path)
        }
    }

    // MARK: - Listening

    private func startOnQueue() throws {
        guard acceptSource == nil else { throw Error.alreadyStarted }
        let path = socketURL.path
        guard path.utf8.count <= AgentPaths.maxSocketPathBytes else { throw Error.pathTooLong(path.utf8.count) }
        try FileManager.default.createDirectory(at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A crash leaves the file behind, and a second Omelette instance (login copy +
        // dev build) takes the path over: the last launched instance wins.
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Error.posix(call: "socket", errno: errno) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)

        var address = Self.address(for: path)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw Error.posix(call: "bind", errno: code)
        }
        // Before listen(): nobody can connect yet, so the mode is 0600 from the first
        // moment a connection is possible.
        guard chmod(path, 0o600) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw Error.posix(call: "chmod", errno: code)
        }
        guard listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw Error.posix(call: "listen", errno: code)
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(fd) }
        source.resume()
        listenFD = fd
        acceptSource = source
    }

    private static func address(for path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { buffer in
                _ = path.withCString { strlcpy(buffer, $0, capacity) }
            }
        }
        return address
    }

    /// Drains every queued connection (the listening fd is non-blocking).
    private func acceptPending() {
        while listenFD >= 0 {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { return }   // EAGAIN: nothing more queued
            var one: Int32 = 1
            // A helper that closes right after writing must not SIGPIPE the app when we reply.
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            serve(client)
            close(client)
        }
    }

    // MARK: - One connection

    private func serve(_ fd: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(Self.connectionTimeout)
        var newline: Data.Index?
        while newline == nil {
            guard Self.wait(fd, for: POLLIN, until: deadline) else { break }
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { break }                    // EOF or error: what arrived is the message
            buffer.append(chunk, count: count)
            if buffer.count > Self.maxMessageBytes {
                drop(reason: "over \(Self.maxMessageBytes / 1024) KB")
                return
            }
            newline = buffer.firstIndex(of: 0x0A)
        }

        let message = newline.map { buffer.subdata(in: buffer.startIndex..<$0) } ?? buffer
        guard !message.isEmpty else {
            drop(reason: "empty")
            return
        }
        do {
            let event = try AgentEventDecoder.decode(message)
            DispatchQueue.main.async { [self] in
                receivedCount += 1
                onEvent(event)
            }
        } catch {
            // Error cases name a field at most — never the payload.
            drop(reason: String(describing: error))
        }
        _ = Self.reply.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    private func drop(reason: String) {
        NSLog("[UT] agent event dropped: %@", reason)
        DispatchQueue.main.async { [self] in droppedCount += 1 }
    }

    /// Blocks the socket queue until `fd` is ready for `events` or `deadline` passes.
    private static func wait(_ fd: Int32, for events: Int32, until deadline: Date) -> Bool {
        let remainingMilliseconds = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
        var descriptor = pollfd(fd: fd, events: Int16(events), revents: 0)
        return poll(&descriptor, 1, remainingMilliseconds) > 0
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/AgentEventServerTests`
Expected: PASS (9 tests). If `testSocketFileIsASocketOwnedOnlyByTheUser` fails with `EPERM` on `bind`, the test host is being sandboxed — it is not (`UsageTracker.entitlements` has `app-sandbox = false`); do not mark the class skipped, find what changed.

- [ ] **Step 6: Commit**

```bash
git add UsageTracker/Agents/AgentEventServer.swift UsageTrackerTests/AgentFixtures.swift UsageTrackerTests/AgentEventServerTests.swift
git commit -m "Agents: POSIX Unix-socket event server (0600, 64 KB, per-line)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

### Task 6: `omelette-hook` — the helper target, embedded and signed, tested end-to-end

**Files:**
- Modify: `project.yml` (app target `dependencies:` — add the embed; append the `OmeletteHook` target)
- Create: `HookHelper/main.swift`, `HookHelper/HostProcess.swift`, `HookHelper/SocketClient.swift`
- Test: `UsageTrackerTests/OmeletteHookEndToEndTests.swift`

**Interfaces:**
- Consumes: the wire format; `AgentEventServer` + `AgentFixture` (tests); `AgentPaths.bundledHelperURL`, `AgentPaths.socketEnvironmentKey`.
- Produces:
  ```
  Omelette.app/Contents/Helpers/omelette-hook        (signing identifier com.usagetracker.app.hook, hardened runtime from signing.xcconfig)
  ```
  ```swift
  // HookHelper (separate module — the app never imports these; names are for the executor)
  enum HookMain { static func run() -> Never; static func readPayload(_ arguments: [String]) -> (source: String, payload: [String: Any])?;
                  static func encodeLine(_ object: [String: Any]) -> Data?; static func shrinkingToolInput(_ payload: [String: Any]) -> [String: Any]; static func socketPath() -> String }
  struct HostProcess { var pid: Int32?; var bundleID: String?; var tty: String?; static func describe(from pid: pid_t = getpid()) -> HostProcess; static let knownBundleIDs: Set<String> }
  struct ProcessRecord { let parentPID: pid_t; let tty: String?; let bundleID: String?; static func read(_ pid: pid_t) -> ProcessRecord? }
  enum SocketClient { static func send(_ line: Data, to path: String, connectTimeout: TimeInterval, replyTimeout: TimeInterval) }
  ```
  Environment: `OMELETTE_AGENT_SOCKET=<path>` overrides the socket path (tests); `--codex '<json>'` selects the Codex source; otherwise stdin is a Claude payload.

- [ ] **Step 1: Write the failing end-to-end tests**

```swift
// UsageTrackerTests/OmeletteHookEndToEndTests.swift
import XCTest
@testable import Omelette

/// Spawns the built `omelette-hook`. The test host is `$(BUILT_PRODUCTS_DIR)/Omelette.app`,
/// so `AgentPaths.bundledHelperURL` (`Bundle.main/Contents/Helpers/omelette-hook`) is the
/// binary the Embed Dependencies phase just copied and signed — no environment lookup needed.
final class OmeletteHookEndToEndTests: XCTestCase {
    private final class Box: @unchecked Sendable { var events: [AgentEvent] = [] }

    private var socketURL: URL!
    private var server: AgentEventServer?
    private let box = Box()

    override func setUp() {
        socketURL = AgentFixture.temporarySocketURL()
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: AgentPaths.bundledHelperURL.path),
            "omelette-hook missing at \(AgentPaths.bundledHelperURL.path) — check the OmeletteHook target and the embed dependency in project.yml"
        )
    }

    override func tearDown() {
        server?.stop()
        server = nil
        try? FileManager.default.removeItem(at: socketURL)
    }

    private func startServer() throws {
        let box = self.box
        let server = AgentEventServer(socketURL: socketURL) { box.events.append($0) }
        try server.start()
        self.server = server
    }

    private struct Run {
        let status: Int32
        let stdout: Data
        let elapsed: TimeInterval
    }

    /// Runs the helper against the temp socket with `input` on stdin (or only `arguments`).
    private func runHelper(stdin input: String? = nil, arguments: [String] = []) throws -> Run {
        let process = Process()
        process.executableURL = AgentPaths.bundledHelperURL
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment
            .merging([AgentPaths.socketEnvironmentKey: socketURL.path]) { $1 }
        let stdout = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = stdin
        let started = Date()
        try process.run()
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        try stdin.fileHandleForWriting.close()
        // Read before waiting: waiting on a process whose pipe is full deadlocks.
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus, stdout: output, elapsed: Date().timeIntervalSince(started))
    }

    /// Events arrive on the main queue, which only runs while the test lets it.
    private func waitForEvents(_ count: Int, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while box.events.count < count && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return box.events.count >= count
    }

    func testClaudeStdinPayloadReachesTheServer() throws {
        try startServer()

        let run = try runHelper(stdin: AgentFixture.preToolUseBash)

        XCTAssertEqual(run.status, 0)
        XCTAssertTrue(run.stdout.isEmpty, "the helper must never write to stdout")
        XCTAssertTrue(waitForEvents(1))
        let event = try XCTUnwrap(box.events.first)
        XCTAssertEqual(event.source, .claude)
        XCTAssertEqual(event.kind, .toolStarted)
        XCTAssertEqual(event.sessionID, "sess-1")
        XCTAssertEqual(event.cwd, "/Users/me/Desktop/Usage tracker")
        XCTAssertEqual(event.toolSummary, "Bash: xcodegen generate")
        XCTAssertFalse(event.isSubagent)
        XCTAssertLessThan(abs(event.receivedAt.timeIntervalSinceNow), 5, "received_at must be the helper's wall clock")
        XCTAssertEqual(server?.receivedCount, 1)
        XCTAssertEqual(server?.droppedCount, 0)
    }

    func testCodexArgvPayloadReachesTheServer() throws {
        try startServer()

        let run = try runHelper(arguments: ["--codex", AgentFixture.codexTurnComplete])

        XCTAssertEqual(run.status, 0)
        XCTAssertTrue(run.stdout.isEmpty)
        XCTAssertTrue(waitForEvents(1))
        XCTAssertEqual(box.events.first?.source, .codex)
        XCTAssertEqual(box.events.first?.kind, .codexTurnComplete)
        XCTAssertEqual(box.events.first?.sessionID, "thr-9")
        XCTAssertEqual(box.events.first?.cwd, "/Users/me/Desktop/Orion Gate")
    }

    func testEveryClaudeEventRoundTripsInOrder() throws {
        try startServer()
        let cases: [(payload: String, kind: AgentEvent.Kind)] = [
            (AgentFixture.sessionStart, .sessionStart),
            (AgentFixture.userPromptSubmit, .promptSubmitted),
            (AgentFixture.preToolUseBash, .toolStarted),
            (AgentFixture.postToolUseBash, .toolFinished),
            (AgentFixture.permissionRequestEdit, .permissionRequested),
            (AgentFixture.notificationPermission, .notificationPermission),
            (AgentFixture.notificationIdle, .notificationIdle),
            (AgentFixture.stop, .stop),
            (AgentFixture.sessionEnd, .sessionEnd),
            (AgentFixture.subagentPreToolUse, .toolStarted),
        ]

        for entry in cases {
            XCTAssertEqual(try runHelper(stdin: entry.payload).status, 0)
        }

        XCTAssertTrue(waitForEvents(cases.count))
        XCTAssertEqual(box.events.map(\.kind), cases.map(\.kind))
        XCTAssertEqual(box.events.last?.isSubagent, true)
    }

    func testPermissionRequestWaitsForTheReplyAndStaysWithinBudget() throws {
        try startServer()

        let run = try runHelper(stdin: AgentFixture.permissionRequestEdit)

        XCTAssertEqual(run.status, 0)
        XCTAssertLessThan(run.elapsed, 0.8)
        XCTAssertTrue(waitForEvents(1))
        XCTAssertEqual(box.events.first?.kind, .permissionRequested)
        XCTAssertEqual(box.events.first?.toolSummary, "Edit: WalletView.swift")
    }

    func testNoServerMeansExitZeroImmediately() throws {
        // Nothing listens at socketURL — the normal case when Omelette is not running.
        let run = try runHelper(stdin: AgentFixture.stop)

        XCTAssertEqual(run.status, 0)
        XCTAssertTrue(run.stdout.isEmpty)
        XCTAssertLessThan(run.elapsed, 0.5)
    }

    func testGarbageAndEmptyInputExitZeroWithoutEvents() throws {
        try startServer()

        XCTAssertEqual(try runHelper(stdin: "not json").status, 0)
        XCTAssertEqual(try runHelper(stdin: "").status, 0)
        XCTAssertEqual(try runHelper(stdin: "[1,2,3]").status, 0)
        XCTAssertEqual(try runHelper(arguments: ["--codex"]).status, 0)
        XCTAssertEqual(try runHelper(arguments: ["--codex", "{bad"]).status, 0)

        XCTAssertFalse(waitForEvents(1, timeout: 0.3))
        XCTAssertEqual(server?.receivedCount, 0)
        XCTAssertEqual(server?.droppedCount, 0, "the helper sends nothing it could not parse")
    }

    func testOversizedToolInputIsShrunkNotLost() throws {
        try startServer()
        let content = String(repeating: "z", count: 100 * 1024)
        let payload = AgentFixture.claude(
            "PreToolUse",
            extra: #""tool_name":"Write","tool_input":{"file_path":"/tmp/big.txt","content":"\#(content)"}"#
        )

        XCTAssertEqual(try runHelper(stdin: payload).status, 0)

        XCTAssertTrue(waitForEvents(1))
        XCTAssertEqual(box.events.first?.kind, .toolStarted)
        XCTAssertEqual(box.events.first?.toolSummary, "Write: big.txt")
        XCTAssertEqual(server?.droppedCount, 0)
    }

    func testHostInfoIsWellFormed() throws {
        // Under xcodebuild no known terminal sits above the test host, so the fields may be nil;
        // when present, a pid is a live process with a bundle id and a tty is a /dev path.
        try startServer()

        XCTAssertEqual(try runHelper(stdin: AgentFixture.stop).status, 0)

        XCTAssertTrue(waitForEvents(1))
        let host = try XCTUnwrap(box.events.first?.host)
        if let pid = host.pid {
            XCTAssertEqual(kill(pid, 0), 0, "host pid \(pid) is not alive")
            XCTAssertNotNil(host.bundleID)
        }
        if let tty = host.tty { XCTAssertTrue(tty.hasPrefix("/dev/tty"), tty) }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/OmeletteHookEndToEndTests`
Expected: every test fails in `setUp` with "omelette-hook missing at …/Omelette.app/Contents/Helpers/omelette-hook".

- [ ] **Step 3: Add the target and the embed to `project.yml`**

Re-read `project.yml` first (other sessions may have touched it). Two targeted edits.

(a) In the `UsageTracker` target, replace the first two dependency lines

```yaml
    dependencies:
      - target: UsageTrackerWidget
      - package: Sparkle
```

with

```yaml
    dependencies:
      - target: UsageTrackerWidget
      # omelette-hook rides inside the app at Contents/Helpers/. `wrapper` +
      # subpath is the only spelling that lands there (`executables` means
      # Contents/MacOS). codeSign → CodeSignOnCopy, so the Debug copy carries the
      # app's identity + hardened runtime; the Developer ID export re-signs it.
      # link: false — an executable must never reach "Link Binary With Libraries".
      - target: OmeletteHook
        embed: true
        link: false
        codeSign: true
        copy:
          destination: wrapper
          subpath: Contents/Helpers
      - package: Sparkle
```

(b) Append after the `UsageTrackerWidget` target (end of file):

```yaml

  # Hook helper: a Foundation-only command-line tool Claude Code / Codex spawn on
  # every hook event. Embedded into the app (see the app target's dependency).
  OmeletteHook:
    type: tool
    platform: macOS
    deploymentTarget: "14.0"
    sources:
      - path: HookHelper
    settings:
      base:
        PRODUCT_NAME: omelette-hook
        # signing.xcconfig hands every target the app's bundle id; a nested
        # executable needs its own code-signing identifier.
        PRODUCT_BUNDLE_IDENTIFIER: com.usagetracker.app.hook
        # Without this the tool is also installed to Products/usr/local/bin in
        # the archive, which turns it into a "Generic Xcode Archive" that
        # `xcodebuild -exportArchive` (scripts/build_dmg.sh) refuses to export.
        SKIP_INSTALL: YES
        SWIFT_EMIT_LOC_STRINGS: NO
        DEAD_CODE_STRIPPING: YES
```

Hardened runtime, `--timestamp --options=runtime`, team and identity are not repeated here: they come from `signing.xcconfig` through the project-level `configFiles`, exactly like the widget.

- [ ] **Step 4: Write `HookHelper/main.swift`**

```swift
// HookHelper/main.swift
import Foundation

// omelette-hook — forwards one Claude Code hook payload (stdin) or one Codex notify
// payload (`--codex '<json>'`) to Omelette over its Unix socket.
//
// Contract with the agents that spawn us: exit 0 no matter what, never block past
// 800 ms, never write to stdout (Claude Code parses a hook's stdout), never persist
// or log a payload. Foundation only — no AppKit.

enum HookMain {
    static let helperVersion = 1
    static let wireVersion = 1
    static let maxLineBytes = 64 * 1024
    static let connectTimeout: TimeInterval = 0.3
    static let replyTimeout: TimeInterval = 0.5
    static let totalBudgetMilliseconds = 800
    static let socketEnvironmentKey = "OMELETTE_AGENT_SOCKET"

    static func run() -> Never {
        // Watchdog first: whatever blocks below, the agent gets its process back on time.
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(totalBudgetMilliseconds)) {
            exit(0)
        }
        let receivedAt = Date().timeIntervalSince1970

        guard let input = readPayload(CommandLine.arguments) else { exit(0) }
        let host = HostProcess.describe()
        var envelope: [String: Any] = [
            "v": wireVersion,
            "source": input.source,
            "helper_version": helperVersion,
            "received_at": receivedAt,
            "host": [
                "pid": host.pid.map { Int($0) } ?? NSNull(),
                "bundle_id": host.bundleID ?? NSNull(),
                "tty": host.tty ?? NSNull(),
            ] as [String: Any],
            "payload": input.payload,
        ]

        guard var line = encodeLine(envelope) else { exit(0) }
        if line.count > maxLineBytes {
            envelope["payload"] = shrinkingToolInput(input.payload)
            guard let smaller = encodeLine(envelope), smaller.count <= maxLineBytes else { exit(0) }
            line = smaller
        }

        // Only PermissionRequest waits for an answer (phase 4 will carry a decision);
        // everything else is fire-and-forget.
        let wantsReply = input.source == "claude"
            && (input.payload["hook_event_name"] as? String) == "PermissionRequest"
        SocketClient.send(
            line,
            to: socketPath(),
            connectTimeout: connectTimeout,
            replyTimeout: wantsReply ? replyTimeout : 0
        )
        exit(0)
    }

    /// `--codex '<json>'` (Codex `notify`) or the Claude hook JSON on stdin. nil unless
    /// the payload is a JSON object — nothing else is worth a connection.
    static func readPayload(_ arguments: [String]) -> (source: String, payload: [String: Any])? {
        if arguments.count >= 2, arguments[1] == "--codex" {
            guard arguments.count >= 3, let object = parseObject(Data(arguments[2].utf8)) else { return nil }
            return ("codex", object)
        }
        guard let object = parseObject(FileHandle.standardInput.readDataToEndOfFile()) else { return nil }
        return ("claude", object)
    }

    static func parseObject(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty, let any = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return any as? [String: Any]
    }

    /// Compact JSON + "\n". JSONSerialization escapes newlines inside strings, so one
    /// message is always exactly one line.
    static func encodeLine(_ object: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        else { return nil }
        data.append(0x0A)
        return data
    }

    /// A Write's `tool_input` carries the whole file. Keep only the keys the app
    /// summarises (capped) so the event still counts as `working` with an activity.
    static func shrinkingToolInput(_ payload: [String: Any]) -> [String: Any] {
        var shrunk = payload
        var kept: [String: Any] = ["_omelette_truncated": true]
        if let input = payload["tool_input"] as? [String: Any] {
            for key in ["command", "file_path", "notebook_path", "pattern"] {
                if let value = input[key] as? String { kept[key] = String(value.prefix(1024)) }
            }
        }
        shrunk["tool_input"] = kept
        return shrunk
    }

    static func socketPath() -> String {
        if let override = ProcessInfo.processInfo.environment[socketEnvironmentKey], !override.isEmpty {
            return override
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/UsageTracker/agent.sock").path
    }
}

HookMain.run()
```

- [ ] **Step 5: Write `HookHelper/HostProcess.swift`**

```swift
// HookHelper/HostProcess.swift
import Foundation

/// The terminal / IDE this hook ultimately runs under, found by walking the parent
/// chain: `omelette-hook ← sh ← claude ← zsh ← login ← iTermServer ← iTerm2`.
struct HostProcess {
    var pid: Int32?
    var bundleID: String?
    var tty: String?

    /// Terminals and IDEs the app knows how to bring to the front (package 4).
    static let knownBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "com.github.wez.wezterm",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",   // Cursor
        "com.exafunction.windsurf",
    ]
    static let maxHops = 32

    /// Walks from `pid` up to launchd. `tty` is the first controlling terminal seen
    /// (ours when the agent passed it on, otherwise the agent's own). The host is the
    /// innermost known terminal/IDE, reported with the pid of the outermost process of
    /// the same app (VS Code's Electron main process, not its plugin helper). Without a
    /// known host the outermost `.app` ancestor is reported, so a click can still
    /// activate something.
    static func describe(from pid: pid_t = getpid()) -> HostProcess {
        var result = HostProcess()
        var known: (pid: pid_t, bundleID: String)?
        var outermostApp: (pid: pid_t, bundleID: String)?
        var current = pid
        var hops = 0
        while current > 1, hops < maxHops, let record = ProcessRecord.read(current) {
            hops += 1
            if result.tty == nil { result.tty = record.tty }
            if let bundleID = record.bundleID {
                if let found = known, found.bundleID == bundleID {
                    known = (current, bundleID)
                } else if known == nil, knownBundleIDs.contains(bundleID) {
                    known = (current, bundleID)
                }
                outermostApp = (current, bundleID)
            }
            current = record.parentPID
        }
        if let host = known ?? outermostApp {
            result.pid = host.pid
            result.bundleID = host.bundleID
        }
        return result
    }
}

/// One process, read through `sysctl`. `proc_pidinfo(PROC_PIDTBSDINFO)` refuses
/// other users' processes and the chain crosses root's `login`; `sysctl` answers
/// for every pid.
struct ProcessRecord {
    let parentPID: pid_t
    let tty: String?
    let bundleID: String?

    static func read(_ pid: pid_t) -> ProcessRecord? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return ProcessRecord(
            parentPID: info.kp_eproc.e_ppid,
            tty: ttyPath(info.kp_eproc.e_tdev),
            bundleID: bundleID(ofExecutable: executablePath(pid))
        )
    }

    /// `e_tdev` is NODEV (-1) for a process without a controlling terminal.
    private static func ttyPath(_ device: dev_t) -> String? {
        guard device != -1, device != 0, let name = devname(device, mode_t(S_IFCHR)) else { return nil }
        return "/dev/" + String(cString: name)
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : nil
    }

    /// `/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/…`
    /// → the outer app (first `.app/`), read from its Info.plist — no AppKit needed.
    private static func bundleID(ofExecutable path: String?) -> String? {
        guard let path, let range = path.range(of: ".app/") else { return nil }
        let appPath = String(path[..<range.lowerBound]) + ".app"
        return Bundle(path: appPath)?.bundleIdentifier
    }
}
```

- [ ] **Step 6: Write `HookHelper/SocketClient.swift`**

```swift
// HookHelper/SocketClient.swift
import Foundation

/// Connect → write one line → optionally wait for one reply line → close. Every
/// failure is silent: Omelette not running is the normal case, not an error.
enum SocketClient {
    static func send(_ line: Data, to path: String, connectTimeout: TimeInterval, replyTimeout: TimeInterval) {
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)   // 104, including the NUL
        guard path.utf8.count < capacity else { return }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)

        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &address.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { buffer in
                _ = path.withCString { strlcpy(buffer, $0, capacity) }
            }
        }

        let deadline = Date().addingTimeInterval(connectTimeout)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 {
            // Unix sockets connect synchronously unless the backlog is full (EINPROGRESS).
            guard errno == EINPROGRESS, wait(fd, for: POLLOUT, until: deadline) else { return }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { return }
        }

        guard writeAll(fd, line, until: deadline) else { return }
        guard replyTimeout > 0, wait(fd, for: POLLIN, until: Date().addingTimeInterval(replyTimeout)) else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        _ = read(fd, &buffer, buffer.count)   // phase 2 ignores the reply; phase 4 reads a decision here
    }

    /// The default AF_UNIX send buffer is 8 KB, so a 64 KB line takes several writes
    /// interleaved with the app's reads.
    private static func writeAll(_ fd: Int32, _ data: Data, until deadline: Date) -> Bool {
        var offset = 0
        while offset < data.count {
            guard wait(fd, for: POLLOUT, until: deadline) else { return false }
            let written = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return write(fd, base + offset, data.count - offset)
            }
            if written < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                return false
            }
            offset += written
        }
        return true
    }

    private static func wait(_ fd: Int32, for events: Int32, until deadline: Date) -> Bool {
        let remainingMilliseconds = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
        var descriptor = pollfd(fd: fd, events: Int16(events), revents: 0)
        return poll(&descriptor, 1, remainingMilliseconds) > 0
    }
}
```

- [ ] **Step 7: Regenerate, build, inspect the embedded helper**

Run: `xcodegen generate && xcodebuild -project UsageTracker.xcodeproj -scheme UsageTracker -configuration Debug -derivedDataPath build/DerivedData build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

Run:
```bash
APP=build/DerivedData/Build/Products/Debug/Omelette.app
ls -l "$APP/Contents/Helpers/omelette-hook"
codesign -dv --verbose=2 "$APP/Contents/Helpers/omelette-hook" 2>&1 | grep -E '^(Identifier|CodeDirectory|Authority)='
echo '{"session_id":"smoke","hook_event_name":"Stop","cwd":"/tmp"}' | "$APP/Contents/Helpers/omelette-hook"; echo "exit=$?"
```
Expected: the file exists and is executable; `Identifier=com.usagetracker.app.hook`; `CodeDirectory … flags=0x10000(runtime)` (with an ad-hoc override the line also shows `adhoc`); the smoke run prints only `exit=0` (no socket → silent) in well under a second.

- [ ] **Step 8: Run the end-to-end tests**

Run: `xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/OmeletteHookEndToEndTests`
Expected: PASS (8 tests). Typical `elapsed` values are 15–40 ms; a first run on a freshly built binary can take ~400 ms (page-in), still under the 0.8 s assertion.

- [ ] **Step 9: Commit**

```bash
git add project.yml HookHelper/main.swift HookHelper/HostProcess.swift HookHelper/SocketClient.swift UsageTrackerTests/OmeletteHookEndToEndTests.swift
git commit -m "Add omelette-hook helper target, embedded in Contents/Helpers

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

### Task 7: `AgentChannel` — launch-time wiring (symlink refresh, server start, log-only consumer)

**Files:**
- Create: `UsageTracker/Agents/AgentDiagnostics.swift`
- Create: `UsageTracker/Agents/AgentChannel.swift`
- Modify: `UsageTracker/UsageTrackerApp.swift:50-56` (`applicationDidFinishLaunching`; add `applicationWillTerminate`)
- Test: `UsageTrackerTests/AgentChannelTests.swift`

**Interfaces:**
- Consumes: `AgentPaths.refreshHelperSymlink(link:target:)` (Task 1), `AgentEventServer` (Task 5), `AgentSocketTestClient` / `AgentFixture` (Task 5 tests).
- Produces:
  ```swift
  @MainActor enum AgentDiagnostics { static weak var server: AgentEventServer? }   // package 3 reads receivedCount/droppedCount through this

  @MainActor final class AgentChannel {
      static let shared: AgentChannel
      init()                                              // internal so tests build their own
      var onEvent: (AgentEvent) -> Void                   // the single consumer; package 2 assigns AgentSessionStore.shared.apply
      private(set) var server: AgentEventServer?
      private(set) var startError: String?
      func start(socketURL: URL = AgentPaths.socketURL, refreshSymlink: Bool = true)
      func stop()
  }
  ```
  The app calls `AgentChannel.shared.start()` right after `AppState.shared.bootstrap()` and `AgentChannel.shared.stop()` in `applicationWillTerminate` (unlinks the socket file). `AppEnvironment.isRunningTests` already short-circuits `applicationDidFinishLaunching`, so the test host never binds the real socket.

- [ ] **Step 1: Write the failing tests**

```swift
// UsageTrackerTests/AgentChannelTests.swift
import XCTest
@testable import Omelette

@MainActor
final class AgentChannelTests: XCTestCase {
    private var socketURL: URL!
    private var channel: AgentChannel!

    override func setUp() {
        socketURL = AgentFixture.temporarySocketURL()
        channel = AgentChannel()
    }

    override func tearDown() {
        channel.stop()
        try? FileManager.default.removeItem(at: socketURL)
    }

    private func waitOnMain(timeout: TimeInterval = 2, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    func testStartBindsTheSocketAndPublishesTheServerForDiagnostics() throws {
        channel.start(socketURL: socketURL, refreshSymlink: false)

        let server = try XCTUnwrap(channel.server)
        XCTAssertNil(channel.startError)
        XCTAssertTrue(AgentDiagnostics.server === server)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketURL.path))
    }

    func testEventsReachTheConsumerOnTheMainActor() throws {
        var kinds: [AgentEvent.Kind] = []
        channel.onEvent = { kinds.append($0.kind) }
        channel.start(socketURL: socketURL, refreshSymlink: false)

        AgentSocketTestClient.send(AgentFixture.envelope(payload: AgentFixture.userPromptSubmit) + Data([0x0A]), to: socketURL.path)

        XCTAssertTrue(waitOnMain { kinds == [.promptSubmitted] }, "got \(kinds)")
    }

    func testSecondStartIsANoOp() throws {
        channel.start(socketURL: socketURL, refreshSymlink: false)
        let first = try XCTUnwrap(channel.server)
        channel.start(socketURL: socketURL, refreshSymlink: false)
        XCTAssertTrue(channel.server === first)
    }

    func testStartFailureIsRecordedNotThrown() {
        let tooLong = FileManager.default.temporaryDirectory
            .appendingPathComponent(String(repeating: "x", count: 120) + ".sock")
        channel.start(socketURL: tooLong, refreshSymlink: false)
        XCTAssertNil(channel.server)
        XCTAssertNotNil(channel.startError)
    }

    func testStopRemovesTheSocketFile() {
        channel.start(socketURL: socketURL, refreshSymlink: false)
        channel.stop()
        XCTAssertNil(channel.server)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test … -only-testing:UsageTrackerTests/AgentChannelTests` (with the mandatory overrides)
Expected: compile error "cannot find 'AgentChannel' in scope".

- [ ] **Step 3: Create `AgentDiagnostics` and `AgentChannel`**

```swift
// UsageTracker/Agents/AgentDiagnostics.swift
import Foundation

/// Read side for Settings → Agents (package 3): the live server's counters.
/// Main-actor isolated so the static is concurrency-safe under Swift 6.
@MainActor
enum AgentDiagnostics {
    /// Set by `AgentChannel` after a successful `start()`; nil when the socket
    /// could not be bound or the channel was stopped.
    static weak var server: AgentEventServer?
}
```

```swift
// UsageTracker/Agents/AgentChannel.swift
import Foundation

/// Owns the hook → app channel for the app's lifetime: refreshes the helper
/// symlink, starts the socket server, fans events out to one consumer.
///
/// Package 2 replaces the log-only consumer by assigning `onEvent` in
/// `AppState.bootstrap()` — one line, nothing else moves. The server hands every
/// event over on the main queue, so the consumer always runs on the main actor.
@MainActor
final class AgentChannel {
    static let shared = AgentChannel()

    /// The single consumer. The default logs the event kind and a session-id
    /// prefix — never a payload, cwd or tool summary (spec, "Security and privacy").
    var onEvent: (AgentEvent) -> Void = { event in
        NSLog("[UT] agent event %@ session=%@", String(describing: event.kind), String(event.sessionID.prefix(8)))
    }

    private(set) var server: AgentEventServer?
    /// Why the last `start()` failed, for Settings → Agents diagnostics.
    private(set) var startError: String?

    init() {}

    func start(socketURL: URL = AgentPaths.socketURL, refreshSymlink: Bool = true) {
        if refreshSymlink {
            do {
                try AgentPaths.refreshHelperSymlink()
            } catch {
                // Hooks keep pointing at the old symlink target; Settings → Agents shows "outdated".
                NSLog("[UT] helper symlink refresh failed: %@", String(describing: error))
            }
        }
        guard server == nil else { return }

        let server = AgentEventServer(socketURL: socketURL) { [weak self] event in
            // AgentEventServer delivers on the main queue by contract (Task 5).
            MainActor.assumeIsolated { self?.onEvent(event) }
        }
        do {
            try server.start()
            self.server = server
            startError = nil
            AgentDiagnostics.server = server
            NSLog("[UT] agent socket listening at %@", socketURL.path)
        } catch {
            startError = String(describing: error)
            NSLog("[UT] agent socket failed to start: %@", startError ?? "")
        }
    }

    func stop() {
        server?.stop()
        server = nil
        AgentDiagnostics.server = nil
    }
}
```

- [ ] **Step 4: Wire it into the app delegate**

Re-read `UsageTracker/UsageTrackerApp.swift` first. In `applicationDidFinishLaunching`, change

```swift
        AppState.shared.bootstrap()
        UsageNotifier.shared.requestAuthorizationIfNeeded()
```

to

```swift
        AppState.shared.bootstrap()
        // Hook → app channel: helper symlink + Unix socket. Started after bootstrap
        // so a hook that fires during launch never beats the poll's first snapshot.
        AgentChannel.shared.start()
        UsageNotifier.shared.requestAuthorizationIfNeeded()
```

and add, as a new method of `AppDelegate` directly after `applicationDidFinishLaunching`:

```swift
    func applicationWillTerminate(_ notification: Notification) {
        // Unlinks the socket file so a helper spawned after we quit fails fast
        // (ECONNREFUSED on a stale path would still be within budget, but a
        // missing file is the cleaner signal).
        AgentChannel.shared.stop()
    }
```

- [ ] **Step 5: Run the tests, then the full suite, then a launch smoke test**

Run: `xcodegen generate && xcodebuild test … -only-testing:UsageTrackerTests/AgentChannelTests` then the full `xcodebuild test …` (both with the mandatory overrides)
Expected: PASS (5 tests), full suite green.

Run:
```bash
xcodebuild -project UsageTracker.xcodeproj -scheme UsageTracker -configuration Debug -derivedDataPath build/DerivedData build 2>&1 | tail -1
open build/DerivedData/Build/Products/Debug/Omelette.app; sleep 3
ls -l "$HOME/Library/Application Support/UsageTracker/agent.sock" "$HOME/Library/Application Support/UsageTracker/bin/omelette-hook"
echo '{"session_id":"smoke-1234","hook_event_name":"UserPromptSubmit","cwd":"/tmp"}' | "$HOME/Library/Application Support/UsageTracker/bin/omelette-hook"; echo "exit=$?"
log show --last 1m --predicate 'eventMessage CONTAINS "[UT] agent"' --style compact 2>/dev/null | tail -3
```
Expected: `agent.sock` is `srw-------`; `bin/omelette-hook` is a symlink into the built app's `Contents/Helpers/`; `exit=0`. The `log show` line may print nothing on this machine (known: NSLog output is not retrievable via `log show` here) — the socket file mode and the exit code are the assertions. Quit the app afterwards (`osascript -e 'quit app "Omelette"'`) and confirm the socket file is gone.

- [ ] **Step 6: Commit**

```bash
git add UsageTracker/Agents/AgentDiagnostics.swift UsageTracker/Agents/AgentChannel.swift UsageTracker/UsageTrackerApp.swift UsageTrackerTests/AgentChannelTests.swift
git commit -m "Agents: AgentChannel wires symlink refresh and the socket server at launch

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

## Self-review notes

- **Spec coverage.** Helper (stdin / `--codex`, wire envelope, host info via parent walk, 300/500/800 ms caps, exit 0, no stdout, no payload logging): Task 6. Symlink at a stable path refreshed at every launch: Tasks 1 and 7. Server (0600, 64 KB, JSON only, dropped-and-counted): Task 5. Decoding into fixed types incl. subagent flag and Codex kebab-case: Tasks 2 and 4. Tool summary rule and 80-char cap: Task 3. Launch wiring ending at `onEvent`: Task 7. Tests for every item, including the end-to-end helper run and "no server → exit 0 fast".
- **Contract fidelity.** Every name in `…-agent-overview-interfaces.md` is used verbatim; additions (`AgentPaths.appSupportURL/helperName/socketEnvironmentKey/maxSocketPathBytes/refreshHelperSymlink`, `AgentEventServer.socketURL/maxMessageBytes/connectionTimeout/reply/Error`, `AgentChannel`, `AgentDiagnostics`, the test client) are listed under "Produces".
- **Type consistency.** `AgentEventServer(socketURL:onEvent:)` (Task 5) is what Task 6's tests and Task 7 construct; `AgentFixture.envelope(source:payload:)`, `temporarySocketURL()` and `AgentSocketTestClient.send(_:to:replyTimeout:)` are defined in Task 5 and reused unchanged in Tasks 6–7; `AgentPaths.socketEnvironmentKey` = `"OMELETTE_AGENT_SOCKET"` matches `HookMain.socketEnvironmentKey`.
- **Cross-package hand-offs.** Package 2 assigns `AgentChannel.shared.onEvent`; package 3 reads `AgentDiagnostics.server?.receivedCount/droppedCount` and `AgentChannel.shared.startError`; package 4 consumes `AgentHostInfo` produced here.
