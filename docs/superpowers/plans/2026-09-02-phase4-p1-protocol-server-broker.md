# Phase 4 — Package 1: Protocol v2, Helper Decision Path, Held-Connection Server, PermissionBroker, PresenceMonitor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `PermissionRequest` hook can be answered from Omelette: the helper waits on the socket for an `allow`/`deny` carrying its own random request id, the server holds that one connection without blocking any other hook, and a main-actor `PermissionBroker` decides (via `PresenceMonitor`) whether to hold or release, expires holds after 120 s, and exposes `answer`/`release` for package 2's UI.

**Architecture:** Wire v2 adds `request_id` (only on `PermissionRequest`) and a reply line `{"v":2,"request_id":…,"decision":…}`. The helper fails closed: it prints Claude's decision JSON only for a well-formed reply with its own id, otherwise nothing, and always exits 0 (watchdog `_exit(0)`). In the app, `AgentEventServer` authenticates every peer with `LOCAL_PEERCRED`, serves each connection on its own queue, and hands a `Sendable` `AgentReply` (idempotent `send`) up through `AgentChannel.onEvent: (AgentEvent, AgentReply) -> Void`; `AppState.bootstrap()` routes held permission events to `PermissionBroker.shared`, which owns the pending list, the store's `pendingPermissionID`, expiry tasks and presence-driven release.

**Tech Stack:** Swift 6 (strict concurrency), Foundation + Darwin (POSIX sockets, `getsockopt(LOCAL_PEERCRED)`, `poll`, `shutdown`), `os.OSAllocatedUnfairLock`, AppKit (`NSWorkspace` in `PresenceMonitor` only), XCTest, xcodegen.

**Spec:** `docs/superpowers/specs/2026-09-02-phase4-approve-deny-design.md` (binding: behaviour table, security rules 1–7, protocol v2, component signatures — members may be added, never renamed). Roadmap: `docs/superpowers/specs/2026-09-02-agent-control-plane-roadmap.md` ("Phase 4"). Package 2 (UI, notifications, settings toggle, hook template `timeout: 150`, release) builds on the interfaces below.

## Global Constraints

- Deployment target macOS 14.0; `SWIFT_VERSION` 6.0, `SWIFT_STRICT_CONCURRENCY: minimal` (project-level; Swift 6 language mode still checks `Sendable` conformances). Every target compiles warning-free. No `nonisolated(unsafe)` and no new `@unchecked Sendable`; the only existing one in scope is `AgentEventServer` (mutable listener state, queue-confined — its written justification stays). `AgentReply` is a real `Sendable` class (lock-protected state, verified to compile under `-swift-version 6 -strict-concurrency=complete`).
- The helper (`HookHelper/`) links Foundation only — no AppKit, no Security framework. Its invariants: exit code always 0; never writes to stdout except the single Claude decision line for `PermissionRequest`; never logs or persists a payload; never blocks when Omelette is not listening (connect budget 300 ms as today).
- New source files are picked up by xcodegen from `sources:` (`UsageTracker/`, `UsageTrackerTests/`, `HookHelper/`): run `xcodegen generate` after adding a file and before building. `UsageTracker.xcodeproj/` is generated and gitignored — never `git add` it. `signing.xcconfig` is gitignored and must not be committed.
- Build: `xcodebuild -project UsageTracker.xcodeproj -scheme UsageTracker -configuration Debug -derivedDataPath build/DerivedData build`.
  Tests: `xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS=""` (add `-only-testing:UsageTrackerTests/<Class>` for one class). **`ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS=""` are mandatory on every `xcodebuild test`** — `signing.xcconfig` enables the hardened runtime, which blocks the `DYLD_INSERT_LIBRARIES` injection XCTest needs, and the runner hangs ~6 min otherwise. Every `xcodebuild test` line below is written with the overrides.
- In a git worktree: copy `signing.xcconfig` from the main checkout first and use a worktree-local `-derivedDataPath`.
- Server invariants (phase 2 spec, unchanged): socket file 0600, JSON only, ≤ 64 KB per message, parsed into fixed types, malformed input dropped and counted, nothing received is executed or persisted. New (spec rule 2): a connection whose `LOCAL_PEERCRED` uid is not the app's own uid is closed unanswered and counted.
- Security rules 1–7 of the spec are acceptance tests; the tests named in each task below are the ones that cover them (rule 1 → Task 5, rule 2 → Task 4, rule 3 → Tasks 3/5/7, rule 4 → Task 7 (in-memory only, nothing written), rule 5 → Tasks 4/5/7 constants, rule 6 → Task 7 (`PendingPermission` carries only `toolName` + `toolSummary`), rule 7 → Task 7 (only `answer(id:_:)` produces `.allow`)).
- Logging: `NSLog("[UT] …")`; log lines may carry an event kind, a request-id prefix and a session-id prefix, never `tool_input`, `cwd` contents or summaries.
- Commits end with the trailer lines
  `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` and
  `Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X`.
- Other sessions may commit the working tree while you work: re-read a file right before editing it; prefer targeted edits over whole-file rewrites.
- Out of scope here (package 2): notification category/actions, popover buttons, the Settings toggle/caption + diagnostics rows and their `SettingsStoreTests` lines, the hook template `timeout: 150`, CHANGELOG/README, version 2.2.0 / build 32. **Do not touch `AgentHooksInstaller.swift`, `UsageNotifier.swift`, `AgentsSettingsView.swift`.** In `Settings.swift` package 1 adds exactly the `agentsAnswerPermissions` key (default, property, reset line) and nothing else.

---

## Facts verified while planning (2026-09-02)

- **`LOCAL_PEERCRED` from Swift.** `/usr/include/sys/un.h`: `SOL_LOCAL 0`, `LOCAL_PEERCRED 0x001`, `LOCAL_PEERPID 0x002`. `/usr/include/sys/ucred.h`: `struct xucred { u_int cr_version; uid_t cr_uid; short cr_ngroups; gid_t cr_groups[NGROUPS]; }`, `XUCRED_VERSION 0`, 76 bytes. A scratch program compiled with `-swift-version 6 -strict-concurrency=complete` (Foundation only) ran `getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &creds, &len)` on a `socketpair` and on an accepted Unix socket: `rc=0`, `cr_version=0`, `cr_uid=501 == getuid()`, `len=76`. `XUCRED_VERSION` imports as `Int32`.
- **Socket semantics used by the hold.** On the accepted socket, `write(line)` followed by `shutdown(fd, SHUT_RDWR)` delivers the line, then EOF, to the peer (measured: peer reads 8 bytes, then 0), and wakes a `poll(POLLIN)` on the same fd in another thread with `revents = POLLIN|POLLHUP` (17). Accepted sockets inherit `O_NONBLOCK` from the listener on macOS (measured `true`), so a ≤ 100-byte reply write from the main thread never blocks. `SO_NOSIGPIPE` is inherited from the listener (existing comment in `AgentEventServer.startOnQueue`), so a write to a dead helper is `EPIPE`, not a signal.
- **Claude Code `PermissionRequest` hook** (https://code.claude.com/docs/en/hooks, fetched 2026-09-02): fires "when a tool call needs a permission decision" (the moment the dialog would be shown). Decision output is `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}` / `{"behavior":"deny","message":"…"}` (`message` optional). "When the hook exits 0 with no JSON output, the permission dialog is shown as normal." Exit code 2 is *not* honoured for this event. The hook `timeout` field is "Seconds before canceling" (default 600 for `command` hooks); a timed-out hook's output is discarded and "the call continues through the normal permission flow". `async: true` is not applicable to `PermissionRequest` (decision events are synchronous). The current template registers it with `"timeout": 5` (`AgentHooksInstaller.claudeTemplate`, line 60) — package 2 raises it to 150.
- **Helper randomness without Security.framework.** `FileHandle(forReadingAtPath: "/dev/urandom")?.read(upToCount: 16)` returns 16 bytes (measured); hex-encoded → 32 chars.
- **`DispatchWorkItem.cancel()`** prevents a not-yet-started `asyncAfter` item from running (measured) — the watchdog can be re-armed once the event kind is known.

## Decisions locked in this plan

**Hold = one blocked GCD worker per held connection, on a per-connection serial queue.** `serve` reads the line on the connection's own queue (1 s budget as today), decodes, delivers on main, and — for a held `PermissionRequest` — stays on that queue in `poll(fd, POLLIN, ≤ 140 s)`. `AgentReply.send` (any thread) writes the reply line and `shutdown(SHUT_RDWR)`s the socket, which wakes that `poll`; the connection queue is the *only* place the descriptor is closed. The helper hanging up early is the same wake-up (`read` → 0) and is surfaced as `AgentReply.onPeerClosed` so the broker can withdraw the request instead of showing Allow/Deny for a hook that is already gone (this matters during the 2.2.0 upgrade window: installs still on `timeout: 5` have Claude Code kill the helper after 5 s until the user clicks Update). A DispatchSource-based EOF watch was rejected: `DispatchSourceRead` is not `Sendable`, so `AgentReply` could not own it without `@unchecked`.

**Ordering.** Delivery is `DispatchQueue.main.async` from the connection queue as soon as a line is decoded, and helpers write their whole line within microseconds of connecting, so accept order is delivery order in practice; the existing `testRapidClientsArriveInOrder` (sequential clients) keeps passing. Two genuinely concurrent helpers were never ordered by the server anyway (their `connect`s race before we accept).

**Immediate replies stay exactly `{"v":1,"decision":null}`.** Every non-permission event, and a `PermissionRequest` without a valid `request_id` (a v1 helper still linked from an old symlink target), is answered on the connection queue *before* `onEvent` runs, with the unchanged `AgentEventServer.reply` constant; `onEvent` receives an already-settled `AgentReply` (`requestID == nil`, `isSettled == true`, `send` a no-op). This is the "for non-permission events the server calls `reply.send(nil)` itself" clause of the spec made concrete — the tests that read the reply synchronously (`AgentSocketTestClient.send` before spinning the main run loop) depend on it.

**`AgentEvent.requestID` is decoded, `AgentEventServer` decides.** The decoder keeps a `request_id` only when it is exactly 32 lowercase hex characters; the server holds only when `event.kind == .permissionRequested && event.requestID != nil`. Version gate: `AgentPaths.supportedWireVersions = 1...2`; `AgentPaths.wireVersion` (what the app speaks) and `helperVersion` become 2.

**Helper watchdog re-arm.** The 800 ms watchdog is armed first, as today (nothing below may hang the agent). Only after the line has been *written to a listening Omelette* does a `PermissionRequest` helper cancel it and arm the 145 s one, then wait ≤ 140 s for the decision. Omelette not running → connect fails → exit 0 within 300 ms, unchanged. `OMELETTE_DECISION_TIMEOUT` (seconds, clamped to `0 < t ≤ 140`) shortens the wait for tests and is honoured only when the socket override was honoured (same allow-listed roots as `OMELETTE_AGENT_SOCKET`); shortening can only ever produce "no decision", so it is not an attack surface.

**Broker before store (spec ordering rule).** For a `.permissionRequested` event `AppState.bootstrap()` calls `PermissionBroker.shared.register(…)` *before* `AgentSessionStore.shared.apply(event)`, so that when `apply` fires `onNeedsYou` synchronously, `broker.pending(for:)` already answers. Because the session may not exist yet at `register` time (hooks enabled mid-session, first event is a `PermissionRequest`), `AgentSessionStore.setPendingPermission(id:for:)` records the id in a private `pendingPermissionIDs: [sessionID: requestID]` map *and* patches the row if present; `apply` copies the map entry onto the row on every upsert and drops the entry when the session leaves `needsYou` or ends. Presence is evaluated against `event.host`, falling back to `session?.host` when the event's is `.none`.

**Feature flag.** `SettingsStore.agentsAnswerPermissions` (`Defaults` + `@AppStorage` + reset line, default `true`) is added here; the broker reads it through an injectable `featureEnabled: () -> Bool` whose default is `{ SettingsStore.shared.agentsAnswerPermissions }`. Package 2 adds the toggle, caption and settings tests.

**`onResolved` fires after removal.** `PermissionResolution` (`.answered(decision)`, `.releasedForPresence`, `.expired`) is passed to `onResolved` only once the request has left `pending` and the store field is cleared, so package 2 can re-fire the plain needs-you banner on `.expired` with `pending(for:)` already nil. A helper that hangs up early (`AgentReply.onPeerClosed`) is resolved as `.expired`: from the user's point of view the hold is over and Claude Code is showing its own prompt.

## File structure

```
HookHelper/
  main.swift                      MODIFY: v2 envelope, request_id, decision wait, per-kind watchdog, decision stdout
  SocketClient.swift              MODIFY: send returns the fd; awaitDecision(fd:requestID:timeout:)
UsageTracker/Agents/
  AgentPaths.swift                MODIFY: helperVersion/wireVersion = 2, supportedWireVersions, decisionTimeoutEnvironmentKey
  AgentModels.swift               MODIFY: AgentEvent.requestID, AgentSession.pendingPermissionID (+ explicit inits)
  AgentEventDecoder.swift         MODIFY: accept v1…v2, parse/validate request_id
  AgentReply.swift                CREATE: PermissionDecision, AgentReply (Sendable, idempotent send, peer-closed hook)
  AgentEventServer.swift          MODIFY: peer uid check, per-connection queues, hold, rejectedPeerCount, holdTimeout
  AgentSessionStore.swift         MODIFY: setPendingPermission(id:for:), clearing on leaving needsYou
  AgentChannel.swift              MODIFY: onEvent: (AgentEvent, AgentReply) -> Void
  PresenceMonitor.swift           CREATE: frontmost/lock/sleep presence, onActivation
  PermissionBroker.swift          CREATE: pending list, hold/release decision, expiry, answer/release
UsageTracker/Core/AppState.swift  MODIFY: bootstrap() routes permission events to the broker (register before apply)
UsageTracker/Core/Settings.swift  MODIFY: agentsAnswerPermissions default + @AppStorage + reset line
UsageTracker/UsageTrackerApp.swift MODIFY: PresenceMonitor.shared.start() after AgentChannel.shared.start()
UsageTrackerTests/
  AgentFixtures.swift             MODIFY: envelope(requestID:), requestID constant, held client (open/readLine), replyPair
  AgentPathsTests.swift           MODIFY: version constants
  AgentEventDecoderTests.swift    MODIFY: v2 accepted, v3 rejected, request_id parsing
  AgentReplyTests.swift           CREATE
  AgentEventServerTests.swift     MODIFY: new callback shape; hold / peer / idempotence / timeout tests
  OmeletteHookEndToEndTests.swift MODIFY: launch/finish split; allow / deny / none / mismatch / malformed
  AgentChannelTests.swift         MODIFY: new callback shape; default consumer answers a hold
  AgentSessionStoreTests.swift    MODIFY: pendingPermissionID tests
  PresenceMonitorTests.swift      CREATE
  PermissionBrokerTests.swift     CREATE
```

Task order: 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8. Task 4 changes the `onEvent` shape and must leave every caller compiling (channel, `AppState`, three test files); Task 8 only adds the broker routing.

---

### Task 1: Wire v2 in the models, paths and decoder

**Files:**
- Modify: `UsageTracker/Agents/AgentPaths.swift:35-41`
- Modify: `UsageTracker/Agents/AgentModels.swift` (`AgentEvent`, `AgentSession`)
- Modify: `UsageTracker/Agents/AgentEventDecoder.swift:17-28`
- Modify: `UsageTrackerTests/AgentFixtures.swift:36-44` (`envelope`)
- Modify: `UsageTrackerTests/AgentPathsTests.swift:24-25`
- Test: `UsageTrackerTests/AgentEventDecoderTests.swift`, `UsageTrackerTests/AgentModelsTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  ```swift
  enum AgentPaths {
      static let helperVersion = 2
      static let wireVersion = 2                                  // what the app speaks (reply lines)
      static let supportedWireVersions: ClosedRange<Int> = 1...2  // addition: what the decoder accepts
      static let decisionTimeoutEnvironmentKey = "OMELETTE_DECISION_TIMEOUT"   // addition: helper test override
      static let requestIDLength = 32                             // addition: hex chars of a 128-bit id
  }
  struct AgentEvent {  // existing fields unchanged, plus:
      let requestID: String?        // 32 lowercase hex chars, only ever set on PermissionRequest; nil otherwise
      init(source:kind:sessionID:cwd:toolName:toolSummary:isSubagent:host:receivedAt:requestID: = nil)
  }
  struct AgentSession {  // existing fields unchanged, plus:
      var pendingPermissionID: String?     // set/cleared only through AgentSessionStore.setPendingPermission
      init(… existing labels …, pendingPermissionID: String? = nil)
  }
  enum AgentEventDecoder {
      static func validRequestID(_ value: Any?) -> String?   // addition: exactly 32 of [0-9a-f], else nil
  }
  // Tests:
  enum AgentFixture {
      static let requestID = "0123456789abcdef0123456789abcdef"
      static func envelope(source: = "claude", payload:, v: Int = 2, receivedAt:, host:, requestID: String? = nil) -> Data
  }
  ```

- [ ] **Step 1: Update the fixtures**

Replace `envelope(...)` in `UsageTrackerTests/AgentFixtures.swift` (lines 36–44) with:

```swift
    /// A 128-bit request id as the helper prints it: 32 lowercase hex characters.
    static let requestID = "0123456789abcdef0123456789abcdef"

    /// The helper's envelope. `v` defaults to the current wire version; pass 1 for a
    /// pre-2.2 helper. `requestID` is only ever present on a `PermissionRequest`.
    static func envelope(
        source: String = "claude",
        payload: String,
        v: Int = 2,
        receivedAt: Double = 1_756_800_000.123,
        host: String = AgentFixture.hostJSON,
        requestID: String? = nil
    ) -> Data {
        let id = requestID.map { #","request_id":"\#($0)""# } ?? ""
        return Data(#"{"v":\#(v),"source":"\#(source)","helper_version":\#(v),"received_at":\#(receivedAt),"host":\#(host)\#(id),"payload":\#(payload)}"#.utf8)
    }
```

- [ ] **Step 2: Write the failing tests**

In `UsageTrackerTests/AgentPathsTests.swift` replace lines 24–25 with:

```swift
        XCTAssertEqual(AgentPaths.helperVersion, 2)
        XCTAssertEqual(AgentPaths.wireVersion, 2)
        XCTAssertEqual(AgentPaths.supportedWireVersions, 1...2)
        XCTAssertEqual(AgentPaths.decisionTimeoutEnvironmentKey, "OMELETTE_DECISION_TIMEOUT")
        XCTAssertEqual(AgentPaths.requestIDLength, 32)
```

In `UsageTrackerTests/AgentEventDecoderTests.swift` replace `testRejectsOtherWireVersions` with:

```swift
    func testAcceptsV1AndV2RejectsOthers() throws {
        XCTAssertEqual(try AgentEventDecoder.decode(AgentFixture.envelope(payload: AgentFixture.stop, v: 1)).kind, .stop)
        XCTAssertEqual(try AgentEventDecoder.decode(AgentFixture.envelope(payload: AgentFixture.stop, v: 2)).kind, .stop)
        XCTAssertThrowsError(try AgentEventDecoder.decode(AgentFixture.envelope(payload: AgentFixture.stop, v: 3))) { error in
            XCTAssertEqual(error as? AgentEventDecoder.Error, .unsupportedVersion(3))
        }
        let noVersion = Data(#"{"source":"claude","payload":\#(AgentFixture.stop)}"#.utf8)
        XCTAssertThrowsError(try AgentEventDecoder.decode(noVersion)) { error in
            XCTAssertEqual(error as? AgentEventDecoder.Error, .missingField("v"))
        }
    }

    // MARK: Request id (wire v2)

    func testPermissionRequestCarriesItsRequestID() throws {
        let data = AgentFixture.envelope(payload: AgentFixture.permissionRequestEdit, requestID: AgentFixture.requestID)
        let event = try AgentEventDecoder.decode(data)
        XCTAssertEqual(event.kind, .permissionRequested)
        XCTAssertEqual(event.requestID, AgentFixture.requestID)
    }

    func testRequestIDIsNilWhenAbsentOrMalformed() throws {
        XCTAssertNil(try AgentEventDecoder.decode(AgentFixture.envelope(payload: AgentFixture.permissionRequestEdit)).requestID,
                     "a v1 helper sends no id")
        for bad in ["", "0123", String(repeating: "g", count: 32), AgentFixture.requestID.uppercased(),
                    AgentFixture.requestID + "0", "\"; drop table"] {
            let data = AgentFixture.envelope(payload: AgentFixture.permissionRequestEdit, requestID: bad)
            XCTAssertNil(try AgentEventDecoder.decode(data).requestID, "accepted \(bad)")
        }
        let numeric = Data(#"{"v":2,"source":"claude","request_id":42,"payload":\#(AgentFixture.permissionRequestEdit)}"#.utf8)
        XCTAssertNil(try AgentEventDecoder.decode(numeric).requestID)
    }

    func testRequestIDIsIgnoredOnOtherEvents() throws {
        let data = AgentFixture.envelope(payload: AgentFixture.preToolUseBash, requestID: AgentFixture.requestID)
        XCTAssertNil(try AgentEventDecoder.decode(data).requestID, "only a PermissionRequest can be held")
    }
```

Append to `UsageTrackerTests/AgentModelsTests.swift` (inside the class):

```swift
    func testEventAndSessionDefaultTheirPhase4Fields() {
        let now = Date(timeIntervalSince1970: 1_756_800_000)
        let event = AgentEvent(source: .claude, kind: .stop, sessionID: "s", cwd: nil, toolName: nil,
                               toolSummary: nil, isSubagent: false, host: .none, receivedAt: now)
        XCTAssertNil(event.requestID)
        let session = AgentSession(sessionID: "s", source: .claude, projectName: "p", cwd: nil,
                                   state: .idle, stateSince: now, lastEventAt: now, startedAt: now)
        XCTAssertNil(session.pendingPermissionID)
        var copy = session
        copy.pendingPermissionID = "abc"
        XCTAssertNotEqual(copy, session, "the pending id takes part in equality so the popover redraws")
    }
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS="" -only-testing:UsageTrackerTests/AgentEventDecoderTests -only-testing:UsageTrackerTests/AgentPathsTests -only-testing:UsageTrackerTests/AgentModelsTests`
Expected: compile errors — `extra argument 'requestID' in call`, `type 'AgentPaths' has no member 'supportedWireVersions'`, `value of type 'AgentEvent' has no member 'requestID'`.

- [ ] **Step 4: Bump the constants**

In `UsageTracker/Agents/AgentPaths.swift` replace lines 35–41 with:

```swift
    /// Bumped together with the helper: 2 = phase 4 (request ids + decisions).
    static let helperVersion = 2
    /// The wire version this app speaks (its reply lines carry it).
    static let wireVersion = 2
    /// Envelope versions the decoder still accepts. A pre-2.2 helper (old symlink
    /// target still running) sends v1 and gets the phase-2 behaviour: no hold.
    static let supportedWireVersions: ClosedRange<Int> = 1...2
    static let helperName = "omelette-hook"
    /// Set in the helper's environment to redirect it to another socket (tests use a temp path).
    static let socketEnvironmentKey = "OMELETTE_AGENT_SOCKET"
    /// Shortens the helper's decision wait (seconds) — tests only; honoured only
    /// together with a socket override, and never above the production 140 s.
    static let decisionTimeoutEnvironmentKey = "OMELETTE_DECISION_TIMEOUT"
    /// A request id is 128 random bits as lowercase hex.
    static let requestIDLength = 32
    /// `sockaddr_un.sun_path` holds 104 bytes including the terminating NUL.
    static let maxSocketPathBytes = 103
```

- [ ] **Step 5: Extend the models**

In `UsageTracker/Agents/AgentModels.swift` replace the body of `struct AgentEvent` after `enum Kind` (lines 49–57) with:

```swift
    let source: AgentSource
    let kind: Kind
    let sessionID: String            // Claude session_id / Codex thread-id
    let cwd: String?
    let toolName: String?
    let toolSummary: String?         // AgentToolSummary.make(toolName:toolInput:)
    let isSubagent: Bool             // payload has agent_id
    let host: AgentHostInfo
    let receivedAt: Date
    /// Wire v2: the helper's one-shot id for a `PermissionRequest` it is waiting on.
    /// nil for every other event and for a v1 helper.
    let requestID: String?

    init(
        source: AgentSource,
        kind: Kind,
        sessionID: String,
        cwd: String?,
        toolName: String?,
        toolSummary: String?,
        isSubagent: Bool,
        host: AgentHostInfo,
        receivedAt: Date,
        requestID: String? = nil
    ) {
        self.source = source
        self.kind = kind
        self.sessionID = sessionID
        self.cwd = cwd
        self.toolName = toolName
        self.toolSummary = toolSummary
        self.isSubagent = isSubagent
        self.host = host
        self.receivedAt = receivedAt
        self.requestID = requestID
    }
```

In `struct AgentSession` add after `var needsYouCount: Int`:

```swift
    /// The `request_id` of a permission request Omelette is holding for this session
    /// (Allow / Deny buttons in the popover). Owned by `PermissionBroker`, written only
    /// through `AgentSessionStore.setPendingPermission(id:for:)`.
    var pendingPermissionID: String?
```

and extend the init: add the parameter `pendingPermissionID: String? = nil` after `needsYouCount: Int = 0`, and `self.pendingPermissionID = pendingPermissionID` as the last assignment.

- [ ] **Step 6: Decode v1 and v2, validate the id**

In `UsageTracker/Agents/AgentEventDecoder.swift` replace line 22 with:

```swift
        guard AgentPaths.supportedWireVersions.contains(version) else { throw Error.unsupportedVersion(version) }
```

Replace line 28 (`let host = …`) and the `switch source` block (lines 30–33) with:

```swift
        let host = decodeHost(envelope["host"] as? [String: Any])
        let requestID = validRequestID(envelope["request_id"])

        switch source {
        case .claude: return try claudeEvent(payload: payload, host: host, receivedAt: receivedAt, requestID: requestID)
        case .codex: return try codexEvent(payload: payload, host: host, receivedAt: receivedAt)
        }
    }

    /// The only shape the server will ever echo back: 32 lowercase hex characters.
    /// Anything else is treated as "no id" — the request is answered immediately
    /// like a v1 event instead of being held for an id the helper could not match.
    static func validRequestID(_ value: Any?) -> String? {
        guard let id = value as? String, id.utf8.count == AgentPaths.requestIDLength,
              id.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) })
        else { return nil }
        return id
```

Change `claudeEvent`'s signature to `(payload: [String: Any], host: AgentHostInfo, receivedAt: Date, requestID: String?)` and its `return AgentEvent(` to pass `requestID: kind == .permissionRequested ? requestID : nil` after `receivedAt: receivedAt`. `codexEvent` is unchanged (its `AgentEvent(...)` call takes the `nil` default).

- [ ] **Step 7: Run the tests to verify they pass**

Run: `xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS="" -only-testing:UsageTrackerTests/AgentEventDecoderTests -only-testing:UsageTrackerTests/AgentPathsTests -only-testing:UsageTrackerTests/AgentModelsTests`
Expected: PASS (decoder 19, paths 6, models 6). Every other test target still compiles: `AgentSessionStoreTests.event(...)` and `Fixture.agentSession(...)` use the defaults.

- [ ] **Step 8: Commit**

```bash
git add UsageTracker/Agents/AgentPaths.swift UsageTracker/Agents/AgentModels.swift UsageTracker/Agents/AgentEventDecoder.swift UsageTrackerTests/AgentFixtures.swift UsageTrackerTests/AgentPathsTests.swift UsageTrackerTests/AgentEventDecoderTests.swift UsageTrackerTests/AgentModelsTests.swift
git commit -m "Agents: wire v2 — request ids on the event, pending id on the session

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

### Task 2: `AgentSessionStore.setPendingPermission(id:for:)` and clearing on leaving `needsYou`

**Files:**
- Modify: `UsageTracker/Agents/AgentSessionStore.swift` (`apply`, new method, one private map)
- Test: `UsageTrackerTests/AgentSessionStoreTests.swift`

**Interfaces:**
- Consumes: `AgentSession.pendingPermissionID` (Task 1).
- Produces:
  ```swift
  extension AgentSessionStore {
      /// Broker-owned. Remembers the id even for a session the store has not seen yet
      /// (register runs before apply), patches the row when present, publishes.
      func setPendingPermission(id: String?, for sessionID: String)
  }
  ```
  Rules: `apply` copies the remembered id onto the row on every upsert; the id is dropped when the session's state after the event is not `needsYou` (tool started/finished, prompt, stop, idle notification) and on `sessionEnd`; `notificationPermission` and a repeated `permissionRequested` keep it.

- [ ] **Step 1: Write the failing tests**

Append inside `AgentSessionStoreTests` (before `// MARK: - Passive fixtures`):

```swift
    // MARK: - Pending permission (phase 4)

    func testSetPendingPermissionPatchesTheRowAndPublishes() {
        let store = makeStore()
        store.apply(event(.permissionRequested), now: t0)
        var emissions = 0
        let cancellable = store.$sessions.dropFirst().sink { _ in emissions += 1 }
        defer { cancellable.cancel() }

        store.setPendingPermission(id: AgentFixture.requestID, for: "claude:s1")
        XCTAssertEqual(store.sessions.first?.pendingPermissionID, AgentFixture.requestID)
        XCTAssertEqual(emissions, 1)

        store.setPendingPermission(id: AgentFixture.requestID, for: "claude:s1")
        XCTAssertEqual(emissions, 1, "same value, no redraw")

        store.setPendingPermission(id: nil, for: "claude:s1")
        XCTAssertNil(store.sessions.first?.pendingPermissionID)
        XCTAssertEqual(emissions, 2)
    }

    func testPendingPermissionSetBeforeTheSessionExistsLandsOnTheRow() {
        // Bootstrap registers with the broker before applying the event, so the very
        // first thing the store hears about a session can be its pending id.
        let store = makeStore()
        store.setPendingPermission(id: AgentFixture.requestID, for: "claude:s1")
        XCTAssertTrue(store.sessions.isEmpty, "remembering an id does not invent a row")

        store.apply(event(.permissionRequested), now: t0)
        XCTAssertEqual(store.sessions.first?.state, .needsYou)
        XCTAssertEqual(store.sessions.first?.pendingPermissionID, AgentFixture.requestID)
    }

    func testPendingPermissionClearsWhenTheSessionLeavesNeedsYou() {
        let leaving: [(AgentEvent.Kind, String)] = [
            (.toolStarted, "tool started"), (.toolFinished, "tool finished"), (.promptSubmitted, "prompt"),
            (.stop, "stop"), (.notificationIdle, "idle"), (.sessionStart, "session start"),
        ]
        for (kind, label) in leaving {
            let store = makeStore()
            store.apply(event(.permissionRequested), now: t0)
            store.setPendingPermission(id: AgentFixture.requestID, for: "claude:s1")
            store.apply(event(kind), now: at(1))
            XCTAssertNil(store.sessions.first?.pendingPermissionID, label)
            // And it stays cleared: a later apply must not resurrect it from the map.
            store.apply(event(.permissionRequested), now: at(2))
            XCTAssertNil(store.sessions.first?.pendingPermissionID, "\(label): stale id came back")
        }
    }

    func testPendingPermissionSurvivesEventsThatStayInNeedsYou() {
        let store = makeStore()
        store.apply(event(.permissionRequested), now: t0)
        store.setPendingPermission(id: AgentFixture.requestID, for: "claude:s1")
        store.apply(event(.notificationPermission), now: at(1))
        XCTAssertEqual(store.sessions.first?.pendingPermissionID, AgentFixture.requestID)
        store.apply(event(.unknown("PreCompact")), now: at(2))
        XCTAssertEqual(store.sessions.first?.pendingPermissionID, AgentFixture.requestID)
    }

    func testSessionEndForgetsThePendingPermission() {
        let store = makeStore()
        store.apply(event(.permissionRequested), now: t0)
        store.setPendingPermission(id: AgentFixture.requestID, for: "claude:s1")
        store.apply(event(.sessionEnd), now: at(1))
        store.apply(event(.permissionRequested), now: at(2))
        XCTAssertNil(store.sessions.first?.pendingPermissionID)
    }

    func testSetPendingPermissionForAnUnknownSessionIsHarmless() {
        let store = makeStore()
        store.setPendingPermission(id: nil, for: "claude:never")
        store.setPendingPermission(id: "x", for: "claude:never")
        store.setPendingPermission(id: nil, for: "claude:never")
        XCTAssertTrue(store.sessions.isEmpty)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS="" -only-testing:UsageTrackerTests/AgentSessionStoreTests`
Expected: compile error `value of type 'AgentSessionStore' has no member 'setPendingPermission'`.

- [ ] **Step 3: Implement**

In `UsageTracker/Agents/AgentSessionStore.swift` add after `private var endedIDs: [String: Date] = [:]` (line 40):

```swift
    /// `AgentSession.id` → request id of the permission Omelette is holding for it.
    /// Kept beside the rows because the broker registers a request *before* the
    /// event that creates the row is applied (see `AppState.bootstrap`).
    private var pendingPermissionIDs: [String: String] = [:]
```

In `apply`, inside the `.sessionEnd` branch, add `pendingPermissionIDs.removeValue(forKey: id)` right after `endedIDs[id] = now`.

In `apply`, replace

```swift
        if session.state == .needsYou, previousState != .needsYou {
            session.needsYouCount += 1
        }
        upsert(session)
```

with

```swift
        if session.state == .needsYou, previousState != .needsYou {
            session.needsYouCount += 1
        }
        // A held permission is moot once the session moved on (the user answered in
        // the terminal, or the hook was released): the buttons must go with it.
        if session.state != .needsYou {
            pendingPermissionIDs.removeValue(forKey: id)
        }
        session.pendingPermissionID = pendingPermissionIDs[id]
        upsert(session)
```

Add after `func sessions(for source:)`:

```swift
    // MARK: - Pending permission (phase 4)

    /// Records which permission request is held for `sessionID` (nil = none). The
    /// broker is the only caller. Publishes only when the row actually changes.
    func setPendingPermission(id: String?, for sessionID: String) {
        if let id {
            pendingPermissionIDs[sessionID] = id
        } else {
            pendingPermissionIDs.removeValue(forKey: sessionID)
        }
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
              sessions[index].pendingPermissionID != id else { return }
        sessions[index].pendingPermissionID = id
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS="" -only-testing:UsageTrackerTests/AgentSessionStoreTests`
Expected: PASS (all existing tests plus the 6 new ones).

- [ ] **Step 5: Commit**

```bash
git add UsageTracker/Agents/AgentSessionStore.swift UsageTrackerTests/AgentSessionStoreTests.swift
git commit -m "Agents: session store carries the held permission id, clears it on leaving needsYou

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

### Task 3: `AgentReply` — the Sendable answer handle

**Files:**
- Create: `UsageTracker/Agents/AgentReply.swift`
- Modify: `UsageTrackerTests/AgentFixtures.swift` (append `replyPair`, `readLine`)
- Test: `UsageTrackerTests/AgentReplyTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces (spec + additions):
  ```swift
  enum PermissionDecision: String, Codable, Sendable { case allow, deny }

  final class AgentReply: Sendable {
      let requestID: String?
      init(requestID: String?, fd: Int32 = -1)      // fd -1 = already answered (non-permission events)
      func send(_ decision: PermissionDecision?)    // idempotent: first call writes the line + shutdown(SHUT_RDWR); later calls no-op
      var isSettled: Bool                           // addition: a line was sent, or the peer hung up, or the fd was never held
      func onPeerClosed(_ handler: @escaping @Sendable () -> Void)   // addition: runs once if the helper leaves before a decision (immediately if it already has)
      // server-side (internal):
      func sendRaw(_ line: Data)                    // addition: what send() calls; tests forge replies with it
      func peerClosed()                             // addition: connection queue saw EOF before any decision
      func closeDescriptor()                        // addition: connection queue releases the fd; the only close()
      static func line(requestID: String?, decision: PermissionDecision?) -> Data   // addition: {"v":2,"request_id":"…","decision":"allow"}\n
  }
  // Tests (AgentFixtures.swift):
  extension AgentFixture {
      static func replyPair(requestID: String? = AgentFixture.requestID) -> (reply: AgentReply, peer: Int32)  // socketpair; caller closes peer
  }
  extension AgentSocketTestClient {
      static func readLine(_ fd: Int32, timeout: TimeInterval = 1) -> String?   // one reply line without its newline, nil on timeout/EOF
  }
  ```

- [ ] **Step 1: Add the test helpers**

Append to `UsageTrackerTests/AgentFixtures.swift`:

```swift
extension AgentFixture {
    /// An `AgentReply` wired to one end of a socketpair, and the other end for the
    /// test to read what was written. Close `peer` in the test.
    static func replyPair(requestID: String? = AgentFixture.requestID) -> (reply: AgentReply, peer: Int32) {
        var fds: [Int32] = [-1, -1]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0, "socketpair failed: \(errno)")
        var one: Int32 = 1
        setsockopt(fds[0], SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return (AgentReply(requestID: requestID, fd: fds[0]), fds[1])
    }
}

extension AgentSocketTestClient {
    /// Reads one line (without its "\n") from `fd`. nil when nothing arrives within
    /// `timeout` or the peer closed without sending.
    static func readLine(_ fd: Int32, timeout: TimeInterval = 1) -> String? {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, Int32(timeout * 1000)) > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(fd, &buffer, buffer.count)
        guard count > 0 else { return nil }
        return String(decoding: buffer[0..<count], as: UTF8.self).trimmingCharacters(in: .newlines)
    }
}
```

- [ ] **Step 2: Write the failing tests**

```swift
// UsageTrackerTests/AgentReplyTests.swift
import XCTest
@testable import Omelette

final class AgentReplyTests: XCTestCase {
    func testLineFormat() {
        XCTAssertEqual(String(decoding: AgentReply.line(requestID: AgentFixture.requestID, decision: .allow), as: UTF8.self),
                       #"{"v":2,"request_id":"0123456789abcdef0123456789abcdef","decision":"allow"}"# + "\n")
        XCTAssertEqual(String(decoding: AgentReply.line(requestID: AgentFixture.requestID, decision: .deny), as: UTF8.self),
                       #"{"v":2,"request_id":"0123456789abcdef0123456789abcdef","decision":"deny"}"# + "\n")
        XCTAssertEqual(String(decoding: AgentReply.line(requestID: AgentFixture.requestID, decision: nil), as: UTF8.self),
                       #"{"v":2,"request_id":"0123456789abcdef0123456789abcdef","decision":null}"# + "\n")
        XCTAssertEqual(String(decoding: AgentReply.line(requestID: nil, decision: nil), as: UTF8.self),
                       #"{"v":2,"decision":null}"# + "\n")
    }

    func testSendWritesOnceThenEOF() {
        let (reply, peer) = AgentFixture.replyPair()
        defer { close(peer) }
        XCTAssertFalse(reply.isSettled)

        reply.send(.deny)
        reply.send(.allow)          // ignored: the first answer stands
        reply.send(nil)

        XCTAssertTrue(reply.isSettled)
        XCTAssertEqual(AgentSocketTestClient.readLine(peer), #"{"v":2,"request_id":"0123456789abcdef0123456789abcdef","decision":"deny"}"#)
        var byte: UInt8 = 0
        XCTAssertEqual(read(peer, &byte, 1), 0, "after the line the helper sees EOF, nothing else")
        reply.closeDescriptor()
    }

    func testAnAlreadyAnsweredHandleIsInert() {
        let reply = AgentReply(requestID: nil)
        XCTAssertTrue(reply.isSettled)
        XCTAssertNil(reply.requestID)
        reply.send(.allow)          // nothing to write to; must not crash
        var fired = false
        reply.onPeerClosed { fired = true }
        XCTAssertFalse(fired, "a settled handle never reports a lost peer")
    }

    func testPeerClosedFiresTheHandlerOnceAndSettles() {
        let (reply, peer) = AgentFixture.replyPair()
        defer { close(peer) }
        final class Counter: @unchecked Sendable { var count = 0 }
        let counter = Counter()
        reply.onPeerClosed { counter.count += 1 }

        reply.peerClosed()
        reply.peerClosed()
        XCTAssertEqual(counter.count, 1)
        XCTAssertTrue(reply.isSettled)

        reply.send(.allow)          // too late: nothing is written
        XCTAssertNil(AgentSocketTestClient.readLine(peer, timeout: 0.1))
        reply.closeDescriptor()
    }

    func testHandlerRegisteredAfterThePeerLeftRunsImmediately() {
        let (reply, peer) = AgentFixture.replyPair()
        defer { close(peer) }
        reply.peerClosed()
        var fired = false
        reply.onPeerClosed { fired = true }
        XCTAssertTrue(fired)
        reply.closeDescriptor()
    }

    func testPeerClosedAfterSendIsANoOp() {
        let (reply, peer) = AgentFixture.replyPair()
        defer { close(peer) }
        var fired = false
        reply.onPeerClosed { fired = true }
        reply.send(.allow)
        reply.peerClosed()          // the wake-up after our own shutdown
        XCTAssertFalse(fired)
        reply.closeDescriptor()
    }

    func testSendAfterCloseDescriptorIsSafe() {
        let (reply, peer) = AgentFixture.replyPair()
        defer { close(peer) }
        reply.closeDescriptor()
        reply.send(.allow)          // fd is gone; must not write to a recycled descriptor
        XCTAssertTrue(reply.isSettled)
    }
}
```

(`testPeerClosedFiresTheHandlerOnceAndSettles` mutates a captured var from a `@Sendable` closure through a `@unchecked Sendable` box — the same pattern `AgentEventServerTests` already uses for its `Box` classes; the handler runs synchronously on the calling thread here.)

- [ ] **Step 3: Run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS="" -only-testing:UsageTrackerTests/AgentReplyTests`
Expected: compile error `cannot find 'AgentReply' in scope`.

- [ ] **Step 4: Create `AgentReply`**

```swift
// UsageTracker/Agents/AgentReply.swift
import Foundation
import os

/// What the app may answer on a held `PermissionRequest`. Wire spelling.
enum PermissionDecision: String, Codable, Sendable {
    case allow, deny
}

/// The answer side of one hook connection.
///
/// For a held `PermissionRequest` the server hands this to `onEvent` and then parks
/// the connection's queue in `poll` on the descriptor. `send` — from any thread, once —
/// writes the reply line and `shutdown`s the socket, which both delivers the line to
/// the helper and wakes that `poll`; the connection queue is the only thing that ever
/// `close`s the descriptor (`closeDescriptor`). A helper that exits first is seen by
/// the same `poll` and reported through `onPeerClosed`, so the broker can withdraw a
/// request nobody can answer any more.
///
/// For every other event the server has already written its immediate reply: the
/// handle is born settled and `send` is a no-op.
final class AgentReply: Sendable {
    let requestID: String?

    private struct State: Sendable {
        var fd: Int32                 // -1 once released (or never held)
        var settled: Bool             // a line went out, the peer left, or nothing was ever held
        var peerClosed = false
        var peerClosedHandler: (@Sendable () -> Void)?
    }
    private let state: OSAllocatedUnfairLock<State>

    /// `fd` is the accepted socket, owned by the server's connection queue. -1 builds
    /// an already-answered handle.
    init(requestID: String?, fd: Int32 = -1) {
        self.requestID = requestID
        state = OSAllocatedUnfairLock(initialState: State(fd: fd, settled: fd < 0))
    }

    var isSettled: Bool { state.withLock { $0.settled } }

    /// First call wins; later calls (a second click, expiry racing an answer) do nothing.
    func send(_ decision: PermissionDecision?) {
        sendRaw(Self.line(requestID: requestID, decision: decision))
    }

    /// Writes `line` verbatim if nothing has been sent yet. Tests use it to forge
    /// replies (wrong id, garbage) and prove the helper ignores them.
    func sendRaw(_ line: Data) {
        let fd: Int32? = state.withLock { state in
            guard !state.settled else { return nil }
            state.settled = true
            return state.fd >= 0 ? state.fd : nil
        }
        guard let fd else { return }
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        // Delivers EOF after the line and wakes the connection queue's poll so it
        // releases the descriptor. EPIPE on a helper that already left is harmless:
        // SO_NOSIGPIPE is inherited from the listening socket.
        shutdown(fd, SHUT_RDWR)
    }

    /// Runs `handler` once if the helper disconnects before any decision was sent —
    /// immediately, on the caller's thread, if it already has. Never runs after `send`.
    func onPeerClosed(_ handler: @escaping @Sendable () -> Void) {
        let fireNow: Bool = state.withLock { state in
            if state.peerClosed { return true }
            guard !state.settled else { return false }
            state.peerClosedHandler = handler
            return false
        }
        if fireNow { handler() }
    }

    /// Server side: the connection queue read EOF. A no-op after `send` (that EOF was
    /// our own shutdown).
    func peerClosed() {
        let handler: (@Sendable () -> Void)? = state.withLock { state in
            guard !state.settled else { return nil }
            state.settled = true
            state.peerClosed = true
            defer { state.peerClosedHandler = nil }
            return state.peerClosedHandler
        }
        handler?()
    }

    /// Server side, connection queue only: releases the descriptor. Afterwards `send`
    /// cannot touch a number the kernel may have reused.
    func closeDescriptor() {
        let fd: Int32 = state.withLock { state in
            let fd = state.fd
            state.fd = -1
            state.settled = true
            return fd
        }
        if fd >= 0 { Darwin.close(fd) }
    }

    /// `{"v":2,"request_id":"<id>","decision":"allow"|"deny"|null}\n`. Built by hand:
    /// the id is validated hex and the decision a bare word, so nothing needs escaping
    /// and the key order is fixed for the tests.
    static func line(requestID: String?, decision: PermissionDecision?) -> Data {
        var text = "{\"v\":\(AgentPaths.wireVersion)"
        if let requestID { text += ",\"request_id\":\"\(requestID)\"" }
        text += ",\"decision\":" + (decision.map { "\"\($0.rawValue)\"" } ?? "null") + "}\n"
        return Data(text.utf8)
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS="" -only-testing:UsageTrackerTests/AgentReplyTests`
Expected: PASS (7 tests), no warnings in `AgentReply.swift` (a `Sendable` warning here means a stored property slipped past the lock — fix the code, never add `@unchecked`).

- [ ] **Step 6: Commit**

```bash
git add UsageTracker/Agents/AgentReply.swift UsageTrackerTests/AgentReplyTests.swift UsageTrackerTests/AgentFixtures.swift
git commit -m "Agents: AgentReply — Sendable, idempotent answer handle for a held hook connection

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

### Task 4: `AgentEventServer` — peer authentication, per-connection queues, the hold; `onEvent` gains the reply

**Files:**
- Modify: `UsageTracker/Agents/AgentEventServer.swift`
- Modify: `UsageTracker/Agents/AgentChannel.swift:13-17, 52-55`
- Modify: `UsageTracker/Core/AppState.swift:32-36`
- Modify: `UsageTrackerTests/AgentFixtures.swift` (`AgentSocketTestClient`: shared `connect`, new `open`)
- Modify: `UsageTrackerTests/OmeletteHookEndToEndTests.swift:8, 28-33` (callback shape only)
- Modify: `UsageTrackerTests/AgentChannelTests.swift:47` (+ two tests)
- Test: `UsageTrackerTests/AgentEventServerTests.swift`

**Interfaces:**
- Consumes: `AgentEvent.requestID` (Task 1), `AgentReply` (Task 3).
- Produces:
  ```swift
  final class AgentEventServer: @unchecked Sendable {
      init(socketURL: URL,
           holdTimeout: TimeInterval = AgentEventServer.defaultHoldTimeout,          // addition
           peerUID: @escaping @Sendable (Int32) -> uid_t? = AgentEventServer.localPeerUID,   // addition: injectable for tests
           onEvent: @escaping @Sendable (AgentEvent, AgentReply) -> Void)             // CHANGED shape
      static let defaultHoldTimeout: TimeInterval = 140    // addition: spec rule 5 (helper waits ≤ 140 s too)
      let holdTimeout: TimeInterval                        // addition
      static let localPeerUID: @Sendable (Int32) -> uid_t? // addition: getsockopt(SOL_LOCAL, LOCAL_PEERCRED)
      private(set) var rejectedPeerCount: Int              // addition: main queue only, subset of droppedCount
      // unchanged: start(), stop(), receivedCount, droppedCount, socketURL, maxMessageBytes, connectionTimeout, reply, Error
  }
  @MainActor final class AgentChannel {
      var onEvent: (AgentEvent, AgentReply) -> Void       // CHANGED shape; default logs and reply.send(nil)
  }
  // Tests:
  enum AgentSocketTestClient {
      static func open(_ line: Data, to path: String) -> Int32?   // connect + write, connection kept open (no half-close); caller closes
      // unchanged: send(_:to:replyTimeout:) ×2, readLine (Task 3)
  }
  ```
  Contract: `onEvent` runs on the main queue. For a `permissionRequested` event with a `requestID` the reply is *unsettled* and the connection stays open until `reply.send` or `holdTimeout`; for everything else the server has already written `{"v":1,"decision":null}` and closed, and `reply` is settled (`requestID == nil`).

- [ ] **Step 1: Extend the test client**

In `UsageTrackerTests/AgentFixtures.swift` replace `enum AgentSocketTestClient { … }` (the whole enum, currently lines 58–101) with:

```swift
/// A blocking POSIX client mirroring what `omelette-hook` does.
enum AgentSocketTestClient {
    /// Connects to `path`. nil when nothing listens there.
    private static func connect(to path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
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
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { close(fd); return nil }
        return fd
    }

    /// Fire-and-forget or one-shot request: connect, write, half-close, optionally wait
    /// for one reply line. Returns the reply without its newline, or nil when the
    /// connection fails, nothing is written, or no reply arrives within `replyTimeout`
    /// (pass 0 to not wait).
    @discardableResult
    static func send(_ line: Data, to path: String, replyTimeout: TimeInterval = 1) -> String? {
        guard let fd = connect(to: path) else { return nil }
        defer { close(fd) }
        let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        // Half-close like the helper does (it closes outright when it wants no reply):
        // without it a line that carries no trailing "\n" would only reach the server
        // when its 1 s per-connection budget expires, i.e. after our own reply timeout.
        shutdown(fd, SHUT_WR)
        guard written == line.count, replyTimeout > 0 else { return nil }
        return readLine(fd, timeout: replyTimeout)
    }

    @discardableResult
    static func send(_ line: String, to path: String, replyTimeout: TimeInterval = 1) -> String? {
        send(Data(line.utf8), to: path, replyTimeout: replyTimeout)
    }

    /// A held request: connect, write the line (which must end in "\n") and keep the
    /// connection open exactly like the helper does for a `PermissionRequest` — no
    /// half-close, because an EOF after the line is what "the helper left" looks like
    /// to the server. Read the reply with `readLine`; close the fd yourself.
    static func open(_ line: Data, to path: String) -> Int32? {
        precondition(line.last == 0x0A, "a held line must end in a newline")
        guard let fd = connect(to: path) else { return nil }
        let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == line.count else { close(fd); return nil }
        return fd
    }
}
```

(Keep the `extension AgentSocketTestClient { static func readLine … }` from Task 3 below it.)

- [ ] **Step 2: Write the failing server tests**

In `UsageTrackerTests/AgentEventServerTests.swift`:

Replace `startServer` (lines 24–29) with:

```swift
    private func startServer(
        holdTimeout: TimeInterval = AgentEventServer.defaultHoldTimeout,
        peerUID: @escaping @Sendable (Int32) -> uid_t? = AgentEventServer.localPeerUID,
        onEvent: @escaping @Sendable (AgentEvent, AgentReply) -> Void = { _, _ in }
    ) throws -> AgentEventServer {
        let server = AgentEventServer(socketURL: socketURL, holdTimeout: holdTimeout, peerUID: peerUID, onEvent: onEvent)
        try server.start()
        self.server = server
        return server
    }

    /// A PermissionRequest line the server will hold: v2 with a request id and a trailing "\n".
    private func heldLine(sessionID: String = "sess-1") -> Data {
        AgentFixture.envelope(payload: AgentFixture.claude("PermissionRequest", sessionID: sessionID, extra: #""tool_name":"Bash","tool_input":{"command":"rm -rf build"}"#),
                              requestID: AgentFixture.requestID) + Data([0x0A])
    }
```

Change every existing `startServer { event in … }` closure to take two parameters: `{ event, _ in … }` (five sites: `testDeliversDecodedEventsOnTheMainQueueAndReplies`, `testCodexLineIsDecodedToo`, `testMessageWithoutTrailingNewlineIsAcceptedAtEOF`, `testDropsMalformedEmptyAndOversizedMessages`, `testRapidClientsArriveInOrder`), and the four direct `AgentEventServer(socketURL: socketURL) { _ in }` calls to `{ _, _ in }`. In `testDeliversDecodedEventsOnTheMainQueueAndReplies` add, after `XCTAssertEqual(server.droppedCount, 0)`:

```swift
        XCTAssertEqual(server.rejectedPeerCount, 0)
```

and extend its closure to also record the reply: `final class Box: @unchecked Sendable { var events: [AgentEvent] = []; var replies: [AgentReply] = []; var onMain = false }`, `box.replies.append(reply)`, then assert:

```swift
        XCTAssertEqual(box.replies.first?.isSettled, true, "a non-permission event is answered by the server itself")
        XCTAssertNil(box.replies.first?.requestID)
```

Append the new tests:

```swift
    // MARK: - Held permission requests (phase 4)

    private final class Held: @unchecked Sendable {
        var events: [AgentEvent] = []
        var replies: [AgentReply] = []
    }

    func testPermissionWithRequestIDIsHeldUntilSend() throws {
        let held = Held()
        _ = try startServer { event, reply in held.events.append(event); held.replies.append(reply) }
        let fd = try XCTUnwrap(AgentSocketTestClient.open(heldLine(), to: socketURL.path))
        defer { close(fd) }

        XCTAssertTrue(waitOnMain { held.replies.count == 1 })
        let reply = try XCTUnwrap(held.replies.first)
        XCTAssertEqual(held.events.first?.kind, .permissionRequested)
        XCTAssertEqual(reply.requestID, AgentFixture.requestID)
        XCTAssertFalse(reply.isSettled)
        XCTAssertNil(AgentSocketTestClient.readLine(fd, timeout: 0.2), "nothing is written while the request is held")

        reply.send(.allow)

        XCTAssertEqual(AgentSocketTestClient.readLine(fd), #"{"v":2,"request_id":"0123456789abcdef0123456789abcdef","decision":"allow"}"#)
        var byte: UInt8 = 0
        XCTAssertEqual(read(fd, &byte, 1), 0, "the server closes after the reply")
        XCTAssertTrue(reply.isSettled)
    }

    func testAHeldPermissionDoesNotDelayAFollowingStop() throws {
        let held = Held()
        let server = try startServer { event, reply in held.events.append(event); held.replies.append(reply) }
        let fd = try XCTUnwrap(AgentSocketTestClient.open(heldLine(), to: socketURL.path))
        defer { close(fd) }
        XCTAssertTrue(waitOnMain { held.replies.count == 1 })

        let started = Date()
        let stopReply = AgentSocketTestClient.send(line(AgentFixture.stop), to: socketURL.path)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(stopReply, #"{"v":1,"decision":null}"#)
        XCTAssertLessThan(elapsed, 0.5, "a held connection must not block the next hook; took \(elapsed)s")
        XCTAssertTrue(waitOnMain { server.receivedCount == 2 })
        XCTAssertEqual(held.events.map(\.kind), [.permissionRequested, .stop])
        held.replies.first?.send(nil)
    }

    func testPermissionWithoutRequestIDIsAnsweredImmediately() throws {
        // A pre-2.2 helper (v1 envelope): phase-2 behaviour, nothing is held.
        let held = Held()
        _ = try startServer { event, reply in held.events.append(event); held.replies.append(reply) }
        let v1 = AgentFixture.envelope(payload: AgentFixture.permissionRequestEdit, v: 1) + Data([0x0A])

        let reply = AgentSocketTestClient.send(v1, to: socketURL.path)

        XCTAssertEqual(reply, #"{"v":1,"decision":null}"#)
        XCTAssertTrue(waitOnMain { held.replies.count == 1 })
        XCTAssertEqual(held.events.first?.kind, .permissionRequested)
        XCTAssertNil(held.events.first?.requestID)
        XCTAssertEqual(held.replies.first?.isSettled, true)
    }

    func testSendOnAHeldReplyIsIdempotentOnTheWire() throws {
        let held = Held()
        _ = try startServer { _, reply in held.replies.append(reply) }
        let fd = try XCTUnwrap(AgentSocketTestClient.open(heldLine(), to: socketURL.path))
        defer { close(fd) }
        XCTAssertTrue(waitOnMain { held.replies.count == 1 })
        let reply = try XCTUnwrap(held.replies.first)

        reply.send(.deny)
        reply.send(.allow)
        reply.send(nil)

        var buffer = [UInt8](repeating: 0, count: 4096)
        var received = Data()
        while true {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 1000) > 0 else { break }
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            received.append(buffer, count: count)
        }
        XCTAssertEqual(String(decoding: received, as: UTF8.self),
                       #"{"v":2,"request_id":"0123456789abcdef0123456789abcdef","decision":"deny"}"# + "\n",
                       "exactly one reply line, then EOF")
    }

    func testHoldTimeoutAnswersWithNoDecision() throws {
        let held = Held()
        _ = try startServer(holdTimeout: 0.3) { _, reply in held.replies.append(reply) }
        let fd = try XCTUnwrap(AgentSocketTestClient.open(heldLine(), to: socketURL.path))
        defer { close(fd) }
        XCTAssertTrue(waitOnMain { held.replies.count == 1 })
        let started = Date()

        let reply = AgentSocketTestClient.readLine(fd, timeout: 2)

        XCTAssertEqual(reply, #"{"v":2,"request_id":"0123456789abcdef0123456789abcdef","decision":null}"#)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.25)
        XCTAssertEqual(held.replies.first?.isSettled, true)
        held.replies.first?.send(.allow)   // late answer after the hold: ignored
    }

    func testAHelperThatLeavesEarlyIsReportedAndItsConnectionReleased() throws {
        let held = Held()
        _ = try startServer { _, reply in held.replies.append(reply) }
        let fd = try XCTUnwrap(AgentSocketTestClient.open(heldLine(), to: socketURL.path))
        XCTAssertTrue(waitOnMain { held.replies.count == 1 })
        let reply = try XCTUnwrap(held.replies.first)
        final class Flag: @unchecked Sendable { var fired = false }
        let flag = Flag()
        reply.onPeerClosed { flag.fired = true }

        close(fd)   // Claude Code killed the helper (old 5 s template), or it crashed

        XCTAssertTrue(waitOnMain { reply.isSettled })
        XCTAssertTrue(flag.fired)
    }

    // MARK: - Peer authentication (spec rule 2)

    func testRejectsAPeerWithAnotherUID() throws {
        final class Box: @unchecked Sendable { var count = 0 }
        let box = Box()
        let server = try startServer(peerUID: { _ in 0 }) { _, _ in box.count += 1 }   // "root" is not us

        let reply = AgentSocketTestClient.send(line(AgentFixture.stop), to: socketURL.path, replyTimeout: 0.5)

        XCTAssertNil(reply, "a foreign peer is closed unanswered")
        XCTAssertTrue(waitOnMain { server.rejectedPeerCount == 1 }, "rejected: \(server.rejectedPeerCount)")
        XCTAssertEqual(server.droppedCount, 1, "rejections are part of droppedCount (spec rule 2)")
        XCTAssertEqual(server.receivedCount, 0)
        XCTAssertEqual(box.count, 0)
    }

    func testAPeerWhoseCredentialsCannotBeReadIsRejectedToo() throws {
        let server = try startServer(peerUID: { _ in nil })
        XCTAssertNil(AgentSocketTestClient.send(line(AgentFixture.stop), to: socketURL.path, replyTimeout: 0.5))
        XCTAssertTrue(waitOnMain { server.rejectedPeerCount == 1 })
    }

    func testTheRealPeerCheckAcceptsOurOwnUID() throws {
        // Every other test runs with the real check; this one pins the reason.
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        XCTAssertEqual(AgentEventServer.localPeerUID(fds[0]), getuid())
        XCTAssertNil(AgentEventServer.localPeerUID(-1), "not a socket → no credentials → rejected")
    }
```

- [ ] **Step 3: Make the other callers compile (test files and channel)**

`UsageTrackerTests/OmeletteHookEndToEndTests.swift`: line 8 → `private final class Box: @unchecked Sendable { var events: [AgentEvent] = []; var replies: [AgentReply] = [] }`; in `startServer()` the server is created with `AgentEventServer(socketURL: socketURL) { event, reply in box.events.append(event); box.replies.append(reply) }`. Nothing else changes here in this task (the helper is still v1 until Task 5, so no E2E test holds).

`UsageTrackerTests/AgentChannelTests.swift` line 47 → `channel.onEvent = { event, _ in kinds.append(event.kind) }`, and append:

```swift
    func testTheDefaultConsumerAnswersAHeldPermissionWithNoDecision() throws {
        // Nobody assigned onEvent (a unit test, or bootstrap not yet run): a held
        // helper must still be released rather than wait out the 140 s budget.
        channel.start(socketURL: socketURL, refreshSymlink: false, historyURL: historyURL)
        let line = AgentFixture.envelope(payload: AgentFixture.permissionRequestEdit, requestID: AgentFixture.requestID) + Data([0x0A])
        let fd = try XCTUnwrap(AgentSocketTestClient.open(line, to: socketURL.path))
        defer { close(fd) }

        var reply: String?
        XCTAssertTrue(waitOnMain { reply = AgentSocketTestClient.readLine(fd, timeout: 0.05); return reply != nil })
        XCTAssertEqual(reply, #"{"v":2,"request_id":"0123456789abcdef0123456789abcdef","decision":null}"#)
    }

    func testAHeldPermissionReachesTheConsumerWithAnUnsettledReply() throws {
        var replies: [AgentReply] = []
        channel.onEvent = { _, reply in replies.append(reply) }
        channel.start(socketURL: socketURL, refreshSymlink: false, historyURL: historyURL)
        let line = AgentFixture.envelope(payload: AgentFixture.permissionRequestEdit, requestID: AgentFixture.requestID) + Data([0x0A])
        let fd = try XCTUnwrap(AgentSocketTestClient.open(line, to: socketURL.path))
        defer { close(fd) }

        XCTAssertTrue(waitOnMain { replies.count == 1 })
        XCTAssertEqual(replies.first?.isSettled, false)
        replies.first?.send(.deny)
        XCTAssertEqual(AgentSocketTestClient.readLine(fd), #"{"v":2,"request_id":"0123456789abcdef0123456789abcdef","decision":"deny"}"#)
    }
```

`UsageTracker/Agents/AgentChannel.swift`: replace lines 13–17 with

```swift
    /// The single consumer. The default logs the event kind and a session-id prefix —
    /// never a payload, cwd or tool summary (spec, "Security and privacy") — and
    /// releases a held permission request, so a helper never waits on a consumer
    /// nobody installed.
    var onEvent: (AgentEvent, AgentReply) -> Void = { event, reply in
        NSLog("[UT] agent event %@ session=%@", String(describing: event.kind), String(event.sessionID.prefix(8)))
        reply.send(nil)
    }
```

and lines 52–55 with

```swift
        let server = AgentEventServer(socketURL: socketURL) { [weak self] event, reply in
            // AgentEventServer delivers on the main queue by contract (Task 5 of phase 2).
            MainActor.assumeIsolated {
                guard let self else { reply.send(nil); return }   // channel gone: release the helper
                self.onEvent(event, reply)
            }
        }
```

`UsageTracker/Core/AppState.swift` lines 32–36 →

```swift
        // Package 1's AgentChannel delivers hook events on the main actor; the
        // session store is its one consumer (replaces the log-only default).
        // Phase 4 Task 8 adds the PermissionBroker routing; until then a held
        // request is released without a decision.
        AgentChannel.shared.onEvent = { event, reply in
            AgentSessionStore.shared.apply(event)
            reply.send(nil)
        }
```

- [ ] **Step 4: Run the server tests to verify the new ones fail**

Run: `xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS="" -only-testing:UsageTrackerTests/AgentEventServerTests`
Expected: compile error `extra arguments at positions #2, #3 in call` (the new `init` labels) — the server still has the old shape.

- [ ] **Step 5: Rewrite the server's accept/serve path**

In `UsageTracker/Agents/AgentEventServer.swift`:

Replace the class doc comment (lines 3–13) with:

```swift
/// Listens on a Unix domain socket for one-line JSON messages from `omelette-hook`.
///
/// POSIX sockets rather than Network.framework: `NWListener` cannot set the socket
/// file's mode, does not unlink a stale file and leaves the file behind on cancel;
/// here the file is `chmod 0600` before `listen()`, so there is never a moment when
/// another local user could connect. One connection carries one message: read until
/// "\n" / EOF / 64 KB / 1 s, decode, answer, close.
///
/// Phase 4: every accepted peer is authenticated with `LOCAL_PEERCRED` (same uid or
/// closed unanswered), and each connection is served on its own serial queue. A
/// `PermissionRequest` that carries a request id is *held*: `onEvent` receives an
/// unsettled `AgentReply`, and the connection's queue parks in `poll` until the reply
/// is sent, the helper leaves, or `holdTimeout` passes — nothing else waits on it.
/// Every other event is answered with `reply` on the spot, before `onEvent` runs.
///
/// Threading: accept runs on `queue` (serial); reads and holds on a per-connection
/// queue; `onEvent` and the counters on the main queue. The owner calls `stop()`; it
/// is deliberately not called from `deinit`.
```

Replace lines 21–47 (`maxMessageBytes` … `init`) with:

```swift
    /// Spec cap per message. Anything longer is dropped without decoding.
    static let maxMessageBytes = 64 * 1024
    /// Read budget per connection. The helper writes immediately after connecting;
    /// a client that stalls longer than this is counted as dropped.
    static let connectionTimeout: TimeInterval = 1.0
    /// How long a held `PermissionRequest` connection may wait for `AgentReply.send`.
    /// The helper gives up at the same 140 s; the broker's 120 s window sits inside
    /// both (spec rule 5), so in practice this only fires if the broker is bypassed.
    static let defaultHoldTimeout: TimeInterval = 140
    /// Sent immediately for every event that is not held; the helper reads it only
    /// for a `PermissionRequest` it did not tag with a request id (a v1 helper).
    static let reply = Data("{\"v\":1,\"decision\":null}\n".utf8)

    /// Effective uid of the process on the other end of an accepted Unix socket, or
    /// nil when the kernel will not say (not a socket, unsupported family).
    static let localPeerUID: @Sendable (Int32) -> uid_t? = { fd in
        var credentials = xucred()
        var length = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &credentials, &length) == 0,
              credentials.cr_version == UInt32(XUCRED_VERSION) else { return nil }
        return credentials.cr_uid
    }

    let socketURL: URL
    let holdTimeout: TimeInterval
    private let peerUID: @Sendable (Int32) -> uid_t?
    private let onEvent: @Sendable (AgentEvent, AgentReply) -> Void
    private let queue = DispatchQueue(label: "com.usagetracker.agent-socket")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    /// Identity of the file this instance bound. A second Omelette instance takes the
    /// path over (see `startOnQueue`); when this one then quits, the file at the path
    /// is no longer ours and must survive our `stop()`.
    private var boundIdentity: FileIdentity?

    /// Diagnostics (Settings → Agents). Main queue only. `rejectedPeerCount` is the
    /// subset of `droppedCount` that failed the uid check.
    private(set) var receivedCount = 0
    private(set) var droppedCount = 0
    private(set) var rejectedPeerCount = 0

    /// `peerUID` exists so tests can simulate a foreign peer; production uses `localPeerUID`.
    init(
        socketURL: URL,
        holdTimeout: TimeInterval = AgentEventServer.defaultHoldTimeout,
        peerUID: @escaping @Sendable (Int32) -> uid_t? = AgentEventServer.localPeerUID,
        onEvent: @escaping @Sendable (AgentEvent, AgentReply) -> Void
    ) {
        self.socketURL = socketURL
        self.holdTimeout = holdTimeout
        self.peerUID = peerUID
        self.onEvent = onEvent
    }
```

Replace `acceptPending` and `serve` (from `/// Drains every queued connection` through the end of `serve`) with:

```swift
    /// Drains every queued connection (the listening fd is non-blocking). Each one is
    /// authenticated here and then handed to its own queue, so a held request never
    /// stands between the next hook and its reply.
    private func acceptPending() {
        while listenFD >= 0 {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { return }   // EAGAIN: nothing more queued
            // SO_NOSIGPIPE and O_NONBLOCK come from the listening socket by inheritance.
            guard peerUID(client) == getuid() else {
                close(client)
                rejectPeer()
                continue
            }
            let connection = DispatchQueue(label: "com.usagetracker.agent-conn")
            connection.async { [self] in serve(client) }
        }
    }

    // MARK: - One connection

    /// Runs on the connection's own queue; owns `fd` until it returns.
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
                close(fd)
                return
            }
            newline = buffer.firstIndex(of: 0x0A)
        }

        let message = newline.map { buffer.subdata(in: buffer.startIndex..<$0) } ?? buffer
        guard !message.isEmpty else {
            drop(reason: "empty")
            close(fd)
            return
        }
        do {
            let event = try AgentEventDecoder.decode(message)
            if event.kind == .permissionRequested, let requestID = event.requestID {
                hold(fd, event: event, requestID: requestID)
                return
            }
            DispatchQueue.main.async { [self] in
                receivedCount += 1
                onEvent(event, AgentReply(requestID: nil))
            }
        } catch {
            // Error cases name a field at most — never the payload.
            drop(reason: String(describing: error))
        }
        _ = Self.reply.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)
    }

    /// Parks this connection's queue — only this one — until the app answers, the
    /// helper goes away, or the hold budget runs out. `AgentReply.send` shuts the
    /// socket down, which is what wakes the poll; the descriptor is released here and
    /// nowhere else.
    private func hold(_ fd: Int32, event: AgentEvent, requestID: String) {
        let reply = AgentReply(requestID: requestID, fd: fd)
        DispatchQueue.main.async { [self] in
            receivedCount += 1
            onEvent(event, reply)
        }
        if Self.wait(fd, for: POLLIN, until: Date().addingTimeInterval(holdTimeout)) {
            var byte: UInt8 = 0
            _ = read(fd, &byte, 1)
            reply.peerClosed()   // no-op when the wake-up was our own send()
        } else {
            reply.send(nil)      // budget exhausted: let the helper go without a decision
        }
        reply.closeDescriptor()
    }

    private func rejectPeer() {
        NSLog("[UT] agent connection rejected: peer uid is not ours")
        DispatchQueue.main.async { [self] in
            droppedCount += 1
            rejectedPeerCount += 1
        }
    }
```

(`drop(reason:)` and `wait(_:for:until:)` stay as they are; `wait`'s millisecond conversion covers 140 s comfortably inside `Int32`.)

- [ ] **Step 6: Run the server, channel and E2E tests**

Run: `xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS="" -only-testing:UsageTrackerTests/AgentEventServerTests -only-testing:UsageTrackerTests/AgentChannelTests -only-testing:OmeletteHookEndToEndTests`
Expected: PASS — server 20 tests (11 existing + 9 new), channel 8, E2E 8 (unchanged behaviour: the built helper is still v1 here). No warnings.

- [ ] **Step 7: Build the app target to catch any remaining caller**

Run: `xcodebuild -project UsageTracker.xcodeproj -scheme UsageTracker -configuration Debug -derivedDataPath build/DerivedData build 2>&1 | grep -E "warning:|error:|BUILD"`
Expected: `** BUILD SUCCEEDED **`, no `warning:` lines from `UsageTracker/Agents/` or `UsageTracker/Core/AppState.swift`.

- [ ] **Step 8: Commit**

```bash
git add UsageTracker/Agents/AgentEventServer.swift UsageTracker/Agents/AgentChannel.swift UsageTracker/Core/AppState.swift UsageTrackerTests/AgentFixtures.swift UsageTrackerTests/AgentEventServerTests.swift UsageTrackerTests/AgentChannelTests.swift UsageTrackerTests/OmeletteHookEndToEndTests.swift
git commit -m "Agents: server authenticates peers, serves per connection, holds PermissionRequest until AgentReply.send

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

### Task 5: Helper — wire v2, request id, decision wait, decision on stdout

**Files:**
- Modify: `HookHelper/SocketClient.swift`
- Modify: `HookHelper/main.swift`
- Test: `UsageTrackerTests/OmeletteHookEndToEndTests.swift`

**Interfaces:**
- Consumes: the server's hold (Task 4) through the built `omelette-hook` — E2E only; the helper links nothing from the app.
- Produces (helper-internal; the tool target has no unit-test target, the E2E tests are its tests):
  ```swift
  enum HookMain {
      static let helperVersion = 2, wireVersion = 2
      static let decisionTimeout: TimeInterval = 140                 // spec rule 5
      static let permissionWatchdogGraceMilliseconds = 5_000         // watchdog = decision timeout + 5 s → 145 s
      static let decisionTimeoutEnvironmentKey = "OMELETTE_DECISION_TIMEOUT"
      static func makeRequestID() -> String?                         // 32 lowercase hex from /dev/urandom
      static func socketPath(environment:) -> (path: String, overridden: Bool)
      static func decisionTimeout(environment:, overrideAllowed: Bool) -> TimeInterval
      static func decisionOutput(_ decision: String) -> String       // the exact Claude JSON line
  }
  enum SocketClient {
      static func send(_ line: Data, to path: String, connectTimeout: TimeInterval) -> Int32?   // connected fd on success (caller closes), nil otherwise
      static func awaitDecision(fd: Int32, requestID: String, timeout: TimeInterval) -> String? // "allow" | "deny" | nil
  }
  enum Watchdog { @discardableResult static func arm(milliseconds: Int) -> DispatchWorkItem }
  ```
  stdout contract: for `allow`/`deny` exactly `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}` (or `deny`) followed by one `\n`; otherwise nothing. Exit status always 0.

- [ ] **Step 1: Write the failing E2E tests**

In `UsageTrackerTests/OmeletteHookEndToEndTests.swift` replace `runHelper` (lines 35–61) with a launch/finish split — a held helper waits for a reply that only arrives once the test spins the main run loop, so stdout must be read *after* the reply, not while blocking on it:

```swift
    private struct Run {
        let status: Int32
        let stdout: Data
        let elapsed: TimeInterval
    }

    private struct Launched {
        let process: Process
        let stdout: Pipe
        let started: Date
    }

    static let allowJSON = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"# + "\n"
    static let denyJSON = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"# + "\n"

    /// Starts the helper against the temp socket with `input` on stdin (or only `arguments`).
    /// `decisionTimeout` sets OMELETTE_DECISION_TIMEOUT (seconds) — the helper honours it
    /// only because the socket override is in the temp dir.
    private func launchHelper(stdin input: String? = nil, arguments: [String] = [], decisionTimeout: TimeInterval? = nil) throws -> Launched {
        let process = Process()
        process.executableURL = AgentPaths.bundledHelperURL
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment[AgentPaths.socketEnvironmentKey] = socketURL.path
        if let decisionTimeout { environment[AgentPaths.decisionTimeoutEnvironmentKey] = String(decisionTimeout) }
        process.environment = environment
        let stdout = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = stdin
        let started = Date()
        try process.run()
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        try stdin.fileHandleForWriting.close()
        return Launched(process: process, stdout: stdout, started: started)
    }

    /// Drains stdout (the helper writes at most one short line, so the pipe never
    /// fills) and waits for exit.
    private func finish(_ launched: Launched) -> Run {
        let output = launched.stdout.fileHandleForReading.readDataToEndOfFile()
        launched.process.waitUntilExit()
        return Run(status: launched.process.terminationStatus, stdout: output, elapsed: Date().timeIntervalSince(launched.started))
    }

    /// Fire-and-forget events: launch and finish in one go.
    private func runHelper(stdin input: String? = nil, arguments: [String] = [], decisionTimeout: TimeInterval? = nil) throws -> Run {
        finish(try launchHelper(stdin: input, arguments: arguments, decisionTimeout: decisionTimeout))
    }

    /// The reply handle of the `count`-th event, once the server has delivered it on main.
    private func waitForReply(_ count: Int = 1, timeout: TimeInterval = 2) -> AgentReply? {
        guard waitForEvents(count, timeout: timeout) else { return nil }
        return box.replies[count - 1]
    }
```

In `testEveryClaudeEventRoundTripsInOrder` change the loop body to `XCTAssertEqual(try runHelper(stdin: entry.payload, decisionTimeout: 0.2).status, 0)` (the `PermissionRequest` in that list is now held; with the override the helper gives up after 0.2 s and the server sees EOF).

Replace `testPermissionRequestWaitsForTheReplyAndStaysWithinBudget` with:

```swift
    // MARK: - PermissionRequest decisions (spec rules 1, 3, 5)

    func testAllowIsPrintedExactlyAsClaudeExpectsIt() throws {
        try startServer()
        let launched = try launchHelper(stdin: AgentFixture.permissionRequestEdit)

        let reply = try XCTUnwrap(waitForReply())
        XCTAssertEqual(box.events.first?.kind, .permissionRequested)
        XCTAssertEqual(box.events.first?.toolSummary, "Edit: WalletView.swift")
        XCTAssertEqual(reply.requestID?.count, 32)
        XCTAssertEqual(box.events.first?.requestID, reply.requestID)
        XCTAssertFalse(reply.isSettled)
        reply.send(.allow)

        let run = finish(launched)
        XCTAssertEqual(run.status, 0)
        XCTAssertEqual(String(decoding: run.stdout, as: UTF8.self), Self.allowJSON)
        XCTAssertLessThan(run.elapsed, 3)
    }

    func testDenyIsPrintedExactlyAsClaudeExpectsIt() throws {
        try startServer()
        let launched = try launchHelper(stdin: AgentFixture.permissionRequestEdit)
        let reply = try XCTUnwrap(waitForReply())
        reply.send(.deny)

        let run = finish(launched)
        XCTAssertEqual(run.status, 0)
        XCTAssertEqual(String(decoding: run.stdout, as: UTF8.self), Self.denyJSON)
    }

    func testNoDecisionPrintsNothingAndExitsZeroWithinItsBudget() throws {
        try startServer()
        let launched = try launchHelper(stdin: AgentFixture.permissionRequestEdit, decisionTimeout: 0.5)
        let reply = try XCTUnwrap(waitForReply())
        // The app says nothing: the helper must give up on its own.
        let run = finish(launched)

        XCTAssertEqual(run.status, 0)
        XCTAssertTrue(run.stdout.isEmpty, "no decision → no output: \(String(decoding: run.stdout, as: UTF8.self))")
        XCTAssertGreaterThanOrEqual(run.elapsed, 0.45)
        XCTAssertLessThan(run.elapsed, 1.5)
        XCTAssertTrue(waitOnMainUntil { reply.isSettled }, "the server saw the helper leave")
    }

    func testNullDecisionFromTheAppPrintsNothing() throws {
        try startServer()
        let launched = try launchHelper(stdin: AgentFixture.permissionRequestEdit)
        let reply = try XCTUnwrap(waitForReply())
        reply.send(nil)   // presence release / expiry

        let run = finish(launched)
        XCTAssertEqual(run.status, 0)
        XCTAssertTrue(run.stdout.isEmpty)
        XCTAssertLessThan(run.elapsed, 2)
    }

    func testAReplyWithAnotherRequestIDPrintsNothing() throws {
        try startServer()
        let launched = try launchHelper(stdin: AgentFixture.permissionRequestEdit, decisionTimeout: 1)
        let reply = try XCTUnwrap(waitForReply())
        XCTAssertNotEqual(reply.requestID, AgentFixture.requestID)
        reply.sendRaw(AgentReply.line(requestID: AgentFixture.requestID, decision: .allow))   // forged: someone else's id

        let run = finish(launched)
        XCTAssertEqual(run.status, 0)
        XCTAssertTrue(run.stdout.isEmpty, "an allow for a foreign id must never reach Claude")
    }

    func testMalformedRepliesPrintNothing() throws {
        try startServer()
        let forged: [Data] = [
            Data("not json\n".utf8),
            Data("{\"v\":2,\"decision\":\"allow\"}\n".utf8),                         // no request_id
            Data("{\"v\":2,\"request_id\":\"".utf8) + Data("X".utf8) + Data("\",\"decision\":\"allow\"}\n".utf8),
            Data("[\"allow\"]\n".utf8),
        ]
        for line in forged {
            let launched = try launchHelper(stdin: AgentFixture.permissionRequestEdit, decisionTimeout: 1)
            let reply = try XCTUnwrap(waitForReply(box.events.count + 1))
            reply.sendRaw(line)
            let run = finish(launched)
            XCTAssertEqual(run.status, 0)
            XCTAssertTrue(run.stdout.isEmpty, "printed for \(String(decoding: line, as: UTF8.self))")
        }
    }

    func testADecisionOtherThanAllowOrDenyPrintsNothing() throws {
        try startServer()
        let launched = try launchHelper(stdin: AgentFixture.permissionRequestEdit, decisionTimeout: 1)
        let reply = try XCTUnwrap(waitForReply())
        let id = try XCTUnwrap(reply.requestID)
        reply.sendRaw(Data("{\"v\":2,\"request_id\":\"\(id)\",\"decision\":\"maybe\"}\n".utf8))

        let run = finish(launched)
        XCTAssertEqual(run.status, 0)
        XCTAssertTrue(run.stdout.isEmpty)
    }

    func testEachPermissionRequestGetsAFreshID() throws {
        try startServer()
        let first = try launchHelper(stdin: AgentFixture.permissionRequestEdit)
        let firstReply = try XCTUnwrap(waitForReply(1))
        let second = try launchHelper(stdin: AgentFixture.permissionRequestEdit)
        let secondReply = try XCTUnwrap(waitForReply(2))
        XCTAssertNotEqual(firstReply.requestID, secondReply.requestID)
        firstReply.send(nil)
        secondReply.send(nil)
        _ = finish(first)
        _ = finish(second)
    }

    func testOtherEventsStillNeverWaitAndNeverPrint() throws {
        try startServer()
        let run = try runHelper(stdin: AgentFixture.preToolUseBash)
        XCTAssertEqual(run.status, 0)
        XCTAssertTrue(run.stdout.isEmpty)
        XCTAssertLessThan(run.elapsed, 0.8)
        XCTAssertTrue(waitForEvents(1))
        XCTAssertNil(box.events.first?.requestID, "only a PermissionRequest carries an id")
    }

    func testTheTimeoutOverrideCannotLengthenTheWait() throws {
        // OMELETTE_DECISION_TIMEOUT is clamped to the production 140 s; a huge value
        // must not turn into a longer hold. Observable here only as "still exits when
        // the app answers", so the assertion is on the answer path, not on 140 s.
        try startServer()
        let launched = try launchHelper(stdin: AgentFixture.permissionRequestEdit, decisionTimeout: 1_000_000)
        let reply = try XCTUnwrap(waitForReply())
        reply.send(.allow)
        let run = finish(launched)
        XCTAssertEqual(String(decoding: run.stdout, as: UTF8.self), Self.allowJSON)
    }

    private func waitOnMainUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }
```

- [ ] **Step 2: Run the E2E tests to verify they fail**

Run: `xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS="" -only-testing:UsageTrackerTests/OmeletteHookEndToEndTests`
Expected: `testAllowIsPrintedExactlyAsClaudeExpectsIt` fails at `waitForReply()` (nil: the v1 helper sends no id, the server answers immediately and the reply is settled) — actually it fails at `XCTAssertEqual(reply.requestID?.count, 32)` (nil ≠ 32) and `XCTAssertFalse(reply.isSettled)`; `testEachPermissionRequestGetsAFreshID` fails on `XCTAssertNotEqual(nil, nil)`.

- [ ] **Step 3: Rewrite `SocketClient`**

```swift
// HookHelper/SocketClient.swift
import Foundation

/// Connect → write one line → (PermissionRequest only) wait for the decision line.
/// Every failure is silent: Omelette not running is the normal case, not an error.
enum SocketClient {
    /// Connects within `connectTimeout`, writes `line`, and returns the connected
    /// descriptor so the caller can wait for a reply on it. nil (and the socket
    /// closed) when anything goes wrong. The caller closes a returned fd.
    static func send(_ line: Data, to path: String, connectTimeout: TimeInterval) -> Int32? {
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)   // 104, including the NUL
        guard path.utf8.count < capacity else { return nil }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
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
            guard errno == EINPROGRESS, wait(fd, for: POLLOUT, until: deadline) else { close(fd); return nil }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { close(fd); return nil }
        }

        guard writeAll(fd, line, until: deadline) else { close(fd); return nil }
        return fd
    }

    /// Reads one reply line and returns "allow" / "deny" only when it is a JSON object
    /// whose `request_id` is exactly ours and whose `decision` is one of those two
    /// words. Anything else — timeout, EOF (Omelette quit), garbage, a foreign id, a
    /// `null` or unknown decision — is nil. Fail closed (spec rule 1).
    static func awaitDecision(fd: Int32, requestID: String, timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 1024)
        while !buffer.contains(0x0A) {
            guard buffer.count < 4096, wait(fd, for: POLLIN, until: deadline) else { return nil }
            let count = read(fd, &chunk, chunk.count)
            if count < 0, errno == EAGAIN || errno == EINTR { continue }
            guard count > 0 else { return nil }              // EOF: no decision survives Omelette going away
            buffer.append(chunk, count: count)
        }
        let line = buffer.prefix(while: { $0 != 0x0A })
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
              let id = object["request_id"] as? String, id == requestID,
              let decision = object["decision"] as? String, decision == "allow" || decision == "deny"
        else { return nil }
        return decision
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

- [ ] **Step 4: Rewrite `main.swift`**

```swift
// HookHelper/main.swift
import Foundation

// omelette-hook — forwards one Claude Code hook payload (stdin) or one Codex notify
// payload (`--codex '<json>'`) to Omelette over its Unix socket, and for a Claude
// `PermissionRequest` waits for Omelette's decision.
//
// Contract with the agents that spawn us: exit 0 no matter what; never block past
// 800 ms unless Omelette is actually listening and this is a PermissionRequest
// (then ≤ 140 s, watchdog at 145 s); write to stdout only the one decision line
// Claude Code understands, and only for a reply that carries our own request id;
// never persist or log a payload. Foundation only — no AppKit, no Security.

enum HookMain {
    static let helperVersion = 2
    static let wireVersion = 2
    static let maxLineBytes = 64 * 1024
    static let connectTimeout: TimeInterval = 0.3
    static let totalBudgetMilliseconds = 800
    /// Spec rule 5: helper ≤ 140 s < hook timeout 150 s; the app gives up at 120 s.
    static let decisionTimeout: TimeInterval = 140
    /// The PermissionRequest watchdog fires this long after the decision deadline.
    static let permissionWatchdogGraceMilliseconds = 5_000
    static let socketEnvironmentKey = "OMELETTE_AGENT_SOCKET"
    static let decisionTimeoutEnvironmentKey = "OMELETTE_DECISION_TIMEOUT"
    static let requestIDBytes = 16

    static func run() -> Never {
        // Watchdog first: whatever blocks below, the agent gets its process back on time.
        let watchdog = Watchdog.arm(milliseconds: totalBudgetMilliseconds)
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

        // Only a Claude PermissionRequest gets an id and waits for a decision. No id
        // (the random source failed) degrades to phase-2 behaviour: sent, not held.
        let isPermissionRequest = input.source == "claude"
            && (input.payload["hook_event_name"] as? String) == "PermissionRequest"
        let requestID = isPermissionRequest ? makeRequestID() : nil
        if let requestID { envelope["request_id"] = requestID }

        guard var line = encodeLine(envelope) else { exit(0) }
        if line.count > maxLineBytes {
            envelope["payload"] = shrinkingToolInput(input.payload)
            guard let smaller = encodeLine(envelope), smaller.count <= maxLineBytes else { exit(0) }
            line = smaller
        }

        let socket = socketPath(environment: ProcessInfo.processInfo.environment)
        guard let fd = SocketClient.send(line, to: socket.path, connectTimeout: connectTimeout) else { exit(0) }
        guard let requestID else {
            close(fd)
            exit(0)
        }

        // Omelette is listening and has our request: swap the 800 ms watchdog for the
        // long one, then wait. Cancelling an unfired DispatchWorkItem is what makes
        // the swap safe; if it fired already we are gone anyway.
        let timeout = decisionTimeout(environment: ProcessInfo.processInfo.environment, overrideAllowed: socket.overridden)
        watchdog.cancel()
        Watchdog.arm(milliseconds: Int(timeout * 1000) + permissionWatchdogGraceMilliseconds)
        let decision = SocketClient.awaitDecision(fd: fd, requestID: requestID, timeout: timeout)
        close(fd)
        if let decision {
            FileHandle.standardOutput.write(Data(decisionOutput(decision).utf8))
        }
        exit(0)
    }

    /// The one line Claude Code reads. `decision` is "allow" or "deny" — nothing else
    /// reaches this function (see `SocketClient.awaitDecision`).
    static func decisionOutput(_ decision: String) -> String {
        #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"\#(decision)"}}}"# + "\n"
    }

    /// 128 random bits as 32 lowercase hex characters, from the kernel's pool.
    /// nil if /dev/urandom cannot be read — the caller then sends without an id.
    static func makeRequestID() -> String? {
        guard let urandom = FileHandle(forReadingAtPath: "/dev/urandom"),
              let bytes = try? urandom.read(upToCount: requestIDBytes),
              bytes.count == requestIDBytes else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
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

    /// The socket to talk to, and whether the environment override was honoured.
    static func socketPath(environment: [String: String]) -> (path: String, overridden: Bool) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let production = home.appendingPathComponent("Library/Application Support/UsageTracker/agent.sock").path
        guard let override = environment[socketEnvironmentKey], !override.isEmpty else {
            return (production, false)
        }
        // The override exists for the test suite. Anything that can set an
        // environment variable on the agent's process (direnv, a devcontainer, a
        // dependency's install script) must not be able to redirect hook payloads —
        // which include tool inputs — to a socket of its choosing, so only paths in
        // the per-user temp dir or Omelette's own App Support dir are honoured.
        let candidate = URL(fileURLWithPath: override).standardizedFileURL.path
        let allowedRoots = [
            NSTemporaryDirectory(),
            "/private" + NSTemporaryDirectory(),
            home.appendingPathComponent("Library/Application Support/UsageTracker").path + "/",
        ]
        return allowedRoots.contains(where: { candidate.hasPrefix($0) }) ? (override, true) : (production, false)
    }

    /// 140 s, or a shorter value from OMELETTE_DECISION_TIMEOUT when — and only when —
    /// the socket override was honoured (tests). Shorter can only mean "no decision",
    /// so this is not a lever anyone can pull to make us print more.
    static func decisionTimeout(environment: [String: String], overrideAllowed: Bool) -> TimeInterval {
        guard overrideAllowed, let raw = environment[decisionTimeoutEnvironmentKey],
              let value = TimeInterval(raw), value > 0 else { return decisionTimeout }
        return min(value, decisionTimeout)
    }
}

/// `_exit`, not `exit`: the main thread may be blocked inside Foundation holding a
/// lock, and atexit handlers would wait on it forever.
enum Watchdog {
    @discardableResult
    static func arm(milliseconds: Int) -> DispatchWorkItem {
        let item = DispatchWorkItem { _exit(0) }
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(milliseconds), execute: item)
        return item
    }
}

HookMain.run()
```

- [ ] **Step 5: Run the E2E tests to verify they pass**

Run: `xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS="" -only-testing:UsageTrackerTests/OmeletteHookEndToEndTests`
Expected: PASS (17 tests: 7 existing + 10 new). If `testNoDecisionPrintsNothingAndExitsZeroWithinItsBudget` measures ≥ 1.5 s, the override did not reach the helper — check that `socketURL` is under `NSTemporaryDirectory()` (it is: `AgentFixture.temporarySocketURL()`).

- [ ] **Step 6: Check the helper stays Foundation-only and warning-free**

Run: `xcodebuild -project UsageTracker.xcodeproj -scheme UsageTracker -configuration Debug -derivedDataPath build/DerivedData build 2>&1 | grep -E "HookHelper.*warning:|error:|BUILD"; otool -L build/DerivedData/Build/Products/Debug/Omelette.app/Contents/Helpers/omelette-hook | grep -E "AppKit|Security"`
Expected: `** BUILD SUCCEEDED **`, no warnings from `HookHelper/`, and no AppKit/Security line from `otool`.

- [ ] **Step 7: Commit**

```bash
git add HookHelper/main.swift HookHelper/SocketClient.swift UsageTrackerTests/OmeletteHookEndToEndTests.swift
git commit -m "omelette-hook: wire v2 — random request id, wait ≤ 140 s for a decision, print Claude's allow/deny

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

### Task 6: `PresenceMonitor` — is the user looking at the session's host?

**Files:**
- Create: `UsageTracker/Agents/PresenceMonitor.swift`
- Test: `UsageTrackerTests/PresenceMonitorTests.swift`

**Interfaces:**
- Consumes: `AgentHostInfo`.
- Produces (spec + additions):
  ```swift
  @MainActor final class PresenceMonitor {
      static let shared: PresenceMonitor
      typealias Frontmost = (pid: Int32?, bundleID: String?)                        // addition
      init(frontmost: @escaping () -> Frontmost? = PresenceMonitor.systemFrontmost,   // addition: injectable
           isLockedOrAsleep: (() -> Bool)? = nil)                                    // addition: injectable; nil = tracked from notifications
      var onActivation: ((NSRunningApplication) -> Void)?
      func isUserAt(host: AgentHostInfo) -> Bool
      static func matches(frontmost: Frontmost?, host: AgentHostInfo) -> Bool       // addition: the pure rule
      static func systemFrontmost() -> Frontmost?                                    // addition
      var isLockedOrAsleep: Bool                                                     // addition
      func start()   // addition: registers the NSWorkspace / distributed observers (AppDelegate calls it once)
      func stop()    // addition
      func setLocked(_:)  func setAsleep(_:)                                         // addition: what the observers call; tests drive these
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
// UsageTrackerTests/PresenceMonitorTests.swift
import AppKit
import XCTest
@testable import Omelette

@MainActor
final class PresenceMonitorTests: XCTestCase {
    private let iterm = AgentHostInfo(pid: 4242, bundleID: "com.googlecode.iterm2", tty: "/dev/ttys004")

    func testMatchesUsesThePIDWhenTheHostHasOne() {
        XCTAssertTrue(PresenceMonitor.matches(frontmost: (4242, "com.googlecode.iterm2"), host: iterm))
        XCTAssertTrue(PresenceMonitor.matches(frontmost: (4242, nil), host: iterm), "pid alone is enough")
        XCTAssertFalse(PresenceMonitor.matches(frontmost: (1, "com.googlecode.iterm2"), host: iterm),
                       "same app, other process: a second iTerm instance is not this session's window")
        XCTAssertFalse(PresenceMonitor.matches(frontmost: nil, host: iterm))
    }

    func testMatchesFallsBackToTheBundleIDWhenThereIsNoPID() {
        let byBundle = AgentHostInfo(pid: nil, bundleID: "com.apple.Terminal", tty: nil)
        XCTAssertTrue(PresenceMonitor.matches(frontmost: (77, "com.apple.Terminal"), host: byBundle))
        XCTAssertFalse(PresenceMonitor.matches(frontmost: (77, "com.googlecode.iterm2"), host: byBundle))
        XCTAssertFalse(PresenceMonitor.matches(frontmost: (77, nil), host: byBundle))
    }

    func testAHostWithoutIdentityNeverMatches() {
        XCTAssertFalse(PresenceMonitor.matches(frontmost: (77, "com.apple.Terminal"), host: .none))
        XCTAssertFalse(PresenceMonitor.matches(frontmost: (77, "x"), host: AgentHostInfo(pid: nil, bundleID: nil, tty: "/dev/ttys001")))
    }

    func testIsUserAtHostIsFalseWhenLockedOrAsleep() {
        let monitor = PresenceMonitor(frontmost: { (4242, "com.googlecode.iterm2") })
        XCTAssertTrue(monitor.isUserAt(host: iterm))
        monitor.setLocked(true)
        XCTAssertFalse(monitor.isUserAt(host: iterm), "a locked screen means nobody is at the terminal")
        monitor.setLocked(false)
        monitor.setAsleep(true)
        XCTAssertFalse(monitor.isUserAt(host: iterm))
        monitor.setAsleep(false)
        XCTAssertTrue(monitor.isUserAt(host: iterm))
    }

    func testInjectedLockStateWinsOverTheTrackedOne() {
        let monitor = PresenceMonitor(frontmost: { (4242, "com.googlecode.iterm2") }, isLockedOrAsleep: { true })
        XCTAssertTrue(monitor.isLockedOrAsleep)
        XCTAssertFalse(monitor.isUserAt(host: iterm))
    }

    func testFrontmostIsReadAtCallTimeNotAtInit() {
        final class Front: @unchecked Sendable { var value: PresenceMonitor.Frontmost? = (1, "com.other") }
        let front = Front()
        let monitor = PresenceMonitor(frontmost: { front.value })
        XCTAssertFalse(monitor.isUserAt(host: iterm))
        front.value = (4242, "com.googlecode.iterm2")
        XCTAssertTrue(monitor.isUserAt(host: iterm))
    }

    func testActivationNotificationsReachOnActivationAfterStart() {
        let monitor = PresenceMonitor(frontmost: { nil })
        var seen: [Int32] = []
        monitor.onActivation = { seen.append($0.processIdentifier) }
        monitor.start()
        monitor.start()   // idempotent: no double delivery
        defer { monitor.stop() }

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didActivateApplicationNotification, object: NSWorkspace.shared,
            userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current]
        )

        let deadline = Date().addingTimeInterval(1)
        while seen.isEmpty && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(seen, [getpid()])
    }

    func testStopUnregisters() {
        let monitor = PresenceMonitor(frontmost: { nil })
        var count = 0
        monitor.onActivation = { _ in count += 1 }
        monitor.start()
        monitor.stop()
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didActivateApplicationNotification, object: NSWorkspace.shared,
            userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current]
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(count, 0)
    }
}
```

(The screen-lock and sleep notifications are *not* posted by the tests: `com.apple.screenIsLocked` is a distributed notification and posting it would reach every app on the owner's Mac, including a running Omelette that pauses its polling on it. Those observers call `setLocked`/`setAsleep`, which the tests drive directly.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS="" -only-testing:UsageTrackerTests/PresenceMonitorTests`
Expected: compile error `cannot find 'PresenceMonitor' in scope`.

- [ ] **Step 3: Create `PresenceMonitor`**

```swift
// UsageTracker/Agents/PresenceMonitor.swift
import AppKit

/// Answers one question for the permission broker: is the user looking at the app
/// that hosts a session right now? "Looking at" means that app is frontmost and the
/// screen is neither locked nor asleep. Also reports every app activation so the
/// broker can release a hold the moment the user switches back to the terminal.
///
/// `frontmost` and `isLockedOrAsleep` are injectable so the rule is testable without
/// a window server; production reads `NSWorkspace` and tracks lock/sleep from the
/// same notifications `AppState.observeSystemState` uses.
@MainActor
final class PresenceMonitor {
    static let shared = PresenceMonitor()

    typealias Frontmost = (pid: Int32?, bundleID: String?)

    /// Every `NSWorkspace.didActivateApplicationNotification` after `start()`.
    var onActivation: ((NSRunningApplication) -> Void)?

    private let frontmost: () -> Frontmost?
    private let lockedOrAsleepOverride: (() -> Bool)?
    private var locked = false
    private var asleep = false
    private var observers: [NSObjectProtocol] = []

    init(
        frontmost: @escaping () -> Frontmost? = PresenceMonitor.systemFrontmost,
        isLockedOrAsleep: (() -> Bool)? = nil
    ) {
        self.frontmost = frontmost
        self.lockedOrAsleepOverride = isLockedOrAsleep
    }

    static func systemFrontmost() -> Frontmost? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return (app.processIdentifier, app.bundleIdentifier)
    }

    var isLockedOrAsleep: Bool { lockedOrAsleepOverride?() ?? (locked || asleep) }

    /// Spec: frontmost app's pid == host.pid, or bundle id match when the host has no
    /// pid; false whenever the screen is locked or asleep.
    func isUserAt(host: AgentHostInfo) -> Bool {
        guard !isLockedOrAsleep else { return false }
        return Self.matches(frontmost: frontmost(), host: host)
    }

    /// The pure rule. A pid, when the host reported one, must match exactly — the
    /// bundle id is only consulted for hosts that came without a pid.
    static func matches(frontmost: Frontmost?, host: AgentHostInfo) -> Bool {
        guard let frontmost else { return false }
        if let pid = host.pid { return frontmost.pid == pid }
        if let bundleID = host.bundleID { return frontmost.bundleID == bundleID }
        return false
    }

    func setLocked(_ value: Bool) { locked = value }
    func setAsleep(_ value: Bool) { asleep = value }

    /// Registers the observers once. Observer blocks run on the main queue; the
    /// `@Sendable` closures capture only a weak self and, for activation, pull the
    /// app out of the notification inside `assumeIsolated` so nothing non-Sendable
    /// crosses a boundary.
    func start() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        func flag(locked: Bool? = nil, asleep: Bool? = nil) -> @Sendable (Notification) -> Void {
            { [weak self] _ in
                MainActor.assumeIsolated {
                    if let locked { self?.setLocked(locked) }
                    if let asleep { self?.setAsleep(asleep) }
                }
            }
        }
        observers = [
            workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                    self?.onActivation?(app)
                }
            },
            workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main, using: flag(asleep: true)),
            workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main, using: flag(asleep: false)),
            workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: flag(asleep: true)),
            workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: flag(asleep: false)),
            distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main, using: flag(locked: true)),
            distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main, using: flag(locked: false)),
        ]
    }

    func stop() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        for observer in observers {
            workspace.removeObserver(observer)
            distributed.removeObserver(observer)
        }
        observers = []
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS="" -only-testing:UsageTrackerTests/PresenceMonitorTests`
Expected: PASS (8 tests), no concurrency warnings. If the compiler complains about `note` being captured in `assumeIsolated`, the closure passed to `addObserver` is already `@Sendable (Notification) -> Void` and `assumeIsolated`'s body is non-escaping — keep the extraction inside it, do not hoist `app` out.

- [ ] **Step 5: Commit**

```bash
git add UsageTracker/Agents/PresenceMonitor.swift UsageTrackerTests/PresenceMonitorTests.swift
git commit -m "Agents: PresenceMonitor — frontmost/lock/sleep rule and activation hook for the permission broker

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

### Task 7: `PermissionBroker` — hold or release, answer, expire, and the settings key

**Files:**
- Modify: `UsageTracker/Core/Settings.swift:69, 128, 172` (the `agentsAnswerPermissions` key — default, property, reset line)
- Create: `UsageTracker/Agents/PermissionBroker.swift`
- Test: `UsageTrackerTests/PermissionBrokerTests.swift`

**Interfaces:**
- Consumes: `AgentReply` (Task 3), `AgentSessionStore.setPendingPermission` (Task 2), `PresenceMonitor` (Task 6), `AgentEvent.requestID` (Task 1), `SettingsStore.agentsAnswerPermissions` (this task).
- Produces (spec + additions):
  ```swift
  struct PendingPermission: Identifiable, Equatable, Sendable { id, sessionID, toolName, toolSummary, receivedAt, expiresAt }
  enum PermissionResolution: Equatable, Sendable { case answered(PermissionDecision), releasedForPresence, expired }

  @MainActor final class PermissionBroker: ObservableObject {
      static let shared: PermissionBroker
      static let holdWindow: TimeInterval = 120                                    // addition: spec "hold up to 120 s"
      init(store: AgentSessionStore = .shared, presence: PresenceMonitor = .shared,
           featureEnabled: @escaping () -> Bool = { SettingsStore.shared.agentsAnswerPermissions },
           holdWindow: TimeInterval = PermissionBroker.holdWindow)                  // addition: injectable
      @Published private(set) var pending: [PendingPermission]                     // newest first
      private(set) var answeredCount, expiredCount, releasedForPresenceCount: Int
      func register(event: AgentEvent, reply: AgentReply, session: AgentSession?, now: Date = Date())
      func answer(id: String, _ decision: PermissionDecision)
      func release(id: String)
      func releaseAll(for sessionID: String)
      func pending(for sessionID: String) -> PendingPermission?
      var onPending: ((PendingPermission) -> Void)?
      var onResolved: ((PendingPermission, PermissionResolution) -> Void)?         // called after the request left `pending`
      static func shouldHold(userAtHost: Bool, featureEnabled: Bool, hasHost: Bool) -> Bool
  }
  extension SettingsStore { @AppStorage("agentsAnswerPermissions") var agentsAnswerPermissions: Bool }  // default true
  ```
  Rules: `expiredCount` also counts a hold that ended because the helper hung up (`AgentReply.onPeerClosed`) — from the user's side it is the same outcome, resolution `.expired`. `releasedForPresenceCount` counts immediate releases (user already at the host) and activation releases. A second `PermissionRequest` for a session that still has a hold resolves the old one as `.expired` first (Claude Code cannot have two open).

- [ ] **Step 1: Add the settings key**

In `UsageTracker/Core/Settings.swift`:
- after line 69 (`static let agentsShowInMenuBar = true`) add `        static let agentsAnswerPermissions = true`
- after the `agentsShowInMenuBar` `@AppStorage` line (128) add
  ```swift
      /// Phase 4: hold a Claude Code permission request and offer Allow / Deny from
      /// Omelette while the hosting terminal is not in front. Read by `PermissionBroker`.
      @AppStorage("agentsAnswerPermissions") var agentsAnswerPermissions: Bool = Defaults.agentsAnswerPermissions
  ```
- in `resetToDefaults()` after `agentsShowInMenuBar = Defaults.agentsShowInMenuBar` add `        agentsAnswerPermissions = Defaults.agentsAnswerPermissions`.

- [ ] **Step 2: Write the failing tests**

```swift
// UsageTrackerTests/PermissionBrokerTests.swift
import AppKit
import XCTest
@testable import Omelette

@MainActor
final class PermissionBrokerTests: XCTestCase {
    private var directory: URL!
    private var store: AgentSessionStore!
    private var presence: PresenceMonitor!
    private var frontmost: PresenceMonitor.Frontmost? = (1, "com.other.app")   // "the user is elsewhere"
    private var featureEnabled = true
    private var peers: [Int32] = []
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let iterm = AgentHostInfo(pid: 4242, bundleID: "com.googlecode.iterm2", tty: "/dev/ttys004")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PermissionBrokerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = AgentSessionStore(historyURL: directory.appendingPathComponent("agent-sessions.jsonl"))
        presence = PresenceMonitor(frontmost: { [weak self] in self?.frontmost })
    }

    override func tearDownWithError() throws {
        for peer in peers { close(peer) }
        peers = []
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeBroker(holdWindow: TimeInterval = PermissionBroker.holdWindow) -> PermissionBroker {
        PermissionBroker(store: store, presence: presence, featureEnabled: { [weak self] in self?.featureEnabled ?? true }, holdWindow: holdWindow)
    }

    private func event(host: AgentHostInfo? = nil, sessionID: String = "s1", requestID: String = AgentFixture.requestID) -> AgentEvent {
        AgentEvent(source: .claude, kind: .permissionRequested, sessionID: sessionID,
                   cwd: "/Users/tester/Projects/alpha", toolName: "Bash", toolSummary: "Bash: rm -rf build",
                   isSubagent: false, host: host ?? iterm, receivedAt: t0, requestID: requestID)
    }

    /// A reply on a socketpair; the peer end is read to see what was written.
    private func reply(_ requestID: String = AgentFixture.requestID) -> (AgentReply, Int32) {
        let pair = AgentFixture.replyPair(requestID: requestID)
        peers.append(pair.peer)
        return (pair.reply, pair.peer)
    }

    private func line(_ peer: Int32, timeout: TimeInterval = 0.2) -> String? {
        AgentSocketTestClient.readLine(peer, timeout: timeout)
    }

    // MARK: - The pure rule

    func testShouldHoldTable() {
        // (userAtHost, featureEnabled, hasHost) → hold?
        let table: [(Bool, Bool, Bool, Bool)] = [
            (false, true, true, true),     // away, on, known host → hold
            (true, true, true, false),     // at the terminal → release, Claude prompts there
            (false, false, true, false),   // feature off → observe only
            (false, true, false, false),   // no host info (passive / unknown) → release
            (true, false, false, false),
        ]
        for (userAtHost, enabled, hasHost, expected) in table {
            XCTAssertEqual(PermissionBroker.shouldHold(userAtHost: userAtHost, featureEnabled: enabled, hasHost: hasHost), expected,
                           "userAtHost=\(userAtHost) enabled=\(enabled) hasHost=\(hasHost)")
        }
    }

    // MARK: - register

    func testHoldsWhenTheUserIsAwayAndPublishesPending() {
        let broker = makeBroker()
        var announced: [PendingPermission] = []
        broker.onPending = { announced.append($0) }
        let (reply, peer) = reply()

        broker.register(event: event(), reply: reply, session: nil, now: t0)

        XCTAssertEqual(broker.pending.count, 1)
        let request = broker.pending[0]
        XCTAssertEqual(request.id, AgentFixture.requestID)
        XCTAssertEqual(request.sessionID, "claude:s1")
        XCTAssertEqual(request.toolName, "Bash")
        XCTAssertEqual(request.toolSummary, "Bash: rm -rf build")
        XCTAssertEqual(request.receivedAt, t0)
        XCTAssertEqual(request.expiresAt, t0.addingTimeInterval(120))
        XCTAssertEqual(announced, [request])
        XCTAssertEqual(broker.pending(for: "claude:s1"), request)
        XCTAssertFalse(reply.isSettled)
        XCTAssertNil(line(peer), "nothing goes to the helper while held")
    }

    func testRegisterBeforeTheStoreKnowsTheSessionStillLandsThePendingID() {
        // Bootstrap order: register, then apply.
        let broker = makeBroker()
        let (reply, _) = reply()
        broker.register(event: event(), reply: reply, session: nil, now: t0)
        XCTAssertTrue(store.sessions.isEmpty)

        store.apply(event(), now: t0)

        XCTAssertEqual(store.sessions.first?.pendingPermissionID, AgentFixture.requestID)
        XCTAssertEqual(store.sessions.first?.state, .needsYou)
    }

    func testPendingIsVisibleInsideOnNeedsYouWhenRegisteredFirst() {
        let broker = makeBroker()
        var seenPending: PendingPermission?? = .none
        store.onNeedsYou = { [broker] session in seenPending = .some(broker.pending(for: session.id)) }
        let (reply, _) = reply()

        broker.register(event: event(), reply: reply, session: nil, now: t0)
        store.apply(event(), now: t0)

        XCTAssertEqual(seenPending??.id, AgentFixture.requestID, "the notifier vetoes the plain banner through pending(for:)")
    }

    func testReleasesAtOnceWhenTheUserIsAtTheHost() {
        frontmost = (4242, "com.googlecode.iterm2")
        let broker = makeBroker()
        var announced = 0
        broker.onPending = { _ in announced += 1 }
        let (reply, peer) = reply()

        broker.register(event: event(), reply: reply, session: nil, now: t0)

        XCTAssertTrue(broker.pending.isEmpty)
        XCTAssertEqual(announced, 0)
        XCTAssertEqual(line(peer), #"{"v":2,"request_id":"0123456789abcdef0123456789abcdef","decision":null}"#)
        XCTAssertEqual(broker.releasedForPresenceCount, 1)
        XCTAssertNil(store.sessions.first?.pendingPermissionID)
    }

    func testHoldsWhenTheHostIsFrontmostButTheScreenIsLocked() {
        frontmost = (4242, "com.googlecode.iterm2")
        presence.setLocked(true)
        let broker = makeBroker()
        let (reply, _) = reply()
        broker.register(event: event(), reply: reply, session: nil, now: t0)
        XCTAssertEqual(broker.pending.count, 1)
    }

    func testFeatureOffReleasesWithoutCountingPresence() {
        featureEnabled = false
        let broker = makeBroker()
        let (reply, peer) = reply()
        broker.register(event: event(), reply: reply, session: nil, now: t0)
        XCTAssertTrue(broker.pending.isEmpty)
        XCTAssertEqual(line(peer), #"{"v":2,"request_id":"0123456789abcdef0123456789abcdef","decision":null}"#)
        XCTAssertEqual(broker.releasedForPresenceCount, 0)
    }

    func testNoHostAnywhereReleases() {
        let broker = makeBroker()
        let (reply, peer) = reply()
        broker.register(event: event(host: .none), reply: reply, session: nil, now: t0)
        XCTAssertTrue(broker.pending.isEmpty)
        XCTAssertNotNil(line(peer))
    }

    func testFallsBackToTheStoredSessionHostWhenTheEventHasNone() {
        let broker = makeBroker()
        let session = Fixture.agentSession(sessionID: "s1", host: iterm)
        let (reply, _) = reply()
        broker.register(event: event(host: .none), reply: reply, session: session, now: t0)
        XCTAssertEqual(broker.pending.count, 1, "the store remembers the terminal from earlier hooks")
    }

    func testAnEventWithoutARequestIDIsReleasedNotHeld() {
        let broker = makeBroker()
        let reply = AgentReply(requestID: nil)   // v1 helper: the server already answered
        broker.register(event: event(), reply: reply, session: nil, now: t0)
        XCTAssertTrue(broker.pending.isEmpty)
    }

    func testASecondRequestForTheSameSessionExpiresTheFirst() {
        let broker = makeBroker()
        var resolved: [(String, PermissionResolution)] = []
        broker.onResolved = { resolved.append(($0.id, $1)) }
        let first = reply("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        let second = reply("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")

        broker.register(event: event(requestID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"), reply: first.0, session: nil, now: t0)
        broker.register(event: event(requestID: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"), reply: second.0, session: nil, now: t0.addingTimeInterval(1))

        XCTAssertEqual(broker.pending.map(\.id), ["bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"])
        XCTAssertEqual(resolved.map(\.0), ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"])
        XCTAssertEqual(resolved.first?.1, .expired)
        XCTAssertNotNil(line(first.1))
        XCTAssertNil(line(second.1))
    }

    func testPendingIsNewestFirstAcrossSessions() {
        let broker = makeBroker()
        let a = reply("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        let b = reply("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        broker.register(event: event(sessionID: "s1", requestID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"), reply: a.0, session: nil, now: t0)
        broker.register(event: event(sessionID: "s2", requestID: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"), reply: b.0, session: nil, now: t0.addingTimeInterval(1))
        XCTAssertEqual(broker.pending.map(\.sessionID), ["claude:s2", "claude:s1"])
        XCTAssertEqual(broker.pending(for: "claude:s1")?.id, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        XCTAssertNil(broker.pending(for: "claude:s9"))
    }

    // MARK: - answer / release / expiry

    func testAnswerAllowWritesOnceClearsTheStoreAndResolvesAfterRemoval() {
        let broker = makeBroker()
        var resolved: [(PendingPermission, PermissionResolution, Int)] = []
        broker.onResolved = { [broker] request, why in resolved.append((request, why, broker.pending.count)) }
        let (reply, peer) = reply()
        broker.register(event: event(), reply: reply, session: nil, now: t0)
        store.apply(event(), now: t0)
        XCTAssertEqual(store.sessions.first?.pendingPermissionID, AgentFixture.requestID)

        broker.answer(id: AgentFixture.requestID, .allow)
        broker.answer(id: AgentFixture.requestID, .deny)     // duplicate: ignored
        broker.answer(id: "nope", .allow)                     // unknown: ignored

        XCTAssertEqual(line(peer), #"{"v":2,"request_id":"0123456789abcdef0123456789abcdef","decision":"allow"}"#)
        var byte: UInt8 = 0
        XCTAssertEqual(read(peer, &byte, 1), 0, "one line, then EOF")
        XCTAssertTrue(broker.pending.isEmpty)
        XCTAssertEqual(broker.answeredCount, 1)
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.1, .answered(.allow))
        XCTAssertEqual(resolved.first?.2, 0, "onResolved runs after the request left pending")
        XCTAssertNil(store.sessions.first?.pendingPermissionID)
        XCTAssertEqual(store.sessions.first?.state, .needsYou, "the store's state is Claude Code's to change, via the next hook")
    }

    func testDenyIsWrittenAsDeny() {
        let broker = makeBroker()
        let (reply, peer) = reply()
        broker.register(event: event(), reply: reply, session: nil, now: t0)
        broker.answer(id: AgentFixture.requestID, .deny)
        XCTAssertEqual(line(peer), #"{"v":2,"request_id":"0123456789abcdef0123456789abcdef","decision":"deny"}"#)
    }

    func testReleaseWritesNoDecisionAndCountsPresence() {
        let broker = makeBroker()
        var resolved: [PermissionResolution] = []
        broker.onResolved = { resolved.append($1) }
        let (reply, peer) = reply()
        broker.register(event: event(), reply: reply, session: nil, now: t0)

        broker.release(id: AgentFixture.requestID)
        broker.release(id: AgentFixture.requestID)

        XCTAssertEqual(line(peer), #"{"v":2,"request_id":"0123456789abcdef0123456789abcdef","decision":null}"#)
        XCTAssertEqual(resolved, [.releasedForPresence])
        XCTAssertEqual(broker.releasedForPresenceCount, 1)
        XCTAssertTrue(broker.pending.isEmpty)
    }

    func testReleaseAllForSessionLeavesOtherSessionsAlone() {
        let broker = makeBroker()
        let a = reply("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        let b = reply("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        broker.register(event: event(sessionID: "s1", requestID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"), reply: a.0, session: nil, now: t0)
        broker.register(event: event(sessionID: "s2", requestID: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"), reply: b.0, session: nil, now: t0)

        broker.releaseAll(for: "claude:s1")

        XCTAssertEqual(broker.pending.map(\.sessionID), ["claude:s2"])
        XCTAssertNotNil(line(a.1))
        XCTAssertNil(line(b.1))
    }

    func testActivatingTheHostAppReleasesItsSessions() {
        let broker = makeBroker()
        // Our own process stands in for the terminal: NSRunningApplication.current is the only one a test can hand over.
        let mine = AgentHostInfo(pid: getpid(), bundleID: Bundle.main.bundleIdentifier, tty: nil)
        let a = reply("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        let b = reply("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        broker.register(event: event(host: mine, sessionID: "s1", requestID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"), reply: a.0, session: nil, now: t0)
        broker.register(event: event(sessionID: "s2", requestID: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"), reply: b.0, session: nil, now: t0)

        presence.onActivation?(NSRunningApplication.current)

        XCTAssertEqual(broker.pending.map(\.sessionID), ["claude:s2"])
        XCTAssertEqual(broker.releasedForPresenceCount, 1)
        XCTAssertNotNil(line(a.1))
    }

    func testExpiryReleasesWithNoDecisionAndReportsExpired() async throws {
        let broker = makeBroker(holdWindow: 0.2)
        var resolved: [(PermissionResolution, Int)] = []
        broker.onResolved = { [broker] _, why in resolved.append((why, broker.pending.count)) }
        let (reply, peer) = reply()
        broker.register(event: event(), reply: reply, session: nil, now: t0)
        store.apply(event(), now: t0)

        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertTrue(broker.pending.isEmpty)
        XCTAssertEqual(broker.expiredCount, 1)
        XCTAssertEqual(resolved.map(\.0), [.expired])
        XCTAssertEqual(resolved.first?.1, 0)
        XCTAssertEqual(line(peer), #"{"v":2,"request_id":"0123456789abcdef0123456789abcdef","decision":null}"#)
        XCTAssertNil(store.sessions.first?.pendingPermissionID)

        broker.answer(id: AgentFixture.requestID, .allow)   // stale click after expiry: ignored
        XCTAssertEqual(broker.answeredCount, 0)
    }

    func testAnsweringCancelsTheExpiry() async throws {
        let broker = makeBroker(holdWindow: 0.2)
        var resolved: [PermissionResolution] = []
        broker.onResolved = { resolved.append($1) }
        let (reply, _) = reply()
        broker.register(event: event(), reply: reply, session: nil, now: t0)
        broker.answer(id: AgentFixture.requestID, .allow)

        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(resolved, [.answered(.allow)])
        XCTAssertEqual(broker.expiredCount, 0)
    }

    func testAHelperThatHangsUpIsResolvedAsExpired() async throws {
        let broker = makeBroker()
        var resolved: [PermissionResolution] = []
        broker.onResolved = { resolved.append($1) }
        let (reply, _) = reply()
        broker.register(event: event(), reply: reply, session: nil, now: t0)

        reply.peerClosed()   // what the server calls when it reads EOF from the helper
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(broker.pending.isEmpty)
        XCTAssertEqual(resolved, [.expired])
        XCTAssertEqual(broker.expiredCount, 1)
    }

    func testNothingIsPersisted() {
        // Spec rule 4: pending requests live in memory only.
        let broker = makeBroker()
        let (reply, _) = reply()
        broker.register(event: event(), reply: reply, session: nil, now: t0)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertEqual(contents, [], "the broker wrote \(contents)")
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS="" -only-testing:UsageTrackerTests/PermissionBrokerTests`
Expected: compile error `cannot find 'PermissionBroker' in scope`.

- [ ] **Step 4: Create `PermissionBroker`**

```swift
// UsageTracker/Agents/PermissionBroker.swift
import AppKit
import Combine

/// One Claude Code permission request Omelette is holding. Carries only what the
/// notification and the popover row show (spec rule 6): the tool name and the
/// ≤ 80-char summary — never the tool input.
struct PendingPermission: Identifiable, Equatable, Sendable {
    let id: String                 // request_id
    let sessionID: String          // AgentSession.id ("claude:<uuid>")
    let toolName: String?
    let toolSummary: String?
    let receivedAt: Date
    let expiresAt: Date
}

/// Why a hold ended. Passed to `PermissionBroker.onResolved` once the request has
/// left `pending`.
enum PermissionResolution: Equatable, Sendable {
    case answered(PermissionDecision)   // Allow / Deny from the notification or the row
    case releasedForPresence            // the hosting app became frontmost (or already was)
    case expired                        // the 120 s hold ran out, or the helper went away first
}

/// Decides what happens to a `PermissionRequest` the server is holding: release it at
/// once (the user is looking at that terminal, the feature is off, or we don't know
/// where the session lives) or hold it for up to `holdWindow` while the UI offers
/// Allow / Deny. Everything lives in memory (spec rule 4); only `answer(id:_:)` can
/// ever produce an `allow` (rule 7); every id is consumed on first resolution (rule 3).
@MainActor
final class PermissionBroker: ObservableObject {
    static let shared = PermissionBroker()

    /// Spec: hold up to 120 s. The helper waits 140 s and the hook allows 150 s, so
    /// the app always gives up first and withdraws its UI before the helper can.
    static let holdWindow: TimeInterval = 120

    /// Newest first.
    @Published private(set) var pending: [PendingPermission] = []

    /// Diagnostics (Settings → Agents, package 2).
    private(set) var answeredCount = 0
    private(set) var expiredCount = 0
    private(set) var releasedForPresenceCount = 0

    /// A request was just held — package 2 files the Allow / Deny notification.
    var onPending: ((PendingPermission) -> Void)?
    /// A request is gone from `pending` (and the session's `pendingPermissionID` is
    /// cleared) — package 2 withdraws the notification and, on `.expired`, falls back
    /// to the plain needs-you banner.
    var onResolved: ((PendingPermission, PermissionResolution) -> Void)?

    private struct Held {
        let reply: AgentReply
        let host: AgentHostInfo
        var expiry: Task<Void, Never>?
    }
    private var held: [String: Held] = [:]
    private let store: AgentSessionStore
    private let presence: PresenceMonitor
    private let featureEnabled: () -> Bool
    private let holdWindow: TimeInterval

    init(
        store: AgentSessionStore = .shared,
        presence: PresenceMonitor = .shared,
        featureEnabled: @escaping () -> Bool = PermissionBroker.featureIsUsable,
        holdWindow: TimeInterval = PermissionBroker.holdWindow
    ) {
        self.store = store
        self.presence = presence
        self.featureEnabled = featureEnabled
        self.holdWindow = holdWindow
        presence.onActivation = { [weak self] app in
            self?.hostActivated(pid: app.processIdentifier, bundleID: app.bundleIdentifier)
        }
    }

    /// The production feature flag: the switch is on *and* the installed Claude hooks
    /// are exactly this build's template. A hold only makes sense if the
    /// `PermissionRequest` hook is registered with the 150 s cap; an install from 2.1
    /// (`timeout: 5`, which reads `.outdated`) has Claude Code kill the helper after
    /// five seconds, and a five-second Allow/Deny banner that vanishes on its own is
    /// worse than the terminal prompt. Two small file reads per request — the same
    /// check Settings → Agents polls every 2 s.
    static func featureIsUsable() -> Bool {
        SettingsStore.shared.agentsAnswerPermissions
            && AgentHooksInstaller.claudeStatus(
                settingsURL: AgentPaths.claudeSettingsURL,
                helperPath: AgentPaths.helperSymlinkURL.path
            ) == .installed
    }

    /// The whole policy, as a pure function (spec).
    static func shouldHold(userAtHost: Bool, featureEnabled: Bool, hasHost: Bool) -> Bool {
        featureEnabled && hasHost && !userAtHost
    }

    /// Called by the channel for every `permissionRequested` event, *before* the store
    /// applies it (so `pending(for:)` already answers inside `onNeedsYou`).
    func register(event: AgentEvent, reply: AgentReply, session: AgentSession?, now: Date = Date()) {
        guard event.kind == .permissionRequested, let id = reply.requestID else {
            reply.send(nil)   // nothing to hold (v1 helper, or a misrouted event)
            return
        }
        let host = event.host == .none ? (session?.host ?? .none) : event.host
        let hasHost = host.pid != nil || host.bundleID != nil
        let userAtHost = hasHost && presence.isUserAt(host: host)
        guard Self.shouldHold(userAtHost: userAtHost, featureEnabled: featureEnabled(), hasHost: hasHost) else {
            if userAtHost { releasedForPresenceCount += 1 }
            reply.send(nil)
            return
        }

        let sessionID = session?.id ?? AgentSession.makeID(source: event.source, sessionID: event.sessionID)
        // Claude Code blocks on the hook, so a second request for the same session
        // means the first hook is already gone (killed by an old 5 s timeout).
        for stale in pending where stale.sessionID == sessionID {
            resolve(id: stale.id, decision: nil, as: .expired)
        }

        let request = PendingPermission(
            id: id, sessionID: sessionID, toolName: event.toolName, toolSummary: event.toolSummary,
            receivedAt: now, expiresAt: now.addingTimeInterval(holdWindow)
        )
        held[id] = Held(reply: reply, host: host, expiry: nil)
        pending.insert(request, at: 0)
        store.setPendingPermission(id: id, for: sessionID)
        reply.onPeerClosed { [weak self] in
            Task { @MainActor [weak self] in self?.peerLeft(id: id) }
        }
        held[id]?.expiry = Task { [weak self, holdWindow] in
            try? await Task.sleep(nanoseconds: UInt64(holdWindow * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.expire(id: id)
        }
        NSLog("[UT] permission held request=%@ session=%@", String(id.prefix(8)), String(event.sessionID.prefix(8)))
        onPending?(request)
    }

    /// User action. Idempotent: a second click, or a click after expiry, does nothing.
    func answer(id: String, _ decision: PermissionDecision) {
        guard held[id] != nil else { return }
        answeredCount += 1
        resolve(id: id, decision: decision, as: .answered(decision))
    }

    /// No decision — the user went back to the terminal. Idempotent.
    func release(id: String) {
        guard held[id] != nil else { return }
        releasedForPresenceCount += 1
        resolve(id: id, decision: nil, as: .releasedForPresence)
    }

    func releaseAll(for sessionID: String) {
        for id in pending.filter({ $0.sessionID == sessionID }).map(\.id) {
            release(id: id)
        }
    }

    func pending(for sessionID: String) -> PendingPermission? {
        pending.first { $0.sessionID == sessionID }
    }

    // MARK: - Private

    private func expire(id: String) {
        guard held[id] != nil else { return }
        expiredCount += 1
        resolve(id: id, decision: nil, as: .expired)
    }

    /// The helper hung up before anyone answered: same outcome as expiry for the user
    /// (Claude Code is showing its own prompt), so it is counted and reported as one.
    private func peerLeft(id: String) {
        expire(id: id)
    }

    private func hostActivated(pid: Int32, bundleID: String?) {
        let ids = held.filter { PresenceMonitor.matches(frontmost: (pid, bundleID), host: $0.value.host) }.map(\.key)
        for id in ids { release(id: id) }
    }

    /// Consumes the id: sends (at most once — `AgentReply` is idempotent too), cancels
    /// the expiry, drops the row, clears the store field, and only then tells the UI.
    private func resolve(id: String, decision: PermissionDecision?, as resolution: PermissionResolution) {
        guard let entry = held.removeValue(forKey: id),
              let index = pending.firstIndex(where: { $0.id == id }) else { return }
        entry.expiry?.cancel()
        entry.reply.send(decision)
        let request = pending.remove(at: index)
        store.setPendingPermission(id: nil, for: request.sessionID)
        NSLog("[UT] permission resolved request=%@ %@", String(id.prefix(8)), String(describing: resolution))
        onResolved?(request, resolution)
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS="" -only-testing:UsageTrackerTests/PermissionBrokerTests -only-testing:UsageTrackerTests/SettingsStoreTests`
Expected: PASS (broker 21 tests; the existing settings tests still pass with the new key). No warnings. If `testActivatingTheHostAppReleasesItsSessions` fails on the pid, `Bundle.main.bundleIdentifier` under xcodebuild is the test host's (`Omelette.app`) — the match is on pid, which is `getpid()` either way.

- [ ] **Step 6: Commit**

```bash
git add UsageTracker/Core/Settings.swift UsageTracker/Agents/PermissionBroker.swift UsageTrackerTests/PermissionBrokerTests.swift
git commit -m "Agents: PermissionBroker — presence-aware hold/release, answer, 120 s expiry; agentsAnswerPermissions key

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

### Task 8: Wire it up — router, `AppState.bootstrap()`, presence start, full run

**Files:**
- Modify: `UsageTracker/Agents/AgentChannel.swift` (append `AgentEventRouter`)
- Modify: `UsageTracker/Core/AppState.swift:32-38`
- Modify: `UsageTracker/UsageTrackerApp.swift:54-57`
- Test: `UsageTrackerTests/AgentChannelTests.swift` (router tests)

**Interfaces:**
- Consumes: `AgentChannel.onEvent` (Task 4), `PermissionBroker.register` (Task 7), `AgentSessionStore.apply` (Task 2), `PresenceMonitor.start()` (Task 6).
- Produces:
  ```swift
  /// The one place the ordering rule lives. AppState.bootstrap() installs it.
  enum AgentEventRouter {
      @MainActor static func handle(_ event: AgentEvent, reply: AgentReply, store: AgentSessionStore, broker: PermissionBroker)
  }
  ```
  Contract: `.permissionRequested` with a `requestID` → `broker.register(event:reply:session:)` **then** `store.apply(event)`; everything else → `store.apply(event)` only (the server already answered; `reply` is settled). A `.permissionRequested` *without* an id is applied only — nothing to hold.

- [ ] **Step 1: Write the failing router tests**

Append to `UsageTrackerTests/AgentChannelTests.swift` (inside the class):

```swift
    // MARK: - AgentEventRouter (bootstrap wiring)

    private func makeStoreAndBroker(userAway: Bool = true) -> (AgentSessionStore, PermissionBroker) {
        let store = AgentSessionStore(historyURL: historyURL)
        let presence = PresenceMonitor(frontmost: { userAway ? (1, "com.other") : (4242, "com.googlecode.iterm2") })
        let broker = PermissionBroker(store: store, presence: presence, featureEnabled: { true })
        return (store, broker)
    }

    private func permissionEvent(requestID: String? = AgentFixture.requestID) -> AgentEvent {
        AgentEvent(source: .claude, kind: .permissionRequested, sessionID: "s1", cwd: "/Users/tester/Projects/alpha",
                   toolName: "Edit", toolSummary: "Edit: WalletView.swift", isSubagent: false,
                   host: AgentHostInfo(pid: 4242, bundleID: "com.googlecode.iterm2", tty: nil),
                   receivedAt: Date(), requestID: requestID)
    }

    func testRouterRegistersWithTheBrokerBeforeApplyingToTheStore() {
        let (store, broker) = makeStoreAndBroker()
        var pendingInsideNeedsYou: String??
        store.onNeedsYou = { [broker] session in pendingInsideNeedsYou = .some(broker.pending(for: session.id)?.id) }
        let (reply, peer) = AgentFixture.replyPair()
        defer { close(peer) }

        AgentEventRouter.handle(permissionEvent(), reply: reply, store: store, broker: broker)

        XCTAssertEqual(pendingInsideNeedsYou, .some(AgentFixture.requestID), "onNeedsYou must already see the held request")
        XCTAssertEqual(store.sessions.first?.state, .needsYou)
        XCTAssertEqual(store.sessions.first?.pendingPermissionID, AgentFixture.requestID)
        XCTAssertFalse(reply.isSettled)
    }

    func testRouterReleasesWhenTheUserIsAtTheTerminalAndStillAppliesTheEvent() {
        let (store, broker) = makeStoreAndBroker(userAway: false)
        let (reply, peer) = AgentFixture.replyPair()
        defer { close(peer) }

        AgentEventRouter.handle(permissionEvent(), reply: reply, store: store, broker: broker)

        XCTAssertTrue(reply.isSettled)
        XCTAssertTrue(broker.pending.isEmpty)
        XCTAssertEqual(store.sessions.first?.state, .needsYou, "the row still shows needs-you; Claude is prompting in the terminal")
        XCTAssertNil(store.sessions.first?.pendingPermissionID)
    }

    func testRouterHandsTheStoredSessionToTheBroker() {
        // Second request in a session the store already knows: the broker gets the row.
        let (store, broker) = makeStoreAndBroker()
        let first = AgentFixture.replyPair(requestID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        defer { close(first.peer) }
        AgentEventRouter.handle(permissionEvent(requestID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"), reply: first.reply, store: store, broker: broker)
        broker.answer(id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .allow)

        let second = AgentFixture.replyPair(requestID: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        defer { close(second.peer) }
        var hostless = permissionEvent(requestID: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        hostless = AgentEvent(source: hostless.source, kind: hostless.kind, sessionID: hostless.sessionID, cwd: hostless.cwd,
                              toolName: hostless.toolName, toolSummary: hostless.toolSummary, isSubagent: false,
                              host: .none, receivedAt: hostless.receivedAt, requestID: hostless.requestID)
        AgentEventRouter.handle(hostless, reply: second.reply, store: store, broker: broker)

        XCTAssertEqual(broker.pending.map(\.id), ["bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"], "the session's stored host made the hold possible")
    }

    func testRouterOnlyAppliesNonPermissionEvents() {
        let (store, broker) = makeStoreAndBroker()
        let reply = AgentReply(requestID: nil)
        let stop = AgentEvent(source: .claude, kind: .stop, sessionID: "s1", cwd: nil, toolName: nil, toolSummary: nil,
                              isSubagent: false, host: .none, receivedAt: Date())

        AgentEventRouter.handle(stop, reply: reply, store: store, broker: broker)

        XCTAssertEqual(store.sessions.first?.state, .done)
        XCTAssertTrue(broker.pending.isEmpty)
    }

    func testRouterAppliesAPermissionWithoutAnIDWithoutHolding() {
        let (store, broker) = makeStoreAndBroker()
        AgentEventRouter.handle(permissionEvent(requestID: nil), reply: AgentReply(requestID: nil), store: store, broker: broker)
        XCTAssertEqual(store.sessions.first?.state, .needsYou)
        XCTAssertTrue(broker.pending.isEmpty)
        XCTAssertNil(store.sessions.first?.pendingPermissionID)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS="" -only-testing:UsageTrackerTests/AgentChannelTests`
Expected: compile error `cannot find 'AgentEventRouter' in scope`.

- [ ] **Step 3: Add the router and install it**

Append to `UsageTracker/Agents/AgentChannel.swift`:

```swift
/// What `AppState.bootstrap()` installs as `AgentChannel.shared.onEvent`. Kept as a
/// function over its two collaborators so the ordering rule is testable:
///
/// 1. A held `PermissionRequest` (it carries a request id) is registered with the
///    broker *first*, so that when the store applies the event and fires `onNeedsYou`
///    synchronously, `broker.pending(for:)` already answers and the notifier can
///    withhold the plain needs-you banner.
/// 2. Then the store applies it. For every other event only step 2 runs — the server
///    has already written the immediate reply.
enum AgentEventRouter {
    @MainActor
    static func handle(_ event: AgentEvent, reply: AgentReply, store: AgentSessionStore, broker: PermissionBroker) {
        if event.kind == .permissionRequested, reply.requestID != nil {
            let id = AgentSession.makeID(source: event.source, sessionID: event.sessionID)
            broker.register(event: event, reply: reply, session: store.sessions.first { $0.id == id })
        }
        store.apply(event)
    }
}
```

In `UsageTracker/Core/AppState.swift` replace the `AgentChannel.shared.onEvent = …` block (the one Task 4 left, with its comment) with:

```swift
        // Package 1's AgentChannel delivers hook events on the main actor. The router
        // registers a held PermissionRequest with the broker before the session store
        // applies it (see AgentEventRouter for why the order matters).
        AgentChannel.shared.onEvent = { event, reply in
            AgentEventRouter.handle(event, reply: reply, store: AgentSessionStore.shared, broker: PermissionBroker.shared)
        }
```

In `UsageTracker/UsageTrackerApp.swift` after `AgentChannel.shared.start()` (line 57) add:

```swift
        // Presence for held permission requests: which app is in front, lock/sleep,
        // and the activation that releases a hold when the user returns to the terminal.
        PresenceMonitor.shared.start()
```

- [ ] **Step 4: Run the router tests**

Run: `xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS="" -only-testing:UsageTrackerTests/AgentChannelTests`
Expected: PASS (13 tests).

- [ ] **Step 5: Run the whole suite and the app build**

Run: `xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS="" 2>&1 | grep -E "warning:|error:|Test Suite 'All tests'|Executed|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, `Executed N tests, with 0 failures`, and no `warning:` line from `UsageTracker/`, `UsageTrackerTests/` or `HookHelper/`.

Run: `xcodebuild -project UsageTracker.xcodeproj -scheme UsageTracker -configuration Debug -derivedDataPath build/DerivedData build 2>&1 | grep -E "warning:|error:|BUILD"`
Expected: `** BUILD SUCCEEDED **`, no warnings.

- [ ] **Step 6: Manual smoke (owner's machine — deferred until package 2 is merged)**

**Do not run this from the worktree, and do not run it at all in this package**: `PermissionBroker.featureIsUsable` requires the installed hooks to match the *current* template, and until package 2 bumps `PermissionRequest` to `timeout: 150` (and the owner clicks Update) every request is released to the terminal, so there is nothing to observe. The list below is the phase-4 smoke the coordinator runs after both packages land.

1. Run the Debug build (`open build/DerivedData/Build/Products/Debug/Omelette.app`; it takes the socket over from the login copy). Hooks installed → Settings → Agents shows "omelette-hook v2".
2. In iTerm, in a project where Claude Code will ask for permission, trigger a prompt; **stay in iTerm**: the prompt appears immediately as before (release-for-presence; `releasedForPresenceCount` increments — visible in package 2's diagnostics, or `log stream --predicate 'eventMessage contains "[UT] permission"'`).
3. Trigger another one, then switch to Safari before it fires: the log shows `permission held …`; the terminal shows no prompt yet. Switch back to iTerm → `permission resolved … releasedForPresence`, and Claude Code's prompt appears. (Allow/Deny UI is package 2.)
4. Hold once more and wait: after ~120 s → `resolved … expired`; the prompt appears in the terminal. With the still-current `timeout: 5` template, expect instead `resolved … expired` after ~5 s (Claude Code killed the helper; `onPeerClosed` path) — package 2's template bump removes that.
5. Quit Omelette while a request is held: Claude Code's prompt appears at once (EOF → no decision).

- [ ] **Step 7: Commit**

```bash
git add UsageTracker/Agents/AgentChannel.swift UsageTracker/Core/AppState.swift UsageTracker/UsageTrackerApp.swift UsageTrackerTests/AgentChannelTests.swift
git commit -m "Agents: route held PermissionRequests to the broker before the store; start PresenceMonitor at launch

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

## Self-review

**Spec coverage.**
- Behaviour table: host frontmost → release (Task 7 `testReleasesAtOnceWhenTheUserIsAtTheHost`); other app / locked / asleep → hold (Tasks 6–7); no host or feature off → release (Task 7). Switching to the host releases (Task 7 activation test + Task 6 observer). Expiry 120 s releases without a decision and reports `.expired` after removal (Task 7). Omelette quitting → helper sees EOF → no decision (Task 5 `awaitDecision` EOF branch; E2E `testNullDecisionFromTheAppPrintsNothing` covers the null path, the quit path is the same `read == 0`).
- Security rules: 1 fail-closed (Task 5: none / mismatch / malformed / unknown decision / clamp); 2 peer auth (Task 4, three tests, counted in `droppedCount` + `rejectedPeerCount`); 3 one-shot id (Task 3 idempotence, Task 4 wire idempotence, Task 5 fresh id per request, Task 7 duplicate/late answer ignored); 4 in-memory only (Task 7 `testNothingIsPersisted`; `PendingPermission` is never encoded); 5 timeouts 140 / 145 / 120 (`HookMain.decisionTimeout`, `permissionWatchdogGraceMilliseconds`, `AgentEventServer.defaultHoldTimeout`, `PermissionBroker.holdWindow`; the hook `timeout: 150` is package 2); 6 notification content (`PendingPermission` fields); 7 no auto-allow (`answer` is the only `.allow` producer; the server's timeout, the broker's expiry/release/peer-left and the helper's failure paths all yield `nil`/nothing).
- Protocol: `v: 2`, `request_id` only on `PermissionRequest` (Task 5 helper, Task 1 decoder ignores it elsewhere), v1 still accepted (Task 1), reply line shape (Task 3 `line`), immediate reply unchanged (Task 4).
- Components: helper (Task 5), server (Task 4), `AgentReply` (Task 3), broker + `PermissionResolution` + `shouldHold` (Task 7), presence (Task 6), session model + store (Tasks 1–2), channel wiring with register-before-apply (Task 8), `agentsAnswerPermissions` key (Task 7). `AgentDiagnostics` untouched.
- Coordinator amendments: `onResolved(_, PermissionResolution)` after removal (Task 7, asserted via `pending.count == 0` inside the callback); register before apply with a test (Task 7 `testPendingIsVisibleInsideOnNeedsYouWhenRegisteredFirst`, Task 8 `testRouterRegistersWithTheBrokerBeforeApplyingToTheStore`); `event.host` first, session host fallback (Task 7 `testFallsBackToTheStoredSessionHostWhenTheEventHasNone`), unseen session held when host known (`testHoldsWhenTheUserIsAwayAndPublishesPending` passes `session: nil`); settings key owned here (Task 7 Step 1).

**Placeholder scan.** No TBD/TODO; every code step carries the code; the manual smoke is labelled optional and is not a substitute for any test.

**Type consistency.** `AgentReply.send(_:)` / `sendRaw(_:)` / `peerClosed()` / `closeDescriptor()` / `onPeerClosed(_:)` / `isSettled` / `line(requestID:decision:)` are used with those exact names in Tasks 4, 5, 7, 8. `AgentEventServer.init(socketURL:holdTimeout:peerUID:onEvent:)` matches its test helper. `PresenceMonitor.matches(frontmost:host:)`, `isUserAt(host:)`, `setLocked`/`setAsleep`, `onActivation` match Tasks 6–7. `AgentSessionStore.setPendingPermission(id:for:)` matches Tasks 2, 7. `AgentFixture.envelope(…requestID:)`, `AgentFixture.requestID`, `AgentFixture.replyPair`, `AgentSocketTestClient.open/readLine` match every test that uses them. `AgentEvent.init` gains only a trailing defaulted `requestID`, so `AgentSessionStoreTests.event(...)` and the decoder keep compiling.
