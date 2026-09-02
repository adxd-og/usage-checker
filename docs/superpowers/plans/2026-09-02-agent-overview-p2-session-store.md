# Agent Overview — Package 2: Session Store, Passive Scan, History (Phase 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the hook events package 1 delivers into a live, sorted list of agent sessions with a precise state machine, fill the gaps with a passive read of the CLIs' own logs, and record every finished session to an append-only history log.

**Architecture:** `AgentSessionStore` is the single `@MainActor ObservableObject` the UI will observe (packages 4 and 5); it owns the state machine (`apply`), staleness (`pruneStale`) and the merge with approximate data (`mergePassive`), and hands finished sessions to a plain append-only `AgentHistoryStore` that mirrors `HistoryStore`'s JSONL pattern. `PassiveSessionScanner` is a pure, stateless enum that walks `~/.claude/projects` and `~/.codex/sessions`, derives session ids from file names and `cwd`/`session_meta` from the head of each log, and returns approximate `AgentSession` values; `AppState` runs it off the main actor on the existing 60 s poll tick, which is already suspended during sleep and screen lock.

**Tech Stack:** Swift 6 (strict concurrency `minimal`), SwiftUI/Combine (`ObservableObject`), Foundation `FileManager`/`FileHandle`/`JSONSerialization`, XCTest (`UsageTrackerTests`, `@testable import Omelette`), xcodegen-generated project.

**Spec:** `docs/superpowers/specs/2026-09-02-agent-overview-design.md` (sections "Data sources", "AgentSessionStore", "Tool summary", "Packages"); binding contract: `docs/superpowers/specs/2026-09-02-agent-overview-interfaces.md`; roadmap: `docs/superpowers/specs/2026-09-02-agent-control-plane-roadmap.md`.

## Global Constraints

- Deployment target macOS 14.0; Swift 6 with `SWIFT_STRICT_CONCURRENCY: minimal` (`project.yml`).
- **Package 1 owns `UsageTracker/Agents/AgentModels.swift`, `AgentToolSummary.swift`, `AgentEventDecoder.swift`, `AgentEventServer.swift` and `AgentPaths.swift`.** This package never creates or edits those files. `AgentEvent`, `AgentSession`, `AgentState`, `AgentHostInfo`, `AgentSource` and `AgentPaths` are used exactly as declared in the interfaces doc; tests build an `AgentEvent` with its memberwise initialiser (`AgentEvent(source:kind:sessionID:cwd:toolName:toolSummary:isSubagent:host:receivedAt:)`).
- Contract names are fixed and must not be renamed: `AgentSessionStore`, `AgentSessionStore.shared`, `sessions`, `lastEventAt`, `needsYouCount`, `workingCount`, `apply(_:now:)`, `mergePassive(_:now:)`, `pruneStale(now:)`, `sessions(for:)`, `onNeedsYou`, `onDone`, `PassiveSessionScanner.scan(claudeProjects:codexSessions:now:recentWindow:workingWindow:)`, `AgentHistoryStore(fileURL:)`, `append(_:)`, `load()`, `AgentSessionRecord`.
- New source files are picked up by xcodegen from `sources: - path: UsageTracker` and `- path: UsageTrackerTests`; run `xcodegen generate` after adding a file and before building. `UsageTracker.xcodeproj/` is generated and gitignored — never `git add` it.
- Build: `xcodebuild -project UsageTracker.xcodeproj -scheme UsageTracker -configuration Debug -derivedDataPath build/DerivedData build`.
  Tests: `xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData` (add `-only-testing:UsageTrackerTests/<Class>` for a single class). If local signing of the test host fails, append `CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO`.
- Tests must never touch the real `~/Library/Application Support/UsageTracker`, `~/.claude` or `~/.codex`: `FileManager.urls(for: .applicationSupportDirectory, …)` ignores `$HOME`, so every directory is injected explicitly (`AgentSessionStore(historyURL:)`, `AgentHistoryStore(fileURL:)`, `PassiveSessionScanner.scan(claudeProjects:codexSessions:)`).
- No hook payload content is ever persisted: `AgentSessionRecord` carries only `{id, source, project, startedAt, endedAt, turns, needsYouCount}` — no tool names, no tool inputs, no `cwd`.
- Commits end with the trailer lines
  `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` and
  `Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X`.
- Other sessions may commit the working tree while you work: re-read a file right before editing it; prefer targeted edits over whole-file rewrites.
- No CHANGELOG entry and no version bump in this plan — the phase-2 release package owns both, and three packages editing `CHANGELOG.md` in parallel only produces conflicts.

---

## Verified facts this plan is built on

Checked against the machine's real logs on 2026-09-02; the code comments repeat them so a future reader does not have to re-derive them.

| Fact | Evidence |
|---|---|
| A Claude Code transcript is named after its session: `~/.claude/projects/<slug>/<session_id>.jsonl`. | `~/.claude/projects/-Users-me-Desktop-Usage-tracker/37384099-5d4f-423d-ae8b-0eb0c3308aae.jsonl` contains `"sessionId":"37384099-5d4f-423d-ae8b-0eb0c3308aae"`; same convention documented at `UsageTracker/Services/JSONLAggregator.swift:427-429`. |
| `cwd` is a **top-level string** on Claude message records but is **not** on the first line — the file opens with `last-prompt` / `mode` preamble records. In a real transcript the first record carrying `cwd` is line 6 (cumulative 4,947 bytes). | Line 1 is `{"type":"last-prompt","leafUuid":…,"sessionId":…}`; line 6 keys are `[attachment, cwd, entrypoint, gitBranch, isSidechain, parentUuid, sessionId, timestamp, type, userType, uuid, version]` with `cwd = "<repo>"`. |
| `~/.claude/projects` also holds **subagent** transcripts nested under `<slug>/<session_id>/subagents/**.jsonl` (and `subagents/workflows/**`). On this machine: 165 real session transcripts vs 2,137 nested files. A naive recursive walk would invent sessions called `agent-afbf299881b38acd9` and `journal`. | `find ~/.claude/projects -name '*.jsonl' \| awk -F/ '{print NF}' \| sort \| uniq -c` → `165` at depth 7 (the real ones), `537` at 9, `1600` at 11, e.g. `…/-Users-…-Jaravis/ad0b4e72-…/subagents/agent-afbf299881b38acd9.jsonl`. **Therefore the Claude scan accepts only files whose grandparent directory is the root, and prunes the enumerator below the project directories.** |
| Non-`.jsonl` siblings exist (`<uuid>.orion.json`), so the extension filter is load-bearing. | `ls ~/.claude/projects/-Users-me-Desktop-Jaravis` → `2cf9944a-….orion.json`. |
| A Codex rollout is named `rollout-<YYYY-MM-DDTHH-MM-SS>-<uuid>.jsonl`; the uuid is the last 36 characters and equals the session id inside the file. | `~/.codex/archived_sessions/rollout-2026-08-06T14-30-14-019fd6d6-94a9-7611-a007-3c094955e537.jsonl`, whose first line is `{"timestamp":…,"type":"session_meta","payload":{"session_id":"019fd6d6-94a9-7611-a007-3c094955e537","id":"019fd6d6-…","cwd":"~/Desktop/Moive app/Movie app",…}}`. Layout `~/.codex/sessions/YYYY/MM/DD/` confirmed by `find ~/.codex/sessions -maxdepth 4` and `UsageTracker/Services/CodexUsageAggregator.swift:4`. |
| Codex's `session_meta` line is large (18,615 bytes here) because it embeds `base_instructions`; Claude's `cwd` arrives inside 5 KB. A **64 KB head read** covers both with margin and never pulls a multi-megabyte tool-result line. | Measured line lengths: codex line 1 = 18,615 B; claude lines 1–6 = 4,947 B cumulative. |

---

## File structure

```
UsageTracker/Agents/
  AgentSessionStore.swift        state machine, sorting, counts, callbacks, staleness, passive merge   (task 3, 4)
  PassiveSessionScanner.swift    stateless scan of ~/.claude/projects and ~/.codex/sessions            (task 5)
  AgentHistoryStore.swift        AgentSessionRecord + append-only agent-sessions.jsonl                 (task 2)
UsageTracker/Core/
  ProjectName.swift              + display(path:) — prettify a real absolute cwd                       (task 1)
  AppState.swift                 + agent socket start and the per-tick passive scan                    (task 6)
UsageTrackerTests/
  ProjectNameDisplayTests.swift  (task 1)
  AgentHistoryStoreTests.swift   (task 2)
  AgentSessionStoreTests.swift   (tasks 3 and 4)
  PassiveSessionScannerTests.swift (task 5)
```

`UsageTracker/Agents/` is created by package 1; if it does not exist yet when you start, `mkdir -p UsageTracker/Agents` — xcodegen picks it up from the app target's `sources: - path: UsageTracker`.

---

## Task 1: `ProjectName.display(path:)` — a project name from a real `cwd`

Every agent session identifies itself by `cwd` (an absolute path), not by Claude's lossy dash slug. `ProjectName` already knows how to prettify a path — the logic is just locked behind the two slug-decoding entry points.

**Files:**
- Modify: `UsageTracker/Core/ProjectName.swift` (add one static method after `decode(encodedPath:)`, around line 46)
- Test: `UsageTrackerTests/ProjectNameDisplayTests.swift` (create)

**Interfaces:**
- Consumes: `ProjectName.prettify(_:fallback:)` (private, same file, `UsageTracker/Core/ProjectName.swift:96`).
- Produces:
  ```swift
  extension ProjectName {
      /// Display name for a real absolute path (an agent session's `cwd`).
      static func display(path: String) -> String
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
// UsageTrackerTests/ProjectNameDisplayTests.swift
import XCTest
@testable import Omelette

/// `decode(slug:)` guesses a path out of Claude's lossy dash slug. An agent session
/// hands us the real `cwd`, so there is nothing to guess — but the display rules
/// (strip $HOME, drop a noise parent, keep the last two components) must be identical
/// so a hook-tracked row and a cost row name the same project the same way.
final class ProjectNameDisplayTests: XCTestCase {
    func testKeepsTheLastTwoComponents() {
        XCTAssertEqual(ProjectName.display(path: "/Users/tester/Projects/alpha"), "Projects / alpha")
    }

    func testStripsTheHomePrefixAndANoiseParent() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(ProjectName.display(path: "\(home)/Desktop/Usage tracker"), "Usage tracker")
        XCTAssertEqual(ProjectName.display(path: "\(home)/Desktop/Orion Gate/mobile-app"), "Orion Gate / mobile-app")
    }

    func testASingleComponentPathIsItsOwnName() {
        XCTAssertEqual(ProjectName.display(path: "/opt"), "opt")
    }

    func testARelativeOrEmptyPathIsReturnedUnchanged() {
        // Nothing to prettify and nothing to invent — a hook that sends a relative
        // path is better shown verbatim than turned into a wrong project.
        XCTAssertEqual(ProjectName.display(path: "some/relative/dir"), "some/relative/dir")
        XCTAssertEqual(ProjectName.display(path: ""), "")
    }

    func testSpacesSurviveUnlikeTheSlugPath() {
        // The whole point of the new entry point: "Orion Gate" is a single folder and
        // the dash slug cannot prove that, but the real cwd can.
        XCTAssertEqual(ProjectName.display(path: "/Volumes/Work/Orion Gate"), "Work / Orion Gate")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/ProjectNameDisplayTests`
Expected: compile error — `type 'ProjectName' has no member 'display'`.

- [ ] **Step 3: Add the method**

Insert into `UsageTracker/Core/ProjectName.swift` directly after the closing brace of `decode(encodedPath:)` (currently line 46) and before `private static func computeDecode`:

```swift
    /// Display name for a real absolute path — an agent session's `cwd`, a hook's
    /// `cwd` field. Unlike `decode(slug:)` there is nothing lossy to reconstruct, so
    /// no filesystem walk happens; the prettifying rules are shared so the same
    /// project reads identically in the cost rows and in the agents list.
    /// A path that isn't absolute is returned verbatim rather than guessed at.
    static func display(path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        return prettify(path, fallback: path)
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/ProjectNameDisplayTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add UsageTracker/Core/ProjectName.swift UsageTrackerTests/ProjectNameDisplayTests.swift
git commit -m "ProjectName: display(path:) for a real cwd

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

## Task 2: `AgentHistoryStore` + `AgentSessionRecord`

An append-only JSONL log of finished sessions, one record per line, mirroring `UsageTracker/Core/HistoryStore.swift:243-257` (`FileHandle` seek-to-end append, `.atomic` write when the file does not exist yet, corrupt lines skipped on load). The phase-3 dashboard reads it; nothing else writes it.

**Files:**
- Create: `UsageTracker/Agents/AgentHistoryStore.swift`
- Test: `UsageTrackerTests/AgentHistoryStoreTests.swift` (create)

**Interfaces:**
- Consumes: `AgentSource` (package 1, `UsageTracker/Agents/AgentModels.swift`).
- Produces:
  ```swift
  struct AgentSessionRecord: Codable, Equatable {
      let id: String; let source: AgentSource; let project: String
      let startedAt: Date; let endedAt: Date; let turns: Int; let needsYouCount: Int
  }
  final class AgentHistoryStore {
      init(fileURL: URL)
      func append(_ record: AgentSessionRecord) throws
      func load() throws -> [AgentSessionRecord]
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
// UsageTrackerTests/AgentHistoryStoreTests.swift
import XCTest
@testable import Omelette

final class AgentHistoryStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var fileURL: URL { directory.appendingPathComponent("agent-sessions.jsonl") }

    private func record(
        id: String = "claude:s1",
        source: AgentSource = .claude,
        project: String = "Projects / alpha",
        startedAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
        endedAt: Date = Date(timeIntervalSince1970: 1_800_003_600),
        turns: Int = 4,
        needsYouCount: Int = 1
    ) -> AgentSessionRecord {
        AgentSessionRecord(
            id: id, source: source, project: project,
            startedAt: startedAt, endedAt: endedAt, turns: turns, needsYouCount: needsYouCount
        )
    }

    func testAnEmptyLogLoadsAsNothing() throws {
        let store = AgentHistoryStore(fileURL: fileURL)
        XCTAssertEqual(try store.load(), [])
    }

    func testRecordsRoundTripInOrder() throws {
        let store = AgentHistoryStore(fileURL: fileURL)
        let first = record(id: "claude:s1", turns: 4)
        let second = record(id: "codex:t2", source: .codex, project: "Projects / beta", turns: 1, needsYouCount: 0)
        try store.append(first)
        try store.append(second)

        let loaded = try AgentHistoryStore(fileURL: fileURL).load()
        XCTAssertEqual(loaded, [first, second], "the log is append-only: order is the order things ended")
        XCTAssertEqual(loaded[1].source, .codex)
    }

    func testTheLogIsOneJSONObjectPerLine() throws {
        let store = AgentHistoryStore(fileURL: fileURL)
        try store.append(record())
        try store.append(record(id: "claude:s2"))

        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(text.hasSuffix("\n"), "every record ends its own line so an append never corrupts the previous one")
        for line in lines {
            XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(line.utf8)))
        }
    }

    func testNoToolDetailIsEverWritten() throws {
        // Privacy rule from the spec: the history is a summary, never a transcript.
        let store = AgentHistoryStore(fileURL: fileURL)
        try store.append(record())
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(try String(contentsOf: fileURL, encoding: .utf8).split(separator: "\n")[0].utf8)
            ) as? [String: Any]
        )
        XCTAssertEqual(Set(json.keys), ["id", "source", "project", "startedAt", "endedAt", "turns", "needsYouCount"])
    }

    func testACorruptLineIsSkippedRatherThanLosingTheLog() throws {
        let store = AgentHistoryStore(fileURL: fileURL)
        try store.append(record(id: "claude:good1"))
        try "{not json at all\n".appendTo(fileURL)
        try store.append(record(id: "claude:good2"))

        let loaded = try AgentHistoryStore(fileURL: fileURL).load()
        XCTAssertEqual(loaded.map(\.id), ["claude:good1", "claude:good2"])
    }

    func testTheDirectoryIsCreatedOnDemand() throws {
        // App Support/UsageTracker may not exist on a fresh install before the first
        // session ends; an append must not fail because of that.
        let nested = directory.appendingPathComponent("does/not/exist/agent-sessions.jsonl")
        let store = AgentHistoryStore(fileURL: nested)
        try store.append(record())
        XCTAssertEqual(try store.load().count, 1)
    }
}

private extension String {
    /// Appends raw bytes to a file the test already created.
    func appendTo(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(self.utf8))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/AgentHistoryStoreTests`
Expected: compile error — `cannot find 'AgentHistoryStore' in scope`.

- [ ] **Step 3: Implement the store**

```swift
// UsageTracker/Agents/AgentHistoryStore.swift
import Foundation

/// One finished agent session, summarised. Deliberately narrow: the spec forbids
/// persisting anything from a hook payload, so there is no cwd, no tool name and no
/// tool input here — only what the phase-3 "run history" needs to draw a row.
struct AgentSessionRecord: Codable, Equatable {
    let id: String
    let source: AgentSource
    let project: String
    let startedAt: Date
    let endedAt: Date
    /// Prompts the user submitted during the session.
    let turns: Int
    /// How many times the session waited for an approval.
    let needsYouCount: Int
}

/// Append-only JSONL log of finished agent sessions, the same shape `HistoryStore`
/// uses for usage points: one record per line, appended with a seek-to-end write so a
/// session ending never rewrites the whole file, and a line that fails to decode is
/// skipped instead of discarding everything after it.
final class AgentHistoryStore {
    private let fileURL: URL

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Injectable log location — the tests point it at a temp directory instead of
    /// `~/Library/Application Support/UsageTracker/agent-sessions.jsonl`.
    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func append(_ record: AgentSessionRecord) throws {
        var data = try encoder.encode(record)
        data.append(0x0A)

        let fm = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            // No file yet: one atomic write creates it with this first record.
            try data.write(to: fileURL, options: [.atomic])
            return
        }
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    func load() throws -> [AgentSessionRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        var records: [AgentSessionRecord] = []
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            guard let record = try? decoder.decode(AgentSessionRecord.self, from: Data(line)) else { continue }
            records.append(record)
        }
        return records
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/AgentHistoryStoreTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add UsageTracker/Agents/AgentHistoryStore.swift UsageTrackerTests/AgentHistoryStoreTests.swift
git commit -m "Agents: append-only session history log

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

## Task 3: `AgentSessionStore` — the state machine

The whole transition table from the spec, plus `turns` / `needsYouCount` bookkeeping, `stateSince` semantics, sorting, the two callbacks and the `sessionEnd` history append. Staleness and the passive merge come in task 4.

**Files:**
- Create: `UsageTracker/Agents/AgentSessionStore.swift`
- Test: `UsageTrackerTests/AgentSessionStoreTests.swift` (create)

**Interfaces:**
- Consumes: `AgentEvent`, `AgentEvent.Kind`, `AgentSession`, `AgentState`, `AgentState.rank`, `AgentSource`, `AgentHostInfo`, `AgentPaths.historyURL` (package 1); `AgentHistoryStore`, `AgentSessionRecord` (task 2); `ProjectName.display(path:)` (task 1).
- Produces:
  ```swift
  @MainActor
  final class AgentSessionStore: ObservableObject {
      static let shared: AgentSessionStore
      /// Beyond the contract, so tests can point the history log at a temp file.
      init(historyURL: URL = AgentPaths.historyURL)
      @Published private(set) var sessions: [AgentSession]
      @Published private(set) var lastEventAt: Date?
      var needsYouCount: Int
      var workingCount: Int
      var onNeedsYou: ((AgentSession) -> Void)?
      var onDone: ((AgentSession) -> Void)?
      func apply(_ event: AgentEvent, now: Date = Date())
      func sessions(for source: AgentSource) -> [AgentSession]
      /// Beyond the contract; package 4 builds row ids with it.
      static func identifier(source: AgentSource, sessionID: String) -> String
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
// UsageTrackerTests/AgentSessionStoreTests.swift
import XCTest
@testable import Omelette

@MainActor
final class AgentSessionStoreTests: XCTestCase {
    private var directory: URL!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var historyURL: URL { directory.appendingPathComponent("agent-sessions.jsonl") }

    private func makeStore() -> AgentSessionStore {
        AgentSessionStore(historyURL: historyURL)
    }

    private func event(
        _ kind: AgentEvent.Kind,
        source: AgentSource = .claude,
        sessionID: String = "s1",
        cwd: String? = "/Users/tester/Projects/alpha",
        toolName: String? = nil,
        toolSummary: String? = nil,
        isSubagent: Bool = false,
        pid: Int32? = nil
    ) -> AgentEvent {
        AgentEvent(
            source: source,
            kind: kind,
            sessionID: sessionID,
            cwd: cwd,
            toolName: toolName,
            toolSummary: toolSummary,
            isSubagent: isSubagent,
            host: AgentHostInfo(pid: pid, bundleID: nil, tty: nil),
            receivedAt: t0
        )
    }

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    // MARK: - The transition table

    func testEveryClaudeTransition() {
        let cases: [(AgentEvent.Kind, AgentState)] = [
            (.sessionStart, .idle),
            (.promptSubmitted, .working),
            (.toolStarted, .working),
            (.toolFinished, .working),
            (.permissionRequested, .needsYou),
            (.notificationPermission, .needsYou),
            (.notificationIdle, .idle),
            (.stop, .done),
        ]
        for (kind, expected) in cases {
            let store = makeStore()
            store.apply(event(.sessionStart), now: t0)
            store.apply(event(kind), now: at(10))
            XCTAssertEqual(store.sessions.first?.state, expected, "\(kind) must land in \(expected)")
        }
    }

    func testCodexTurnCompleteFinishesTheSession() {
        let store = makeStore()
        store.apply(event(.codexTurnComplete, source: .codex, sessionID: "t1"), now: t0)
        XCTAssertEqual(store.sessions.first?.state, .done)
        XCTAssertEqual(store.sessions.first?.source, .codex)
        XCTAssertEqual(store.sessions.first?.id, "codex:t1")
    }

    func testSessionEndRemovesTheSession() {
        let store = makeStore()
        store.apply(event(.sessionStart), now: t0)
        store.apply(event(.promptSubmitted), now: at(1))
        store.apply(event(.sessionEnd), now: at(2))
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testSessionEndForAnUnknownSessionIsHarmless() {
        let store = makeStore()
        store.apply(event(.sessionEnd, sessionID: "never-seen"), now: t0)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertEqual(store.lastEventAt, t0)
    }

    // MARK: - Ignore rules

    func testSubagentEventsAreIgnoredEntirely() {
        let store = makeStore()
        store.apply(event(.sessionStart, sessionID: "sub", isSubagent: true), now: t0)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertNil(store.lastEventAt, "an ignored event is not activity")
    }

    func testASubagentEventNeverDisturbsItsParentSession() {
        let store = makeStore()
        store.apply(event(.promptSubmitted), now: t0)
        store.apply(event(.stop, isSubagent: true), now: at(5))
        XCTAssertEqual(store.sessions.first?.state, .working)
        XCTAssertEqual(store.sessions.first?.lastEventAt, t0)
    }

    func testAnUnknownKindOnlyRefreshesActivity() {
        let store = makeStore()
        store.apply(event(.promptSubmitted), now: t0)
        store.apply(event(.toolStarted, toolSummary: "Bash: xcodegen generate"), now: at(5))
        store.apply(event(.unknown("PreCompact")), now: at(60))

        let session = try? XCTUnwrap(store.sessions.first)
        XCTAssertEqual(session?.state, .working)
        XCTAssertEqual(session?.stateSince, t0, "an unknown event is not a state change")
        XCTAssertEqual(session?.activity, "Bash: xcodegen generate")
        XCTAssertEqual(session?.lastEventAt, at(60))
        XCTAssertEqual(store.lastEventAt, at(60))
    }

    func testAnUnknownKindDoesNotInventASession() {
        let store = makeStore()
        store.apply(event(.unknown("PreCompact"), sessionID: "never-seen"), now: t0)
        XCTAssertTrue(store.sessions.isEmpty, "we know nothing about this session but its id")
    }

    // MARK: - stateSince

    func testStateSinceMovesOnlyWhenTheStateChanges() {
        let store = makeStore()
        store.apply(event(.promptSubmitted), now: t0)
        store.apply(event(.toolStarted), now: at(30))
        store.apply(event(.toolFinished), now: at(60))
        XCTAssertEqual(store.sessions.first?.stateSince, t0, "still working — the clock keeps running")

        store.apply(event(.stop), now: at(90))
        XCTAssertEqual(store.sessions.first?.stateSince, at(90))
        XCTAssertEqual(store.sessions.first?.state, .done)
    }

    // MARK: - Activity

    func testAPromptClearsTheActivityAndAToolSetsIt() {
        let store = makeStore()
        store.apply(event(.toolStarted, toolName: "Bash", toolSummary: "Bash: git status"), now: t0)
        XCTAssertEqual(store.sessions.first?.activity, "Bash: git status")

        store.apply(event(.promptSubmitted), now: at(5))
        XCTAssertNil(store.sessions.first?.activity, "a new prompt is a new subject")

        store.apply(event(.permissionRequested, toolSummary: "Bash: rm -rf build"), now: at(6))
        XCTAssertEqual(store.sessions.first?.activity, "Bash: rm -rf build")
    }

    func testPostToolUseKeepsTheActivityItHasNoSummaryFor() {
        let store = makeStore()
        store.apply(event(.toolStarted, toolSummary: "Read: PopoverView.swift"), now: t0)
        store.apply(event(.toolFinished, toolName: "Read", toolSummary: nil), now: at(1))
        XCTAssertEqual(store.sessions.first?.activity, "Read: PopoverView.swift")
    }

    // MARK: - Counters

    func testTurnsCountPromptsAndNothingElse() {
        let store = makeStore()
        store.apply(event(.sessionStart), now: t0)
        store.apply(event(.promptSubmitted), now: at(1))
        store.apply(event(.toolStarted), now: at(2))
        store.apply(event(.stop), now: at(3))
        store.apply(event(.promptSubmitted), now: at(4))
        XCTAssertEqual(store.sessions.first?.turns, 2)
    }

    func testNeedsYouCountsEpisodesNotEvents() {
        let store = makeStore()
        store.apply(event(.permissionRequested), now: t0)
        store.apply(event(.notificationPermission), now: at(1)) // same episode, the fallback fired too
        XCTAssertEqual(store.sessions.first?.needsYouCount, 1)

        store.apply(event(.toolStarted), now: at(2))
        store.apply(event(.permissionRequested), now: at(3))
        XCTAssertEqual(store.sessions.first?.needsYouCount, 2)
    }

    func testStoreLevelCounts() {
        let store = makeStore()
        store.apply(event(.permissionRequested, sessionID: "a"), now: t0)
        store.apply(event(.promptSubmitted, sessionID: "b"), now: at(1))
        store.apply(event(.promptSubmitted, sessionID: "c"), now: at(2))
        store.apply(event(.stop, sessionID: "d"), now: at(3))

        XCTAssertEqual(store.needsYouCount, 1)
        XCTAssertEqual(store.workingCount, 2)
    }

    // MARK: - Callbacks

    func testNeedsYouFiresOncePerEpisode() {
        let store = makeStore()
        var fired: [String] = []
        store.onNeedsYou = { fired.append($0.id) }

        store.apply(event(.permissionRequested), now: t0)
        store.apply(event(.notificationPermission), now: at(1))
        XCTAssertEqual(fired, ["claude:s1"], "one prompt, one notification")

        store.apply(event(.toolStarted), now: at(2))
        store.apply(event(.permissionRequested), now: at(3))
        XCTAssertEqual(fired, ["claude:s1", "claude:s1"], "leaving and re-entering is a new episode")
    }

    func testDoneFiresOncePerEpisodeAndCarriesTheSession() {
        let store = makeStore()
        var done: [AgentSession] = []
        store.onDone = { done.append($0) }

        store.apply(event(.promptSubmitted), now: t0)
        store.apply(event(.stop), now: at(1))
        store.apply(event(.stop), now: at(2))
        XCTAssertEqual(done.count, 1)
        XCTAssertEqual(done.first?.id, "claude:s1")
        XCTAssertEqual(done.first?.projectName, "Projects / alpha")
        XCTAssertEqual(done.first?.turns, 1)
    }

    func testNoCallbackFiresForAStateThatDidNotChange() {
        let store = makeStore()
        var needsYou = 0
        var done = 0
        store.onNeedsYou = { _ in needsYou += 1 }
        store.onDone = { _ in done += 1 }

        store.apply(event(.sessionStart), now: t0)
        store.apply(event(.notificationIdle), now: at(1))
        store.apply(event(.toolStarted), now: at(2))
        store.apply(event(.toolFinished), now: at(3))
        XCTAssertEqual(needsYou, 0)
        XCTAssertEqual(done, 0)
    }

    // MARK: - Identity and projects

    func testASessionCarriesItsProjectAndHost() {
        let store = makeStore()
        store.apply(
            event(.sessionStart, cwd: "/Users/tester/Projects/alpha", pid: 4242),
            now: t0
        )
        let session = store.sessions.first
        XCTAssertEqual(session?.id, "claude:s1")
        XCTAssertEqual(session?.sessionID, "s1")
        XCTAssertEqual(session?.projectName, "Projects / alpha")
        XCTAssertEqual(session?.cwd, "/Users/tester/Projects/alpha")
        XCTAssertEqual(session?.host.pid, 4242)
        XCTAssertEqual(session?.startedAt, t0)
        XCTAssertFalse(session?.isApproximate ?? true)
    }

    func testTheSameSessionIDFromTwoSourcesIsTwoSessions() {
        let store = makeStore()
        store.apply(event(.promptSubmitted, source: .claude, sessionID: "x"), now: t0)
        store.apply(event(.codexTurnComplete, source: .codex, sessionID: "x"), now: at(1))
        XCTAssertEqual(Set(store.sessions.map(\.id)), ["claude:x", "codex:x"])
        XCTAssertEqual(store.sessions(for: .claude).map(\.id), ["claude:x"])
        XCTAssertEqual(store.sessions(for: .codex).map(\.id), ["codex:x"])
    }

    func testASessionWithoutACwdStillHasAName() {
        let store = makeStore()
        store.apply(event(.sessionStart, cwd: nil), now: t0)
        XCTAssertEqual(store.sessions.first?.projectName, "Unknown project")
    }

    // MARK: - Sorting

    func testSessionsSortByStateThenRecency() {
        let store = makeStore()
        store.apply(event(.sessionStart, sessionID: "idle"), now: t0)
        store.apply(event(.stop, sessionID: "done"), now: at(1))
        store.apply(event(.promptSubmitted, sessionID: "workingOld"), now: at(2))
        store.apply(event(.promptSubmitted, sessionID: "workingNew"), now: at(3))
        store.apply(event(.permissionRequested, sessionID: "needsYou"), now: at(4))

        XCTAssertEqual(
            store.sessions.map(\.sessionID),
            ["needsYou", "workingNew", "workingOld", "done", "idle"]
        )
    }

    // MARK: - History

    func testSessionEndWritesOneHistoryRecord() throws {
        let store = makeStore()
        store.apply(event(.sessionStart), now: t0)
        store.apply(event(.promptSubmitted), now: at(10))
        store.apply(event(.permissionRequested), now: at(20))
        store.apply(event(.promptSubmitted), now: at(30))
        store.apply(event(.sessionEnd), now: at(40))

        let records = try AgentHistoryStore(fileURL: historyURL).load()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.id, "claude:s1")
        XCTAssertEqual(records.first?.source, .claude)
        XCTAssertEqual(records.first?.project, "Projects / alpha")
        XCTAssertEqual(records.first?.startedAt, t0)
        XCTAssertEqual(records.first?.endedAt, at(40))
        XCTAssertEqual(records.first?.turns, 2)
        XCTAssertEqual(records.first?.needsYouCount, 1)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/AgentSessionStoreTests`
Expected: compile error — `cannot find 'AgentSessionStore' in scope`.

- [ ] **Step 3: Implement the store**

```swift
// UsageTracker/Agents/AgentSessionStore.swift
import Foundation
import Combine

/// Every agent session the app knows about, and what each one is doing right now.
///
/// Two feeds arrive here. Hook events (`apply`) are precise: Claude Code tells us a
/// prompt was submitted, a tool started, an approval is waiting. The passive scan
/// (`mergePassive`, task 4) is approximate and only fills in sessions no hook has
/// spoken for. Hook state always wins for a session id we have heard from.
@MainActor
final class AgentSessionStore: ObservableObject {
    static let shared = AgentSessionStore()

    /// Sorted for display: `needsYou` first, then `working`, `done`, `idle`
    /// (`AgentState.rank`), and inside a group the most recently active first.
    @Published private(set) var sessions: [AgentSession] = []
    /// When the last hook event of any kind arrived — Settings shows it as a
    /// liveness signal for the socket.
    @Published private(set) var lastEventAt: Date?

    /// Fires when a session *enters* `needsYou` — once per episode, so a
    /// `PermissionRequest` immediately followed by its `Notification` fallback is one
    /// notification, not two.
    var onNeedsYou: ((AgentSession) -> Void)?
    /// Fires when a session *enters* `done`, same once-per-episode rule.
    var onDone: ((AgentSession) -> Void)?

    var needsYouCount: Int { sessions.reduce(0) { $0 + ($1.state == .needsYou ? 1 : 0) } }
    var workingCount: Int { sessions.reduce(0) { $0 + ($1.state == .working ? 1 : 0) } }

    /// A hook-tracked session with no event for this long and no live host process is
    /// assumed dead (`pruneStale`, task 4).
    static let staleAfter: TimeInterval = 2 * 3600

    private let history: AgentHistoryStore

    /// Injectable history location — the tests point it at a temp file instead of
    /// `~/Library/Application Support/UsageTracker/agent-sessions.jsonl`.
    init(historyURL: URL = AgentPaths.historyURL) {
        self.history = AgentHistoryStore(fileURL: historyURL)
    }

    /// `"claude:<session_id>"` — a Claude session and a Codex thread could in
    /// principle carry the same uuid, so the source is part of the identity.
    static func identifier(source: AgentSource, sessionID: String) -> String {
        "\(source.rawValue):\(sessionID)"
    }

    func sessions(for source: AgentSource) -> [AgentSession] {
        sessions.filter { $0.source == source }
    }

    // MARK: - Hook events

    func apply(_ event: AgentEvent, now: Date = Date()) {
        // Subagents are a session's internals, not sessions of their own: a Task tool
        // running five agents must not put five rows in the popover.
        guard !event.isSubagent else { return }
        // Timestamps come from our own clock rather than `event.receivedAt`: the list
        // is sorted by them, and a message that waited in the socket queue must not
        // sort ahead of one that arrived after it.
        lastEventAt = now

        let id = Self.identifier(source: event.source, sessionID: event.sessionID)

        if case .sessionEnd = event.kind {
            guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
            let ended = sessions.remove(at: index)
            archive(ended, endedAt: now)
            return
        }

        let existing = sessions.first(where: { $0.id == id })
        // An event we don't model, for a session we've never seen, tells us nothing
        // worth a row — all we would have is an id.
        if case .unknown = event.kind, existing == nil { return }

        var session = existing ?? makeSession(from: event, now: now)
        let previousState: AgentState? = existing?.state

        if let cwd = event.cwd, !cwd.isEmpty {
            session.cwd = cwd
            session.projectName = ProjectName.display(path: cwd)
        }
        if event.host.pid != nil || event.host.bundleID != nil || event.host.tty != nil {
            session.host = event.host
        }
        // A hook has spoken for this id, so whatever the passive scan guessed is
        // superseded from here on.
        session.isApproximate = false
        session.lastEventAt = now

        switch event.kind {
        case .sessionStart:
            transition(&session, to: .idle, now: now)
        case .promptSubmitted:
            session.turns += 1
            session.activity = nil
            transition(&session, to: .working, now: now)
        case .toolStarted, .toolFinished:
            // PostToolUse carries no tool_input, so it usually has no summary; the
            // one from PreToolUse stays on screen until the next tool starts.
            if let summary = event.toolSummary { session.activity = summary }
            transition(&session, to: .working, now: now)
        case .permissionRequested, .notificationPermission:
            if let summary = event.toolSummary { session.activity = summary }
            transition(&session, to: .needsYou, now: now)
        case .notificationIdle:
            transition(&session, to: .idle, now: now)
        case .stop, .codexTurnComplete:
            transition(&session, to: .done, now: now)
        case .unknown:
            break // lastEventAt is already refreshed; the state is left alone.
        case .sessionEnd:
            break // handled above
        }

        if session.state == .needsYou, previousState != .needsYou {
            session.needsYouCount += 1
        }
        upsert(session)
        sortSessions()

        if session.state != previousState {
            switch session.state {
            case .needsYou: onNeedsYou?(session)
            case .done: onDone?(session)
            case .working, .idle: break
            }
        }
    }

    // MARK: - Private

    private func makeSession(from event: AgentEvent, now: Date) -> AgentSession {
        AgentSession(
            id: Self.identifier(source: event.source, sessionID: event.sessionID),
            sessionID: event.sessionID,
            source: event.source,
            projectName: Self.projectName(for: event.cwd),
            cwd: event.cwd,
            state: .idle,
            activity: nil,
            stateSince: now,
            lastEventAt: now,
            startedAt: now,
            host: event.host,
            isApproximate: false,
            turns: 0,
            needsYouCount: 0
        )
    }

    static func projectName(for cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "Unknown project" }
        return ProjectName.display(path: cwd)
    }

    /// `stateSince` is what the UI counts up from ("working 4m"), so it moves only on
    /// a real change: five tool events in a row are one stretch of working.
    private func transition(_ session: inout AgentSession, to state: AgentState, now: Date) {
        guard session.state != state else { return }
        session.state = state
        session.stateSince = now
    }

    private func upsert(_ session: AgentSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
    }

    /// State group first, then most recent activity, then id so the order is stable
    /// when two sessions share a timestamp (they do: one poll merges many at once).
    private func sortSessions() {
        sessions.sort { a, b in
            if a.state.rank != b.state.rank { return a.state.rank < b.state.rank }
            if a.lastEventAt != b.lastEventAt { return a.lastEventAt > b.lastEventAt }
            return a.id < b.id
        }
    }

    /// A session leaves the list into the history log. Approximate (passive) sessions
    /// are dropped without a record: their `turns` is 0 and their `startedAt` is only
    /// when we first noticed the file, so writing them would put numbers in the
    /// phase-3 history that never happened.
    private func archive(_ session: AgentSession, endedAt: Date) {
        guard !session.isApproximate else { return }
        let record = AgentSessionRecord(
            id: session.id,
            source: session.source,
            project: session.projectName,
            startedAt: session.startedAt,
            endedAt: endedAt,
            turns: session.turns,
            needsYouCount: session.needsYouCount
        )
        do {
            try history.append(record)
        } catch {
            NSLog("[UT] agent history append failed: %@", String(describing: error))
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/AgentSessionStoreTests`
Expected: PASS (22 tests).

- [ ] **Step 5: Commit**

```bash
git add UsageTracker/Agents/AgentSessionStore.swift UsageTrackerTests/AgentSessionStoreTests.swift
git commit -m "Agents: session store state machine

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

## Task 4: `pruneStale` and `mergePassive`

Staleness (2 h without events **and** no live host process) and the merge rule that lets approximate sessions fill the gaps without ever overruling a hook.

**Files:**
- Modify: `UsageTracker/Agents/AgentSessionStore.swift` (add two methods before `// MARK: - Private`, and one private helper)
- Test: `UsageTrackerTests/AgentSessionStoreTests.swift` (extend)

**Interfaces:**
- Consumes: everything from task 3; `kill(_:_:)` from Darwin.
- Produces:
  ```swift
  extension AgentSessionStore {
      func mergePassive(_ scanned: [AgentSession], now: Date = Date())
      func pruneStale(now: Date = Date())
  }
  ```

- [ ] **Step 1: Write the failing tests**

Append these two `MARK` sections inside `AgentSessionStoreTests` (before the closing brace). They use one extra helper, `passive(...)`, that builds exactly what `PassiveSessionScanner` will return in task 5.

```swift
    // MARK: - Passive fixtures

    private func passive(
        source: AgentSource = .claude,
        sessionID: String = "s1",
        project: String = "Projects / alpha",
        cwd: String? = "/Users/tester/Projects/alpha",
        state: AgentState = .idle,
        at seen: Date? = nil
    ) -> AgentSession {
        let seenAt = seen ?? t0
        return AgentSession(
            id: AgentSessionStore.identifier(source: source, sessionID: sessionID),
            sessionID: sessionID,
            source: source,
            projectName: project,
            cwd: cwd,
            state: state,
            activity: nil,
            stateSince: seenAt,
            lastEventAt: seenAt,
            startedAt: seenAt,
            host: AgentHostInfo(pid: nil, bundleID: nil, tty: nil),
            isApproximate: true,
            turns: 0,
            needsYouCount: 0
        )
    }

    // MARK: - mergePassive

    func testAPassiveSessionAppears() {
        let store = makeStore()
        store.mergePassive([passive(state: .working, at: t0)], now: t0)

        let session = store.sessions.first
        XCTAssertEqual(session?.id, "claude:s1")
        XCTAssertEqual(session?.state, .working)
        XCTAssertEqual(session?.projectName, "Projects / alpha")
        XCTAssertTrue(session?.isApproximate ?? false)
    }

    func testAPassiveSessionMirrorsTheScanAndDisappearsWithIt() {
        let store = makeStore()
        store.mergePassive([passive(state: .working, at: t0)], now: t0)
        store.mergePassive([passive(state: .idle, at: at(60))], now: at(60))
        XCTAssertEqual(store.sessions.first?.state, .idle)
        XCTAssertEqual(store.sessions.first?.stateSince, at(60))
        XCTAssertEqual(store.sessions.first?.startedAt, t0, "we keep the earliest sighting")

        store.mergePassive([], now: at(120))
        XCTAssertTrue(store.sessions.isEmpty, "the log aged out of the scan window")
    }

    func testAHookTrackedClaudeSessionIgnoresThePassiveReading() {
        let store = makeStore()
        store.apply(event(.stop), now: t0)
        store.mergePassive([passive(state: .working, at: at(60))], now: at(60))

        let session = store.sessions.first
        XCTAssertEqual(session?.state, .done, "the hook knows the turn finished; the file mtime does not")
        XCTAssertEqual(session?.stateSince, t0)
        XCTAssertEqual(session?.lastEventAt, t0)
        XCTAssertFalse(session?.isApproximate ?? true)
    }

    func testAHookTrackedSessionSurvivesDisappearingFromTheScan() {
        let store = makeStore()
        store.apply(event(.promptSubmitted), now: t0)
        store.mergePassive([], now: at(60))
        XCTAssertEqual(store.sessions.map(\.id), ["claude:s1"])
    }

    func testAPassiveWorkingUpgradesACodexSessionOnly() {
        // Codex has no "turn started" event — a rollout file that just changed is the
        // only evidence the agent is running again.
        let store = makeStore()
        store.apply(event(.codexTurnComplete, source: .codex, sessionID: "t1"), now: t0)
        store.mergePassive(
            [passive(source: .codex, sessionID: "t1", project: "Projects / beta",
                     cwd: "/Users/tester/Projects/beta", state: .working, at: at(60))],
            now: at(60)
        )

        let session = store.sessions.first
        XCTAssertEqual(session?.state, .working)
        XCTAssertEqual(session?.stateSince, at(60))
        XCTAssertFalse(session?.isApproximate ?? true, "it is still a hook-tracked session")
    }

    func testAPassiveIdleNeverDowngradesACodexSession() {
        let store = makeStore()
        store.apply(event(.codexTurnComplete, source: .codex, sessionID: "t1"), now: t0)
        store.mergePassive(
            [passive(source: .codex, sessionID: "t1", state: .idle, at: at(60))],
            now: at(60)
        )
        XCTAssertEqual(store.sessions.first?.state, .done)
    }

    func testAPassiveWorkingNeverTouchesAClaudeNeedsYou() {
        let store = makeStore()
        store.apply(event(.permissionRequested), now: t0)
        store.mergePassive([passive(state: .working, at: at(60))], now: at(60))
        XCTAssertEqual(store.sessions.first?.state, .needsYou)
    }

    func testAHookEventTakesOverAPassiveSession() {
        let store = makeStore()
        store.mergePassive([passive(state: .working, at: t0)], now: t0)
        store.apply(event(.permissionRequested, toolSummary: "Bash: rm -rf build"), now: at(30))

        let session = store.sessions.first
        XCTAssertEqual(store.sessions.count, 1, "same id, same row")
        XCTAssertEqual(session?.state, .needsYou)
        XCTAssertEqual(session?.activity, "Bash: rm -rf build")
        XCTAssertFalse(session?.isApproximate ?? true)

        // And the scan no longer has any say over it.
        store.mergePassive([passive(state: .idle, at: at(60))], now: at(60))
        XCTAssertEqual(store.sessions.first?.state, .needsYou)
    }

    func testMergeKeepsTheListSorted() {
        let store = makeStore()
        store.apply(event(.permissionRequested, sessionID: "needsYou"), now: t0)
        store.mergePassive([
            passive(sessionID: "idle", state: .idle, at: at(10)),
            passive(sessionID: "working", state: .working, at: at(5)),
        ], now: at(10))

        XCTAssertEqual(store.sessions.map(\.sessionID), ["needsYou", "working", "idle"])
    }

    // MARK: - pruneStale

    func testAStaleSessionWithADeadHostIsDropped() throws {
        let store = makeStore()
        // Far above the kernel's pid ceiling, so it can never name a live process.
        store.apply(event(.sessionStart, pid: Int32.max), now: t0)
        store.apply(event(.promptSubmitted), now: t0)
        store.pruneStale(now: t0.addingTimeInterval(AgentSessionStore.staleAfter + 1))

        XCTAssertTrue(store.sessions.isEmpty)
        let records = try AgentHistoryStore(fileURL: historyURL).load()
        XCTAssertEqual(records.map(\.id), ["claude:s1"], "a pruned session is still a session that ran")
        XCTAssertEqual(records.first?.turns, 1)
    }

    func testAStaleSessionWhoseHostIsStillRunningIsKept() {
        let store = makeStore()
        store.apply(event(.sessionStart, pid: getpid()), now: t0)
        store.pruneStale(now: t0.addingTimeInterval(AgentSessionStore.staleAfter + 1))
        XCTAssertEqual(store.sessions.count, 1, "the terminal is still open — the session may just be quiet")
    }

    func testASessionWithoutAHostPIDIsDroppedOnceStale() {
        let store = makeStore()
        store.apply(event(.sessionStart, pid: nil), now: t0)
        store.pruneStale(now: t0.addingTimeInterval(AgentSessionStore.staleAfter + 1))
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testAFreshSessionIsNeverPruned() {
        let store = makeStore()
        store.apply(event(.sessionStart, pid: Int32.max), now: t0)
        store.pruneStale(now: t0.addingTimeInterval(AgentSessionStore.staleAfter - 1))
        XCTAssertEqual(store.sessions.count, 1)
    }

    func testAPrunedPassiveSessionWritesNoHistory() throws {
        // Its turns are 0 and its startedAt is only when we first saw the file: a
        // record would be fiction.
        let store = makeStore()
        store.mergePassive([passive(state: .idle, at: t0)], now: t0)
        store.pruneStale(now: t0.addingTimeInterval(AgentSessionStore.staleAfter + 1))

        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertEqual(try AgentHistoryStore(fileURL: historyURL).load(), [])
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/AgentSessionStoreTests`
Expected: compile error — `value of type 'AgentSessionStore' has no member 'mergePassive'` (and `pruneStale`).

- [ ] **Step 3: Implement both methods**

Insert into `UsageTracker/Agents/AgentSessionStore.swift` immediately before the `// MARK: - Private` line:

```swift
    // MARK: - Passive scan

    /// Folds one `PassiveSessionScanner` result into the list.
    ///
    /// Precedence: a session id a hook has spoken for is never rewritten by a file
    /// mtime — the hook knows whether the agent is waiting for you, the file only
    /// knows that bytes were appended. The single exception is Codex, which has no
    /// "turn started" hook at all: a rollout file that changed in the last 30 seconds
    /// is the only evidence its agent is running again, so it may lift a Codex session
    /// out of `done`/`idle` into `working`.
    ///
    /// Passive-only sessions mirror the scan exactly: added when they appear, updated
    /// while they are in it, dropped when they fall out of the 30-minute window.
    func mergePassive(_ scanned: [AgentSession], now: Date = Date()) {
        let scannedByID = Dictionary(scanned.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var merged: [AgentSession] = []
        merged.reserveCapacity(max(sessions.count, scanned.count))

        for existing in sessions {
            guard existing.isApproximate else {
                merged.append(upgradedIfCodexIsWorking(existing, scannedByID[existing.id], now: now))
                continue
            }
            guard var fresh = scannedByID[existing.id] else { continue } // gone from the scan
            fresh.startedAt = min(existing.startedAt, fresh.startedAt)
            if fresh.state == existing.state {
                fresh.stateSince = existing.stateSince
            }
            merged.append(fresh)
        }

        let known = Set(sessions.map(\.id))
        for fresh in scanned where !known.contains(fresh.id) {
            merged.append(fresh)
        }

        sessions = merged
        sortSessions()
    }

    /// Drops sessions that have gone quiet for `staleAfter` and whose host process is
    /// no longer running. A session whose terminal is still open is kept however quiet
    /// it is — the user can see it and would not expect it to vanish.
    func pruneStale(now: Date = Date()) {
        var kept: [AgentSession] = []
        var dropped: [AgentSession] = []
        for session in sessions {
            if Self.isStale(session, now: now) {
                dropped.append(session)
            } else {
                kept.append(session)
            }
        }
        guard !dropped.isEmpty else { return }
        sessions = kept
        for session in dropped {
            archive(session, endedAt: session.lastEventAt)
        }
    }

    private func upgradedIfCodexIsWorking(
        _ session: AgentSession, _ scanned: AgentSession?, now: Date
    ) -> AgentSession {
        guard session.source == .codex,
              let scanned, scanned.state == .working,
              session.state == .done || session.state == .idle
        else { return session }
        var upgraded = session
        upgraded.state = .working
        upgraded.stateSince = now
        upgraded.lastEventAt = max(session.lastEventAt, scanned.lastEventAt)
        return upgraded
    }

    private static func isStale(_ session: AgentSession, now: Date) -> Bool {
        guard now.timeIntervalSince(session.lastEventAt) >= staleAfter else { return false }
        guard let pid = session.host.pid else { return true }
        return !isProcessAlive(pid)
    }

    /// `kill(pid, 0)` sends no signal and only reports whether the process exists.
    /// `EPERM` means it exists but belongs to someone else — still alive.
    private static func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/AgentSessionStoreTests`
Expected: PASS (36 tests — the 22 from task 3 plus 14 here).

- [ ] **Step 5: Commit**

```bash
git add UsageTracker/Agents/AgentSessionStore.swift UsageTrackerTests/AgentSessionStoreTests.swift
git commit -m "Agents: staleness pruning and passive merge precedence

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

## Task 5: `PassiveSessionScanner`

Reads what the two CLIs already write to disk so the Agents section is useful before anyone installs a hook. Stateless, pure, and safe to run off the main actor.

**Files:**
- Create: `UsageTracker/Agents/PassiveSessionScanner.swift`
- Test: `UsageTrackerTests/PassiveSessionScannerTests.swift` (create)

**Interfaces:**
- Consumes: `AgentSession`, `AgentSource`, `AgentState`, `AgentHostInfo` (package 1); `ProjectName.display(path:)` (task 1), `ProjectName.decode(slug:)` (`UsageTracker/Core/ProjectName.swift:22`).
- Produces:
  ```swift
  enum PassiveSessionScanner {
      static func scan(claudeProjects: URL, codexSessions: URL, now: Date = Date(),
                       recentWindow: TimeInterval = 30 * 60,
                       workingWindow: TimeInterval = 30) -> [AgentSession]
      /// Beyond the contract, tested directly because the name format is the fallback
      /// when a rollout's first line is unreadable.
      static func codexSessionID(fileName: String) -> String?
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
// UsageTrackerTests/PassiveSessionScannerTests.swift
import XCTest
@testable import Omelette

/// Fixture trees mimic the real layouts:
///   ~/.claude/projects/<slug>/<session_id>.jsonl
///   ~/.codex/sessions/YYYY/MM/DD/rollout-<stamp>-<uuid>.jsonl
/// Both roots are injected, so nothing here can read the developer's own logs.
final class PassiveSessionScannerTests: XCTestCase {
    private var root: URL!
    private var claudeRoot: URL!
    private var codexRoot: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private let alphaSlug = "-Users-tester-Projects-alpha"
    private let claudeSessionID = "37384099-5d4f-423d-ae8b-0eb0c3308aae"
    private let codexSessionID = "019fd6d6-94a9-7611-a007-3c094955e537"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PassiveScanTests-\(UUID().uuidString)", isDirectory: true)
        claudeRoot = root.appendingPathComponent("claude-projects", isDirectory: true)
        codexRoot = root.appendingPathComponent("codex-sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixture writing

    @discardableResult
    private func write(_ contents: String, to relativePath: String, secondsAgo: TimeInterval) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-secondsAgo)], ofItemAtPath: url.path
        )
        return url
    }

    /// A Claude transcript: preamble records first, `cwd` only on the first message
    /// record — exactly like a real one, where it lands on line 6.
    private func claudeTranscript(cwd: String, sessionID: String) -> String {
        """
        {"type":"last-prompt","leafUuid":"b118ed81-eb23-40e2-8423-f9dc1459a503","sessionId":"\(sessionID)"}
        {"type":"mode","sessionId":"\(sessionID)"}
        {"type":"user","sessionId":"\(sessionID)","cwd":"\(cwd)","uuid":"a1"}
        {"type":"assistant","sessionId":"\(sessionID)","cwd":"/somewhere/else","uuid":"a2"}

        """
    }

    private func codexRollout(cwd: String, sessionID: String) -> String {
        """
        {"timestamp":"2026-08-06T11:30:14.849Z","type":"session_meta","payload":{"session_id":"\(sessionID)","id":"\(sessionID)","cwd":"\(cwd)","originator":"Codex Desktop"}}
        {"timestamp":"2026-08-06T11:30:14.849Z","type":"event_msg","payload":{"type":"task_started"}}

        """
    }

    private func scan(recentWindow: TimeInterval = 30 * 60, workingWindow: TimeInterval = 30) -> [AgentSession] {
        PassiveSessionScanner.scan(
            claudeProjects: claudeRoot, codexSessions: codexRoot,
            now: now, recentWindow: recentWindow, workingWindow: workingWindow
        )
    }

    // MARK: - Claude

    func testAClaudeTranscriptBecomesAnApproximateSession() throws {
        try write(
            claudeTranscript(cwd: "/Users/tester/Projects/alpha", sessionID: claudeSessionID),
            to: "claude-projects/\(alphaSlug)/\(claudeSessionID).jsonl",
            secondsAgo: 300
        )

        let sessions = scan()
        XCTAssertEqual(sessions.count, 1)
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session.id, "claude:\(claudeSessionID)")
        XCTAssertEqual(session.sessionID, claudeSessionID, "the file name IS the session id")
        XCTAssertEqual(session.source, .claude)
        XCTAssertEqual(session.cwd, "/Users/tester/Projects/alpha", "the first record carrying cwd wins")
        XCTAssertEqual(session.projectName, "Projects / alpha")
        XCTAssertEqual(session.state, .idle)
        XCTAssertTrue(session.isApproximate)
        XCTAssertNil(session.host.pid)
        XCTAssertNil(session.activity)
        XCTAssertEqual(session.turns, 0)
        XCTAssertEqual(session.needsYouCount, 0)
        XCTAssertEqual(session.lastEventAt, now.addingTimeInterval(-300))
        XCTAssertEqual(session.stateSince, now.addingTimeInterval(-300))
    }

    func testATranscriptTouchedSecondsAgoIsWorking() throws {
        try write(
            claudeTranscript(cwd: "/Users/tester/Projects/alpha", sessionID: claudeSessionID),
            to: "claude-projects/\(alphaSlug)/\(claudeSessionID).jsonl",
            secondsAgo: 5
        )
        XCTAssertEqual(scan().first?.state, .working)
    }

    func testATranscriptOlderThanTheWindowIsNotASession() throws {
        try write(
            claudeTranscript(cwd: "/Users/tester/Projects/alpha", sessionID: claudeSessionID),
            to: "claude-projects/\(alphaSlug)/\(claudeSessionID).jsonl",
            secondsAgo: 31 * 60
        )
        XCTAssertTrue(scan().isEmpty)
    }

    func testSubagentTranscriptsAreNotSessions() throws {
        // A working machine has ~2,000 of these against ~165 real transcripts:
        // <slug>/<session_id>/subagents/agent-*.jsonl and .../workflows/*/journal.jsonl.
        // The spec ignores subagents, and "journal" is not a session at all.
        try write(
            claudeTranscript(cwd: "/Users/tester/Projects/alpha", sessionID: claudeSessionID),
            to: "claude-projects/\(alphaSlug)/\(claudeSessionID).jsonl",
            secondsAgo: 60
        )
        try write(
            claudeTranscript(cwd: "/Users/tester/Projects/alpha", sessionID: "agent-afbf299881b38acd9"),
            to: "claude-projects/\(alphaSlug)/\(claudeSessionID)/subagents/agent-afbf299881b38acd9.jsonl",
            secondsAgo: 60
        )
        try write(
            claudeTranscript(cwd: "/Users/tester/Projects/alpha", sessionID: "journal"),
            to: "claude-projects/\(alphaSlug)/\(claudeSessionID)/subagents/workflows/wf_9611ae5d/journal.jsonl",
            secondsAgo: 60
        )

        XCTAssertEqual(scan().map(\.sessionID), [claudeSessionID])
    }

    func testNonJSONLSiblingsAreIgnored() throws {
        try write("{}", to: "claude-projects/\(alphaSlug)/\(claudeSessionID).orion.json", secondsAgo: 10)
        XCTAssertTrue(scan().isEmpty)
    }

    func testATranscriptWithoutACwdFallsBackToTheProjectSlug() throws {
        try write(
            "{\"type\":\"last-prompt\",\"sessionId\":\"\(claudeSessionID)\"}\n",
            to: "claude-projects/\(alphaSlug)/\(claudeSessionID).jsonl",
            secondsAgo: 60
        )
        let session = scan().first
        XCTAssertNil(session?.cwd)
        XCTAssertEqual(session?.projectName, "Projects / alpha", "the dash slug is the fallback")
    }

    func testAnUnparseableTranscriptStillProducesASession() throws {
        // Half-written JSON is normal — a poll can land mid-write. We still know the
        // session id from the file name, which is the part the merge needs.
        try write(
            "{\"type\":\"user\",\"cwd\":\"/Users/tester/Proj",
            to: "claude-projects/\(alphaSlug)/\(claudeSessionID).jsonl",
            secondsAgo: 60
        )
        let session = scan().first
        XCTAssertEqual(session?.sessionID, claudeSessionID)
        XCTAssertNil(session?.cwd)
    }

    func testAMissingRootIsNotAnError() {
        let sessions = PassiveSessionScanner.scan(
            claudeProjects: root.appendingPathComponent("nope-claude", isDirectory: true),
            codexSessions: root.appendingPathComponent("nope-codex", isDirectory: true),
            now: now
        )
        XCTAssertTrue(sessions.isEmpty)
    }

    // MARK: - Codex

    func testACodexRolloutBecomesAnApproximateSession() throws {
        try write(
            codexRollout(cwd: "/Users/tester/Projects/beta", sessionID: codexSessionID),
            to: "codex-sessions/2026/09/02/rollout-2026-09-02T10-00-00-\(codexSessionID).jsonl",
            secondsAgo: 10
        )

        let session = try XCTUnwrap(scan().first)
        XCTAssertEqual(session.id, "codex:\(codexSessionID)")
        XCTAssertEqual(session.sessionID, codexSessionID)
        XCTAssertEqual(session.source, .codex)
        XCTAssertEqual(session.cwd, "/Users/tester/Projects/beta")
        XCTAssertEqual(session.projectName, "Projects / beta")
        XCTAssertEqual(session.state, .working)
        XCTAssertTrue(session.isApproximate)
    }

    func testANonRolloutJSONLUnderTheCodexRootIsIgnored() throws {
        try write("{}\n", to: "codex-sessions/2026/09/02/history.jsonl", secondsAgo: 10)
        XCTAssertTrue(scan().isEmpty)
    }

    func testTheThreadIDComesFromTheFileNameWhenTheHeadIsUnreadable() throws {
        try write(
            "not json at all\n",
            to: "codex-sessions/2026/09/02/rollout-2026-09-02T10-00-00-\(codexSessionID).jsonl",
            secondsAgo: 10
        )
        let session = scan().first
        XCTAssertEqual(session?.sessionID, codexSessionID)
        XCTAssertEqual(session?.projectName, "Unknown project")
    }

    func testCodexSessionIDParsing() {
        XCTAssertEqual(
            PassiveSessionScanner.codexSessionID(fileName: "rollout-2026-08-06T14-30-14-019fd6d6-94a9-7611-a007-3c094955e537"),
            "019fd6d6-94a9-7611-a007-3c094955e537"
        )
        XCTAssertNil(PassiveSessionScanner.codexSessionID(fileName: "rollout-2026-08-06T14-30-14-not-a-uuid"))
        XCTAssertNil(PassiveSessionScanner.codexSessionID(fileName: "history"))
    }

    // MARK: - Both roots at once

    func testBothProvidersAreScannedInOnePass() throws {
        try write(
            claudeTranscript(cwd: "/Users/tester/Projects/alpha", sessionID: claudeSessionID),
            to: "claude-projects/\(alphaSlug)/\(claudeSessionID).jsonl",
            secondsAgo: 600
        )
        try write(
            codexRollout(cwd: "/Users/tester/Projects/beta", sessionID: codexSessionID),
            to: "codex-sessions/2026/09/02/rollout-2026-09-02T10-00-00-\(codexSessionID).jsonl",
            secondsAgo: 5
        )

        let sessions = scan()
        XCTAssertEqual(Set(sessions.map(\.id)), ["claude:\(claudeSessionID)", "codex:\(codexSessionID)"])
        XCTAssertEqual(sessions.first(where: { $0.source == .claude })?.state, .idle)
        XCTAssertEqual(sessions.first(where: { $0.source == .codex })?.state, .working)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/PassiveSessionScannerTests`
Expected: compile error — `cannot find 'PassiveSessionScanner' in scope`.

- [ ] **Step 3: Implement the scanner**

```swift
// UsageTracker/Agents/PassiveSessionScanner.swift
import Foundation

/// Sessions read straight from the CLIs' own logs, for when no hooks are installed —
/// and as a safety net when they are. Everything here is approximate: a file's
/// modification time says bytes were appended, not what the agent is waiting for, so
/// these sessions never claim `needsYou` and are flagged `isApproximate`.
///
/// Stateless on purpose: `AppState` calls it from a background task on every poll
/// tick, and the store owns all the memory.
enum PassiveSessionScanner {
    /// How much of a log we are willing to read looking for `cwd` / `session_meta`.
    /// Claude puts `cwd` on its first message record (~5 KB into a real transcript);
    /// Codex's `session_meta` line is ~19 KB because it embeds the base instructions.
    /// 64 KB clears both and can never pull in a multi-megabyte tool-result line.
    private static let headBytes = 64 * 1024
    /// Upper bound on JSON parses per file — a pathological log of tiny lines must not
    /// turn a poll tick into thousands of deserialisations.
    private static let maxHeadLines = 200

    static func scan(
        claudeProjects: URL,
        codexSessions: URL,
        now: Date = Date(),
        recentWindow: TimeInterval = 30 * 60,
        workingWindow: TimeInterval = 30
    ) -> [AgentSession] {
        scanClaude(root: claudeProjects, now: now, recentWindow: recentWindow, workingWindow: workingWindow)
            + scanCodex(root: codexSessions, now: now, recentWindow: recentWindow, workingWindow: workingWindow)
    }

    // MARK: - Claude Code

    /// `~/.claude/projects/<slug>/<session_id>.jsonl` — the transcript is named after
    /// the session, which is the same id the hooks send, so a passive row is replaced
    /// by the hook row instead of duplicating it.
    ///
    /// Only files whose grandparent is the root count. Below a project directory sits
    /// `<session_id>/subagents/**.jsonl` (and `subagents/workflows/*/journal.jsonl`) —
    /// side-transcripts of subagents, which the spec ignores, and which outnumber real
    /// transcripts by more than ten to one. The enumerator is pruned there too, so the
    /// per-minute scan never walks that tree.
    private static func scanClaude(
        root: URL, now: Date, recentWindow: TimeInterval, workingWindow: TimeInterval
    ) -> [AgentSession] {
        // Symlinks resolved on both sides: the temp dir the tests use is
        // /var/folders/… which is a link to /private/var/folders/….
        let rootPath = root.resolvingSymlinksInPath().path
        var sessions: [AgentSession] = []
        forEachRecentLog(root: root, now: now, recentWindow: recentWindow, descendInto: { directory in
            directory.deletingLastPathComponent().resolvingSymlinksInPath().path == rootPath
        }) { url, mtime in
            guard url.deletingLastPathComponent().deletingLastPathComponent()
                .resolvingSymlinksInPath().path == rootPath else { return }
            let sessionID = url.deletingPathExtension().lastPathComponent
            guard !sessionID.isEmpty else { return }
            let cwd = firstString(forKey: "cwd", in: url)
            sessions.append(makeSession(
                source: .claude,
                sessionID: sessionID,
                cwd: cwd,
                fallbackSlug: url.deletingLastPathComponent().lastPathComponent,
                mtime: mtime, now: now, workingWindow: workingWindow
            ))
        }
        return sessions
    }

    // MARK: - Codex

    /// `~/.codex/sessions/YYYY/MM/DD/rollout-<stamp>-<uuid>.jsonl`. The uuid in the
    /// name is the thread id, and the file's first line (`session_meta`) repeats it
    /// alongside `cwd` — we prefer the line because it is authoritative and we are
    /// reading the head for `cwd` anyway.
    private static func scanCodex(
        root: URL, now: Date, recentWindow: TimeInterval, workingWindow: TimeInterval
    ) -> [AgentSession] {
        var sessions: [AgentSession] = []
        forEachRecentLog(root: root, now: now, recentWindow: recentWindow, descendInto: { _ in true }) { url, mtime in
            let name = url.deletingPathExtension().lastPathComponent
            guard name.hasPrefix("rollout-") else { return }
            let head = codexHead(url)
            guard let sessionID = head.sessionID ?? codexSessionID(fileName: name) else { return }
            sessions.append(makeSession(
                source: .codex,
                sessionID: sessionID,
                cwd: head.cwd,
                fallbackSlug: nil,
                mtime: mtime, now: now, workingWindow: workingWindow
            ))
        }
        return sessions
    }

    /// The thread id is the trailing 36 characters of the file name:
    /// `rollout-2026-08-06T14-30-14-019fd6d6-94a9-7611-a007-3c094955e537`.
    static func codexSessionID(fileName: String) -> String? {
        guard fileName.hasPrefix("rollout-") else { return nil }
        let tail = String(fileName.suffix(36))
        guard tail.count == 36, UUID(uuidString: tail) != nil else { return nil }
        return tail
    }

    private static func codexHead(_ url: URL) -> (sessionID: String?, cwd: String?) {
        for line in headLines(of: url) {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            let payload = object["payload"] as? [String: Any]
            let id = (payload?["session_id"] as? String) ?? (payload?["id"] as? String)
            let cwd = (payload?["cwd"] as? String) ?? (object["cwd"] as? String)
            if id != nil || cwd != nil { return (nonEmpty(id), nonEmpty(cwd)) }
        }
        return (nil, nil)
    }

    // MARK: - Shared

    private static func makeSession(
        source: AgentSource, sessionID: String, cwd: String?, fallbackSlug: String?,
        mtime: Date, now: Date, workingWindow: TimeInterval
    ) -> AgentSession {
        // "Working" is the only thing an mtime can tell us: the CLI wrote to this log
        // moments ago. Anything older is just "open".
        let state: AgentState = mtime >= now.addingTimeInterval(-workingWindow) ? .working : .idle
        return AgentSession(
            id: AgentSessionStore.identifier(source: source, sessionID: sessionID),
            sessionID: sessionID,
            source: source,
            projectName: projectName(cwd: cwd, fallbackSlug: fallbackSlug),
            cwd: cwd,
            state: state,
            activity: nil,
            stateSince: mtime,
            lastEventAt: mtime,
            startedAt: mtime,
            host: AgentHostInfo(pid: nil, bundleID: nil, tty: nil),
            isApproximate: true,
            turns: 0,
            needsYouCount: 0
        )
    }

    private static func projectName(cwd: String?, fallbackSlug: String?) -> String {
        if let cwd, !cwd.isEmpty { return ProjectName.display(path: cwd) }
        if let fallbackSlug, !fallbackSlug.isEmpty { return ProjectName.decode(slug: fallbackSlug) }
        return "Unknown project"
    }

    /// Walks `root` for `.jsonl` files modified inside `recentWindow`. `descendInto`
    /// decides whether a directory is worth entering, which is what keeps the Claude
    /// scan out of the subagents trees.
    private static func forEachRecentLog(
        root: URL, now: Date, recentWindow: TimeInterval,
        descendInto: (URL) -> Bool,
        body: (URL, Date) -> Void
    ) {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = now.addingTimeInterval(-recentWindow)
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey]
            )
            if values?.isDirectory == true {
                if !descendInto(url) { enumerator.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true, url.pathExtension == "jsonl" else { continue }
            guard let mtime = values?.contentModificationDate, mtime >= cutoff else { continue }
            body(url, mtime)
        }
    }

    private static func firstString(forKey key: String, in url: URL) -> String? {
        for line in headLines(of: url) {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let value = object[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    /// Complete lines from the first `headBytes` of a log. A trailing partial line is
    /// dropped: a poll can land mid-write, and half a JSON object is not data.
    private static func headLines(of url: URL) -> [Data] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: headBytes), !data.isEmpty else { return [] }

        var lines: [Data] = []
        var lineStart = data.startIndex
        var index = data.startIndex
        while index < data.endIndex {
            if data[index] == 0x0A {
                if index > lineStart { lines.append(Data(data[lineStart..<index])) }
                lineStart = data.index(after: index)
                if lines.count >= maxHeadLines { return lines }
            }
            index = data.index(after: index)
        }
        return lines
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/PassiveSessionScannerTests`
Expected: PASS (13 tests).

- [ ] **Step 5: Commit**

```bash
git add UsageTracker/Agents/PassiveSessionScanner.swift UsageTrackerTests/PassiveSessionScannerTests.swift
git commit -m "Agents: passive session scan of the Claude and Codex logs

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

## Task 6: Wire the store into `AppState`

The socket feeds `apply`; the existing 60 s poll feeds `mergePassive` + `pruneStale`. Nothing new is scheduled: the poll loop already stops during sleep and screen lock (`AppState.isSuspended`, `UsageTracker/Core/AppState.swift:25`), which is exactly the cadence the spec asks for.

**Files:**
- Modify: `UsageTracker/Core/AppState.swift` (add a stored property near line 26, a call in `bootstrap()` at line 30-34, one new private method, and one call at the end of `performRefresh()` around line 164)

**Interfaces:**
- Consumes: `AgentEventServer(socketURL:onEvent:)`, `AgentEventServer.start()`, `AgentPaths.socketURL`, `AgentPaths.claudeProjectsURL`, `AgentPaths.codexSessionsURL` (package 1); `AgentSessionStore.shared`, `apply(_:now:)`, `mergePassive(_:now:)`, `pruneStale(now:)` (tasks 3-4); `PassiveSessionScanner.scan(claudeProjects:codexSessions:)` (task 5).
- Produces: nothing other packages call — this task only connects existing pieces.

- [ ] **Step 1: Check whether package 1 already starts the server**

Run: `grep -rn "AgentEventServer(" UsageTracker`
Expected: exactly one hit, the declaration in `UsageTracker/Agents/AgentEventServer.swift`.
If a second hit shows package 1 already constructing and starting a server somewhere (e.g. in `AppDelegate`), do **not** add a second one: instead set that instance's event handler to the closure from step 2 and skip the `startAgentChannel()` half of this task. Everything about the passive scan (steps 3-4) still applies.

- [ ] **Step 2: Start the socket and feed the store**

In `UsageTracker/Core/AppState.swift`, add the stored property directly after `private var suspensionObservers: [NSObjectProtocol] = []` (line 26):

```swift
    /// Hook events arrive here from the `omelette-hook` helper. Held for the life of
    /// the app; the socket file is recreated on every launch.
    private var agentEventServer: AgentEventServer?
```

and change `bootstrap()` (lines 30-34) to:

```swift
    func bootstrap() {
        observeSystemState()
        startAgentChannel()
        refreshNow()
        startTimer()
    }

    /// Opens the hook socket. A failure here is not fatal — without it the Agents
    /// section falls back to the passive scan, which is exactly the pre-opt-in
    /// experience the spec describes.
    private func startAgentChannel() {
        guard agentEventServer == nil else { return }
        let server = AgentEventServer(socketURL: AgentPaths.socketURL) { event in
            Task { @MainActor in
                AgentSessionStore.shared.apply(event)
            }
        }
        do {
            try server.start()
            agentEventServer = server
        } catch {
            NSLog("[UT] agent event server failed to start: %@", String(describing: error))
        }
    }
```

- [ ] **Step 3: Run the passive scan on the poll tick**

In `performRefresh()`, add one line at the very end, after
`NotificationCenter.default.post(name: .snapshotUpdated, object: nil)` (line 164):

```swift
        await scanAgentsPassively()
```

and add this method directly after `performRefresh()` (before `applyPayAsYouGo`):

```swift
    /// Sessions no hook has spoken for, read from the CLIs' own logs. Riding the poll
    /// tick means it inherits the 60-second cadence and, more importantly, the
    /// sleep/lock suspension — a laptop with the lid shut walks no log trees. The scan
    /// itself is file I/O over two directory trees, so it runs off the main actor and
    /// only the merge comes back.
    private func scanAgentsPassively() async {
        let claudeProjects = AgentPaths.claudeProjectsURL
        let codexSessions = AgentPaths.codexSessionsURL
        let scanned = await Task.detached(priority: .utility) {
            PassiveSessionScanner.scan(claudeProjects: claudeProjects, codexSessions: codexSessions)
        }.value
        AgentSessionStore.shared.mergePassive(scanned)
        AgentSessionStore.shared.pruneStale()
    }
```

- [ ] **Step 4: Build and confirm the wiring**

Run: `xcodegen generate && xcodebuild -project UsageTracker.xcodeproj -scheme UsageTracker -configuration Debug -derivedDataPath build/DerivedData build`
Expected: BUILD SUCCEEDED.

Run: `grep -n "scanAgentsPassively\|startAgentChannel\|AgentSessionStore.shared" UsageTracker/Core/AppState.swift`
Expected: `startAgentChannel` twice (call + definition), `scanAgentsPassively` twice, `AgentSessionStore.shared` three times (apply, mergePassive, pruneStale).

- [ ] **Step 5: Run the whole test suite**

Run: `xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData`
Expected: PASS — every pre-existing test plus the 4 new classes (`ProjectNameDisplayTests`, `AgentHistoryStoreTests`, `AgentSessionStoreTests`, `PassiveSessionScannerTests`). No test touches the real `~/.claude`, `~/.codex` or App Support directory, and `AppState.bootstrap()` never runs under the test host (`AppEnvironment.isRunningTests` guard in `UsageTracker/UsageTrackerApp.swift:52`).

- [ ] **Step 6: Smoke-test against the real logs**

Run: `open build/DerivedData/Build/Products/Debug/Omelette.app`
Then, in a terminal, start a Claude Code session in any project and wait for one poll tick (≤ 60 s).
Expected: no crash, no repeated `[UT] agent event server failed to start` in `log stream --predicate 'process == "Omelette"' --info`. There is no Agents UI yet (package 4), so verify the store instead — with the app running, confirm the scan is finding the live transcript by checking that the file it should match exists:
`ls -lt ~/.claude/projects/*/*.jsonl | head -3` — the newest file's name is the session id the store now holds as `claude:<that uuid>`.

- [ ] **Step 7: Commit**

```bash
git add UsageTracker/Core/AppState.swift
git commit -m "Agents: wire the session store to the socket and the poll tick

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

## Self-review notes

**Spec coverage.** "AgentSessionStore" bullet 1 (the `sessions` fields) → task 3 uses `AgentSession` verbatim from package 1. Bullet 2 (state machine + unknown events refresh only) → task 3, `testEveryClaudeTransition`, `testAnUnknownKindOnlyRefreshesActivity`. Bullet 3 (staleness, `SessionEnd` drops immediately) → task 4 `pruneStale`, task 3 `testSessionEndRemovesTheSession`. Bullet 4 (passive scan every poll tick, merged) → tasks 5 and 6. Bullet 5 (history on session end, no tool inputs) → task 2 (`testNoToolDetailIsEverWritten`) and task 3 (`testSessionEndWritesOneHistoryRecord`). "Passive fallback" section (30-min window, 30-s working rule, `cwd` from the log, `ProjectName`, "approximate", hook state wins) → task 5 plus task 4's merge tests. Codex `working` inferred passively → `testAPassiveWorkingUpgradesACodexSessionOnly`. Subagents ignored → task 3 (`isSubagent`) and task 5 (`testSubagentTranscriptsAreNotSessions`).

**Out of this package by design:** the helper, socket server, decoder and `AgentToolSummary` (package 1); the installer and Settings diagnostics (package 3); every view, the pill and notifications (packages 4-5) — `onNeedsYou`/`onDone` are left unassigned here, which is why no notification fires yet. `CHANGELOG.md` and the version bump belong to the phase-2 release package.

**Additions beyond the contract**, all listed under their task's "Produces": `ProjectName.display(path:)`; `AgentSessionStore.init(historyURL:)`, `AgentSessionStore.staleAfter`, `AgentSessionStore.identifier(source:sessionID:)`, `AgentSessionStore.projectName(for:)`; `PassiveSessionScanner.codexSessionID(fileName:)`. Nothing in the contract is renamed.

**Type consistency.** `AgentSessionStore.identifier(source:sessionID:)` is the single place `"\(source.rawValue):\(sessionID)"` is built — `makeSession` (task 3), `apply` (task 3) and `PassiveSessionScanner.makeSession` (task 5) all call it, so a passive row and a hook row for the same session always collide on the same id, which is what the whole merge rests on. `AgentSessionRecord`'s field order in task 2's implementation matches the memberwise initialiser the tests in tasks 2 and 4 call. `staleAfter` is referenced by name in the task 4 tests rather than duplicated as `7200`.

**Known risks, for the executor to watch.**
1. *Codex `thread-id` vs rollout uuid.* The merge assumes the `thread-id` Codex sends to `notify` is the uuid in the rollout file name (`019fd6d6-…`). That holds for every rollout on this machine, but it is not verified against a live `notify` payload — package 3's manual Codex test is where it gets proven. If they differ, nothing breaks: the hook session and the passive session simply appear as two rows, and the fix is a mapping in `mergePassive`, not a schema change.
2. *Claude `cwd` beyond 64 KB.* A transcript whose first 64 KB holds no `cwd` (a giant pasted first message) falls back to the dash slug for the project name — degraded, not wrong, and `testATranscriptWithoutACwdFallsBackToTheProjectSlug` pins that behaviour.
3. *History growth.* `agent-sessions.jsonl` has no rotation; at a few dozen sessions a day it is roughly 1.5 MB a year. `HistoryStore`'s 90-day rotation is the model to copy when the phase-3 dashboard starts reading it.
4. *`AgentHistoryStore.append` runs on the main actor* (the contract makes it a plain class, and the store is `@MainActor`). It is a ~150-byte append that happens once per session end, so it is not a hitch risk; if that ever changes, the fix is to move it behind an actor without touching the call sites.
