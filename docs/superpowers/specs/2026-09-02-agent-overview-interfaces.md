# Phase 2 — shared interfaces (contract for parallel package plans)

Companion to `2026-09-02-agent-overview-design.md`. Every phase-2 package plan
uses exactly these names and signatures; a plan that needs something more adds
it to its own package and lists it under "Produces", it never renames these.

## Paths and constants — `UsageTracker/Agents/AgentPaths.swift` (package 1)

```swift
enum AgentPaths {
    /// ~/Library/Application Support/UsageTracker/agent.sock
    static var socketURL: URL
    /// ~/Library/Application Support/UsageTracker/bin/omelette-hook (symlink → bundle helper)
    static var helperSymlinkURL: URL
    /// Omelette.app/Contents/Helpers/omelette-hook
    static var bundledHelperURL: URL
    /// ~/Library/Application Support/UsageTracker/agent-sessions.jsonl
    static var historyURL: URL
    static var claudeSettingsURL: URL      // ~/.claude/settings.json
    static var claudeProjectsURL: URL      // ~/.claude/projects
    static var codexConfigURL: URL         // ~/.codex/config.toml
    static var codexSessionsURL: URL       // ~/.codex/sessions
    static let helperVersion = 1
    static let wireVersion = 1
}
```

## Wire format (helper → app), one JSON object per line, UTF-8, ≤ 64 KB

```json
{
  "v": 1,
  "source": "claude",                 // "claude" | "codex"
  "helper_version": 1,
  "received_at": 1756800000.123,      // seconds since 1970, Double
  "host": { "pid": 4242, "bundle_id": "com.googlecode.iterm2", "tty": "/dev/ttys004" },   // any field may be null
  "payload": { ...raw hook JSON exactly as received... }
}
```

Reply (app → helper), optional, one line: `{"v":1,"decision":null}` — the helper
ignores it in phase 2. Absence of a reply within 500 ms is normal.

## Model — `UsageTracker/Agents/AgentModels.swift` (package 1 creates; package 2 extends the store)

```swift
enum AgentSource: String, Codable, Sendable { case claude, codex }

enum AgentState: String, Codable, Sendable, CaseIterable {
    case needsYou, working, done, idle
    /// Sort/grouping order: needsYou < working < done < idle
    var rank: Int
}

struct AgentHostInfo: Codable, Equatable, Sendable {
    var pid: Int32?
    var bundleID: String?
    var tty: String?
}

/// What the app reacts to. Decoded from the wire message; `kind` is derived
/// from `payload.hook_event_name` (+ `notification_type`) for Claude and from
/// `payload.type` for Codex.
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
    var projectName: String          // ProjectName(...) of cwd, or last path component
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
}
```

## Tool summary — `UsageTracker/Agents/AgentToolSummary.swift` (package 1)

```swift
enum AgentToolSummary {
    /// "Bash: xcodegen generate", "Edit: WalletView.swift", "Grep: usageStatusColor", "Read: PopoverView.swift"; nil when no detail.
    static func make(toolName: String?, toolInput: [String: Any]?) -> String?
    static let maxDetailLength = 80
}
```

## Event decoding — `UsageTracker/Agents/AgentEventDecoder.swift` (package 1)

```swift
enum AgentEventDecoder {
    /// Parses one wire line. Throws `AgentEventDecoder.Error` on malformed input.
    static func decode(_ line: Data) throws -> AgentEvent
    enum Error: Swift.Error { case notJSON, unsupportedVersion(Int), missingField(String), tooLarge }
}
```

## Socket server — `UsageTracker/Agents/AgentEventServer.swift` (package 1)

```swift
final class AgentEventServer: @unchecked Sendable {
    init(socketURL: URL, onEvent: @escaping @Sendable (AgentEvent) -> Void)
    func start() throws          // unlinks a stale socket file, binds, chmod 0600, listens
    func stop()
    private(set) var receivedCount: Int   // diagnostics
    private(set) var droppedCount: Int
}
```

## Store — `UsageTracker/Agents/AgentSessionStore.swift` (package 2)

```swift
@MainActor
final class AgentSessionStore: ObservableObject {
    static let shared: AgentSessionStore
    @Published private(set) var sessions: [AgentSession]      // sorted by state.rank, then lastEventAt desc
    @Published private(set) var lastEventAt: Date?
    var needsYouCount: Int
    var workingCount: Int
    func apply(_ event: AgentEvent, now: Date = Date())
    func mergePassive(_ scanned: [AgentSession], now: Date = Date())
    func pruneStale(now: Date = Date())                       // 2 h without events and host pid gone
    func sessions(for source: AgentSource) -> [AgentSession]
    /// Fires when a session enters `needsYou` (for notifications). Delivered on main.
    var onNeedsYou: ((AgentSession) -> Void)?
    var onDone: ((AgentSession) -> Void)?
}
```

State transitions (Claude): `sessionStart→idle`, `promptSubmitted→working`,
`toolStarted/toolFinished→working (+activity)`, `permissionRequested/notificationPermission→needsYou (+activity)`,
`notificationIdle→idle`, `stop→done`, `sessionEnd→remove`. Codex: `codexTurnComplete→done`;
passive merge may set `working`. Subagent events (`isSubagent`) are ignored.

## Passive scan — `UsageTracker/Agents/PassiveSessionScanner.swift` (package 2)

```swift
enum PassiveSessionScanner {
    static func scan(claudeProjects: URL, codexSessions: URL, now: Date = Date(),
                     recentWindow: TimeInterval = 30 * 60, workingWindow: TimeInterval = 30) -> [AgentSession]
}
```

## History — `UsageTracker/Agents/AgentHistoryStore.swift` (package 2)

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

## Installer — `UsageTracker/Agents/AgentHooksInstaller.swift` (package 3)

```swift
enum HookInstallStatus: Equatable { case installed, outdated, notInstalled, conflict(String) }

enum AgentHooksInstaller {
    // Claude (~/.claude/settings.json)
    static func claudeTemplate(helperPath: String) -> [String: Any]      // the "hooks" fragment we own
    static func claudeStatus(settingsURL: URL, helperPath: String) -> HookInstallStatus
    static func installClaude(settingsURL: URL, helperPath: String) throws
    static func removeClaude(settingsURL: URL, helperPath: String) throws
    // Codex (~/.codex/config.toml)
    static func codexNotifyLine(helperPath: String) -> String            // notify = ["…/omelette-hook", "--codex"]
    static func codexStatus(configURL: URL, helperPath: String) -> HookInstallStatus   // .conflict(existingLine) when notify is someone else's
    static func installCodex(configURL: URL, helperPath: String) throws
    static func removeCodex(configURL: URL, helperPath: String) throws
    enum Error: Swift.Error { case unparsable(URL), conflict(String) }
}
```

Our Claude entries are identified by `command` containing `UsageTracker/bin/omelette-hook`.
Events registered: `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`,
`PermissionRequest` (sync, `"timeout": 5`), `Notification` (matchers `permission_prompt`, `idle_prompt`),
`Stop`, `SessionEnd`; all except `PermissionRequest` carry `"async": true`.

## Settings keys — `UsageTracker/Core/Settings.swift` additions (package 3)

```swift
@AppStorage("agentsNotifyNeedsYou") var agentsNotifyNeedsYou: Bool = true
@AppStorage("agentsNeedsYouBypassQuietHours") var agentsNeedsYouBypassQuietHours: Bool = true
@AppStorage("agentsNotifyDone") var agentsNotifyDone: Bool = false
@AppStorage("agentsShowInMenuBar") var agentsShowInMenuBar: Bool = true
```

## Jump to session — `UsageTracker/Agents/SessionActivator.swift` (package 4)

```swift
enum SessionActivator {
    /// Activates the host app; Terminal.app / iTerm2 also get a tab-select attempt by tty. Falls back to revealing cwd in Finder.
    static func jump(to session: AgentSession)
}
```

## UI (packages 4 and 5) — built on the phase-1 design system

```swift
struct OMAgentRow: View { let session: AgentSession; var showsProviderIcon: Bool = true; let action: () -> Void }
struct AgentsSection: View { let sessions: [AgentSession]; let grouped: Bool; let hooksInstalled: Bool; let onEnable: () -> Void }
struct OMAgentsPill: View { let needsYou: Int; let working: Int; let total: Int }   // menu bar
```

`AgentsSection(grouped: true)` renders the `Needs you / Working / Done / Idle` groups (All tab);
`grouped: false` renders a flat list (provider tab). `OMSegmentItem.showsDot` is set from
`AgentSessionStore.sessions(for:)` containing a `needsYou` session.

## Helper target — `omelette-hook` (package 1)

- xcodegen target `OmeletteHook`, `type: tool`, `PRODUCT_NAME: omelette-hook`, Swift, no SwiftUI,
  sources `HookHelper/` (`main.swift`, `HostProcess.swift`, `SocketClient.swift`).
- Copied into the app at `Contents/Helpers/` (xcodegen `dependencies: - target: OmeletteHook, embed: true, copy: {destination: executables}` or an explicit copy-files phase — the plan decides and documents).
- Hardened runtime + Developer ID signing inherit from `signing.xcconfig`.
- Exit code always 0; total wall-clock cap 800 ms; never prints to stdout in phase 2.
