# Phase 4 — approve / deny Claude Code permission requests from Omelette

Part of the [roadmap](2026-09-02-agent-control-plane-roadmap.md). Ships as **2.2.0**.
Owner decisions (2026-09-02): presence-aware holding (below), Allow-once / Deny only,
Claude Code only (Codex has no approval hook), hold window 120 s, one-time hook
update (the `PermissionRequest` timeout grows from 5 s to 150 s).

## Behaviour

When Claude Code fires `PermissionRequest`, the `omelette-hook` helper connects as
today and now waits for a decision. Omelette decides how long to hold it:

| Situation at arrival | What happens |
|---|---|
| The app hosting that session (`session.host.pid` / `bundleID`) is the frontmost app | **Release immediately** (no decision) → Claude Code shows its usual terminal prompt. Nothing changes for terminal users. |
| Any other app is frontmost, the screen is locked, or the display is asleep | **Hold** up to 120 s. A notification with **Allow / Deny** actions appears; the popover row for that session shows the same two buttons and the tool summary. |
| Session has no host info (passive / unknown) or the feature is off | Release immediately (observe-only, as in 2.1). |

While held: the user's Allow/Deny answers the hook (`{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"|"deny"}}}` on the helper's stdout; Claude Code applies it and skips its prompt). Switching to the hosting app releases the hold at once (no decision → terminal prompt appears). Expiry (120 s) releases without a decision and withdraws the notification. Omelette quitting or crashing closes the socket → the helper sees EOF → no decision. A `Deny` is a one-off refusal of that tool call; Claude continues its turn.

## Security rules (acceptance tests)

1. **Fail closed**: the helper prints a decision only after receiving a well-formed reply carrying `allow` or `deny` AND its own request id; on timeout, EOF, malformed reply, id mismatch or any error it prints nothing and exits 0.
2. **Peer authentication**: the server accepts a connection only when `LOCAL_PEERCRED` reports the app's own uid; others are closed unanswered and counted in `droppedCount`.
3. **One-shot request id**: the helper generates a 128-bit random `request_id` per `PermissionRequest`; the app answers at most once per id; late or duplicate answers are ignored by both sides.
4. **No decision survives a restart**: pending requests live in memory only.
5. **Timeouts**: helper waits ≤ 140 s (watchdog `_exit(0)` at 145 s); hook registered with `timeout: 150`; app hold ≤ 120 s, so the app always gives up first and withdraws its UI before the helper can.
6. **Notification content**: tool name + truncated summary (existing `AgentToolSummary`, ≤ 80 chars); nothing else from the payload.
7. **No auto-allow anywhere**: only a user action on the notification or the popover produces `allow`.

## Protocol (wire v2, backward compatible)

Envelope gains `"request_id": "<32 hex>"` (present only for `PermissionRequest`) and
`"v": 2`. The app accepts v1 and v2. Reply line: `{"v":2,"request_id":"…","decision":"allow"|"deny"|null}`;
the immediate reply for every other event stays `{"v":1,"decision":null}`-compatible
(the helper ignores it).

## Components

### Helper (`HookHelper/`)
- `HookMain`: for `PermissionRequest` generate `request_id`, send, then `SocketClient.awaitDecision(fd:requestID:timeout: 140)` → prints the Claude decision JSON for `allow`/`deny`, nothing otherwise. Watchdog per event kind: 800 ms as today, 145 s for `PermissionRequest`.
- `SocketClient.send` returns the connected fd for the reply phase instead of closing.

### Server (`UsageTracker/Agents/AgentEventServer.swift`)
- Accept loop stays on the serial queue; each accepted connection is served on its own `DispatchQueue` (label `…agent-conn`) so a held request never blocks other hooks.
- `LOCAL_PEERCRED` check right after `accept`; failures → close + `droppedCount`.
- New callback shape: `onEvent: (AgentEvent, AgentReply) -> Void` where `AgentReply` is a `Sendable` handle with `func send(_ decision: PermissionDecision?)` (thread-safe, idempotent: first call writes the reply line and closes; later calls are no-ops) and `let requestID: String?`. For non-permission events the server calls `reply.send(nil)` itself after `onEvent` returns.
- `connectionTimeout` becomes per-kind: 1 s read budget as today; the write side waits until `send` (max 140 s, then closes without a reply).

### Broker (`UsageTracker/Agents/PermissionBroker.swift`, `@MainActor ObservableObject`)
```swift
enum PermissionDecision: String, Codable, Sendable { case allow, deny }

struct PendingPermission: Identifiable, Equatable, Sendable {
    let id: String                 // request_id
    let sessionID: String          // AgentSession.id ("claude:<uuid>")
    let toolName: String?
    let toolSummary: String?
    let receivedAt: Date
    let expiresAt: Date
}

@MainActor final class PermissionBroker: ObservableObject {
    static let shared: PermissionBroker
    @Published private(set) var pending: [PendingPermission]      // newest first
    var answeredCount: Int; var expiredCount: Int; var releasedForPresenceCount: Int   // diagnostics
    /// Called by AgentChannel for every permissionRequested event; decides hold vs release.
    func register(event: AgentEvent, reply: AgentReply, session: AgentSession?, now: Date = Date())
    func answer(id: String, _ decision: PermissionDecision)      // user action; idempotent
    func release(id: String)                                     // no decision (presence / expiry)
    func releaseAll(for sessionID: String)                       // host became frontmost
    func pending(for sessionID: String) -> PendingPermission?
    var onPending: ((PendingPermission) -> Void)?                 // notifications
    /// Called after the request has left `pending`, with why — package 2 withdraws
    /// the banner and, on `.expired`, puts the plain needs-you banner up instead.
    var onResolved: ((PendingPermission, PermissionResolution) -> Void)?
}

enum PermissionResolution: Equatable, Sendable {
    case answered(PermissionDecision)   // Allow / Deny from the notification or the row
    case releasedForPresence            // the hosting app became frontmost
    case expired                        // the 120 s hold ran out
}
```
**Ordering rule.** `AppState.bootstrap()` wires `AgentChannel.shared.onEvent` so that for a
`permissionRequested` event `PermissionBroker.shared.register(…)` runs **before**
`AgentSessionStore.shared.apply(event)`. The store fires `onNeedsYou` synchronously inside
`apply`, and the notifier vetoes that banner by asking `broker.pending(for:)`; registering
second would let the plain banner through next to the Allow/Deny one. Presence is checked
against `event.host` (every envelope carries it), falling back to the stored session's host
when the event's is `.none`; a session the store has never seen still gets held if its host
is known. `SettingsStore.agentsAnswerPermissions` (`Defaults` + `@AppStorage` + the reset line,
default `true`) is **package 1's** because the broker reads it; package 2 adds the toggle, the
caption and the settings tests.
Presence: `PresenceMonitor` (`UsageTracker/Agents/PresenceMonitor.swift`) observes
`NSWorkspace.didActivateApplicationNotification`, screen lock/unlock and
`NSWorkspace.screensDidSleepNotification`; exposes `func isUserAt(host: AgentHostInfo) -> Bool`
(frontmost app's pid == host.pid, or bundle id match when pid is nil; false when locked/asleep;
**2.2.3:** also false when that app has no ordinary window on screen — minimised, hidden with ⌘H
or on another Space — read from `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` by owner pid
and layer 0, failing open to "visible" if the list is unreadable. Because un-minimising fires no
NSWorkspace notification, the broker re-asks `isUserAt` once a second while anything is held
and releases holds whose terminal became visible.)
and `var onActivation: ((NSRunningApplication) -> Void)?` that the broker uses to
`releaseAll(for:)` sessions hosted by the activated app. Pure decision:
`PermissionBroker.shouldHold(userAtHost: Bool, featureEnabled: Bool, hasHost: Bool) -> Bool`.

### Session model
`AgentSession` gains `var pendingPermissionID: String?` (set/cleared by the broker via the store: `AgentSessionStore.setPendingPermission(id: String?, for sessionID: String)`). `AgentsSection` / `OMAgentRow` show Allow / Deny buttons when non-nil.

### Notifications (`UsageNotifier`)
Category `AGENT_PERMISSION` with actions `AGENT_ALLOW` ("Allow") and `AGENT_DENY` ("Deny", `.destructive`), identifier `agent-permission-<request_id>`, delivered on `onPending`, withdrawn on `onResolved`; bypasses quiet hours like needs-you (same toggle). Body: `"<tool summary>"`, title `"<project> wants to run <tool>"`. Tapping the body opens the popover. The existing needs-you notification is **not** sent while a permission request is pending for that session (the permission one supersedes it); it still fires for `Notification/permission_prompt` events that arrive without a `PermissionRequest`. When a hold ends `.expired` and the session is still `needsYou`, the notifier fires the plain needs-you banner (**Open**) for it — the terminal prompt is up and nobody was there to see the two-minute banner; `.answered` and `.releasedForPresence` replace the withdrawn banner with nothing. As a belt-and-braces against ordering, `onPending` also withdraws any needs-you banner already filed for that session.

### Settings → Agents
`@AppStorage("agentsAnswerPermissions") = true` ("Answer permission requests from Omelette when the terminal isn't in front"), caption explaining the presence rule and the 120 s window; diagnostics rows: pending, answered, expired, released-to-terminal. Hook template: `PermissionRequest` entry `timeout: 150` → existing installs read `outdated` → Update (one click); the prompt row copy mentions nothing new.

### Onboarding / docs
README + CHANGELOG `[2.2.0]`. No onboarding change.

## Packages (parallel planning)

1. **Protocol, helper, server, broker** — wire v2, helper decision path, per-connection server with `LOCAL_PEERCRED`, `AgentReply`, `PermissionBroker` + `PresenceMonitor` + `shouldHold` + `PermissionResolution`, `AgentChannel` wiring (`onEvent` signature change; package 2 of phase 2 assigned `AgentChannel.shared.onEvent` — update `AppState.bootstrap()` accordingly, register-before-apply), store field, the `agentsAnswerPermissions` settings key. Tests: helper E2E (allow/deny/none/timeout/id mismatch), server concurrency (a held connection does not delay a second hook), peer-cred rejection (unit-test the check with injected creds), broker table tests, presence pure rule.
2. **UI + settings + hook template** — notification category/actions/withdrawal, popover buttons, settings toggle + diagnostics, template timeout 150 with installer tests, CHANGELOG/README, version 2.2.0 / build 32.

Package 2 depends on package 1's interfaces (this doc is the contract).
