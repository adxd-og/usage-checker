# Phase 4 · Package 2 — Allow / Deny in the notification and the popover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put the two buttons on screen — **Allow** and **Deny** on the notification and on the session's row in the popover — wire them to `PermissionBroker`, give the feature a switch and four counters in Settings → Agents, widen the hook's timeout to 150 s, and cut 2.2.0.

**Architecture:** Package 1 owns the decision machinery (`PermissionBroker`, `PresenceMonitor`, `AgentReply`, `AgentSession.pendingPermissionID`); this package is the surface over it and adds no logic of its own beyond four pure rules. `AgentNotificationRules` gains the permission banner's copy, its identifier and the one gate that stops the old "needs you" banner from doubling the new one; `UsageNotifier` is the shell that registers the category, fires on `broker.onPending`, withdraws on `broker.onResolved` and routes the two action identifiers back to `broker.answer(id:_:)`. `OMAgentRow` grows a second line whose visibility is decided by `AgentRowText.permissionButtonsVisible(pendingPermissionID:source:)`, tested without a view hierarchy. Everything else is text: a settings key, a hook template number, a changelog and a version bump.

**Tech Stack:** Swift 6 (strict concurrency `minimal`), SwiftUI, Combine, UserNotifications, macOS 14 floor, XCTest (`UsageTrackerTests`, `@testable import Omelette`), xcodegen-generated project.

**Spec:** `docs/superpowers/specs/2026-09-02-phase4-approve-deny-design.md` (binding — this package is its "Packages / 2"); roadmap: `docs/superpowers/specs/2026-09-02-agent-control-plane-roadmap.md`, "Phase 4".

## Global Constraints

Carried verbatim from `docs/superpowers/plans/2026-09-02-agent-overview-p5-pill-notifications.md` and the phase-3 package it inherits from:

- Deployment target macOS 14.0; every glass effect goes through the existing helpers in `UsageTracker/UI/Components/LiquidGlass.swift` (`liquidGlass(in:tint:)`, `GlassGroup`, `glassButtonStyle()`, `glassProminentButtonStyle()`), never a bare `glassEffect` call.
- Colour semantics: `usageStatusColor` returns `.green` below 70, `.orange` from 70, `.red` from 90. Agent-state colours come from `OMAgentColor`.
- Popover width stays 360 pt; `NSPopover.contentSize` in `StatusBarController.swift:21` stays 340×460.
- Every user-visible string that exists today keeps its wording (status phrases, burn verdict, "N unused windows", "You haven't used X yet", "Server responded but returned no usage data.", state help texts, the Agents tab's existing captions). This package only *adds* strings, plus the README/CHANGELOG edits in Task 7.
- **The menu bar must never redraw continuously.** No `TimelineView`, no `.repeatForever`, no timer, no `withAnimation` anywhere in the pill's path. Nothing in this package touches `MenuBarLabel.swift` or `OMAgentsPill`.
- New source files are picked up by xcodegen from `sources: - path: UsageTracker` / `- path: UsageTrackerTests`; run `xcodegen generate` after adding a file and before building. `UsageTracker.xcodeproj/` is generated and gitignored — never `git add` it. (This package adds **no** new source file, so no `xcodegen generate` is needed until Task 7's version bump.)
- Build: `xcodebuild -project UsageTracker.xcodeproj -scheme UsageTracker -configuration Debug -derivedDataPath build/DerivedData build`
- Tests: `xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS=""` (add `-only-testing:UsageTrackerTests/<Class>` for one class). **The two overrides are mandatory on every `xcodebuild test`** — `signing.xcconfig` turns on the hardened runtime, which blocks the `DYLD_INSERT_LIBRARIES` injection XCTest needs, and the runner then hangs for ~6 min with "The test runner hung before establishing connection". Plain `build` keeps the real settings.
- The build must stay warning-free: `xcodebuild ... build 2>&1 | grep -c "warning:"` must print `0`. Swift 6 with no `nonisolated(unsafe)` additions.
- Commits end with the trailer lines
  `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` and
  `Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X`.
- Other sessions may commit the working tree while you work: re-read a file right before editing it, and prefer targeted edits over whole-file rewrites.
- No release build in this plan: the owner runs the local build/notarize flow after testing. Task 7 prepares the version and the notes only.

### Package-1 dependency (do not build these)

`PermissionBroker`, `PendingPermission`, `PermissionDecision`, `PresenceMonitor`, `AgentReply` and `AgentSession.pendingPermissionID` belong to package 1 and are consumed here by the names the spec fixes. If a symbol below is missing, package 1 is not merged yet — **stop and say so rather than stubbing it**.

### Preconditions (verify before Task 1)

Run:

```bash
cd "<repo>" && \
grep -n "static let shared\|var pending\|func answer\|func pending(for\|var onPending\|var onResolved\|answeredCount\|expiredCount\|releasedForPresenceCount\|static func shouldHold" UsageTracker/Agents/PermissionBroker.swift; \
grep -n "pendingPermissionID" UsageTracker/Agents/AgentModels.swift; \
grep -rn "onPending\|onResolved" UsageTracker --include='*.swift' | grep -v PermissionBroker.swift; \
grep -n "enum PermissionResolution\|case answered\|case releasedForPresence\|case expired" UsageTracker/Agents/PermissionBroker.swift; \
grep -n "agentsAnswerPermissions" UsageTracker/Core/Settings.swift
```

Expected: the first grep lists `shared`, `pending`, `answer(id:_:)`, `pending(for:)`, `onPending`, `onResolved`, the three counters and `shouldHold`; the second shows `var pendingPermissionID: String?` on `AgentSession`; the third prints **nothing** — nobody has claimed the two callbacks, which this package assigns in Task 2. If the third prints an assignment in `AppState`/`AgentChannel`, read it first: two owners of `onPending` means the last assignment wins and the notification silently disappears. Keep `UsageNotifier`'s assignment and delete the other, or stop and report the conflict. The fourth shows `enum PermissionResolution` with its three cases (`onResolved` is `((PendingPermission, PermissionResolution) -> Void)?` — two arguments). The fifth shows the `Defaults` constant, the `@AppStorage` property and the reset line: package 1 owns that key; Task 3 only tests it.

---

## File structure

```
UsageTracker/Services/
  AgentNotificationRules.swift    MODIFIED — permission copy, identifier, suppression gate (Task 1)
  UsageNotifier.swift             MODIFIED — AGENT_PERMISSION category, broker wiring, routing (Task 2)
UsageTracker/Core/
  Settings.swift                  MODIFIED — agentsAnswerPermissions (Task 3)
UsageTracker/Agents/
  PermissionBroker.swift          MODIFIED — one line: the feature flag reads the setting (Task 3)
  AgentHooksInstaller.swift       MODIFIED — PermissionRequest timeout 5 → 150 (Task 6)
UsageTracker/UI/DesignSystem/
  OMAgentRow.swift                MODIFIED — permissionButtonsVisible + the Allow/Deny line + previews (Task 4)
  AgentsSection.swift             MODIFIED — passes the two broker closures into the row (Task 4)
UsageTracker/UI/
  AgentsSettingsView.swift        MODIFIED — Permissions section: toggle, caption, four counters (Task 5)
UsageTrackerTests/
  AgentNotificationRulesTests.swift  MODIFIED — suppression + permission copy/identifier (Task 1)
  SettingsStoreTests.swift           MODIFIED — the new key in scramble/assert/defaults (Task 3)
  AgentRowTextTests.swift            MODIFIED — permissionButtonsVisible table (Task 4)
  AgentHooksInstallerTests.swift     MODIFIED — timeout 150 + "a 5 s install is outdated" (Task 6)
project.yml                       MODIFIED — 2.2.0 / 32 in the app and the widget (Task 7)
CHANGELOG.md                      MODIFIED — [2.2.0] — unreleased (Task 7)
README.md                         MODIFIED — Features bullet, Settings bullet (Task 7)
```

`PopoverView.swift` is **not** in the list on purpose: both agent lists (All tab, provider tab) render through `AgentsSection`, so Task 4's change reaches them without touching the popover. The dashboard's live list (`UI/Dashboard/AgentsHistoryView.swift:68`) uses the same section and therefore gets the same buttons — intended, and nothing to edit there either.

---

### Task 1: The permission banner's rules

**Files:**
- Modify: `UsageTracker/Services/AgentNotificationRules.swift`
- Test: `UsageTrackerTests/AgentNotificationRulesTests.swift`

**Interfaces:**
- Consumes: nothing from package 1 (the rules take plain values, which is what keeps them testable).
- Produces:
  ```swift
  extension AgentNotificationRules {
      static let permissionPrefix: String                     // "agent-permission-"
      static let maxPermissionBodyLength: Int                 // 80
      static func permissionIdentifier(requestID: String) -> String
      static func requestID(fromIdentifier identifier: String) -> String?
      static func permissionTitle(projectName: String, toolName: String?) -> String
      static func permissionBody(toolSummary: String?) -> String
      // CHANGED signature — gains a required parameter:
      static func shouldNotifyNeedsYou(
          notifyEnabled: Bool, bypassQuietHours: Bool, isQuietHours: Bool, permissionPending: Bool
      ) -> Bool
  }
  ```

- [ ] **Step 1: Write the failing tests**

Edit `UsageTrackerTests/AgentNotificationRulesTests.swift`. Replace the body of `testEveryNeedsYouToggleCombination` with the table below (it gains a `pending` column and two rows), and append the two new test classes at the end of the file.

```swift
    func testEveryNeedsYouToggleCombination() {
        // Both toggles against both quiet-hours states. `agentsNeedsYouBypassQuietHours`
        // is the only reason any notification in this app survives quiet hours.
        // The last column is phase 4: a session with a permission request in flight is
        // already being asked about by a banner that has Allow and Deny on it.
        let cases: [(notify: Bool, bypass: Bool, quiet: Bool, pending: Bool, expected: Bool)] = [
            (true,  true,  false, false, true),
            (true,  true,  true,  false, true),
            (true,  false, false, false, true),
            (true,  false, true,  false, false),
            (false, true,  false, false, false),
            (false, true,  true,  false, false),
            (false, false, false, false, false),
            (false, false, true,  false, false),
            // A pending request outranks every "yes" above it.
            (true,  true,  false, true,  false),
            (true,  true,  true,  true,  false),
        ]
        for c in cases {
            XCTAssertEqual(
                AgentNotificationRules.shouldNotifyNeedsYou(
                    notifyEnabled: c.notify,
                    bypassQuietHours: c.bypass,
                    isQuietHours: c.quiet,
                    permissionPending: c.pending
                ),
                c.expected,
                "notify=\(c.notify) bypass=\(c.bypass) quiet=\(c.quiet) pending=\(c.pending)"
            )
        }
    }
```

```swift
/// What the Allow / Deny banner says. Only the tool name and the truncated summary
/// leave the hook payload (design doc, security rule 6).
final class AgentPermissionNotificationCopyTests: XCTestCase {
    func testTheTitleNamesTheProjectAndTheTool() {
        XCTAssertEqual(
            AgentNotificationRules.permissionTitle(projectName: "Usage tracker", toolName: "Bash"),
            "Usage tracker wants to run Bash"
        )
    }

    func testARequestWithoutAToolNameStillReadsAsASentence() {
        // The hook payload is not ours to rely on: a PermissionRequest can arrive
        // with no tool_name at all, and "… wants to run " would read as a bug.
        XCTAssertEqual(
            AgentNotificationRules.permissionTitle(projectName: "Orion", toolName: nil),
            "Orion wants to run a tool"
        )
        XCTAssertEqual(
            AgentNotificationRules.permissionTitle(projectName: "Orion", toolName: "   "),
            "Orion wants to run a tool"
        )
    }

    func testTheBodyIsTheToolSummary() {
        XCTAssertEqual(
            AgentNotificationRules.permissionBody(toolSummary: "Bash: rm -rf build/DerivedData"),
            "Bash: rm -rf build/DerivedData"
        )
    }

    func testAMissingSummaryFallsBackToTheWaitingSentence() {
        XCTAssertEqual(AgentNotificationRules.permissionBody(toolSummary: nil), "Waiting for your approval.")
        XCTAssertEqual(AgentNotificationRules.permissionBody(toolSummary: " "), "Waiting for your approval.")
    }

    func testALongSummaryIsCutAtEightyCharacters() {
        // Tighter than the 120 the other banners use: the spec caps what a permission
        // request may show at 80.
        let long = "Bash: " + String(repeating: "x", count: 300)
        let body = AgentNotificationRules.permissionBody(toolSummary: long)
        XCTAssertEqual(body.count, 80)
        XCTAssertEqual(AgentNotificationRules.maxPermissionBodyLength, 80)
        XCTAssertTrue(body.hasSuffix("…"))
        XCTAssertTrue(body.hasPrefix("Bash: xxx"))
    }
}

/// The identifier is what the app withdraws when the hold ends, and what carries the
/// request id back from a button press.
final class AgentPermissionNotificationIdentifierTests: XCTestCase {
    func testTheIdentifierIsTheRequestIDNotTheSession() {
        // Two requests from one session are two questions; filing them both under the
        // session would let the second replace the first and leave one unanswered.
        XCTAssertEqual(
            AgentNotificationRules.permissionIdentifier(requestID: "0f1e2d3c"),
            "agent-permission-0f1e2d3c"
        )
        XCTAssertNotEqual(
            AgentNotificationRules.permissionIdentifier(requestID: "aaaa"),
            AgentNotificationRules.permissionIdentifier(requestID: "bbbb")
        )
    }

    func testTheRequestIDSurvivesTheRoundTrip() {
        let identifier = AgentNotificationRules.permissionIdentifier(requestID: "0f1e2d3c4b5a")
        XCTAssertEqual(AgentNotificationRules.requestID(fromIdentifier: identifier), "0f1e2d3c4b5a")
    }

    func testSomebodyElsesNotificationCarriesNoRequestID() {
        XCTAssertNil(AgentNotificationRules.requestID(fromIdentifier: UUID().uuidString))
        XCTAssertNil(AgentNotificationRules.requestID(fromIdentifier: "agent-permission-"))
        XCTAssertNil(AgentNotificationRules.requestID(fromIdentifier: "agent-needsyou-claude:abc"))
    }

    func testAPermissionIdentifierIsNeverMistakenForASession() {
        // `handleAgentResponse` jumps to whatever session an identifier names; a request
        // id is not one, and answering must not be confused with jumping.
        let identifier = AgentNotificationRules.permissionIdentifier(requestID: "0f1e2d3c")
        XCTAssertNil(AgentNotificationRules.sessionID(fromIdentifier: identifier))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
cd "<repo>" && xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/AgentPermissionNotificationCopyTests ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS="" 2>&1 | tail -20
```
Expected: compilation fails with `type 'AgentNotificationRules' has no member 'permissionTitle'` (and the same for `permissionBody`, `permissionIdentifier`, `requestID`, `maxPermissionBodyLength`), plus `extra argument 'permissionPending' in call`.

- [ ] **Step 3: Add the rules**

In `UsageTracker/Services/AgentNotificationRules.swift`, replace the `shouldNotifyNeedsYou` function with the version below and add the permission block after `donePrefix` / `maxBodyLength`.

```swift
    /// A permission banner is filed under the *request*, not the session: the app
    /// answers one request id at most once, and a second request from the same
    /// session is a different question that must not quietly replace the first.
    static let permissionPrefix = "agent-permission-"
    /// Tighter than `maxBodyLength`: a held request may show the tool name and a
    /// truncated summary and nothing else (design doc, security rule 6).
    static let maxPermissionBodyLength = 80
```

```swift
    /// "Needs you" is the alert the feature exists for, so it gets the one
    /// quiet-hours escape hatch in the app (`agentsNeedsYouBypassQuietHours`,
    /// default on): an agent that blocks at 23:30 blocks until morning otherwise.
    ///
    /// `permissionPending` is the phase-4 veto. When a request for that session is
    /// held, the `AGENT_PERMISSION` banner is already on screen asking the same
    /// question with Allow and Deny on it; a second banner that says the same thing
    /// and can do nothing about it is noise, and its withdrawal races the first.
    static func shouldNotifyNeedsYou(
        notifyEnabled: Bool,
        bypassQuietHours: Bool,
        isQuietHours: Bool,
        permissionPending: Bool
    ) -> Bool {
        guard notifyEnabled, !permissionPending else { return false }
        return !isQuietHours || bypassQuietHours
    }

    static func permissionIdentifier(requestID: String) -> String {
        permissionPrefix + requestID
    }

    /// The request id an identifier was built from, or nil when the banner is not a
    /// permission one. Kept apart from `sessionID(fromIdentifier:)` because the two
    /// answer different questions: this one says who to answer, that one where to jump.
    static func requestID(fromIdentifier identifier: String) -> String? {
        guard identifier.hasPrefix(permissionPrefix) else { return nil }
        let id = String(identifier.dropFirst(permissionPrefix.count))
        return id.isEmpty ? nil : id
    }

    /// "Usage tracker wants to run Bash". The tool name is the one part of the
    /// payload worth a title; without it the sentence still has to hold together.
    static func permissionTitle(projectName: String, toolName: String?) -> String {
        let tool = toolName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "\(projectName) wants to run \(tool.isEmpty ? "a tool" : tool)"
    }

    /// The truncated tool summary — "Bash: rm -rf build/DerivedData". A request that
    /// carries no summary still has to say what the buttons are for.
    static func permissionBody(toolSummary: String?) -> String {
        let summary = toolSummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !summary.isEmpty else { return "Waiting for your approval." }
        return truncate(summary, limit: maxPermissionBodyLength)
    }
```

- [ ] **Step 4: Fix the one existing caller so the app still compiles**

`UsageNotifier.agentNeedsYou(_:)` calls the changed function. Task 2 rewrites that method properly; for now add the argument so this task's tests can run:

```swift
        guard AgentNotificationRules.shouldNotifyNeedsYou(
            notifyEnabled: SettingsStore.shared.agentsNotifyNeedsYou,
            bypassQuietHours: SettingsStore.shared.agentsNeedsYouBypassQuietHours,
            isQuietHours: isInQuietHours(),
            permissionPending: PermissionBroker.shared.pending(for: session.id) != nil
        ) else { return }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run:
```bash
cd "<repo>" && xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/AgentPermissionNotificationCopyTests -only-testing:UsageTrackerTests/AgentPermissionNotificationIdentifierTests -only-testing:UsageTrackerTests/AgentNotificationGatingTests ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS="" 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
cd "<repo>" && git add UsageTracker/Services/AgentNotificationRules.swift UsageTracker/Services/UsageNotifier.swift UsageTrackerTests/AgentNotificationRulesTests.swift && git commit -m "$(cat <<'EOF'
Agents: the permission banner's copy, identifier and needs-you veto

A held PermissionRequest is filed under its request id, shows the tool name
and a summary capped at 80 characters, and suppresses the plain "needs you"
banner for that session — the same question with no buttons on it.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X
EOF
)"
```

---

### Task 2: `AGENT_PERMISSION` — the category, the wiring and the routing

**Files:**
- Modify: `UsageTracker/Services/UsageNotifier.swift` (constants near `agentNeedsYouCategory:346`, `startAgentNotifications:366`, `agentNeedsYou:462`, `handleAgentResponse:512`)

**Interfaces:**
- Consumes: `PermissionBroker.shared`, `.onPending`, `.onResolved`, `.answer(id:_:)`, `.pending(for:)`, `PendingPermission` (`id`, `sessionID`, `toolName`, `toolSummary`), `PermissionDecision.allow` / `.deny` (package 1); `AgentNotificationRules.permissionTitle/permissionBody/permissionIdentifier/requestID/shouldNotifyNeedsYou` (Task 1).
- Produces:
  ```swift
  extension UsageNotifier {
      static let agentPermissionCategory: String   // "AGENT_PERMISSION"
      static let agentAllowAction: String          // "AGENT_ALLOW"
      static let agentDenyAction: String           // "AGENT_DENY"
      func startAgentNotifications(store: AgentSessionStore = .shared, broker: PermissionBroker = .shared)
  }
  ```

**Design decision — the actions are not `.foreground`.**
`.foreground` tells the system to activate the app before delivering the response. Omelette is `LSUIElement`, so "activate" means it takes key focus away from whatever the user is actually typing in — for a button whose entire purpose is answering without leaving the terminal, that is the wrong outcome. Without the option the action is delivered to `userNotificationCenter(_:didReceive:withCompletionHandler:)` in the background, with no activation, which is all `broker.answer(id:_:)` needs; the delegate is installed at launch (before `requestAuthorizationIfNeeded()`), so it is always there to receive it. If Omelette is *not* running, the system launches it to deliver the response — the broker's pending list is memory-only, `answer` finds no such id and does nothing, and the helper has long since released the request to the terminal. Fail-closed, exactly as the spec requires. **Allow** additionally carries `.authenticationRequired`, so approving from a locked Mac's lock screen — a case the presence rule deliberately treats as "hold" — costs an unlock; **Deny** does not, because refusing a tool call needs no protection. The body tap (`UNNotificationDefaultActionIdentifier`) still activates the app, which is what makes `.showPopover` visible.

- [ ] **Step 1: Register the category**

In `UsageTracker/Services/UsageNotifier.swift`, add the three constants after `agentHooksPromptIdentifier`:

```swift
    static let agentPermissionCategory = "AGENT_PERMISSION"
    static let agentAllowAction = "AGENT_ALLOW"
    static let agentDenyAction = "AGENT_DENY"
```

Add the third `UNNotificationCategory` to the array in `startAgentNotifications`, after the `agentHooksPromptCategory` one:

```swift
            // Neither action is `.foreground`. Omelette is an accessory app, so
            // activating it steals focus from the terminal the user is in — for a
            // button that exists to answer *without* going anywhere, that is the
            // wrong outcome, and the delegate receives the response perfectly well
            // in the background. Allow asks for an unlock first: the presence rule
            // holds requests while the screen is locked, and a lock screen must not
            // be a way to approve `rm -rf`.
            UNNotificationCategory(
                identifier: Self.agentPermissionCategory,
                actions: [
                    UNNotificationAction(
                        identifier: Self.agentAllowAction,
                        title: "Allow",
                        options: [.authenticationRequired]
                    ),
                    UNNotificationAction(
                        identifier: Self.agentDenyAction,
                        title: "Deny",
                        options: [.destructive]
                    ),
                ],
                intentIdentifiers: [],
                options: []
            ),
```

Update the doc comment above `startAgentNotifications` — the sentence "Two categories carry a button: …" becomes:

```swift
    /// Three categories carry a button: "needs you" (**Open**), the one-time hooks
    /// prompt (**Enable**) and a held permission request (**Allow** / **Deny**).
    /// "Finished" needs none — its whole body is the action, and a click on the body
    /// arrives as `UNNotificationDefaultActionIdentifier`, which `handleAgentResponse`
    /// routes exactly like **Open**.
```

- [ ] **Step 2: Hold the broker and wire its two callbacks**

Add the stored property next to `agentSessionsObserver`:

```swift
    /// The broker whose held requests this notifier banners. Injected in
    /// `startAgentNotifications` so a caller can hand in another one; `.shared`
    /// until then, because `agentNeedsYou` may be asked before launch finishes.
    private var broker: PermissionBroker = .shared
```

Change the signature and add the wiring at the end of `startAgentNotifications`, after the `agentSessionsObserver` assignment:

```swift
    func startAgentNotifications(
        store: AgentSessionStore = .shared,
        broker: PermissionBroker = .shared
    ) {
```

```swift
        // The broker is `@MainActor` like this object, so these are plain calls too.
        self.broker = broker
        broker.onPending = { [weak self] pending in
            self?.agentPermissionPending(pending)
        }
        broker.onResolved = { [weak self] pending, resolution in
            self?.permissionResolved(pending, resolution)
        }
```

- [ ] **Step 3: Fire and withdraw**

Add both methods after `agentNeedsYou(_:)`:

```swift
    /// A request the broker decided to hold. It follows the "needs you" toggle and
    /// its quiet-hours escape hatch, because it *is* that interruption — with two
    /// buttons on it. `permissionPending: false` is not a contradiction: the flag
    /// suppresses the *other* banner, and this is the one it suppresses it for.
    private func agentPermissionPending(_ pending: PendingPermission) {
        guard AgentNotificationRules.shouldNotifyNeedsYou(
            notifyEnabled: SettingsStore.shared.agentsNotifyNeedsYou,
            bypassQuietHours: SettingsStore.shared.agentsNeedsYouBypassQuietHours,
            isQuietHours: isInQuietHours(),
            permissionPending: false
        ) else { return }

        // Belt and braces against ordering: `AppState` registers with the broker
        // before the store applies the event, so `agentNeedsYou` already vetoed
        // itself — but a needs-you banner that slipped through would sit next to
        // this one asking the same question with no buttons. Pending *and*
        // delivered, because a request added a millisecond ago is still pending.
        let needsYouID = AgentNotificationRules.needsYouPrefix + pending.sessionID
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [needsYouID])
        center.removeDeliveredNotifications(withIdentifiers: [needsYouID])
        notifiedNeedsYou.remove(pending.sessionID)

        // The project name is the session's, not the payload's. A request whose
        // session we somehow do not know still has to name something.
        let project = AgentSessionStore.shared.sessions
            .first { $0.id == pending.sessionID }?.projectName ?? "An agent"
        fire(
            title: AgentNotificationRules.permissionTitle(
                projectName: project, toolName: pending.toolName
            ),
            body: AgentNotificationRules.permissionBody(toolSummary: pending.toolSummary),
            identifier: AgentNotificationRules.permissionIdentifier(requestID: pending.id),
            category: Self.agentPermissionCategory,
            timeSensitive: true
        )
    }

    /// Answered, expired, or released because you switched back to the terminal —
    /// either way the buttons are dead. A banner whose **Allow** no longer allows
    /// anything is worse than no banner (design doc, rule 5). An *expired* hold is
    /// the one case where nobody saw the two-minute banner: the terminal prompt is
    /// up now, so the plain needs-you banner (**Open**) takes its place — through
    /// `agentNeedsYou`, so `notifiedNeedsYou` and `clearResolvedNeedsYou` keep
    /// working. The broker has already dropped the id, so the veto inside it is off.
    private func permissionResolved(_ pending: PendingPermission, _ resolution: PermissionResolution) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: [AgentNotificationRules.permissionIdentifier(requestID: pending.id)]
        )
        guard resolution == .expired,
              let session = AgentSessionStore.shared.sessions.first(where: { $0.id == pending.sessionID }),
              session.state == .needsYou
        else { return }
        agentNeedsYou(session)
    }
```

- [ ] **Step 4: Route the two actions**

In `agentNeedsYou(_:)`, change the `permissionPending:` argument Task 1 added to go through the stored broker:

```swift
            permissionPending: broker.pending(for: session.id) != nil
```

At the top of `handleAgentResponse(identifier:action:)`, right after the hooks-prompt branch, add:

```swift
        if let requestID = AgentNotificationRules.requestID(fromIdentifier: identifier) {
            handlePermissionResponse(requestID: requestID, action: action)
            return
        }
```

And add the handler just below `handleHooksPromptResponse`:

```swift
    /// **Allow** and **Deny** answer the held request; anything else on that banner
    /// — a click on the body, "Close" — opens the popover, where the same two
    /// buttons sit on the row. A press that arrives after the hold window is a
    /// no-op: the broker has already released that id and forgotten it, and it
    /// answers each id at most once (design doc, rule 3).
    private func handlePermissionResponse(requestID: String, action: String) {
        switch action {
        case Self.agentAllowAction:
            broker.answer(id: requestID, .allow)
        case Self.agentDenyAction:
            broker.answer(id: requestID, .deny)
        case UNNotificationDefaultActionIdentifier:
            NotificationCenter.default.post(name: .showPopover, object: nil)
        default:
            break
        }
    }
```

Also update the doc comment on `handleAgentResponse` — it currently says the hooks prompt "names no session and is handled first"; make it:

```swift
    /// Routes a tap on an agent notification to the session it names. A session that
    /// has since ended has nothing to jump to, so the popover — where the remaining
    /// sessions are — opens instead. The two banners that name no session are handled
    /// first: the hooks prompt, and a permission request (which names a request id).
```

- [ ] **Step 5: Build and check the warning count**

Run:
```bash
cd "<repo>" && xcodebuild -project UsageTracker.xcodeproj -scheme UsageTracker -configuration Debug -derivedDataPath build/DerivedData build 2>&1 | tee /tmp/omelette-build.log | tail -5; grep -c "warning:" /tmp/omelette-build.log
```
Expected: `** BUILD SUCCEEDED **` and a warning count of `0`.

- [ ] **Step 6: Run the whole suite (nothing else may have moved)**

Run:
```bash
cd "<repo>" && xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS="" 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`.

> No unit test for this task on purpose: `UNUserNotificationCenter` is out of reach in the test bundle, which is exactly why every rule the banner depends on lives in `AgentNotificationRules` and was tested in Task 1. The manual checklist at the end of this plan covers the delivery path.

- [ ] **Step 7: Commit**

```bash
cd "<repo>" && git add UsageTracker/Services/UsageNotifier.swift && git commit -m "$(cat <<'EOF'
Agents: Allow / Deny on the notification

Registers AGENT_PERMISSION with two background actions — activating an
accessory app would steal focus from the terminal the buttons exist to avoid
— fires on the broker's onPending, withdraws on onResolved, and answers the
request id the identifier carries. Allow needs an unlock; Deny does not.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X
EOF
)"
```

---

### Task 3: The feature switch

**Files:**
- Modify: `UsageTracker/Core/Settings.swift` (`Defaults:45`, the `agents*` block at `:120`, `resetToDefaults():144`)
- Modify: `UsageTracker/Agents/PermissionBroker.swift` (one argument)
- Test: `UsageTrackerTests/SettingsStoreTests.swift`

**Interfaces:**
- Consumes: `PermissionBroker.shouldHold(userAtHost:featureEnabled:hasHost:)` (package 1).
- Produces:
  ```swift
  extension SettingsStore {
      var agentsAnswerPermissions: Bool          // @AppStorage("agentsAnswerPermissions"), default true
  }
  extension SettingsStore.Defaults {
      static let agentsAnswerPermissions: Bool   // true
  }
  ```

- [ ] **Step 1: Write the failing test**

In `UsageTrackerTests/SettingsStoreTests.swift`, add one line to `scrambleEverything` (after the `agentsShowInMenuBar` line):

```swift
        s.agentsAnswerPermissions = !SettingsStore.Defaults.agentsAnswerPermissions
```

one line to `assertAllDefaults` (same place):

```swift
        XCTAssertEqual(s.agentsAnswerPermissions, SettingsStore.Defaults.agentsAnswerPermissions, message)
```

and one assertion inside `testTheAgentDefaultsAreTheOnesTheAgentsTabPromises`, after the `agentsShowInMenuBar` one:

```swift
        XCTAssertTrue(
            settings.agentsAnswerPermissions,
            "the presence rule is what makes this safe to default on: a request is only held when the terminal isn't in front"
        )
```

- [ ] **Step 2: Run it to verify it fails**

Run:
```bash
cd "<repo>" && xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/SettingsStoreTests ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS="" 2>&1 | tail -20
```
Expected: compilation fails with `value of type 'SettingsStore' has no member 'agentsAnswerPermissions'`.

- [ ] **Step 3: Confirm the key exists (package 1 owns it) — add it only if the precondition grep came back empty**

The key belongs to package 1 because the broker reads it. Run:

```bash
cd "<repo>" && grep -n "agentsAnswerPermissions" UsageTracker/Core/Settings.swift
```

Expected: three lines — the `Defaults` constant, the `@AppStorage` property, the reset line. If so, skip to Step 4. Only if the grep prints nothing (package 1 landed without it), add to `Defaults` after `agentsShowInMenuBar`:

```swift
        static let agentsAnswerPermissions = true
```

the property after `agentsShowInMenuBar`:

```swift
    /// Answer Claude Code's permission requests from Omelette while the terminal
    /// running that session is not in front. Off puts every request back where it
    /// was before 2.2.0: Claude Code prompts in the terminal, always.
    @AppStorage("agentsAnswerPermissions") var agentsAnswerPermissions: Bool = Defaults.agentsAnswerPermissions
```

and the reset line after `agentsShowInMenuBar = Defaults.agentsShowInMenuBar`:

```swift
        agentsAnswerPermissions = Defaults.agentsAnswerPermissions
```

- [ ] **Step 4: Run it to verify it passes**

Run:
```bash
cd "<repo>" && xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/SettingsStoreTests ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS="" 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Point the broker's feature flag at the setting**

Run:
```bash
cd "<repo>" && grep -n "featureEnabled" UsageTracker/Agents/PermissionBroker.swift
```

Two possible outcomes:
- The init's default is `PermissionBroker.featureIsUsable`, a static function that returns `SettingsStore.shared.agentsAnswerPermissions && AgentHooksInstaller.claudeStatus(…) == .installed` — package 1 wrote it against this contract (the hooks must match this build's template, or a 2.1 install's 5 s cap would kill the helper mid-hold). Nothing to change; note it and move on.
- It passes a literal (`true`) or a placeholder. Replace that argument with:

```swift
            featureEnabled: PermissionBroker.featureIsUsable,
```

and if `featureIsUsable` does not exist, add it to `PermissionBroker`:

```swift
    static func featureIsUsable() -> Bool {
        SettingsStore.shared.agentsAnswerPermissions
            && AgentHooksInstaller.claudeStatus(
                settingsURL: AgentPaths.claudeSettingsURL,
                helperPath: AgentPaths.helperSymlinkURL.path
            ) == .installed
    }
```

Do not change `shouldHold` itself — its signature belongs to package 1.

- [ ] **Step 6: Build and re-run the suite**

Run:
```bash
cd "<repo>" && xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS="" 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **` — in particular package 1's `PermissionBroker` table tests still pass, since `shouldHold` is untouched.

- [ ] **Step 7: Commit**

```bash
cd "<repo>" && git add UsageTracker/Core/Settings.swift UsageTracker/Agents/PermissionBroker.swift UsageTrackerTests/SettingsStoreTests.swift && git commit -m "$(cat <<'EOF'
Settings: agentsAnswerPermissions, on by default

The broker's featureEnabled now reads the stored preference, so turning the
switch off sends every PermissionRequest straight back to the terminal.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X
EOF
)"
```

---

### Task 4: Allow / Deny on the row

**Files:**
- Modify: `UsageTracker/UI/DesignSystem/OMAgentRow.swift` (`AgentRowText`, the `OMAgentRow` body, the previews)
- Modify: `UsageTracker/UI/DesignSystem/AgentsSection.swift` (`row(_:)`, `:91`)
- Test: `UsageTrackerTests/AgentRowTextTests.swift`

**Interfaces:**
- Consumes: `AgentSession.pendingPermissionID`, `PermissionBroker.shared.answer(id:_:)`, `PermissionDecision.allow` / `.deny` (package 1); `glassProminentButtonStyle()` / `glassButtonStyle()` (`LiquidGlass.swift`); `OMSpacing`, `OMFont`, `OMSurface.row`, `OMRadius.row` (`SharedUI/OMTokens.swift`).
- Produces:
  ```swift
  extension AgentRowText {
      static func permissionButtonsVisible(pendingPermissionID: String?, source: AgentSource) -> Bool
  }
  struct OMAgentRow: View {
      let session: AgentSession
      var showsProviderIcon: Bool = true
      var onAllow: () -> Void = {}
      var onDeny: () -> Void = {}
      let action: () -> Void
  }
  ```

**Call-site rule for this task:** the two new closures sit *before* `action:`, so an
unlabeled trailing closure is no longer unambiguously `action` — Swift's forward-scan
matching can bind it to `onAllow` and then fail with "missing argument for parameter
'action'". Every `OMAgentRow(...)` call in this task therefore passes `action:`
explicitly, including the five existing preview rows. Do not "tidy" them back into
trailing-closure form.

- [ ] **Step 1: Write the failing test**

Append to `UsageTrackerTests/AgentRowTextTests.swift`, inside `AgentRowTextTests`:

```swift
    // MARK: permission buttons

    func testTheButtonsAppearOnlyForAHeldClaudeRequest() {
        XCTAssertTrue(
            AgentRowText.permissionButtonsVisible(pendingPermissionID: "0f1e2d3c", source: .claude)
        )
    }

    func testARowWithNoHeldRequestOffersNoButtons() {
        XCTAssertFalse(AgentRowText.permissionButtonsVisible(pendingPermissionID: nil, source: .claude))
        XCTAssertFalse(AgentRowText.permissionButtonsVisible(pendingPermissionID: "", source: .claude))
        XCTAssertFalse(AgentRowText.permissionButtonsVisible(pendingPermissionID: "   ", source: .claude))
    }

    func testCodexNeverOffersButtons() {
        // Codex has no approval hook, so nothing on its side is waiting for an
        // answer. Buttons that answer nothing are worse than no buttons, whatever
        // the store happens to hold.
        XCTAssertFalse(
            AgentRowText.permissionButtonsVisible(pendingPermissionID: "0f1e2d3c", source: .codex)
        )
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run:
```bash
cd "<repo>" && xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/AgentRowTextTests ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS="" 2>&1 | tail -20
```
Expected: compilation fails with `type 'AgentRowText' has no member 'permissionButtonsVisible'`.

- [ ] **Step 3: Add the rule**

In `UsageTracker/UI/DesignSystem/OMAgentRow.swift`, add to `AgentRowText` after `sourceName(_:)`:

```swift
    /// Whether the row offers Allow / Deny. Only a Claude session can be held —
    /// Codex reports one event and has no approval hook — and an id that is blank
    /// is not an id, so neither can put buttons on a row that answer nothing.
    static func permissionButtonsVisible(pendingPermissionID: String?, source: AgentSource) -> Bool {
        guard source == .claude else { return false }
        let id = pendingPermissionID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !id.isEmpty
    }
```

- [ ] **Step 4: Run it to verify it passes**

Run:
```bash
cd "<repo>" && xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/AgentRowTextTests ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS="" 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Give the row its second line**

The whole row is a `Button` today, and a button inside a button is a hit-testing coin flip. Move the surface, padding and shape onto a container `VStack`, keep the jump `Button` around the first line only, and put the two controls on a sibling line. Replace `OMAgentRow`'s stored properties and `body` with:

```swift
struct OMAgentRow: View {
    let session: AgentSession
    var showsProviderIcon: Bool = true
    /// Called by the row's **Allow** / **Deny**. Defaults do nothing so previews and
    /// any host that does not deal in permissions can ignore them. They precede
    /// `action`, which is why every call site passes `action:` by name: an unlabeled
    /// trailing closure would be matched against `onAllow` first.
    var onAllow: () -> Void = {}
    var onDeny: () -> Void = {}
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsPermission: Bool {
        AgentRowText.permissionButtonsVisible(
            pendingPermissionID: session.pendingPermissionID,
            source: session.source
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OMSpacing.xs + 2) {
            // The jump target is the row's text, not the whole card: the buttons
            // below must not be nested inside another button, or which one takes
            // the click stops being predictable.
            Button(action: action) {
                summaryLine
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("Jump to \(session.projectName)")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AgentRowText.accessibilityLabel(for: session))
            .accessibilityHint("Brings the window running this session to the front")
            .accessibilityAddTraits(.isButton)

            if showsPermission {
                permissionLine
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: OMRadius.row, style: .continuous).fill(OMSurface.row))
        // The row grows by a line when a request arrives and shrinks when it is
        // answered; without this the list jumps. Reduce Motion gets the jump.
        .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: showsPermission)
    }

    private var summaryLine: some View {
        HStack(spacing: OMSpacing.s + 1) {
            leading
            VStack(alignment: .leading, spacing: 1) {
                Text(session.projectName)
                    .font(OMFont.bodyStrong)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(AgentRowText.subtitle(for: session, showsState: !showsProviderIcon))
                    .font(OMFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: OMSpacing.xs)
            // Only the elapsed time is on a clock, so only it re-renders.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(AgentRowText.elapsed(since: session.stateSince, now: context.date, state: session.state))
                    .font(OMFont.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            .fixedSize()
        }
        .contentShape(Rectangle())
    }

    /// The held request, answerable here. Deliberately plain: the tool it wants to
    /// run is already the subtitle above, and a second copy of it would push the
    /// buttons off a 360 pt popover.
    private var permissionLine: some View {
        HStack(spacing: OMSpacing.s) {
            Button("Allow", action: onAllow)
                .glassProminentButtonStyle()
                .controlSize(.small)
                .accessibilityLabel("Allow \(session.projectName) to run this tool")
                .help("Answers Claude Code with allow, once, for this tool call")
            Button("Deny", action: onDeny)
                .glassButtonStyle()
                .controlSize(.small)
                .accessibilityLabel("Deny \(session.projectName) this tool")
                .help("Refuses this one tool call; the session carries on")
            Spacer(minLength: 0)
        }
        .padding(.leading, 20 + OMSpacing.s + 1)   // clears the leading icon, so the buttons line up under the text
    }
```

Leave `leading`, `sfFallback` and `AgentStateDot` exactly as they are.

- [ ] **Step 6: Wire the section's rows to the broker**

In `UsageTracker/UI/DesignSystem/AgentsSection.swift`, replace `row(_:)`:

```swift
    /// Both list shapes go through here, so the grouped All tab and the flat
    /// provider tab get the same buttons from one place.
    private func row(_ session: AgentSession) -> some View {
        OMAgentRow(
            session: session,
            showsProviderIcon: grouped,
            onAllow: { Self.answer(session, .allow) },
            onDeny: { Self.answer(session, .deny) },
            action: { SessionActivator.jump(to: session) }
        )
        .opacity(Self.rowOpacity(session.state))
    }

    /// A row can outlive the request it was drawn for — the hold expires, or you
    /// switched back to the terminal — so the id is re-read at click time and the
    /// broker ignores an id it has already answered.
    private static func answer(_ session: AgentSession, _ decision: PermissionDecision) {
        guard let id = session.pendingPermissionID else { return }
        PermissionBroker.shared.answer(id: id, decision)
    }
```

`AgentsSection` is a `View`, so `answer` is main-actor isolated along with it and can call the `@MainActor` broker directly.

- [ ] **Step 7: Relabel the existing previews and add the pending-state ones**

In `OMAgentRow.swift`'s `#if DEBUG` block, replace the five rows in `agentRowPreviewStack` so the jump closure is labelled (see the call-site rule above):

```swift
    VStack(spacing: 5) {
        OMAgentRow(session: AgentPreviewData.session("Usage tracker", .needsYou, activity: "Bash: xcodegen generate", minutes: 1), showsProviderIcon: showsProviderIcon, action: {})
        OMAgentRow(session: AgentPreviewData.session("Orion Gate / mobile", .working, activity: "Edit: WalletView.swift", minutes: 14), showsProviderIcon: showsProviderIcon, action: {})
        OMAgentRow(session: AgentPreviewData.session("Jaravis", .done, minutes: 5), showsProviderIcon: showsProviderIcon, action: {})
        OMAgentRow(session: AgentPreviewData.session("orion-gemini", .idle, minutes: 42, source: .codex), showsProviderIcon: showsProviderIcon, action: {})
        OMAgentRow(session: AgentPreviewData.session("Movie app", .working, activity: "Grep: usageStatusColor", minutes: 2, approximate: true), showsProviderIcon: showsProviderIcon, action: {})
    }
```

Then add the builder and its previews after `agentRowPreviewStack`:

```swift
/// A session with a request in flight, next to one without. `pendingPermissionID`
/// is set after the fact because `AgentSession`'s initializer does not take it —
/// the broker sets it through the store.
@MainActor
private func pendingPermissionPreviewStack(showsProviderIcon: Bool) -> some View {
    var waiting = AgentPreviewData.session(
        "Usage tracker", .needsYou, activity: "Bash: rm -rf build/DerivedData", minutes: 1
    )
    waiting.pendingPermissionID = "0f1e2d3c4b5a69788796a5b4c3d2e1f0"
    return VStack(spacing: 5) {
        OMAgentRow(session: waiting, showsProviderIcon: showsProviderIcon, onAllow: {}, onDeny: {}, action: {})
        OMAgentRow(
            session: AgentPreviewData.session("Orion Gate / mobile", .working, activity: "Edit: WalletView.swift", minutes: 14),
            showsProviderIcon: showsProviderIcon,
            action: {}
        )
    }
    .padding()
    .frame(width: 328)
}

#Preview("Agent rows — permission pending, light") { pendingPermissionPreviewStack(showsProviderIcon: true) }
#Preview("Agent rows — permission pending, dark") { pendingPermissionPreviewStack(showsProviderIcon: true).preferredColorScheme(.dark) }
#Preview("Agent rows — permission pending, dots") { pendingPermissionPreviewStack(showsProviderIcon: false) }
```

- [ ] **Step 8: Build, check warnings, run the suite**

Run:
```bash
cd "<repo>" && xcodebuild -project UsageTracker.xcodeproj -scheme UsageTracker -configuration Debug -derivedDataPath build/DerivedData build 2>&1 | tee /tmp/omelette-build.log | tail -5; grep -c "warning:" /tmp/omelette-build.log; xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS="" 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`, warning count `0`, `** TEST SUCCEEDED **` (`AgentsSectionTests` and `AgentRowTextTests` included — the row's grouping and copy rules did not move).

- [ ] **Step 9: Commit**

```bash
cd "<repo>" && git add UsageTracker/UI/DesignSystem/OMAgentRow.swift UsageTracker/UI/DesignSystem/AgentsSection.swift UsageTrackerTests/AgentRowTextTests.swift && git commit -m "$(cat <<'EOF'
Popover: Allow / Deny on a session with a held request

The row's second line carries the two buttons; the click-to-jump keeps the
first line, so nothing is a button inside a button. Claude only — Codex has no
approval hook — and the height change is animated unless Reduce Motion is on.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X
EOF
)"
```

---

### Task 5: Settings → Agents — the switch and four counters

**Files:**
- Modify: `UsageTracker/UI/AgentsSettingsView.swift` (state at `:11-17`, `body:22`, after `alertsSection:149`, `pollDiagnostics:199`)

**Interfaces:**
- Consumes: `SettingsStore.shared.agentsAnswerPermissions` (Task 3); `PermissionBroker.shared.pending`, `.answeredCount`, `.expiredCount`, `.releasedForPresenceCount` (package 1).
- Produces: nothing other tasks depend on.

- [ ] **Step 1: Add the four counters to the view's state**

In `UsageTracker/UI/AgentsSettingsView.swift`, after `@State private var dropped = 0`:

```swift
    @State private var permissionPending = 0
    @State private var permissionAnswered = 0
    @State private var permissionExpired = 0
    @State private var permissionReleased = 0
```

- [ ] **Step 2: Add the section**

Add `permissionsSection` to the `Form`, between `alertsSection` and `diagnosticsSection`:

```swift
            alertsSection
            permissionsSection
            diagnosticsSection
```

and the section itself, after `alertsSection`:

```swift
    // MARK: - Permissions

    private var permissionsSection: some View {
        Section("Permissions") {
            Toggle("Answer permission requests from Omelette", isOn: $settings.agentsAnswerPermissions)
            Text("Allow / Deny appear on the notification and in the popover only while the terminal running that session isn't in front; otherwise Claude Code asks in the terminal as usual. A request you don't answer goes back to the terminal after two minutes.")
                .font(OMFont.caption)
                .foregroundStyle(.secondary)
            LabeledContent("Pending", value: "\(permissionPending)")
            LabeledContent("Answered", value: "\(permissionAnswered)")
            LabeledContent("Expired", value: "\(permissionExpired)")
            LabeledContent("Released to terminal", value: "\(permissionReleased)")
        }
    }
```

- [ ] **Step 3: Read the counters on the existing 2 s tick**

The broker's counters are plain properties, like `receivedCount` / `droppedCount`, so they ride the poll that is already there. In `pollDiagnostics()`, after the `dropped = …` line:

```swift
            let broker = PermissionBroker.shared
            permissionPending = broker.pending.count
            permissionAnswered = broker.answeredCount
            permissionExpired = broker.expiredCount
            permissionReleased = broker.releasedForPresenceCount
```

Update the comment above `pollDiagnostics` so it still describes what it does:

```swift
    /// The counters live on plain objects, not on an ObservableObject, so the tab
    /// re-reads them while it is on screen. `.task` cancels this when it is not.
    /// The install status is re-read on the same tick — two small file reads — so
    /// editing settings.json in another window updates the line here.
```

- [ ] **Step 4: Build and check warnings**

Run:
```bash
cd "<repo>" && xcodebuild -project UsageTracker.xcodeproj -scheme UsageTracker -configuration Debug -derivedDataPath build/DerivedData build 2>&1 | tee /tmp/omelette-build.log | tail -5; grep -c "warning:" /tmp/omelette-build.log
```
Expected: `** BUILD SUCCEEDED **` and `0`.

- [ ] **Step 5: Check the caption is byte-for-byte the one above**

Run:
```bash
cd "<repo>" && grep -c "A request you don't answer goes back to the terminal after two minutes." UsageTracker/UI/AgentsSettingsView.swift
```
Expected: `1`.

- [ ] **Step 6: Commit**

```bash
cd "<repo>" && git add UsageTracker/UI/AgentsSettingsView.swift && git commit -m "$(cat <<'EOF'
Settings: a Permissions section with the switch and its counters

Says what the presence rule does in one sentence and shows how often it
fires: pending, answered, expired, released to terminal.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X
EOF
)"
```

---

### Task 6: The hook waits 150 seconds

**Files:**
- Modify: `UsageTracker/Agents/AgentHooksInstaller.swift` (`claudeTemplate:57-74`)
- Test: `UsageTrackerTests/AgentHooksInstallerTests.swift` (`testTemplateRegistersEveryEventWithTheRightBlockingBehaviour:83`)

**Interfaces:**
- Consumes: nothing new.
- Produces: `AgentHooksInstaller.claudeTemplate(helperPath:)` now emits `"timeout": 150` for `PermissionRequest`; `claudeStatus` therefore reports `.outdated` for every install written before 2.2.0, which the existing Settings row already answers with **Update**.

- [ ] **Step 1: Write the failing tests**

In `UsageTrackerTests/AgentHooksInstallerTests.swift`, change the two lines in `testTemplateRegistersEveryEventWithTheRightBlockingBehaviour`:

```swift
        // The one synchronous entry, and the only one Claude Code waits on. 150 s is
        // the outer ring of the timeout chain: the app gives up holding at 120 s and
        // the helper at 140 s, so Claude Code's own cap is never the one that fires.
        let permission = try templateEntry(template, "PermissionRequest")
        XCTAssertEqual(permission["timeout"] as? Int, 150)
        XCTAssertNil(permission["async"])
```

and append this test to the same class, after `testAnOlderInstallReadsAsOutdatedAndUpdateReplacesOnlyOurs`:

```swift
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
```

- [ ] **Step 2: Run them to verify they fail**

Run:
```bash
cd "<repo>" && xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/AgentHooksInstallerTests ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS="" 2>&1 | tail -25
```
Expected: `** TEST FAILED **` with `XCTAssertEqual failed: ("Optional(5)") is not equal to ("Optional(150)")` from the template test, and the new test failing on `.installed` where it wants `.outdated` (5 is still what the template emits).

- [ ] **Step 3: Widen the template's cap**

In `UsageTracker/Agents/AgentHooksInstaller.swift`, change the `blocking` entry and the doc comment above `shellQuoted`:

```swift
    /// The `hooks` fragment we own. Async everywhere so Claude Code never waits
    /// on us; `PermissionRequest` is the single synchronous entry, and since 2.2.0
    /// it is registered with a 150 s cap so Omelette can hold it while you decide.
    /// The chain is deliberate: the app releases at 120 s and the helper at 140 s,
    /// so Claude Code's own timeout is never the one that fires. The two
    /// `Notification` entries are literal matchers rather than one alternation,
    /// so each notification type we listen to is separately visible in the file.
```

```swift
        let blocking: [String: Any] = ["type": "command", "command": command, "timeout": 150]
```

- [ ] **Step 4: Run them to verify they pass**

Run:
```bash
cd "<repo>" && xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/AgentHooksInstallerTests ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS="" 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
cd "<repo>" && git add UsageTracker/Agents/AgentHooksInstaller.swift UsageTrackerTests/AgentHooksInstallerTests.swift && git commit -m "$(cat <<'EOF'
Hooks: PermissionRequest waits 150 s instead of 5

Long enough for the app's 120 s hold and the helper's 140 s wait to finish
first. Installs from 2.1 read as outdated, which the Agents tab already
answers with a one-click Update.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X
EOF
)"
```

---

### Task 7: Release prep — 2.2.0 / build 32

**Files:**
- Modify: `project.yml` (`:104-105` app, `:159-160` widget)
- Modify: `CHANGELOG.md` (new section above `## [2.1.0] — 2026-09-02`)
- Modify: `README.md` (Features list at `:16`, Settings list at `:86`)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing in code. The owner runs the build/notarize/appcast flow afterwards; this task only stages the numbers and the notes.

- [ ] **Step 1: Bump both targets**

Run:
```bash
cd "<repo>" && sed -i '' 's/MARKETING_VERSION: "2.1.0"/MARKETING_VERSION: "2.2.0"/; s/CURRENT_PROJECT_VERSION: "31"/CURRENT_PROJECT_VERSION: "32"/' project.yml && grep -n 'MARKETING_VERSION\|CURRENT_PROJECT_VERSION' project.yml
```
Expected exactly four lines — `104:        MARKETING_VERSION: "2.2.0"`, `105:        CURRENT_PROJECT_VERSION: "32"`, `159:        MARKETING_VERSION: "2.2.0"`, `160:        CURRENT_PROJECT_VERSION: "32"`. If any line still says 2.1.0 or 31, fix it by hand before continuing.

- [ ] **Step 2: Regenerate the project and confirm the build reads the new version**

Run:
```bash
cd "<repo>" && xcodegen generate && xcodebuild -project UsageTracker.xcodeproj -scheme UsageTracker -configuration Debug -derivedDataPath build/DerivedData -showBuildSettings 2>/dev/null | grep -E "MARKETING_VERSION|CURRENT_PROJECT_VERSION"
```
Expected: `MARKETING_VERSION = 2.2.0` and `CURRENT_PROJECT_VERSION = 32`.

- [ ] **Step 3: Write the changelog entry**

In `CHANGELOG.md`, insert directly above `## [2.1.0] — 2026-09-02`:

```markdown
## [2.2.0] — unreleased

### Added
- **Approve or deny Claude Code from Omelette.** When a session asks permission
  and the terminal running it isn't the app you're looking at, the notification
  carries **Allow** and **Deny**, and so does that session's row in the popover.
  When the terminal *is* in front, nothing changes: Claude Code asks where it
  always has.
- Held requests are answered at most once, expire after two minutes, live only in
  memory, and are released to the terminal untouched on any timeout, quit,
  disconnect or malformed reply — Omelette never allows anything by itself.
- Settings → Agents has a switch for it, with counts of the requests pending,
  answered, expired and released to the terminal.

### Changed
- The `PermissionRequest` hook now waits up to 150 seconds instead of 5, so there
  is time to answer. Settings → Agents will say **Installed — older than this
  build** once; one **Update** click rewrites the entry.
```

- [ ] **Step 4: Add the two README bullets**

In `README.md`, insert this bullet into the Features list directly after the "Agents pill in the menu bar" bullet (the one ending "sessions are still read from the CLIs' own logs"):

```markdown
- **Approve or deny from Omelette (2.2)** — when a Claude Code session asks for
  permission and its terminal isn't in front, the notification and the session's
  popover row both offer **Allow** / **Deny**. The request is held for two minutes,
  answered once, and released to the terminal if you don't answer; when the terminal
  is in front, Claude Code asks there as usual
```

and replace the Settings list's **Agents** bullet with:

```markdown
- **Agents** — enable/remove the Claude Code hooks and the Codex `notify` line (with the exact
  JSON/TOML shown first), agent alert toggles, menu-bar pill toggle, the switch for answering
  permission requests with its pending / answered / expired counts, socket diagnostics
```

- [ ] **Step 5: Verify nothing else claims 2.1.0**

Run:
```bash
cd "<repo>" && grep -rn "2\.1\.0" project.yml README.md CHANGELOG.md | grep -v "^CHANGELOG.md:.*\[2.1.0\]"
```
Expected: no output (the only surviving 2.1.0 is the historical changelog heading).

- [ ] **Step 6: Full suite, one more time**

Run:
```bash
cd "<repo>" && xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS="" 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
cd "<repo>" && git add project.yml CHANGELOG.md README.md && git commit -m "$(cat <<'EOF'
Release prep: 2.2.0 (build 32)

Version keys in the app and the widget, the changelog entry for approve/deny,
and the two README bullets. The build/notarize/appcast flow stays with the
owner.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X
EOF
)"
```

---

## Manual checklist

Nothing below is reachable from XCTest — the notification centre, the presence rule and a real Claude Code session all live outside the test bundle. Run these against a Debug build and report each as verified / not verified, with what you saw. **Item 8 comes first in practice**: the broker holds nothing until the installed hooks match this build's template (`PermissionBroker.featureIsUsable`), so click **Update** in Settings → Agents before expecting any banner.

1. **Hold and allow from the banner.** In a terminal that is *not* frontmost, make Claude Code ask for a permission (e.g. a `Bash` command outside the allowlist). Expect a banner titled "<project> wants to run Bash" with **Allow** / **Deny**. Press **Allow** (unlock if macOS asks): the tool runs, the banner goes away, Settings → Agents shows Answered +1, and **Omelette does not come to the front**.
2. **Deny.** Same setup, press **Deny**: Claude Code reports the refusal and carries on with its turn; Answered +1.
3. **Presence release.** Ask again, then click back into the terminal within the two minutes: the banner disappears, Claude Code's own prompt appears in the terminal, and "Released to terminal" goes up by one.
4. **Expiry.** Ask again and do nothing for two minutes: the Allow/Deny banner is withdrawn on its own, the terminal prompt appears, Expired +1, and the plain "needs you" banner with **Open** takes its place (it stays in Notification Center). Clicking a permission banner that somehow survived does nothing.
5. **Popover row.** With a request held, open the popover: the session's row has the second line with **Allow** / **Deny**, the rest of the row still jumps to the terminal, and the row's growth is animated. Answer from the row — the banner is withdrawn too.
6. **No double banner.** While a request is held, confirm only one banner is on screen (the permission one). The plain "needs you" banner must not also appear.
7. **The switch.** Turn Settings → Agents → "Answer permission requests from Omelette" off, ask again: no banner, no popover buttons, the terminal prompts immediately.
8. **The hook update.** With hooks installed from 2.1, open Settings → Agents: the Claude row reads "Installed — older than this build" and offers **Update**. Click it and confirm `~/.claude/settings.json` has one `PermissionRequest` entry with `"timeout": 150`. **Do this against a scratch copy, or restore the file byte-identically afterwards and delete the `.omelette-backup` it creates.**
9. **Dark mode / Reduce Motion.** Check the pending row in both appearances and with Reduce Motion on (the height change should snap, not slide).

---

## Self-review

**Spec coverage** (`2026-09-02-phase4-approve-deny-design.md`, package 2's share):

| Spec requirement | Task |
|---|---|
| Category `AGENT_PERMISSION`, actions `AGENT_ALLOW` / `AGENT_DENY` (`.destructive`) | 2 |
| Identifier `agent-permission-<request_id>` | 1 (rule + tests), 2 (use) |
| Fired on `onPending`, withdrawn on `onResolved`; `.expired` re-fires the plain needs-you banner; `onPending` withdraws a stray needs-you banner | 2 |
| Title `"<project> wants to run <tool>"`, body = tool summary ≤ 80 / "Waiting for your approval." | 1 |
| Bypasses quiet hours on the existing needs-you toggle | 2 (`shouldNotifyNeedsYou` with the same two settings) |
| Needs-you suppressed while a request is pending | 1 (rule + table), 2 (call site) |
| Body tap → popover; actions → `broker.answer(id:_:)` | 2 |
| Popover Allow / Deny on both list shapes, jump preserved | 4 |
| `@AppStorage("agentsAnswerPermissions") = true` + the exact caption | 3, 5 |
| Diagnostics: pending / answered / expired / released-to-terminal | 5 |
| Feature flag reaches `shouldHold` | 3 |
| Hook template `timeout: 150`, existing install reads `.outdated` | 6 |
| README + CHANGELOG `[2.2.0]`, version 2.2.0 / build 32 | 7 |

No package-2 requirement is unclaimed. Everything else in the spec (protocol v2, helper, server, broker, presence) is package 1's and is consumed here by name only.

**Placeholder scan:** no "TBD", no "add error handling", no "similar to Task N". Every code step carries the code to paste; every run step carries the command and the output to expect. The one branch left to judgment is Task 3 Step 5 (whether package 1 already reads the setting), and both outcomes are spelled out.

**Type consistency:** `permissionIdentifier(requestID:)` / `requestID(fromIdentifier:)` / `permissionTitle(projectName:toolName:)` / `permissionBody(toolSummary:)` / `permissionButtonsVisible(pendingPermissionID:source:)` are spelled the same in every task and test. `shouldNotifyNeedsYou` has one signature everywhere (four labels, all required) and its only two call sites — `agentNeedsYou` and `agentPermissionPending` — are both updated in Task 2. `broker.answer(id:_:)`, `broker.pending(for:)`, `broker.pending`, `answeredCount`, `expiredCount`, `releasedForPresenceCount`, `PendingPermission.id/sessionID/toolName/toolSummary` and `PermissionDecision.allow/.deny` match the spec's declarations verbatim. `OMAgentRow`'s two new closures sit before `action:`, which is why Task 4 labels the jump closure at every call site — the five preview rows, the three new preview rows and `AgentsSection.row` — instead of leaving it trailing, where forward-scan matching would try `onAllow` first and fail the build.
