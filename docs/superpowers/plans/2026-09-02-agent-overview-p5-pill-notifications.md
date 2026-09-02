# Agents Pill + Notifications (Phase 2, Package 5) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put a live agents pill in the menu bar and turn "a session is waiting for you" into a native notification whose **Open** action jumps straight to that session.

**Architecture:** Two pure rule types carry all the logic — `OMAgentsPill.Appearance.make(needsYou:working:total:)` picks colour and text for a triple of counts, `AgentNotificationRules` decides what may page the user and what it says — and both are unit-tested without a view hierarchy or the notification centre. The views and `UsageNotifier` are thin shells over them: the pill is a static capsule wired into the phase-1 `leadingSlot` through a one-line wrapper view so the store's event stream invalidates only the pill subtree, and the notifier gains a category, a `UNUserNotificationCenterDelegate` and three small methods driven by `AgentSessionStore`'s `onNeedsYou` / `onDone` callbacks plus a diff of its published `sessions`.

**Tech Stack:** Swift 6 (strict concurrency `minimal`), SwiftUI, Combine, UserNotifications, macOS 14 floor, XCTest (`UsageTrackerTests`, `@testable import Omelette`), xcodegen-generated project.

**Spec:** `docs/superpowers/specs/2026-09-02-agent-overview-design.md` (sections "Menu bar — agents pill", "Notifications", "Security and privacy", "Packages"); contract: `docs/superpowers/specs/2026-09-02-agent-overview-interfaces.md`; roadmap: `docs/superpowers/specs/2026-09-02-agent-control-plane-roadmap.md`; approved mockup: `.superpowers/brainstorm/66461-1788298131/content/menubar-agents.html`, option **B**.

## Global Constraints

Phase-1's constraints apply verbatim:

- Deployment target macOS 14.0; every glass effect goes through the existing helpers in `UsageTracker/UI/Components/LiquidGlass.swift` (`liquidGlass(in:tint:)`, `GlassGroup`, `glassButtonStyle()`), never a bare `glassEffect` call.
- Colour semantics (spec): `usageStatusColor` returns `.green` below 70, `.orange` from 70, `.red` from 90. Agent-state colours are tokens only in this phase.
- Popover width stays 360 pt; `NSPopover.contentSize` in `StatusBarController.swift:21` stays 340×460.
- Persisted tab key stays `selectedProviderTab`; the value `"all"` (`WindowRanking.allTab`) is the default and the self-heal target.
- Every user-visible string that exists today keeps its wording (status phrases, burn verdict, "N unused windows", "You haven't used X yet", "Server responded but returned no usage data.", state help texts).
- The widget extension keeps its own colour copy (`UsageTrackerWidget.swift:468`) — do not touch the widget in this phase.
- New source files are picked up by xcodegen from `sources: - path: UsageTracker`; run `xcodegen generate` after adding files and before building. `UsageTracker.xcodeproj/` is generated and gitignored — never `git add` it.
- Build: `xcodebuild -project UsageTracker.xcodeproj -scheme UsageTracker -configuration Debug -derivedDataPath build/DerivedData build`.
  Tests: `xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData` (add `-only-testing:UsageTrackerTests/<Class>` for a single class). If local signing of the test host fails, append `CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO`.
- Commits end with the trailer lines
  `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` and
  `Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X`.
- Other sessions may commit the working tree while you work: re-read a file right before editing it; prefer targeted edits over whole-file rewrites (see memory note in `project_usage_checker`).
- No release in this plan: the owner runs the local build/notarize flow after testing.

Package-5 additions:

- **The menu bar must never redraw continuously.** No `TimelineView`, no `.repeatForever`, no timer, no `withAnimation` anywhere in the pill's path. `MiniServiceBar`'s existing `TimelineView(.animation)` is the only one in `MenuBarLabel.swift` and stays exactly as it is. The pill is static in every state, which is also why Reduce Motion needs no branch here — there is no motion to reduce.
- **Contract names are fixed.** `OMAgentsPill(needsYou:working:total:)`, `AgentSessionStore.shared` / `.onNeedsYou` / `.onDone` / `.needsYouCount` / `.workingCount` / `.sessions`, `SessionActivator.jump(to:)`, the settings keys `agentsNotifyNeedsYou` / `agentsNeedsYouBypassQuietHours` / `agentsNotifyDone` / `agentsShowInMenuBar`, `OMAgentColor`, `OMFont.menuNumeral`, `OMSurface.row`. Anything else this package introduces is listed under a task's "Produces".
- **This package creates none of its dependencies.** Packages 1–4 and phase 1 own them; if a symbol below is missing, the prerequisite package is not merged yet — stop and say so rather than stubbing it.
- Notification payloads are hook data: displayed truncated, never written to disk (spec, "Security and privacy"). `AgentNotificationRules` returns strings; nothing in this package persists an activity string.
- Do not touch `MenuBarHostView` in `StatusBarController.swift`. It observes `AppState`, and adding the agent store there would re-render every provider pill on every hook event.

### Preconditions (verify before Task 1)

Run: `grep -rn "OMAgentColor\|menuNumeral" UsageTracker/UI/DesignSystem/OMTokens.swift; grep -rn "leadingSlot" UsageTracker/UI/MenuBarLabel.swift; grep -rn "agentsShowInMenuBar\|agentsNotifyNeedsYou" UsageTracker/Core/Settings.swift; ls UsageTracker/Agents/`
Expected: `OMTokens.swift` defines `OMAgentColor` and `OMFont.menuNumeral` (phase 1, Task 1); `MenuBarLabel.swift` has a `leadingSlot` returning `EmptyView()` (phase 1, Task 15); `Settings.swift` has the four `agents*` keys (package 3); `UsageTracker/Agents/` contains `AgentModels.swift`, `AgentSessionStore.swift` and `SessionActivator.swift` (packages 1, 2, 4).

---

## File structure

```
UsageTracker/UI/DesignSystem/
  OMAgentsPill.swift            NEW — the menu-bar capsule + its pure Appearance rule
UsageTracker/UI/
  MenuBarLabel.swift            MODIFIED — leadingSlot renders the pill via AgentsPillSlot
  StatusBarController.swift     MODIFIED — .showPopover observer (fallback for a dead session)
UsageTracker/Services/
  AgentNotificationRules.swift  NEW — pure gating / identifiers / copy
  UsageNotifier.swift           MODIFIED — AGENT_NEEDS_YOU category, delegate, schedule/withdraw
UsageTracker/
  UsageTrackerApp.swift         MODIFIED — one line in applicationDidFinishLaunching
UsageTrackerTests/
  OMAgentsPillTests.swift       NEW — Appearance.make cases
  AgentNotificationRulesTests.swift  NEW — gating, identifiers, copy, withdrawal diff
```

`AgentNotificationRules` lives in `Services/` next to `UsageNotifier`, not in `Agents/`: it is a notification rule tested exactly like `UsageNotifier.thresholdOutcome`, and `Agents/` belongs to packages 1–4.

---

### Task 1: `OMAgentsPill.Appearance` — the state-selection rule

**Files:**
- Create: `UsageTracker/UI/DesignSystem/OMAgentsPill.swift`
- Test: `UsageTrackerTests/OMAgentsPillTests.swift`

**Interfaces:**
- Consumes: `OMAgentColor.needsYou / .working / .idle` (phase 1, `OMTokens.swift`).
- Produces:
  ```swift
  struct OMAgentsPill: View { let needsYou: Int; let working: Int; let total: Int }
  extension OMAgentsPill {
      struct Appearance: Equatable {
          let dot: Color
          let textColor: Color
          let text: String
          let accessibilityLabel: String
          static func make(needsYou: Int, working: Int, total: Int) -> Appearance?   // nil = draw nothing
          static func accessibilityText(needsYou: Int, total: Int) -> String
      }
  }
  ```
  The `View` conformance is added in Task 2; this task ships the type with an empty body so the file compiles on its own.

- [ ] **Step 1: Write the failing tests**

```swift
// UsageTrackerTests/OMAgentsPillTests.swift
import XCTest
import SwiftUI
@testable import Omelette

/// The pill's state selection is the whole of its logic: colour and text for a
/// triple of counts, and "draw nothing" when there is nothing to count. Kept out
/// of the view so it can be tested without a hosting window.
final class OMAgentsPillAppearanceTests: XCTestCase {
    private func make(needsYou: Int = 0, working: Int = 0, total: Int) -> OMAgentsPill.Appearance? {
        OMAgentsPill.Appearance.make(needsYou: needsYou, working: working, total: total)
    }

    func testNoSessionsDrawNoPill() {
        // The menu bar is the app's scarcest surface: an empty capsule earns none of it.
        XCTAssertNil(make(total: 0))
    }

    func testQuietSessionsAreGreyAndShowTheTotal() {
        let look = make(total: 3)
        XCTAssertEqual(look?.dot, OMAgentColor.idle)
        XCTAssertEqual(look?.text, "3")
    }

    func testAWorkingSessionTurnsThePillBlueAndCountsOnlyTheWorkingOnes() {
        // Four sessions, two of them busy. The number worth a glance is how many
        // are running, not how many exist.
        let look = make(working: 2, total: 4)
        XCTAssertEqual(look?.dot, OMAgentColor.working)
        XCTAssertEqual(look?.text, "2")
    }

    func testOneWaitingSessionOutranksNineWorkingOnes() {
        let look = make(needsYou: 1, working: 9, total: 10)
        XCTAssertEqual(look?.dot, OMAgentColor.needsYou)
        XCTAssertEqual(look?.textColor, OMAgentColor.needsYou)
        XCTAssertEqual(look?.text, "1 needs you")
    }

    func testTheWaitingCountIsSpelledOutForEveryCount() {
        // Mockup option B: the amber state always says what it wants from you.
        XCTAssertEqual(make(needsYou: 3, working: 0, total: 3)?.text, "3 needs you")
    }

    func testTheAccessibilityLabelNamesTotalAndWaitingSessions() {
        XCTAssertEqual(
            make(needsYou: 2, working: 1, total: 5)?.accessibilityLabel,
            "5 agent sessions, 2 need you"
        )
        XCTAssertEqual(
            make(needsYou: 1, working: 0, total: 1)?.accessibilityLabel,
            "1 agent session, 1 needs you"
        )
        XCTAssertEqual(make(total: 4)?.accessibilityLabel, "4 agent sessions")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/OMAgentsPillAppearanceTests`
Expected: FAIL — compilation error, "cannot find 'OMAgentsPill' in scope".

- [ ] **Step 3: Create the file with the type and the rule**

```swift
// UsageTracker/UI/DesignSystem/OMAgentsPill.swift
import SwiftUI

/// Menu-bar capsule for agent sessions: a dot plus a count, amber and spelled out
/// while a session waits for you (approved mockup, option B).
///
/// Deliberately static in every state. The status item's hosting view never leaves
/// the screen, so anything that animates here animates forever — the one pulse in
/// the menu bar (`MiniServiceBar`) enters `TimelineView(.animation)` only while a
/// critical reading is on show, and even that is off under Reduce Motion. The pill
/// has no motion at all, which is why it needs no Reduce Motion branch.
struct OMAgentsPill: View {
    let needsYou: Int
    let working: Int
    let total: Int

    var body: some View {
        EmptyView()   // Task 2 draws the capsule.
    }
}

extension OMAgentsPill {
    /// The pill's entire appearance as data, so the selection rule is testable
    /// without a view hierarchy.
    struct Appearance: Equatable {
        let dot: Color
        let textColor: Color
        let text: String
        let accessibilityLabel: String

        /// `nil` means "draw nothing".
        ///
        /// Precedence is needs-you → working → quiet, and deliberately not
        /// "whichever count is biggest": one session blocked on an approval
        /// outranks nine that are merely busy.
        static func make(needsYou: Int, working: Int, total: Int) -> Appearance? {
            guard total > 0 else { return nil }
            let label = accessibilityText(needsYou: needsYou, total: total)
            if needsYou > 0 {
                return Appearance(
                    dot: OMAgentColor.needsYou,
                    textColor: OMAgentColor.needsYou,
                    text: "\(needsYou) needs you",
                    accessibilityLabel: label
                )
            }
            if working > 0 {
                return Appearance(
                    dot: OMAgentColor.working,
                    textColor: .primary,
                    text: "\(working)",
                    accessibilityLabel: label
                )
            }
            return Appearance(
                dot: OMAgentColor.idle,
                textColor: .secondary,
                text: "\(total)",
                accessibilityLabel: label
            )
        }

        /// "5 agent sessions, 2 need you". The visible text is a bare number in two
        /// of the three states, so VoiceOver has to say what the number counts.
        static func accessibilityText(needsYou: Int, total: Int) -> String {
            let sessions = total == 1 ? "1 agent session" : "\(total) agent sessions"
            guard needsYou > 0 else { return sessions }
            return "\(sessions), \(needsYou) \(needsYou == 1 ? "needs" : "need") you"
        }
    }
}
```

- [ ] **Step 4: Regenerate the project and run the tests**

Run: `xcodegen generate && xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/OMAgentsPillAppearanceTests`
Expected: PASS — 6 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add UsageTracker/UI/DesignSystem/OMAgentsPill.swift UsageTrackerTests/OMAgentsPillTests.swift
git commit -m "Agents pill: state selection rule with tests

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

### Task 2: The pill view

**Files:**
- Modify: `UsageTracker/UI/DesignSystem/OMAgentsPill.swift` (replace the placeholder `body`)

**Interfaces:**
- Consumes: `OMAgentsPill.Appearance.make(needsYou:working:total:)` (Task 1), `OMFont.menuNumeral`, `OMSurface.row` (phase 1), `SettingsStore.shared.agentsShowInMenuBar` (package 3).
- Produces: a drawing `OMAgentsPill` — 6 pt dot + numeral inside a capsule, `EmptyView` when hidden.

- [ ] **Step 1: Replace the placeholder body**

Replace `var body: some View { EmptyView() }` in `OMAgentsPill` with:

```swift
    /// `SettingsStore` rather than an injected flag: the pill is the only thing the
    /// `agentsShowInMenuBar` switch controls, and observing it here keeps
    /// `MenuBarLabel` free of a second reason to re-render.
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        if settings.agentsShowInMenuBar,
           let look = Appearance.make(needsYou: needsYou, working: working, total: total) {
            HStack(spacing: 4) {
                Circle()
                    .fill(look.dot)
                    .frame(width: 6, height: 6)
                Text(look.text)
                    .font(OMFont.menuNumeral)
                    .monospacedDigit()
                    .foregroundStyle(look.textColor)
            }
            .padding(.horizontal, 6)
            .frame(height: 15)
            .background(Capsule(style: .continuous).fill(OMSurface.row))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(look.accessibilityLabel)
        }
    }
```

`body` is an implicit `@ViewBuilder`, so the `if` without an `else` is the `EmptyView` case — no sessions, or the setting off, and the pill occupies no width at all.

- [ ] **Step 2: Add previews for all four states**

Append to the file:

```swift
#Preview("Agents pill") {
    // The dark strip stands in for the menu bar; the pill is drawn on the system
    // material there, so a white canvas would flatter it dishonestly.
    VStack(alignment: .leading, spacing: 10) {
        OMAgentsPill(needsYou: 0, working: 0, total: 3)   // grey "3"
        OMAgentsPill(needsYou: 0, working: 2, total: 4)   // blue "2"
        OMAgentsPill(needsYou: 1, working: 2, total: 4)   // amber "1 needs you"
        OMAgentsPill(needsYou: 0, working: 0, total: 0)   // nothing
    }
    .padding()
    .frame(width: 200, alignment: .leading)
    .background(Color.black.opacity(0.85))
}
```

- [ ] **Step 3: Build and check the pill has no animation path**

Run: `xcodegen generate && xcodebuild -project UsageTracker.xcodeproj -scheme UsageTracker -configuration Debug -derivedDataPath build/DerivedData build && grep -n "TimelineView\|repeatForever\|withAnimation\|Timer" UsageTracker/UI/DesignSystem/OMAgentsPill.swift`
Expected: BUILD SUCCEEDED, and grep prints nothing.

- [ ] **Step 4: Commit**

```bash
git add UsageTracker/UI/DesignSystem/OMAgentsPill.swift
git commit -m "Agents pill: capsule with dot and count

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

### Task 3: Fill the menu bar's `leadingSlot`

**Files:**
- Modify: `UsageTracker/UI/MenuBarLabel.swift` (`leadingSlot`, added by phase-1 Task 15; plus a new private view at the end of the file)

**Interfaces:**
- Consumes: `AgentSessionStore.shared` with `sessions`, `needsYouCount`, `workingCount` (package 2); `OMAgentsPill` (Task 2).
- Produces: `private struct AgentsPillSlot: View` in `MenuBarLabel.swift`.

- [ ] **Step 1: Point `leadingSlot` at the pill**

Re-read `UsageTracker/UI/MenuBarLabel.swift` first (other sessions commit this tree). Replace phase-1's placeholder

```swift
    /// Reserved for the phase-2 agents pill (count of live agent sessions).
    @ViewBuilder
    private var leadingSlot: some View {
        EmptyView()
    }
```

with

```swift
    /// The agents pill. A separate view, not an `@ObservedObject` on `MenuBarLabel`
    /// itself: see `AgentsPillSlot`.
    @ViewBuilder
    private var leadingSlot: some View {
        AgentsPillSlot()
    }
```

- [ ] **Step 2: Add the wrapper view at the end of the file**

Append to `UsageTracker/UI/MenuBarLabel.swift`:

```swift
/// Bridges `AgentSessionStore` into the menu bar.
///
/// The observation lives here rather than on `MenuBarLabel` on purpose. The store
/// republishes on every hook event — a tool starting is an event — and observing it
/// one level up would re-evaluate every provider pill each time an agent ran `Read`.
/// Confined to this view, an event that moves none of the three counts re-evaluates
/// these four lines and stops: SwiftUI compares `OMAgentsPill`'s stored `Int`s,
/// finds them unchanged and skips its body, so nothing is redrawn. Nothing on this
/// path is driven by a timer.
private struct AgentsPillSlot: View {
    @ObservedObject private var store = AgentSessionStore.shared

    var body: some View {
        OMAgentsPill(
            needsYou: store.needsYouCount,
            working: store.workingCount,
            total: store.sessions.count
        )
    }
}
```

- [ ] **Step 3: Build**

Run: `xcodebuild -project UsageTracker.xcodeproj -scheme UsageTracker -configuration Debug -derivedDataPath build/DerivedData build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Prove the pill only redraws on a real change**

Temporarily add `let _ = Self._printChanges()` as the first line of `OMAgentsPill.body`, build, run the app from Xcode (so the console is visible), and drive a Claude Code session with hooks installed.

Run: `xcodebuild -project UsageTracker.xcodeproj -scheme UsageTracker -configuration Debug -derivedDataPath build/DerivedData build && open build/DerivedData/Build/Products/Debug/Omelette.app`
Expected: `OMAgentsPill: @self changed` prints when the session enters `working`, when it enters `needsYou` and when it ends — and **not** on every `PreToolUse`/`PostToolUse` pair while the counts stay the same. In Activity Monitor, Omelette's CPU with the popover closed and three sessions in the pill stays under 0.5 % (this is the invariant the whole wrapper exists for). Remove the `_printChanges()` line before committing.

Run: `grep -n "_printChanges" UsageTracker/UI/DesignSystem/OMAgentsPill.swift`
Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add UsageTracker/UI/MenuBarLabel.swift
git commit -m "Menu bar: agents pill in the reserved leading slot

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

### Task 4: `AgentNotificationRules` — gating, identifiers and copy

**Files:**
- Create: `UsageTracker/Services/AgentNotificationRules.swift`
- Test: `UsageTrackerTests/AgentNotificationRulesTests.swift`

**Interfaces:**
- Consumes: `AgentSession` (`id`, `projectName`, `state`, `activity`, `turns`), `AgentState`, `AgentSource`, `AgentHostInfo` (package 1/2).
- Produces:
  ```swift
  enum AgentNotificationRules {
      static let needsYouPrefix = "agent-needsyou-"
      static let donePrefix = "agent-done-"
      static let maxBodyLength = 120
      static func shouldNotifyNeedsYou(notifyEnabled: Bool, bypassQuietHours: Bool, isQuietHours: Bool) -> Bool
      static func shouldNotifyDone(notifyEnabled: Bool, isQuietHours: Bool) -> Bool
      static func identifier(for session: AgentSession) -> String
      static func doneIdentifier(for session: AgentSession) -> String
      static func sessionID(fromIdentifier identifier: String) -> String?
      static func title(for session: AgentSession) -> String
      static func doneTitle(for session: AgentSession) -> String
      static func body(for session: AgentSession) -> String
      static func doneBody(for session: AgentSession) -> String
      static func truncate(_ text: String, limit: Int = maxBodyLength) -> String
      static func resolvedSessionIDs(notified: Set<String>, sessions: [AgentSession]) -> Set<String>
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
// UsageTrackerTests/AgentNotificationRulesTests.swift
import XCTest
@testable import Omelette

/// Built here rather than in `Fixture` on purpose: packages 2 and 4 also land test
/// code this week, and a shared `Fixture.agentSession` would be three sessions
/// editing one file. Nothing outside this file needs it.
private func agentSession(
    id: String = "claude:abc-123",
    project: String = "Usage tracker",
    state: AgentState = .needsYou,
    activity: String? = "Bash: xcodegen generate",
    turns: Int = 1
) -> AgentSession {
    AgentSession(
        id: id,
        sessionID: String(id.split(separator: ":").last ?? "abc-123"),
        source: id.hasPrefix("codex") ? .codex : .claude,
        projectName: project,
        cwd: "/Users/me/\(project)",
        state: state,
        activity: activity,
        stateSince: Date(),
        lastEventAt: Date(),
        startedAt: Date(),
        host: AgentHostInfo(pid: nil, bundleID: nil, tty: nil),
        isApproximate: false,
        turns: turns,
        needsYouCount: 1
    )
}

/// Which agent events may page the user. The notification centre is deliberately
/// out of reach here, exactly as in `UsageNotifierRulesTests`.
final class AgentNotificationGatingTests: XCTestCase {
    func testEveryNeedsYouToggleCombination() {
        // Both toggles against both quiet-hours states. `agentsNeedsYouBypassQuietHours`
        // is the only reason any notification in this app survives quiet hours.
        let cases: [(notify: Bool, bypass: Bool, quiet: Bool, expected: Bool)] = [
            (true,  true,  false, true),
            (true,  true,  true,  true),
            (true,  false, false, true),
            (true,  false, true,  false),
            (false, true,  false, false),
            (false, true,  true,  false),
            (false, false, false, false),
            (false, false, true,  false),
        ]
        for c in cases {
            XCTAssertEqual(
                AgentNotificationRules.shouldNotifyNeedsYou(
                    notifyEnabled: c.notify,
                    bypassQuietHours: c.bypass,
                    isQuietHours: c.quiet
                ),
                c.expected,
                "notify=\(c.notify) bypass=\(c.bypass) quiet=\(c.quiet)"
            )
        }
    }

    func testDoneNeverSurvivesQuietHours() {
        // "Finished" is an FYI. Nothing about it is worth waking someone for, so it
        // has no bypass at all.
        XCTAssertTrue(AgentNotificationRules.shouldNotifyDone(notifyEnabled: true, isQuietHours: false))
        XCTAssertFalse(AgentNotificationRules.shouldNotifyDone(notifyEnabled: true, isQuietHours: true))
        XCTAssertFalse(AgentNotificationRules.shouldNotifyDone(notifyEnabled: false, isQuietHours: false))
        XCTAssertFalse(AgentNotificationRules.shouldNotifyDone(notifyEnabled: false, isQuietHours: true))
    }
}

/// The identifier is what stops a session's second approval prompt from stacking a
/// second banner, and what lets the app withdraw the banner afterwards.
final class AgentNotificationIdentifierTests: XCTestCase {
    func testTheIdentifierIsStablePerSessionSoARepeatReplacesTheBanner() {
        let first = agentSession(activity: "Bash: xcodegen generate")
        let second = agentSession(activity: "Edit: MenuBarLabel.swift")
        XCTAssertEqual(AgentNotificationRules.identifier(for: first), "agent-needsyou-claude:abc-123")
        XCTAssertEqual(
            AgentNotificationRules.identifier(for: first),
            AgentNotificationRules.identifier(for: second)
        )
    }

    func testTwoSessionsNeverShareAnIdentifier() {
        XCTAssertNotEqual(
            AgentNotificationRules.identifier(for: agentSession(id: "claude:abc")),
            AgentNotificationRules.identifier(for: agentSession(id: "codex:abc"))
        )
    }

    func testDoneAndNeedsYouDoNotCollide() {
        let session = agentSession()
        XCTAssertNotEqual(
            AgentNotificationRules.identifier(for: session),
            AgentNotificationRules.doneIdentifier(for: session)
        )
    }

    func testTheSessionIDSurvivesTheRoundTrip() {
        // A session id contains a colon ("claude:abc-123"), which is why this strips
        // a known prefix instead of splitting on a separator.
        let session = agentSession(id: "claude:abc-123")
        XCTAssertEqual(
            AgentNotificationRules.sessionID(
                fromIdentifier: AgentNotificationRules.identifier(for: session)
            ),
            "claude:abc-123"
        )
        XCTAssertEqual(
            AgentNotificationRules.sessionID(
                fromIdentifier: AgentNotificationRules.doneIdentifier(for: session)
            ),
            "claude:abc-123"
        )
    }

    func testSomebodyElsesNotificationIsNotOurs() {
        // Threshold and daily-summary notifications carry a UUID identifier; acting
        // on one must not try to jump anywhere.
        XCTAssertNil(AgentNotificationRules.sessionID(fromIdentifier: UUID().uuidString))
        XCTAssertNil(AgentNotificationRules.sessionID(fromIdentifier: "agent-needsyou-"))
    }
}

/// What the banner says.
final class AgentNotificationCopyTests: XCTestCase {
    func testTheTitleNamesTheProjectAndTheBodyTheTool() {
        let session = agentSession(project: "Usage tracker", activity: "Bash: xcodegen generate")
        XCTAssertEqual(AgentNotificationRules.title(for: session), "Usage tracker needs your approval")
        XCTAssertEqual(AgentNotificationRules.body(for: session), "Bash: xcodegen generate")
    }

    func testASessionWithoutAToolSummaryStillSaysSomething() {
        // A `Notification`-sourced needsYou carries no tool_input, so the body would
        // otherwise be empty and the banner would read as broken.
        XCTAssertEqual(
            AgentNotificationRules.body(for: agentSession(activity: nil)),
            "Waiting for your approval."
        )
    }

    func testALongCommandIsTruncatedWithAnEllipsis() {
        let long = "Bash: " + String(repeating: "x", count: 300)
        let body = AgentNotificationRules.body(for: agentSession(activity: long))
        XCTAssertEqual(body.count, AgentNotificationRules.maxBodyLength)
        XCTAssertTrue(body.hasSuffix("…"))
        XCTAssertTrue(body.hasPrefix("Bash: xxx"))
    }

    func testABodyThatFitsIsLeftAlone() {
        let body = AgentNotificationRules.body(for: agentSession(activity: "Edit: MenuBarLabel.swift"))
        XCTAssertEqual(body, "Edit: MenuBarLabel.swift")
    }

    func testTheDoneBodyCountsTurns() {
        XCTAssertEqual(
            AgentNotificationRules.doneTitle(for: agentSession(project: "Orion", state: .done)),
            "Orion finished"
        )
        XCTAssertEqual(
            AgentNotificationRules.doneBody(for: agentSession(state: .done, activity: nil, turns: 1)),
            "1 turn"
        )
        XCTAssertEqual(
            AgentNotificationRules.doneBody(
                for: agentSession(state: .done, activity: "Edit: MenuBarLabel.swift", turns: 7)
            ),
            "Edit: MenuBarLabel.swift · 7 turns"
        )
    }
}

/// The leaving edge. The store announces a session *entering* `needsYou`; nothing
/// announces it leaving, so the banner has to be withdrawn from a diff — a banner
/// that outlives the approval it asked for is worse than no banner.
final class AgentNotificationWithdrawalTests: XCTestCase {
    func testASessionThatStopsWaitingHasItsBannerWithdrawn() {
        XCTAssertEqual(
            AgentNotificationRules.resolvedSessionIDs(
                notified: ["claude:a", "claude:b"],
                sessions: [
                    agentSession(id: "claude:a", state: .needsYou),
                    agentSession(id: "claude:b", state: .working),
                ]
            ),
            ["claude:b"]
        )
    }

    func testASessionThatDisappearsEntirelyHasItsBannerWithdrawn() {
        XCTAssertEqual(
            AgentNotificationRules.resolvedSessionIDs(notified: ["claude:a"], sessions: []),
            ["claude:a"]
        )
    }

    func testASessionStillWaitingKeepsItsBanner() {
        XCTAssertTrue(
            AgentNotificationRules.resolvedSessionIDs(
                notified: ["claude:a"],
                sessions: [agentSession(id: "claude:a", state: .needsYou)]
            ).isEmpty
        )
    }

    func testASessionWeNeverNotifiedAboutIsNotWithdrawn() {
        XCTAssertTrue(
            AgentNotificationRules.resolvedSessionIDs(
                notified: [],
                sessions: [agentSession(id: "claude:a", state: .idle)]
            ).isEmpty
        )
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/AgentNotificationGatingTests`
Expected: FAIL — compilation error, "cannot find 'AgentNotificationRules' in scope".

- [ ] **Step 3: Write the rules**

```swift
// UsageTracker/Services/AgentNotificationRules.swift
import Foundation

/// Which agent events may page the user, what the banner is filed under, and what
/// it says.
///
/// Pure and static for the same reason as `UsageNotifier.thresholdOutcome` and
/// `watchableBuckets`: the notification centre is out of reach in tests, and the
/// rules are the part worth testing. Nothing here touches disk — an activity string
/// is hook payload and lives in memory only (spec, "Security and privacy").
enum AgentNotificationRules {
    /// One banner per session, filed under a stable name, so a second approval
    /// prompt for the same session replaces the first instead of stacking, and the
    /// app can withdraw it by name once the session stops waiting.
    static let needsYouPrefix = "agent-needsyou-"
    static let donePrefix = "agent-done-"
    /// A notification body is one line in Notification Centre. The system truncates
    /// past that anyway; our own ellipsis lands on a nicer boundary than theirs.
    static let maxBodyLength = 120

    /// "Needs you" is the alert the feature exists for, so it gets the one
    /// quiet-hours escape hatch in the app (`agentsNeedsYouBypassQuietHours`,
    /// default on): an agent that blocks at 23:30 blocks until morning otherwise.
    static func shouldNotifyNeedsYou(
        notifyEnabled: Bool,
        bypassQuietHours: Bool,
        isQuietHours: Bool
    ) -> Bool {
        guard notifyEnabled else { return false }
        return !isQuietHours || bypassQuietHours
    }

    /// "Finished" is opt-in and stays inside quiet hours like every usage alert.
    static func shouldNotifyDone(notifyEnabled: Bool, isQuietHours: Bool) -> Bool {
        notifyEnabled && !isQuietHours
    }

    static func identifier(for session: AgentSession) -> String {
        needsYouPrefix + session.id
    }

    static func doneIdentifier(for session: AgentSession) -> String {
        donePrefix + session.id
    }

    /// The session id an identifier was built from, or nil when the notification is
    /// not one of ours (threshold and summary alerts carry a UUID). Session ids
    /// contain a colon — `claude:abc-123` — so a known prefix is stripped rather
    /// than the string split on a separator.
    static func sessionID(fromIdentifier identifier: String) -> String? {
        for prefix in [needsYouPrefix, donePrefix] where identifier.hasPrefix(prefix) {
            let id = String(identifier.dropFirst(prefix.count))
            return id.isEmpty ? nil : id
        }
        return nil
    }

    static func title(for session: AgentSession) -> String {
        "\(session.projectName) needs your approval"
    }

    static func doneTitle(for session: AgentSession) -> String {
        "\(session.projectName) finished"
    }

    /// The tool the session is blocked on — "Bash: xcodegen generate". A needsYou
    /// that arrived as a `Notification` hook rather than `PermissionRequest` has no
    /// tool input, hence the fallback sentence.
    static func body(for session: AgentSession) -> String {
        truncate(session.activity ?? "Waiting for your approval.")
    }

    /// What the turn did and how long it ran, in turns.
    static func doneBody(for session: AgentSession) -> String {
        let turns = session.turns == 1 ? "1 turn" : "\(session.turns) turns"
        guard let activity = session.activity else { return turns }
        return truncate("\(activity) · \(turns)")
    }

    static func truncate(_ text: String, limit: Int = maxBodyLength) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }

    /// Sessions whose banner should come down: every id we banner-ed that is no
    /// longer waiting, whether because its state moved on or because the session is
    /// gone. Keyed by session id, not identifier, so the caller updates its own
    /// bookkeeping from the same answer.
    static func resolvedSessionIDs(
        notified: Set<String>,
        sessions: [AgentSession]
    ) -> Set<String> {
        let waiting = Set(sessions.filter { $0.state == .needsYou }.map(\.id))
        return notified.subtracting(waiting)
    }
}
```

- [ ] **Step 4: Run the four test classes**

Run: `xcodegen generate && xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/AgentNotificationGatingTests -only-testing:UsageTrackerTests/AgentNotificationIdentifierTests -only-testing:UsageTrackerTests/AgentNotificationCopyTests -only-testing:UsageTrackerTests/AgentNotificationWithdrawalTests`
Expected: PASS — 15 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add UsageTracker/Services/AgentNotificationRules.swift UsageTrackerTests/AgentNotificationRulesTests.swift
git commit -m "Agent notifications: pure rules for gating, identifiers and copy

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

### Task 5: Deliver the notifications from `UsageNotifier`

**Files:**
- Modify: `UsageTracker/Services/UsageNotifier.swift` (imports, stored properties, `fire`, new "Agent sessions" section, delegate conformance)
- Modify: `UsageTracker/UI/StatusBarController.swift` (`.showPopover` observer, `Notification.Name` extension)
- Modify: `UsageTracker/UsageTrackerApp.swift` (`applicationDidFinishLaunching`, one line)

**Interfaces:**
- Consumes: `AgentNotificationRules` (Task 4); `AgentSessionStore.shared` with `onNeedsYou`, `onDone`, `$sessions`, `sessions` (package 2); `SessionActivator.jump(to:)` (package 4); `SettingsStore.shared.agentsNotifyNeedsYou / .agentsNeedsYouBypassQuietHours / .agentsNotifyDone` (package 3); `UsageNotifier.isInQuietHours(at:)` (existing).
- Produces:
  ```swift
  extension UsageNotifier {
      static let agentNeedsYouCategory = "AGENT_NEEDS_YOU"
      static let agentOpenAction = "AGENT_OPEN"
      func startAgentNotifications(store: AgentSessionStore = .shared)
      func handleAgentResponse(identifier: String, action: String)
  }
  extension Notification.Name { static let showPopover: Notification.Name }
  ```
  `UsageNotifier` gains a `UNUserNotificationCenterDelegate` conformance. `fire` gains three defaulted parameters (`identifier:`, `category:`, `timeSensitive:`) — existing call sites are unchanged.

- [ ] **Step 1: Add the imports and the stored state**

Re-read `UsageTracker/Services/UsageNotifier.swift` first. Change the imports at the top of the file from

```swift
import Foundation
import UserNotifications
```

to

```swift
import Combine
import Foundation
import UserNotifications
```

and add, immediately after `private var firedForWindow: [String: Double]` in the stored-property block:

```swift
    /// Session ids that currently have a "needs you" banner on screen. Not
    /// persisted: a banner does not survive a relaunch, so neither should the
    /// record of it.
    private var notifiedNeedsYou: Set<String> = []
    private var agentSessionsObserver: AnyCancellable?
```

- [ ] **Step 2: Widen `fire` so a notification can carry an identifier and a category**

Replace the existing `private func fire(...)` in the "Plumbing" section with:

```swift
    /// The identifier defaults to a fresh UUID — a usage alert is a one-off. Agent
    /// alerts pass a stable one instead, which is what makes a repeat replace the
    /// banner and lets `clearResolvedNeedsYou` take it down again.
    private func fire(
        title: String,
        body: String,
        critical: Bool = false,
        identifier: String? = nil,
        category: String? = nil,
        timeSensitive: Bool = false
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = critical ? .defaultCritical : .default
        if critical || timeSensitive {
            // Best effort: without the time-sensitive entitlement the system quietly
            // treats this as `.active`. The critical usage alerts already ask for it.
            content.interruptionLevel = .timeSensitive
        }
        if let category {
            content.categoryIdentifier = category
        }
        let request = UNNotificationRequest(
            identifier: identifier ?? UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
```

- [ ] **Step 3: Add the agent section**

Insert a new section immediately before `// MARK: - Plumbing`:

```swift
    // MARK: - Agent sessions

    static let agentNeedsYouCategory = "AGENT_NEEDS_YOU"
    static let agentOpenAction = "AGENT_OPEN"

    /// Installs the notification-centre delegate, registers the agent category and
    /// starts watching the session store. Called once at launch.
    ///
    /// The delegate comes before `requestAuthorizationIfNeeded()` in
    /// `applicationDidFinishLaunching` deliberately: a notification the user acts on
    /// must find a delegate already installed, including on the launch that tap
    /// causes.
    ///
    /// Only the "needs you" alert gets a category. "Finished" needs no button — its
    /// whole body is the action, and a click on the body arrives as
    /// `UNNotificationDefaultActionIdentifier`, which `handleAgentResponse` routes
    /// exactly like **Open**.
    func startAgentNotifications(store: AgentSessionStore = .shared) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.agentNeedsYouCategory,
                actions: [
                    UNNotificationAction(
                        identifier: Self.agentOpenAction,
                        title: "Open",
                        options: [.foreground]
                    )
                ],
                intentIdentifiers: [],
                options: []
            )
        ])

        store.onNeedsYou = { [weak self] session in
            MainActor.assumeIsolated { self?.agentNeedsYou(session) }
        }
        store.onDone = { [weak self] session in
            MainActor.assumeIsolated { self?.agentDone(session) }
        }
        // The store announces a session *entering* `needsYou`; nothing announces it
        // leaving, so the leaving edge is diffed out of the published list.
        agentSessionsObserver = store.$sessions.sink { [weak self] sessions in
            MainActor.assumeIsolated { self?.clearResolvedNeedsYou(in: sessions) }
        }
    }

    private func agentNeedsYou(_ session: AgentSession) {
        guard AgentNotificationRules.shouldNotifyNeedsYou(
            notifyEnabled: SettingsStore.shared.agentsNotifyNeedsYou,
            bypassQuietHours: SettingsStore.shared.agentsNeedsYouBypassQuietHours,
            isQuietHours: isInQuietHours()
        ) else { return }

        // Recorded only once the banner is actually scheduled: a suppressed alert
        // has nothing to withdraw later.
        notifiedNeedsYou.insert(session.id)
        fire(
            title: AgentNotificationRules.title(for: session),
            body: AgentNotificationRules.body(for: session),
            identifier: AgentNotificationRules.identifier(for: session),
            category: Self.agentNeedsYouCategory,
            timeSensitive: true
        )
    }

    private func agentDone(_ session: AgentSession) {
        guard AgentNotificationRules.shouldNotifyDone(
            notifyEnabled: SettingsStore.shared.agentsNotifyDone,
            isQuietHours: isInQuietHours()
        ) else { return }
        fire(
            title: AgentNotificationRules.doneTitle(for: session),
            body: AgentNotificationRules.doneBody(for: session),
            identifier: AgentNotificationRules.doneIdentifier(for: session)
        )
    }

    /// Takes down banners for sessions that stopped waiting — you approved it in the
    /// terminal, or the session ended. Nothing else clears them: a notification with
    /// no identifier of ours is left alone.
    private func clearResolvedNeedsYou(in sessions: [AgentSession]) {
        let resolved = AgentNotificationRules.resolvedSessionIDs(
            notified: notifiedNeedsYou,
            sessions: sessions
        )
        guard !resolved.isEmpty else { return }
        notifiedNeedsYou.subtract(resolved)
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: resolved.map { AgentNotificationRules.needsYouPrefix + $0 }
        )
    }

    /// Routes a tap on an agent notification to the session it names. A session that
    /// has since ended has nothing to jump to, so the popover — where the remaining
    /// sessions are — opens instead.
    func handleAgentResponse(identifier: String, action: String) {
        guard action == UNNotificationDefaultActionIdentifier || action == Self.agentOpenAction,
              let sessionID = AgentNotificationRules.sessionID(fromIdentifier: identifier)
        else { return }
        notifiedNeedsYou.remove(sessionID)
        if let session = AgentSessionStore.shared.sessions.first(where: { $0.id == sessionID }) {
            SessionActivator.jump(to: session)
        } else {
            NotificationCenter.default.post(name: .showPopover, object: nil)
        }
    }
```

- [ ] **Step 4: Conform to `UNUserNotificationCenterDelegate`**

Append at the end of `UsageNotifier.swift`, after the closing brace of the class:

```swift
extension UsageNotifier: UNUserNotificationCenterDelegate {
    /// Tapping the banner, or its **Open** action, jumps to the session.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        let action = response.actionIdentifier
        Task { @MainActor in
            self.handleAgentResponse(identifier: identifier, action: action)
            completionHandler()
        }
    }

    /// Omelette activates itself when you act on a notification (the **Open** action
    /// is `.foreground`), so without this the next banner would be swallowed as
    /// "the app is already frontmost" — which for an accessory app the user is not
    /// even looking at would simply lose the alert.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
```

- [ ] **Step 5: Add the popover fallback route**

In `UsageTracker/UI/StatusBarController.swift`, add next to the existing observer property:

```swift
    nonisolated(unsafe) private var showPopoverObserver: (any NSObjectProtocol)?
```

in `init()`, immediately after `observeSnapshotForTooltip()`:

```swift
        // A notification the user acted on can name a session that has already
        // ended; the popover is where the rest of them are.
        showPopoverObserver = NotificationCenter.default.addObserver(
            forName: .showPopover, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.peek()
            }
        }
```

in `deinit`, after the existing removal:

```swift
        if let observer = showPopoverObserver {
            NotificationCenter.default.removeObserver(observer)
        }
```

and extend the `Notification.Name` extension at the bottom of the file:

```swift
extension Notification.Name {
    static let snapshotUpdated = Notification.Name("com.usagetracker.snapshotUpdated")
    /// Posted when something outside the status item wants the popover on screen.
    /// Today that is one caller: an agent notification whose session is gone.
    static let showPopover = Notification.Name("com.usagetracker.showPopover")
}
```

- [ ] **Step 6: Start it at launch**

In `UsageTracker/UsageTrackerApp.swift`, inside `applicationDidFinishLaunching`, change

```swift
        UsageNotifier.shared.requestAuthorizationIfNeeded()
```

to

```swift
        // Delegate and category first: an authorization prompt can be answered, and
        // a notification acted on, before the next statement would have run.
        UsageNotifier.shared.startAgentNotifications()
        UsageNotifier.shared.requestAuthorizationIfNeeded()
```

- [ ] **Step 7: Build and run the whole suite**

Run: `xcodegen generate && xcodebuild -project UsageTracker.xcodeproj -scheme UsageTracker -configuration Debug -derivedDataPath build/DerivedData build && xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData`
Expected: BUILD SUCCEEDED and all tests PASS, including the untouched `UsageNotifierRulesTests`, `UsageNotifierThresholdTests` and `UsageNotifierDayKeyTests` — the widened `fire` must not have disturbed them.

If `store.$sessions` does not compile (`@Published private(set)` exposes its projected value for reading, but confirm against the merged package-2 source), replace the sink in Step 3 with

```swift
        agentSessionsObserver = store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.clearResolvedNeedsYou(in: AgentSessionStore.shared.sessions)
                }
            }
```

— `objectWillChange` fires before the mutation, so the `receive(on:)` hop is what makes the read see the new array.

- [ ] **Step 8: Commit**

```bash
git add UsageTracker/Services/UsageNotifier.swift UsageTracker/UI/StatusBarController.swift UsageTracker/UsageTrackerApp.swift
git commit -m "Agent notifications: needs-you and finished banners with an Open action

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

### Task 6: Manual verification checklist

**Files:** none (verification only). Needs Claude Code hooks installed (package 3's Settings → Agents → Enable) and a real session; run the Debug build from `build/DerivedData/Build/Products/Debug/Omelette.app`. Grant notification permission on first launch when asked.

Menu bar:

- [ ] No sessions: no pill, and the provider pills sit exactly where they did before this package.
- [ ] Start a Claude Code session and leave it idle: a grey dot with `1` appears; the status item widens without clipping any provider pill.
- [ ] Send a prompt: the pill turns blue and reads `1`. Start a second session: `2`.
- [ ] Trigger an approval prompt (e.g. a `Bash` command outside the allowlist): the pill turns amber and reads `1 needs you`.
- [ ] Approve it in the terminal: the pill goes back to blue, then grey.
- [ ] Settings → Agents → "Show in menu bar" off: the pill disappears immediately, provider pills unaffected; on again: it comes back.
- [ ] With three sessions live and the popover closed, Omelette's CPU in Activity Monitor stays under 0.5 % for a full minute (no continuous redraw).
- [ ] System Settings → Accessibility → Reduce Motion on: the pill looks and behaves identically (it has no animation in either mode).
- [ ] Light and dark appearance; VoiceOver on the status item reads "5 agent sessions, 2 need you".

Notifications:

- [ ] Approval prompt with `agentsNotifyNeedsYou` on: a banner "<project> needs your approval" / "Bash: …" arrives with an **Open** button.
- [ ] A second approval prompt in the same session replaces that banner in Notification Centre rather than adding a second one.
- [ ] Approving in the terminal removes the delivered banner from Notification Centre.
- [ ] **Open** activates the terminal on the right tab (`SessionActivator`). End the session, then act on a still-visible banner: the popover opens instead.
- [ ] Clicking the banner body (not the button) does the same as **Open**.
- [ ] Quiet hours on, `agentsNeedsYouBypassQuietHours` on: the banner still arrives. Bypass off: nothing arrives, and the pill still turns amber.
- [ ] `agentsNotifyDone` on: finishing a turn produces "<project> finished". Off (default): nothing.
- [ ] A usage-threshold alert still fires and still looks the way it did (the `fire` signature changed under it).

Record the result in the commit body of the final package-5 commit:

```bash
git commit --allow-empty -m "Agents pill + notifications: manual checklist passed

Menu bar: grey/blue/amber states, hide toggle, idle CPU under 0.5%, VoiceOver.
Notifications: replace-not-stack, withdrawal on approval, Open jumps, quiet-hours bypass.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

## Self-review notes

- **Spec coverage.** "Menu bar — agents pill" (hidden with no sessions, grey / blue / amber `N needs you`, Reduce Motion respected): Tasks 1–3. "Notifications" — needsYou banner with activity body and an **Open** action, one per session per episode, cleared when the state leaves `needsYou`, quiet-hours bypass, opt-in `done`: Tasks 4–5. "Security and privacy" — payloads shown truncated and never persisted: `AgentNotificationRules.truncate`, and `notifiedNeedsYou` holds ids only, deliberately not persisted. "Testing" — notification dedupe rules unit-tested: Task 4.
- **Contract fidelity.** `OMAgentsPill(needsYou:working:total:)`, `AgentSessionStore.shared` / `onNeedsYou` / `onDone` / `needsYouCount` / `workingCount`, `SessionActivator.jump(to:)`, the four `agents*` settings keys, `OMAgentColor`, `OMFont.menuNumeral`, `OMSurface.row` are consumed exactly as declared and nothing is renamed. Additions this package owns: `OMAgentsPill.Appearance` (+ `make`, `accessibilityText`), `AgentsPillSlot`, the whole of `AgentNotificationRules`, `UsageNotifier.agentNeedsYouCategory` / `agentOpenAction` / `startAgentNotifications(store:)` / `handleAgentResponse(identifier:action:)`, the `UNUserNotificationCenterDelegate` conformance, three defaulted parameters on the private `fire`, and `Notification.Name.showPopover`.
- **Names used consistently across tasks.** `Appearance.make(needsYou:working:total:)` returns `Appearance?` in Task 1 and is consumed as an optional in Task 2; `AgentNotificationRules.identifier(for:)` / `doneIdentifier(for:)` / `sessionID(fromIdentifier:)` / `resolvedSessionIDs(notified:sessions:)` / `needsYouPrefix` are defined in Task 4 with the same spellings Task 5 calls; `notifiedNeedsYou` is the single set written by `agentNeedsYou`, `clearResolvedNeedsYou` and `handleAgentResponse`.
- **No shared fixture.** The test session builder is `private` inside `AgentNotificationRulesTests.swift` rather than added to `UsageTrackerTests/Fixtures.swift`, because packages 2 and 4 land test code in the same window and a shared `Fixture.agentSession` would be three plans editing one file. It uses `AgentSession`'s memberwise initializer with every field from the contract; if package 2 gives `AgentSession` a custom `init`, this builder is the one place to adjust.
- **Deliberate scope choices.** Agent notifications do not consult the master `notificationsEnabled` switch — that toggle gates usage-limit alerts, and the daily summary already sets the precedent of an independent toggle; Settings → Agents (package 3) owns the agent toggles. `willPresent` returning `[.banner, .sound]` is a small behaviour change for *all* notifications and is called out in Task 5's comment; it exists because the **Open** action foregrounds the app. No CHANGELOG entry or version bump here: phase 2 ships as one release, and five packages appending to `## [Unreleased]` in parallel is a merge conflict per package.
- **Open questions / risks.** (1) `store.$sessions` visibility with `@Published private(set)` — Task 5 Step 7 carries the `objectWillChange` fallback. (2) `onNeedsYou` / `onDone` are single-assignment slots; this package is the only assigner, and any other package needing the same signal should subscribe to `$sessions` instead. (3) `.timeSensitive` needs an entitlement the app may not carry; the level degrades silently and the existing critical alerts already rely on it. (4) Task 5 touches `applicationDidFinishLaunching`, which packages 1–3 also extend — keep the edit to the two lines shown so the merge is trivial. (5) The amber text is literally `"\(needsYou) needs you"`, so three waiting sessions read "3 needs you"; that is the approved mockup's wording and the VoiceOver label says "3 need you" correctly.
