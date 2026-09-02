# Phase 2 · Package 4 — Popover Agents section, segment dots, jump to session

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The popover shows every live agent session — grouped by status on the **All** tab, flat on a provider tab — with an amber dot on the segment of a provider that is waiting for you, and one click on a row brings that terminal tab back to the front.

**Architecture:** All wording and clock arithmetic lives in pure helpers (`AgentRowText`, `AgentsSection.groups/flat`) so the copy is unit-tested rather than eyeballed; the two views (`OMAgentRow`, `AgentsSection`) are phase-1 design-system components built from `OMSurface`/`OMRadius`/`OMFont`/`OMAgentColor`; `SessionActivator` is a small AppKit/Apple Events shim whose script generation is a pure, tested function; `PopoverView` only wires them together and owns the two `@State` hook-status flags.

**Tech Stack:** Swift 6 (`SWIFT_VERSION: "6.0"`), SwiftUI, macOS 14 floor, AppKit (`NSRunningApplication`, `NSAppleScript`, `NSWorkspace`), XCTest (`UsageTrackerTests`, `@testable import Omelette`), xcodegen-generated project.

**Spec:** `docs/superpowers/specs/2026-09-02-agent-overview-design.md` (sections "UI → Popover — Agents section", "Security and privacy", "Packages"), contract: `docs/superpowers/specs/2026-09-02-agent-overview-interfaces.md`, roadmap: `docs/superpowers/specs/2026-09-02-agent-control-plane-roadmap.md`, approved mockup: `.superpowers/brainstorm/66461-1788298131/content/popover-layout-v2.html`.

## Global Constraints

**Prerequisites — nothing in this package compiles without them:**

- Phase 1 (`docs/superpowers/plans/2026-09-02-design-system-popover.md`) is merged: `PopoverView` already has `allTab`, `segments`, `ProviderDetail`, `displayedServices`, `currentTab`, `selectedService`, and the kit has `OMSegmentedControl`/`OMSegmentItem` (incl. `showsDot`), `OMSectionHeader(title:trailing:)`, `OMRadius`, `OMSurface`, `OMFont`, `OMSpacing`, `OMAgentColor`, `WindowRanking.allTab`.
- Package 1 is merged: `AgentPaths` (`claudeSettingsURL`, `codexConfigURL`, `helperSymlinkURL`), `AgentSource`.
- Package 2 is merged: `AgentSession`, `AgentState` (+ `rank`, `CaseIterable`), `AgentHostInfo`, `AgentSessionStore.shared` (`sessions`, `sessions(for:)`, `needsYouCount`).
- Package 3 is merged: `AgentHooksInstaller.claudeStatus(settingsURL:helperPath:)` / `codexStatus(configURL:helperPath:)` returning `HookInstallStatus`, and Settings gets an **Agents** tab whose `SettingsView.Tab` raw value is `"Agents"`.

**Rules that apply to every task:**

- Contract names from `2026-09-02-agent-overview-interfaces.md` are fixed: `OMAgentRow(session:showsProviderIcon:action:)`, `AgentsSection(sessions:grouped:hooksInstalled:onEnable:)`, `SessionActivator.jump(to:)`, `OMSegmentItem.showsDot`. Anything else this package introduces is listed under a task's **Produces**.
- Deployment target macOS 14.0; glass effects only through `UsageTracker/UI/Components/LiquidGlass.swift` helpers, never a bare `glassEffect` call. (This package adds no glass: content surfaces use `OMSurface`.)
- Popover width stays 360 pt; `NSPopover.contentSize` in `UsageTracker/UI/StatusBarController.swift:21` stays 340×460 — **do not touch it**. Height is bounded inside `AgentsSection` instead (Task 3).
- Swift 6 language mode is on (evidence: `nonisolated(unsafe)` in `Core/ProjectName.swift` and `UI/StatusBarController.swift`). Write main-actor-safe code: no state mutation from `@Sendable` escaping closures, use `.task(id:)` rather than `onPreferenceChange` for measurement, and keep `NSAppleScript`/`NSRunningApplication` calls `@MainActor`.
- Agent colour semantics (roadmap): amber "needs you", blue pulse "working", green "done", grey "idle". Reduce Motion removes the pulse.
- User-visible strings introduced here are exactly: `Agents`, `Claude agents`, `Codex agents`, `N sessions` / `1 session`, `Needs you`, `Working`, `Done`, `Idle`, `Needs approval`, `No agent sessions`, `Enable precise status`.
- New source files are picked up by xcodegen from `sources: - path: UsageTracker`; run `xcodegen generate` after adding files and before building. `UsageTracker.xcodeproj/` is generated and gitignored — never `git add` it.
- Build: `xcodebuild -project UsageTracker.xcodeproj -scheme UsageTracker -configuration Debug -derivedDataPath build/DerivedData build`.
  Tests: `xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData` (add `-only-testing:UsageTrackerTests/<Class>` for one class). If local signing of the test host fails, append `CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO`.
- Commits end with the trailer lines
  `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` and
  `Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X`.
- Other sessions may commit the working tree while you work: re-read a file right before editing it; prefer targeted edits over whole-file rewrites.
- No release in this plan: version bump, CHANGELOG and notarisation belong to the phase-2 release step.

---

## File structure

```
UsageTracker/Agents/
  SessionActivator.swift        jump to session: activate host app, AppleScript tab select, Finder fallback   (Task 1)
  SettingsRoute.swift           one-shot "open Settings on tab X" intent                                      (Task 4)
UsageTracker/UI/DesignSystem/
  OMAgentRow.swift              AgentRowText (pure copy/time) + OMAgentRow + AgentStateDot + previews          (Task 2)
  AgentsSection.swift           AgentGroup + AgentsSection (+ grouping/ordering statics) + previews            (Task 3)
UsageTracker/UI/
  PopoverView.swift             wiring: hook status, segment dots, All tab section, provider tab section       (Task 5)
  SettingsView.swift            consumes SettingsRoute on appear / on change                                   (Task 4)
UsageTracker/
  UsageTracker.entitlements     + com.apple.security.automation.apple-events                                   (Task 1)
project.yml                     + NSAppleEventsUsageDescription in the app target's info.properties            (Task 1)
UsageTrackerTests/
  AgentFixtures.swift           Fixture.agentSession(...) builder                                              (Task 2)
  AgentRowTextTests.swift       subtitle / elapsed / accessibility label                                       (Task 2)
  AgentsSectionTests.swift      groups / flat / caption / titles / colours / opacity                           (Task 3)
  SessionActivatorTests.swift   AppleScript source for Terminal + iTerm2, escaping, unknown apps               (Task 1)
  SettingsRouteTests.swift      the one-shot tab request is consumed exactly once                              (Task 4)
```

Task order is compile order: `SessionActivator` before `AgentsSection` (which calls it), `OMAgentRow` before `AgentsSection` (which renders it), everything before the `PopoverView` wiring.

---

## Task 1: `SessionActivator` — jump to session, plus the Apple Events permissions

**Files:**
- Create: `UsageTracker/Agents/SessionActivator.swift`
- Create: `UsageTrackerTests/SessionActivatorTests.swift`
- Modify: `project.yml` (app target → `info:` → `properties:`, after `SUEnableAutomaticChecks`)
- Modify: `UsageTracker/UsageTracker.entitlements`

**Interfaces:**
- Consumes: `AgentSession` (`host: AgentHostInfo` with `pid: Int32?`, `bundleID: String?`, `tty: String?`; `cwd: String?`) from package 2.
- Produces:
  ```swift
  enum SessionActivator {
      @MainActor static func jump(to session: AgentSession)
      /// AppleScript source that selects the tab whose tty matches; nil for unsupported apps.
      static func script(for bundleID: String, tty: String) -> String?
      static let terminalBundleID = "com.apple.Terminal"
      static let iTermBundleID = "com.googlecode.iterm2"
  }
  ```

**Why the entitlement and the usage description (verified 2026-09-02):**
`signing.xcconfig` sets `ENABLE_HARDENED_RUNTIME = YES` and `OTHER_CODE_SIGN_FLAGS = --timestamp --options=runtime`. Under the Hardened Runtime an app may not send Apple events to another app unless it carries the **Apple Events entitlement** `com.apple.security.automation.apple-events` (the exception — events to itself or to processes signed with the same Team ID — does not cover Terminal or iTerm2). Separately, TCC requires **`NSAppleEventsUsageDescription`** in Info.plist for the "Omelette wants to control …" prompt; without it the send is refused with `errAEEventNotPermitted (-1743)` and no prompt is ever shown. Both are therefore mandatory. Sources: [Apple Events Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events), [Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime), [Apple Developer Forums thread 750802](https://developer.apple.com/forums/thread/750802), [lapcatsoftware: Hardened Runtime and Sandboxing](https://lapcatsoftware.com/articles/hardened-runtime-sandboxing.html). The app is not sandboxed (`com.apple.security.app-sandbox` is `false`), so no sandbox temporary-exception key is needed; `com.apple.security.*` entitlements need no provisioning profile for Developer ID signing, so `CODE_SIGN_STYLE = Automatic` keeps working.

- [ ] **Step 1: Write the failing tests**

```swift
// UsageTrackerTests/SessionActivatorTests.swift
import XCTest
@testable import Omelette

final class SessionActivatorTests: XCTestCase {
    func testTerminalScriptSelectsTheTabWithThatTTY() throws {
        let source = try XCTUnwrap(SessionActivator.script(for: "com.apple.Terminal", tty: "/dev/ttys004"))
        XCTAssertTrue(source.contains("\"/dev/ttys004\""), source)
        XCTAssertTrue(source.contains("application id \"com.apple.Terminal\""), source)
        XCTAssertTrue(source.contains("tabs of w"), source)
        XCTAssertTrue(source.contains("set selected of t to true"), source)
        XCTAssertTrue(source.contains("set frontmost of w to true"), source)
        XCTAssertTrue(source.contains("with timeout of 2 seconds"), source)
    }

    func testITermScriptWalksWindowsTabsSessions() throws {
        let source = try XCTUnwrap(SessionActivator.script(for: "com.googlecode.iterm2", tty: "/dev/ttys011"))
        XCTAssertTrue(source.contains("\"/dev/ttys011\""), source)
        XCTAssertTrue(source.contains("application id \"com.googlecode.iterm2\""), source)
        XCTAssertTrue(source.contains("tabs of w"), source)
        XCTAssertTrue(source.contains("sessions of t"), source)
        XCTAssertTrue(source.contains("select s"), source)
        XCTAssertTrue(source.contains("with timeout of 2 seconds"), source)
    }

    func testUnsupportedTerminalsGetNoScript() {
        XCTAssertNil(SessionActivator.script(for: "com.mitchellh.ghostty", tty: "/dev/ttys004"))
        XCTAssertNil(SessionActivator.script(for: "com.microsoft.VSCode", tty: "/dev/ttys004"))
        XCTAssertNil(SessionActivator.script(for: "", tty: "/dev/ttys004"))
    }

    /// The tty reaches us over the hook socket. It is machine-generated today,
    /// but a quote in it must not be able to close the AppleScript literal.
    func testQuotesInTheTTYCannotEscapeTheStringLiteral() throws {
        let source = try XCTUnwrap(SessionActivator.script(for: "com.apple.Terminal", tty: "/dev/tty\"s004"))
        XCTAssertTrue(source.contains("\\\"s004"), source)
        XCTAssertFalse(source.contains("tty\"s004"), source)
    }

    func testBackslashesInTheTTYAreEscaped() throws {
        let source = try XCTUnwrap(SessionActivator.script(for: "com.googlecode.iterm2", tty: "/dev/tty\\s004"))
        XCTAssertTrue(source.contains("tty\\\\s004"), source)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/SessionActivatorTests`
Expected: compile error `cannot find 'SessionActivator' in scope`.

- [ ] **Step 3: Implement `SessionActivator`**

```swift
// UsageTracker/Agents/SessionActivator.swift
import AppKit

/// "Jump to session": put the window the agent is running in back in front of
/// the user. Best case that is the exact terminal tab; worst case it is the
/// project folder in Finder. Every failure is silent — a jump that doesn't work
/// must never interrupt anyone with an alert, and half a jump (the app is
/// frontmost, the tab is not) is still most of the value.
enum SessionActivator {
    static let terminalBundleID = "com.apple.Terminal"
    static let iTermBundleID = "com.googlecode.iterm2"

    @MainActor
    static func jump(to session: AgentSession) {
        if let pid = session.host.pid, let app = NSRunningApplication(processIdentifier: pid) {
            // `.activateIgnoringOtherApps` is soft-deprecated on macOS 14 in favour
            // of `[.activateAllWindows]`; a background terminal is exactly the case
            // the old option exists for, so it stays until it stops working.
            app.activate(options: [.activateIgnoringOtherApps])
            if let bundleID = app.bundleIdentifier,
               let tty = session.host.tty, !tty.isEmpty,
               let source = script(for: bundleID, tty: tty) {
                run(source)
            }
            return
        }
        // No host process (passive scan, or the terminal has since quit): the
        // project folder is the only thing left that still identifies the session.
        guard let cwd = session.cwd, !cwd.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd)])
    }

    /// AppleScript that selects the tab/session whose tty matches, for the two
    /// terminals that expose a tty over Apple Events. nil for everything else —
    /// Ghostty, Warp, kitty, WezTerm, VS Code and Cursor have no such API, so
    /// activating the app is the whole jump there.
    ///
    /// `tell application id` addresses the app by bundle id: no guessing whether
    /// the user's copy is called "iTerm" or "iTerm2". `with timeout of 2 seconds`
    /// is what keeps a busy terminal from freezing our main thread — the default
    /// Apple Event timeout is two minutes.
    static func script(for bundleID: String, tty: String) -> String? {
        let tty = escapeForAppleScript(tty)
        switch bundleID {
        case terminalBundleID:
            return """
            with timeout of 2 seconds
                tell application id "com.apple.Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is "\(tty)" then
                                set frontmost of w to true
                                set selected of t to true
                                return
                            end if
                        end repeat
                    end repeat
                end tell
            end timeout
            """
        case iTermBundleID:
            return """
            with timeout of 2 seconds
                tell application id "com.googlecode.iterm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s is "\(tty)" then
                                    select w
                                    select t
                                    select s
                                    return
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
            end timeout
            """
        default:
            return nil
        }
    }

    /// An AppleScript string literal only needs these two characters escaped.
    private static func escapeForAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// NSAppleScript is documented as main-thread-only and the popover click that
    /// gets us here is already on the main actor. Errors are swallowed on purpose:
    /// denied automation (-1743), an app that quit (-600) and a tab that closed
    /// between the hook event and the click all mean the same thing to the user —
    /// the app is frontmost, the tab is wherever it is.
    @MainActor
    private static func run(_ source: String) {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
    }
}
```

- [ ] **Step 4: Add the usage description to the generated Info.plist**

In `project.yml`, inside the `UsageTracker` target's `info:` → `properties:` block, add one line directly after `SUEnableAutomaticChecks: true`:

```yaml
        # Required before macOS will even show the automation prompt: without it a
        # send is refused with errAEEventNotPermitted (-1743) and no prompt appears.
        NSAppleEventsUsageDescription: "Omelette brings the terminal tab of an agent session back to the front when you click it."
```

- [ ] **Step 5: Add the Hardened Runtime entitlement**

In `UsageTracker/UsageTracker.entitlements`, add the key inside the existing `<dict>` (after the `com.apple.security.application-groups` array):

```xml
    <!-- Hardened Runtime blocks Apple events to other apps without this; we send
         them only to Terminal.app and iTerm2 to select the tab of an agent session. -->
    <key>com.apple.security.automation.apple-events</key>
    <true/>
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/SessionActivatorTests`
Expected: PASS (5 tests).

- [ ] **Step 7: Verify the plist key and the entitlement reached the built app**

Run:
```bash
xcodebuild -project UsageTracker.xcodeproj -scheme UsageTracker -configuration Debug -derivedDataPath build/DerivedData build \
  && plutil -extract NSAppleEventsUsageDescription raw build/DerivedData/Build/Products/Debug/Omelette.app/Contents/Info.plist \
  && codesign -d --entitlements - build/DerivedData/Build/Products/Debug/Omelette.app 2>&1 | grep -c "com.apple.security.automation.apple-events"
```
Expected: BUILD SUCCEEDED, then the usage-description sentence, then `1`.

- [ ] **Step 8: Commit**

```bash
git add UsageTracker/Agents/SessionActivator.swift UsageTrackerTests/SessionActivatorTests.swift project.yml UsageTracker/UsageTracker.entitlements
git commit -m "Agents: jump to session (activate host, select tty tab in Terminal/iTerm2)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

## Task 2: `AgentRowText` + `OMAgentRow`

**Files:**
- Create: `UsageTracker/UI/DesignSystem/OMAgentRow.swift`
- Create: `UsageTrackerTests/AgentFixtures.swift`
- Create: `UsageTrackerTests/AgentRowTextTests.swift`

**Interfaces:**
- Consumes: `AgentSession`, `AgentState`, `AgentSource`, `AgentHostInfo` (package 2); `OMFont`, `OMSpacing`, `OMRadius`, `OMSurface`, `OMAgentColor` (phase 1); `ProviderIconView(serviceID:sfFallback:size:)` (`UsageTrackerWidget/ProviderIconView.swift`, compiled into the app).
- Produces:
  ```swift
  enum AgentRowText {
      static func subtitle(for session: AgentSession) -> String
      static func statePhrase(_ state: AgentState) -> String
      static func elapsed(since: Date, now: Date = Date(), state: AgentState) -> String
      static func spokenElapsed(since: Date, now: Date = Date(), state: AgentState) -> String
      static func sourceName(_ source: AgentSource) -> String
      static func accessibilityLabel(for session: AgentSession, now: Date = Date()) -> String
  }
  struct OMAgentRow: View { let session: AgentSession; var showsProviderIcon: Bool = true; let action: () -> Void }
  // DEBUG only, shared with AgentsSection's previews:
  enum AgentPreviewData { static func session(...) -> AgentSession; static var mixed: [AgentSession] }
  ```
  Test-side: `Fixture.agentSession(...)` in `UsageTrackerTests/AgentFixtures.swift`.

- [ ] **Step 1: Write the test fixture**

```swift
// UsageTrackerTests/AgentFixtures.swift
import Foundation
@testable import Omelette

extension Fixture {
    /// A hook-tracked Claude session by default. `isApproximate: true` is what the
    /// passive log scan produces, and the UI marks those differently.
    static func agentSession(
        id: String = "claude:s1",
        sessionID: String = "s1",
        source: AgentSource = .claude,
        projectName: String = "Usage tracker",
        cwd: String? = "/Users/me/Desktop/Usage tracker",
        state: AgentState = .working,
        activity: String? = nil,
        stateSince: Date = Date(timeIntervalSince1970: 1_700_000_000),
        lastEventAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        startedAt: Date = Date(timeIntervalSince1970: 1_699_000_000),
        host: AgentHostInfo = AgentHostInfo(pid: nil, bundleID: nil, tty: nil),
        isApproximate: Bool = false,
        turns: Int = 1,
        needsYouCount: Int = 0
    ) -> AgentSession {
        AgentSession(
            id: id,
            sessionID: sessionID,
            source: source,
            projectName: projectName,
            cwd: cwd,
            state: state,
            activity: activity,
            stateSince: stateSince,
            lastEventAt: lastEventAt,
            startedAt: startedAt,
            host: host,
            isApproximate: isApproximate,
            turns: turns,
            needsYouCount: needsYouCount
        )
    }
}
```

- [ ] **Step 2: Write the failing tests**

```swift
// UsageTrackerTests/AgentRowTextTests.swift
import XCTest
@testable import Omelette

final class AgentRowTextTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ minutesAgo: Double) -> Date { now.addingTimeInterval(-minutesAgo * 60) }

    // MARK: subtitle

    func testSubtitlePrefersTheActivity() {
        let session = Fixture.agentSession(state: .needsYou, activity: "Bash: xcodegen generate")
        XCTAssertEqual(AgentRowText.subtitle(for: session), "Bash: xcodegen generate")
    }

    func testSubtitleFallsBackToTheStatePhrase() {
        XCTAssertEqual(AgentRowText.subtitle(for: Fixture.agentSession(state: .needsYou)), "Needs approval")
        XCTAssertEqual(AgentRowText.subtitle(for: Fixture.agentSession(state: .working)), "Working")
        XCTAssertEqual(AgentRowText.subtitle(for: Fixture.agentSession(state: .done)), "Done")
        XCTAssertEqual(AgentRowText.subtitle(for: Fixture.agentSession(state: .idle)), "Idle")
    }

    func testBlankActivityCountsAsNoActivity() {
        let session = Fixture.agentSession(state: .working, activity: "   ")
        XCTAssertEqual(AgentRowText.subtitle(for: session), "Working")
    }

    func testApproximateSessionsAreMarked() {
        let scanned = Fixture.agentSession(state: .working, activity: "Edit: WalletView.swift", isApproximate: true)
        XCTAssertEqual(AgentRowText.subtitle(for: scanned), "≈ Edit: WalletView.swift")
        XCTAssertEqual(AgentRowText.subtitle(for: Fixture.agentSession(state: .idle, isApproximate: true)), "≈ Idle")
    }

    // MARK: elapsed

    func testElapsedForLiveStatesIsADuration() {
        XCTAssertEqual(AgentRowText.elapsed(since: at(0.5), now: now, state: .working), "now")
        XCTAssertEqual(AgentRowText.elapsed(since: at(1), now: now, state: .working), "1m")
        XCTAssertEqual(AgentRowText.elapsed(since: at(14), now: now, state: .needsYou), "14m")
        XCTAssertEqual(AgentRowText.elapsed(since: at(125), now: now, state: .working), "2h 05m")
        XCTAssertEqual(AgentRowText.elapsed(since: at(60 * 26), now: now, state: .working), "1d")
    }

    func testElapsedForFinishedStatesReadsAsThePast() {
        XCTAssertEqual(AgentRowText.elapsed(since: at(5), now: now, state: .done), "5m ago")
        XCTAssertEqual(AgentRowText.elapsed(since: at(90), now: now, state: .idle), "1h 30m ago")
        XCTAssertEqual(AgentRowText.elapsed(since: at(0.2), now: now, state: .done), "just now")
    }

    /// Hook timestamps come from another process; a clock skew must not print "-3m".
    func testElapsedNeverGoesNegative() {
        XCTAssertEqual(AgentRowText.elapsed(since: now.addingTimeInterval(120), now: now, state: .working), "now")
    }

    // MARK: accessibility

    func testAccessibilityLabelCombinesEverything() {
        let session = Fixture.agentSession(
            projectName: "Usage tracker", state: .needsYou,
            activity: "Bash: xcodegen generate", stateSince: at(1)
        )
        XCTAssertEqual(
            AgentRowText.accessibilityLabel(for: session, now: now),
            "Usage tracker, Claude Code, Needs approval, Bash: xcodegen generate, for 1 minute"
        )
    }

    func testAccessibilityLabelWithoutActivity() {
        let session = Fixture.agentSession(source: .codex, projectName: "orion-gemini", state: .done, stateSince: at(5))
        XCTAssertEqual(
            AgentRowText.accessibilityLabel(for: session, now: now),
            "orion-gemini, Codex, Done, 5 minutes ago"
        )
    }

    func testAccessibilityLabelSaysApproximateInsteadOfPrintingTheSymbol() {
        let session = Fixture.agentSession(
            projectName: "Jaravis", state: .working,
            activity: "editing WalletView.swift", stateSince: at(14), isApproximate: true
        )
        XCTAssertEqual(
            AgentRowText.accessibilityLabel(for: session, now: now),
            "Jaravis, Claude Code, Working, approximately editing WalletView.swift, for 14 minutes"
        )
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/AgentRowTextTests`
Expected: compile error `cannot find 'AgentRowText' in scope`.

- [ ] **Step 4: Implement `AgentRowText`, `OMAgentRow` and the state dot**

```swift
// UsageTracker/UI/DesignSystem/OMAgentRow.swift
import SwiftUI

/// Pure text rules for an agent row. They live outside the view so the wording
/// and the clock arithmetic are unit-tested instead of eyeballed in a preview.
enum AgentRowText {
    /// What the agent is doing, in one line: the tool summary when we have one,
    /// otherwise the state itself. Log-scanned sessions get "≈ " — their state is
    /// inferred from file mtimes, not reported by a hook, and the row should not
    /// pretend otherwise.
    static func subtitle(for session: AgentSession) -> String {
        let activity = session.activity?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = activity.isEmpty ? statePhrase(session.state) : activity
        return session.isApproximate ? "≈ \(text)" : text
    }

    static func statePhrase(_ state: AgentState) -> String {
        switch state {
        case .needsYou: return "Needs approval"
        case .working: return "Working"
        case .done: return "Done"
        case .idle: return "Idle"
        }
    }

    /// How long the session has been in its current state. Live states read as a
    /// running duration ("14m", "2h 05m"); finished ones read as a moment in the
    /// past ("5m ago") because nothing is ticking any more.
    static func elapsed(since: Date, now: Date = Date(), state: AgentState) -> String {
        let seconds = max(0, now.timeIntervalSince(since))
        let isPast = isFinished(state)
        if seconds < 60 { return isPast ? "just now" : "now" }
        let minutes = Int(seconds / 60)
        let base: String
        if minutes < 60 {
            base = "\(minutes)m"
        } else if minutes < 24 * 60 {
            base = String(format: "%dh %02dm", minutes / 60, minutes % 60)
        } else {
            base = "\(minutes / (24 * 60))d"
        }
        return isPast ? "\(base) ago" : base
    }

    /// VoiceOver reads "14m" as "fourteen m", so the spoken form spells the units.
    static func spokenElapsed(since: Date, now: Date = Date(), state: AgentState) -> String {
        let seconds = max(0, now.timeIntervalSince(since))
        let isPast = isFinished(state)
        if seconds < 60 { return isPast ? "just now" : "for less than a minute" }
        let minutes = Int(seconds / 60)
        let phrase: String
        if minutes < 60 {
            phrase = plural(minutes, "minute")
        } else if minutes < 24 * 60 {
            let hours = minutes / 60
            let rest = minutes % 60
            phrase = rest == 0 ? plural(hours, "hour") : "\(plural(hours, "hour")) \(plural(rest, "minute"))"
        } else {
            phrase = plural(minutes / (24 * 60), "day")
        }
        return isPast ? "\(phrase) ago" : "for \(phrase)"
    }

    static func sourceName(_ source: AgentSource) -> String {
        switch source {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// One sentence carrying everything the row shows visually: project,
    /// provider, state, activity, and how long it has been that way.
    static func accessibilityLabel(for session: AgentSession, now: Date = Date()) -> String {
        var parts = [session.projectName, sourceName(session.source), statePhrase(session.state)]
        let activity = session.activity?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !activity.isEmpty {
            parts.append(session.isApproximate ? "approximately \(activity)" : activity)
        }
        parts.append(spokenElapsed(since: session.stateSince, now: now, state: session.state))
        return parts.joined(separator: ", ")
    }

    private static func isFinished(_ state: AgentState) -> Bool {
        state == .done || state == .idle
    }

    private static func plural(_ count: Int, _ unit: String) -> String {
        "\(count) \(unit)\(count == 1 ? "" : "s")"
    }
}

/// One agent session. The leading element is the provider logo with a small
/// state badge on the All tab, where rows from every provider mix, and the state
/// dot alone on a provider tab, where the provider is already the tab. The whole
/// row is a button: clicking it jumps to that session.
struct OMAgentRow: View {
    let session: AgentSession
    var showsProviderIcon: Bool = true
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: OMSpacing.s + 1) {
                leading
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.projectName)
                        .font(OMFont.bodyStrong)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(AgentRowText.subtitle(for: session))
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
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: OMRadius.row, style: .continuous).fill(OMSurface.row))
            .contentShape(RoundedRectangle(cornerRadius: OMRadius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help("Jump to \(session.projectName)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AgentRowText.accessibilityLabel(for: session))
        .accessibilityHint("Brings the window running this session to the front")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var leading: some View {
        if showsProviderIcon {
            ProviderIconView(serviceID: session.source.rawValue, sfFallback: Self.sfFallback(session.source), size: 18)
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .overlay(alignment: .bottomTrailing) {
                    // A badge, not a beacon: the group heading already says the
                    // state on this tab, so the dot never pulses here.
                    AgentStateDot(state: session.state, animates: false, diameter: 6)
                        .padding(1)
                        .background(Circle().fill(.background))
                        .offset(x: 3, y: 3)
                }
        } else {
            AgentStateDot(state: session.state, animates: !reduceMotion, diameter: 8)
                .frame(width: 20, height: 20)
        }
    }

    /// Both sources ship a bundled logo; these only matter to a stripped catalog.
    private static func sfFallback(_ source: AgentSource) -> String {
        switch source {
        case .claude: return "sparkles"
        case .codex: return "terminal"
        }
    }
}

/// The state as a colour: amber with a halo when the agent is waiting for you,
/// a pulsing blue while it works, green when the turn is done, grey when idle.
/// Reduce Motion drops the pulse; the halo stays, because a halo is not motion.
private struct AgentStateDot: View {
    let state: AgentState
    var animates: Bool = true
    var diameter: CGFloat = 8

    @State private var pulsing = false

    private var color: Color {
        switch state {
        case .needsYou: return OMAgentColor.needsYou
        case .working: return OMAgentColor.working
        case .done: return OMAgentColor.done
        case .idle: return OMAgentColor.idle
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .overlay {
                if state == .needsYou {
                    Circle()
                        .strokeBorder(color.opacity(0.28), lineWidth: 3)
                        .padding(-3)
                }
            }
            .background {
                if state == .working, animates {
                    Circle()
                        .stroke(color.opacity(0.55), lineWidth: 2)
                        .scaleEffect(pulsing ? 2.2 : 1)
                        .opacity(pulsing ? 0 : 0.6)
                }
            }
            .onAppear {
                guard state == .working, animates else { return }
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                    pulsing = true
                }
            }
    }
}

#if DEBUG
/// Fixture sessions for the previews in this file and in `AgentsSection`.
/// DEBUG-only so nothing fake ships in the app binary.
enum AgentPreviewData {
    static func session(
        _ project: String,
        _ state: AgentState,
        activity: String? = nil,
        minutes: Double = 3,
        source: AgentSource = .claude,
        approximate: Bool = false
    ) -> AgentSession {
        let now = Date()
        return AgentSession(
            id: "\(source.rawValue):\(project)",
            sessionID: project,
            source: source,
            projectName: project,
            cwd: "/Users/me/Desktop/\(project)",
            state: state,
            activity: activity,
            stateSince: now.addingTimeInterval(-minutes * 60),
            lastEventAt: now.addingTimeInterval(-minutes * 60),
            startedAt: now.addingTimeInterval(-3600),
            host: AgentHostInfo(pid: nil, bundleID: nil, tty: nil),
            isApproximate: approximate,
            turns: 3,
            needsYouCount: state == .needsYou ? 1 : 0
        )
    }

    /// The mockup's cast: one waiting, two working, one finished.
    static var mixed: [AgentSession] {
        [
            session("Usage tracker", .needsYou, activity: "Bash: xcodegen generate", minutes: 1),
            session("Orion Gate / mobile", .working, activity: "Edit: WalletView.swift", minutes: 14),
            session("orion-gemini", .working, activity: "Bash: swift test", minutes: 3, source: .codex),
            session("Jaravis", .done, activity: nil, minutes: 5),
        ]
    }
}

private func agentRowPreviewStack(showsProviderIcon: Bool) -> some View {
    VStack(spacing: 5) {
        OMAgentRow(session: AgentPreviewData.session("Usage tracker", .needsYou, activity: "Bash: xcodegen generate", minutes: 1), showsProviderIcon: showsProviderIcon) {}
        OMAgentRow(session: AgentPreviewData.session("Orion Gate / mobile", .working, activity: "Edit: WalletView.swift", minutes: 14), showsProviderIcon: showsProviderIcon) {}
        OMAgentRow(session: AgentPreviewData.session("Jaravis", .done, minutes: 5), showsProviderIcon: showsProviderIcon) {}
        OMAgentRow(session: AgentPreviewData.session("orion-gemini", .idle, minutes: 42, source: .codex), showsProviderIcon: showsProviderIcon) {}
        OMAgentRow(session: AgentPreviewData.session("Movie app", .working, activity: "Grep: usageStatusColor", minutes: 2, approximate: true), showsProviderIcon: showsProviderIcon) {}
    }
    .padding()
    .frame(width: 328)
}

#Preview("Agent rows — icons, light") { agentRowPreviewStack(showsProviderIcon: true) }
#Preview("Agent rows — icons, dark") { agentRowPreviewStack(showsProviderIcon: true).preferredColorScheme(.dark) }
#Preview("Agent rows — dots, light") { agentRowPreviewStack(showsProviderIcon: false) }
#Preview("Agent rows — dots, dark") { agentRowPreviewStack(showsProviderIcon: false).preferredColorScheme(.dark) }
#endif
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/AgentRowTextTests`
Expected: PASS (10 tests).

- [ ] **Step 6: Review the previews in Xcode**

Open `UsageTracker/UI/DesignSystem/OMAgentRow.swift` in Xcode and resume the canvas for all four previews.
Expected: five rows each; in the "icons" previews the provider logo carries a small state badge, in the "dots" previews the amber row shows a halo and the blue rows pulse; the approximate row reads "≈ Grep: usageStatusColor"; times read `1m`, `14m`, `5m ago`, `42m ago`, `2m`; dark previews keep the row fill visible.

- [ ] **Step 7: Commit**

```bash
git add UsageTracker/UI/DesignSystem/OMAgentRow.swift UsageTrackerTests/AgentFixtures.swift UsageTrackerTests/AgentRowTextTests.swift
git commit -m "Design system: OMAgentRow with tested copy and elapsed-time rules

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

## Task 3: `AgentsSection` — grouping, ordering, empty state, bounded height

**Files:**
- Create: `UsageTracker/UI/DesignSystem/AgentsSection.swift`
- Create: `UsageTrackerTests/AgentsSectionTests.swift`

**Interfaces:**
- Consumes: `OMAgentRow`, `AgentPreviewData` (Task 2); `SessionActivator.jump(to:)` (Task 1); `OMSectionHeader(title:trailing:)`, `OMFont`, `OMSpacing`, `OMRadius`, `OMSurface`, `OMAgentColor` (phase 1); `AgentSession`, `AgentState` (package 2).
- Produces:
  ```swift
  struct AgentGroup: Identifiable, Equatable { let state: AgentState; let sessions: [AgentSession]; var id: String }
  struct AgentsSection: View {
      let sessions: [AgentSession]
      let grouped: Bool
      let hooksInstalled: Bool
      var title: String = "Agents"      // extra member, defaulted: the contract's call site still compiles
      let onEnable: () -> Void
      static let maxListHeight: CGFloat  // 260
      static func groups(_ sessions: [AgentSession]) -> [AgentGroup]
      static func flat(_ sessions: [AgentSession]) -> [AgentSession]
      static func sessionsCaption(_ count: Int) -> String
      static func groupTitle(_ state: AgentState) -> String
      static func groupColor(_ state: AgentState) -> Color
      static func rowOpacity(_ state: AgentState) -> Double
  }
  ```

**Height decision (the popover grows with its content):** `StatusBarController` sets `popover.contentSize = 340×460`, but that is only the pre-layout bootstrap — the popover is hosted by `NSHostingController`, which republishes the SwiftUI ideal size as `preferredContentSize`, and the popover follows it. The proof is in the current build: the content declares `.frame(width: 360)` and renders unclipped, 20 pt wider than the configured `contentSize`. So an unbounded agents list would push the popover off the screen. This section therefore measures its own list and takes `min(measured, 260)` pt, scrolling inside when it is taller; the header, segments, tiles and footer never move. 260 pt is about five rows, or four rows with their group headings — the layout the mockup shows — and keeps the worst realistic popover (four providers + a full list) near 700 pt.

- [ ] **Step 1: Write the failing tests**

```swift
// UsageTrackerTests/AgentsSectionTests.swift
import XCTest
import SwiftUI
@testable import Omelette

final class AgentsSectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func session(_ name: String, _ state: AgentState, minutesAgo: Double, source: AgentSource = .claude) -> AgentSession {
        Fixture.agentSession(
            id: "\(source.rawValue):\(name)",
            sessionID: name,
            source: source,
            projectName: name,
            state: state,
            stateSince: now.addingTimeInterval(-minutesAgo * 60),
            lastEventAt: now.addingTimeInterval(-minutesAgo * 60)
        )
    }

    // MARK: grouped (All tab)

    func testGroupsAreOrderedByStateAndEmptyOnesAreDropped() {
        let sessions = [
            session("Jaravis", .done, minutesAgo: 5),
            session("Usage tracker", .needsYou, minutesAgo: 1),
            session("Orion Gate", .working, minutesAgo: 14),
        ]
        let groups = AgentsSection.groups(sessions)
        XCTAssertEqual(groups.map(\.state), [.needsYou, .working, .done])
        XCTAssertEqual(groups.map(\.id), ["needsYou", "working", "done"])
    }

    func testGroupMembersAreMostRecentlyActiveFirst() {
        let sessions = [session("old", .working, minutesAgo: 30), session("new", .working, minutesAgo: 2)]
        XCTAssertEqual(AgentsSection.groups(sessions).first?.sessions.map(\.projectName), ["new", "old"])
    }

    func testGroupsOfNothingIsEmpty() {
        XCTAssertTrue(AgentsSection.groups([]).isEmpty)
    }

    // MARK: flat (provider tab)

    func testFlatPutsWaitingSessionsFirstThenMostRecent() {
        let sessions = [
            session("recent", .working, minutesAgo: 1),
            session("waiting", .needsYou, minutesAgo: 20),
            session("old", .done, minutesAgo: 40),
        ]
        XCTAssertEqual(AgentsSection.flat(sessions).map(\.projectName), ["waiting", "recent", "old"])
    }

    func testSeveralWaitingSessionsKeepRecencyOrder() {
        let sessions = [session("first", .needsYou, minutesAgo: 9), session("second", .needsYou, minutesAgo: 3)]
        XCTAssertEqual(AgentsSection.flat(sessions).map(\.projectName), ["second", "first"])
    }

    // MARK: copy and styling rules

    func testSessionsCaption() {
        XCTAssertEqual(AgentsSection.sessionsCaption(0), "0 sessions")
        XCTAssertEqual(AgentsSection.sessionsCaption(1), "1 session")
        XCTAssertEqual(AgentsSection.sessionsCaption(4), "4 sessions")
    }

    func testGroupTitles() {
        XCTAssertEqual(AgentsSection.groupTitle(.needsYou), "Needs you")
        XCTAssertEqual(AgentsSection.groupTitle(.working), "Working")
        XCTAssertEqual(AgentsSection.groupTitle(.done), "Done")
        XCTAssertEqual(AgentsSection.groupTitle(.idle), "Idle")
    }

    /// Only the two live states get a colour; a green "Done" heading shouts as
    /// loudly as the amber one that actually needs the user.
    func testGroupColours() {
        XCTAssertEqual(AgentsSection.groupColor(.needsYou), OMAgentColor.needsYou)
        XCTAssertEqual(AgentsSection.groupColor(.working), OMAgentColor.working)
        XCTAssertEqual(AgentsSection.groupColor(.done), Color.secondary)
        XCTAssertEqual(AgentsSection.groupColor(.idle), Color.secondary)
    }

    func testFinishedRowsDim() {
        XCTAssertEqual(AgentsSection.rowOpacity(.needsYou), 1, accuracy: 0.001)
        XCTAssertEqual(AgentsSection.rowOpacity(.working), 1, accuracy: 0.001)
        XCTAssertEqual(AgentsSection.rowOpacity(.done), 0.7, accuracy: 0.001)
        XCTAssertEqual(AgentsSection.rowOpacity(.idle), 0.7, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/AgentsSectionTests`
Expected: compile error `cannot find 'AgentsSection' in scope`.

- [ ] **Step 3: Implement `AgentsSection`**

```swift
// UsageTracker/UI/DesignSystem/AgentsSection.swift
import SwiftUI

/// One "Needs you" / "Working" / … block of the grouped list.
struct AgentGroup: Identifiable, Equatable {
    let state: AgentState
    let sessions: [AgentSession]
    var id: String { state.rawValue }
}

/// The popover's agent list. `grouped` (All tab) puts rows under status
/// headings and shows provider logos, because rows from every provider mix
/// there; flat (provider tab) is one list of state dots with whatever needs you
/// first. The list is the only part of the popover that scrolls — the header,
/// segments and footer must not move when an agent starts a long run.
struct AgentsSection: View {
    let sessions: [AgentSession]
    let grouped: Bool
    let hooksInstalled: Bool
    var title: String = "Agents"
    let onEnable: () -> Void

    /// About five rows, or four rows with their group headings — the mockup's
    /// layout. Past this the list scrolls instead of growing the popover.
    static let maxListHeight: CGFloat = 260

    /// Used only until the list has measured itself once, so the section never
    /// flashes at 1 pt on the first frame.
    private static let estimatedRowHeight: CGFloat = 49
    private static let estimatedGroupLabelHeight: CGFloat = 27

    @State private var listHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: OMSpacing.xs) {
            OMSectionHeader(title: title, trailing: sessions.isEmpty ? nil : Self.sessionsCaption(sessions.count))
            if sessions.isEmpty {
                emptyRow
            } else {
                list
            }
            if !hooksInstalled {
                Button("Enable precise status", action: onEnable)
                    .buttonStyle(.link)
                    .font(OMFont.caption)
                    .help("Install Omelette's hooks so states are exact instead of guessed from log files")
            }
        }
    }

    // MARK: - List

    private var list: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: OMSpacing.xs + 1) {
                if grouped {
                    ForEach(Self.groups(sessions)) { group in
                        Text(Self.groupTitle(group.state))
                            .font(OMFont.micro)
                            .textCase(.uppercase)
                            .tracking(0.5)
                            .foregroundStyle(Self.groupColor(group.state))
                            .padding(.top, OMSpacing.xs)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(group.sessions) { row($0) }
                    }
                } else {
                    ForEach(Self.flat(sessions)) { row($0) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                // Self-sizing scroll view: measure the content, then take exactly
                // that height up to the cap. `.task(id:)` rather than a preference
                // key so the write to @State stays on the main actor under Swift 6.
                GeometryReader { proxy in
                    Color.clear.task(id: proxy.size.height) { listHeight = proxy.size.height }
                }
            }
        }
        .frame(height: min(listHeight > 0 ? listHeight : estimatedHeight, Self.maxListHeight))
        .scrollIndicators(listHeight > Self.maxListHeight ? .automatic : .never)
        .scrollDisabled(listHeight <= Self.maxListHeight)
    }

    private func row(_ session: AgentSession) -> some View {
        OMAgentRow(session: session, showsProviderIcon: grouped) {
            SessionActivator.jump(to: session)
        }
        .opacity(Self.rowOpacity(session.state))
    }

    private var emptyRow: some View {
        Text("No agent sessions")
            .font(OMFont.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: OMRadius.row, style: .continuous).fill(OMSurface.row))
    }

    private var estimatedHeight: CGFloat {
        let labels = grouped ? Self.groups(sessions).count : 0
        return CGFloat(sessions.count) * Self.estimatedRowHeight + CGFloat(labels) * Self.estimatedGroupLabelHeight
    }
}

// MARK: - Grouping and ordering (pure, unit-tested)

extension AgentsSection {
    /// Non-empty groups in state order (needs you → working → done → idle); the
    /// most recently active session leads each group.
    static func groups(_ sessions: [AgentSession]) -> [AgentGroup] {
        AgentState.allCases
            .sorted { $0.rank < $1.rank }
            .compactMap { state in
                let members = sessions
                    .filter { $0.state == state }
                    .sorted { $0.lastEventAt > $1.lastEventAt }
                return members.isEmpty ? nil : AgentGroup(state: state, sessions: members)
            }
    }

    /// Flat list for a provider tab: anything waiting for you first, then most
    /// recent activity first.
    static func flat(_ sessions: [AgentSession]) -> [AgentSession] {
        sessions.sorted { a, b in
            let aWaits = a.state == .needsYou
            let bWaits = b.state == .needsYou
            if aWaits != bWaits { return aWaits }
            return a.lastEventAt > b.lastEventAt
        }
    }

    static func sessionsCaption(_ count: Int) -> String {
        count == 1 ? "1 session" : "\(count) sessions"
    }

    static func groupTitle(_ state: AgentState) -> String {
        switch state {
        case .needsYou: return "Needs you"
        case .working: return "Working"
        case .done: return "Done"
        case .idle: return "Idle"
        }
    }

    /// Only the live states are coloured — a green "Done" heading competes with
    /// the amber one that actually needs the user.
    static func groupColor(_ state: AgentState) -> Color {
        switch state {
        case .needsYou: return OMAgentColor.needsYou
        case .working: return OMAgentColor.working
        case .done, .idle: return .secondary
        }
    }

    /// Finished work stays readable but stops competing with live rows.
    static func rowOpacity(_ state: AgentState) -> Double {
        (state == .done || state == .idle) ? 0.7 : 1
    }
}

#if DEBUG
#Preview("Agents — grouped, light") {
    AgentsSection(sessions: AgentPreviewData.mixed, grouped: true, hooksInstalled: true, onEnable: {})
        .padding().frame(width: 328)
}

#Preview("Agents — grouped, dark") {
    AgentsSection(sessions: AgentPreviewData.mixed, grouped: true, hooksInstalled: true, onEnable: {})
        .padding().frame(width: 328).preferredColorScheme(.dark)
}

#Preview("Agents — flat provider tab") {
    AgentsSection(
        sessions: AgentPreviewData.mixed.filter { $0.source == .claude },
        grouped: false,
        hooksInstalled: true,
        title: "Claude agents",
        onEnable: {}
    )
    .padding().frame(width: 328)
}

#Preview("Agents — empty, hooks missing") {
    AgentsSection(sessions: [], grouped: true, hooksInstalled: false, onEnable: {})
        .padding().frame(width: 328)
}

#Preview("Agents — long list scrolls") {
    AgentsSection(
        sessions: AgentPreviewData.mixed + (1...6).map {
            AgentPreviewData.session("Project \($0)", .idle, minutes: Double($0) * 7)
        },
        grouped: true,
        hooksInstalled: true,
        onEnable: {}
    )
    .padding().frame(width: 328)
}
#endif
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/AgentsSectionTests`
Expected: PASS (9 tests).

- [ ] **Step 5: Review the previews in Xcode**

Expected: grouped previews show `AGENTS · 4 sessions`, an amber "NEEDS YOU" heading, a blue "WORKING" heading, a grey "DONE" heading with its row dimmed; the flat preview shows `CLAUDE AGENTS · 3 sessions` with dots instead of logos; the empty preview shows the quiet "No agent sessions" row plus the "Enable precise status" link; the long-list preview stops growing at 260 pt and scrolls.

- [ ] **Step 6: Commit**

```bash
git add UsageTracker/UI/DesignSystem/AgentsSection.swift UsageTrackerTests/AgentsSectionTests.swift
git commit -m "Design system: AgentsSection with grouped/flat lists and a bounded height

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

## Task 4: `SettingsRoute` — "Enable precise status" opens Settings on the Agents tab

**Files:**
- Create: `UsageTracker/Agents/SettingsRoute.swift`
- Create: `UsageTrackerTests/SettingsRouteTests.swift`
- Modify: `UsageTracker/UI/SettingsView.swift` (the `@State` block near the top, and `body`'s `.onAppear(perform: updateMaskedView)` at the end of the `TabView`)

**Interfaces:**
- Consumes: `SettingsView.Tab` (a `String`-raw-value enum whose cases are the tab titles; package 3 adds `case agents = "Agents"`).
- Produces:
  ```swift
  @MainActor final class SettingsRoute: ObservableObject {
      static let shared: SettingsRoute
      static let agentsTab = "Agents"
      @Published var pendingTab: String?
      func consumePendingTab() -> String?
  }
  ```

**Why this mechanism:** SwiftUI's `Settings` scene has no API for selecting a tab from outside, and `SettingsView` keeps its selection in private `@State`. The popover parks a one-shot intent here and calls `openSettings()`; the settings window applies it on appear (window not open yet) or on change (already open). Matching by raw value means this compiles and behaves correctly even if package 3's Agents tab has not landed yet — an unknown name is simply ignored and Settings opens on General.

- [ ] **Step 1: Write the failing test**

Append a new file `UsageTrackerTests/SettingsRouteTests.swift`:

```swift
// UsageTrackerTests/SettingsRouteTests.swift
import XCTest
@testable import Omelette

@MainActor
final class SettingsRouteTests: XCTestCase {
    func testConsumeReturnsTheRequestOnceAndThenNothing() {
        let route = SettingsRoute()
        XCTAssertNil(route.consumePendingTab())
        route.pendingTab = SettingsRoute.agentsTab
        XCTAssertEqual(route.consumePendingTab(), "Agents")
        XCTAssertNil(route.consumePendingTab())
        XCTAssertNil(route.pendingTab)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/SettingsRouteTests`
Expected: compile error `cannot find 'SettingsRoute' in scope`.

- [ ] **Step 3: Implement `SettingsRoute`**

```swift
// UsageTracker/Agents/SettingsRoute.swift
import Foundation

/// Which Settings tab the next `openSettings()` should land on.
///
/// SwiftUI's `Settings` scene exposes no tab selection, and `SettingsView` keeps
/// its selection in `@State`, so a caller parks the request here and the window
/// picks it up when it appears (or immediately, if it is already open). The
/// value is deliberately not persisted: it is a navigation intent, not a setting.
@MainActor
final class SettingsRoute: ObservableObject {
    static let shared = SettingsRoute()

    /// Matches `SettingsView.Tab.rawValue`. A name with no matching tab is
    /// ignored, so a request can outlive a tab being renamed or not existing yet.
    static let agentsTab = "Agents"

    @Published var pendingTab: String?

    /// Reads and clears in one step — a tab request must never fire twice.
    func consumePendingTab() -> String? {
        defer { pendingTab = nil }
        return pendingTab
    }
}
```

- [ ] **Step 4: Consume the route in `SettingsView`**

Re-read `UsageTracker/UI/SettingsView.swift` first (another session may have added the Agents tab meanwhile). Add the observed object next to the existing `@StateObject private var settings = SettingsStore.shared`:

```swift
    @ObservedObject private var route = SettingsRoute.shared
```

Replace the `TabView`'s trailing modifier `.onAppear(perform: updateMaskedView)` with:

```swift
        .onAppear {
            updateMaskedView()
            applyPendingTab()
        }
        // The window may already be open when the popover asks for a tab, in
        // which case onAppear has long since fired.
        .onChange(of: route.pendingTab) { _, _ in applyPendingTab() }
```

and add the method next to `updateMaskedView()`:

```swift
    /// The popover can ask for a specific tab ("Enable precise status" → Agents).
    /// An unknown name is ignored, which keeps the request harmless.
    private func applyPendingTab() {
        guard let name = route.consumePendingTab(), let tab = Tab(rawValue: name) else { return }
        selectedTab = tab
    }
```

- [ ] **Step 5: Run the test and build**

Run: `xcodegen generate && xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/SettingsRouteTests`
Expected: PASS (1 test), BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add UsageTracker/Agents/SettingsRoute.swift UsageTracker/UI/SettingsView.swift UsageTrackerTests/SettingsRouteTests.swift
git commit -m "Settings: one-shot tab route so the popover can open the Agents tab

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

## Task 5: Wire the popover — hook status, segment dots, both tabs

**Files:**
- Modify: `UsageTracker/UI/PopoverView.swift` (the `PopoverView` property block, `body`, `segments`, `allTab`, `content`, and `private struct ProviderDetail`)

**Interfaces:**
- Consumes: `AgentSessionStore.shared` (`sessions`, `sessions(for:)`), `AgentSource`, `AgentPaths.claudeSettingsURL` / `codexConfigURL` / `helperSymlinkURL`, `AgentHooksInstaller.claudeStatus(settingsURL:helperPath:)` / `codexStatus(configURL:helperPath:)`, `HookInstallStatus`, `AgentsSection`, `SettingsRoute`, plus phase 1's `displayedServices`, `showsSegments`, `currentTab`, `selectedService`, `allTab`, `ProviderDetail`, `OMSegmentItem`, `WindowRanking.allTab`.
- Produces (private to the file):
  ```swift
  @State private var claudeHooksInstalled: Bool
  @State private var codexHooksInstalled: Bool
  private func refreshHookStatus() async
  private func hasWaitingSession(_ serviceID: String) -> Bool
  private func openAgentsSettings()
  // ProviderDetail gains: let hooksInstalled: Bool; let onEnableAgents: () -> Void; private var agentSource: AgentSource?
  ```

- [ ] **Step 1: Add the store, the hook flags and the settings jump to `PopoverView`**

Re-read the file first. Under the existing `@ObservedObject private var dashboard = DashboardState.shared`, add:

```swift
    @ObservedObject private var agents = AgentSessionStore.shared

    /// Whether each source's hooks are installed decides one line of copy, so it
    /// is read once per popover appearance off the main thread instead of on
    /// every layout pass.
    @State private var claudeHooksInstalled = false
    @State private var codexHooksInstalled = false
```

Add `.task { await refreshHookStatus() }` to `body` right after `.frame(width: 360)`, and add these three methods to `PopoverView`:

```swift
    private func refreshHookStatus() async {
        let helperPath = AgentPaths.helperSymlinkURL.path
        let claudeSettings = AgentPaths.claudeSettingsURL
        let codexConfig = AgentPaths.codexConfigURL
        let statuses = await Task.detached(priority: .utility) { () -> (Bool, Bool) in
            (
                AgentHooksInstaller.claudeStatus(settingsURL: claudeSettings, helperPath: helperPath) == .installed,
                AgentHooksInstaller.codexStatus(configURL: codexConfig, helperPath: helperPath) == .installed
            )
        }.value
        claudeHooksInstalled = statuses.0
        codexHooksInstalled = statuses.1
    }

    /// Amber dot on a provider segment while one of its sessions waits for you.
    /// Providers without an agent integration (Antigravity, Grok) never light up.
    private func hasWaitingSession(_ serviceID: String) -> Bool {
        guard let source = AgentSource(rawValue: serviceID) else { return false }
        return agents.sessions(for: source).contains { $0.state == .needsYou }
    }

    private func openAgentsSettings() {
        SettingsRoute.shared.pendingTab = SettingsRoute.agentsTab
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }
```

- [ ] **Step 2: Put the dot on the provider segments**

In `segments`, replace the `displayedServices.map { … }` item builder so each provider item carries the dot (the **All** item deliberately keeps none — its own list already shows what waits):

```swift
    private var segments: some View {
        OMSegmentedControl(
            items: [OMSegmentItem(id: WindowRanking.allTab, title: "All")]
                + displayedServices.map { service in
                    OMSegmentItem(
                        id: service.id,
                        title: service.displayName,
                        serviceID: service.id,
                        sfFallback: service.icon,
                        showsDot: hasWaitingSession(service.id)
                    )
                },
            selection: Binding(
                get: { currentTab },
                set: { selectedProviderTab = $0 }
            )
        )
    }
```

- [ ] **Step 3: Add the grouped section to the All tab**

In `allTab`, after the `OMCostTile` block, inside the same `VStack`:

```swift
            AgentsSection(
                sessions: agents.sessions,
                grouped: true,
                // On All the link should appear while either source is still
                // guessing, so both have to be wired for it to disappear.
                hooksInstalled: claudeHooksInstalled && codexHooksInstalled,
                onEnable: openAgentsSettings
            )
```

- [ ] **Step 4: Pass the hook state into `ProviderDetail` and add its flat section**

In `content`, change the provider branch to:

```swift
        } else if let service = selectedService {
            ProviderDetail(
                service: service,
                burn: dashboard.burn(for: service.id),
                hooksInstalled: AgentSource(rawValue: service.id) == .codex ? codexHooksInstalled : claudeHooksInstalled,
                onEnableAgents: openAgentsSettings
            )
```

In `private struct ProviderDetail`, add the two stored properties after `let burn: BurnRatePrediction?`:

```swift
    let hooksInstalled: Bool
    let onEnableAgents: () -> Void

    @ObservedObject private var agents = AgentSessionStore.shared

    /// Only the two sources phase 2 tracks get agent rows; the other providers
    /// show no section at all rather than an empty one.
    private var agentSource: AgentSource? { AgentSource(rawValue: service.id) }
```

and append to the end of `ProviderDetail.body`'s `VStack`, after the "Last 7 days" row and the "no usage data" text:

```swift
            if let source = agentSource {
                AgentsSection(
                    sessions: agents.sessions(for: source),
                    grouped: false,
                    hooksInstalled: hooksInstalled,
                    title: "\(service.displayName) agents",
                    onEnable: onEnableAgents
                )
            }
```

- [ ] **Step 5: Build and run the whole suite**

Run: `xcodegen generate && xcodebuild -project UsageTracker.xcodeproj -scheme UsageTracker -configuration Debug -derivedDataPath build/DerivedData build && xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData`
Expected: BUILD SUCCEEDED and every test class green (including the untouched `WindowRankingTests`, `BurnVerdictTests`, `DashboardSelectionTests`, `UsageNotifierRulesTests`).

- [ ] **Step 6: Commit**

```bash
git add UsageTracker/UI/PopoverView.swift
git commit -m "Popover: Agents section on All and provider tabs, amber dot on waiting providers

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

## Task 6: Manual verification (recorded in the commit body, no code change)

**Files:** none. Use the Debug build: `open build/DerivedData/Build/Products/Debug/Omelette.app`. Start a real Claude Code session in Terminal.app and one in iTerm2 with the hooks installed (Settings → Agents), plus one Codex turn.

- [ ] **Popover growth and the cap.** With 1 session the All tab is short; with 10 sessions the Agents list stops growing and scrolls while the header, segments, tiles and footer stay put. Nothing is clipped at the bottom of the popover.
- [ ] **All tab.** Groups appear in the order Needs you → Working → Done → Idle, empty groups are absent, Done/Idle rows are dimmed, each row shows the provider logo with a state badge, the project name, the activity, and a time that ticks (watch a "working" row cross a minute boundary).
- [ ] **Provider tab.** Claude shows `CLAUDE AGENTS · N sessions` with state dots instead of logos, waiting session first; the working dot pulses; the amber dot has a halo. Codex shows only Codex sessions. Antigravity and Grok show no Agents section at all.
- [ ] **Segment dot.** While a Claude session waits for approval the Claude segment carries an amber dot; it disappears within one poll of approving.
- [ ] **Jump — Terminal.app.** Click a row whose session runs in Terminal: Terminal comes forward *and* the right tab is selected. The first click shows the macOS "Omelette wants to control Terminal" prompt; approving it makes subsequent clicks silent. Denying it leaves Terminal frontmost with no alert from Omelette.
- [ ] **Jump — iTerm2.** Same, including a session in a split pane (iTerm2 selects the session).
- [ ] **Jump — other hosts.** A session started from Ghostty/VS Code only activates the app (no error). A passive-scan session with no host pid reveals its folder in Finder.
- [ ] **Enable precise status.** With hooks not installed the link shows under the empty row; clicking it opens Settings on the **Agents** tab (and, if Settings was already open on another tab, switches to Agents).
- [ ] **Approximate sessions.** A passive-scan session reads "≈ …" and never appears under "Needs you".
- [ ] **Reduce Motion** (System Settings → Accessibility → Display): the working dot stops pulsing; the amber halo remains.
- [ ] **Light and dark** appearance, and Reduce Transparency on: row fills and group headings stay legible.
- [ ] **VoiceOver** reads a row as "Usage tracker, Claude Code, Needs approval, Bash: xcodegen generate, for 1 minute" and announces it as a button; the group headings are announced as headers.

Record the result in the final commit message (`Popover agents: manual checklist passed — …`), no code change.

---

## Self-review notes

- **Spec coverage.** "Popover — Agents section" All tab: Task 3 (`grouped: true`, groups, empty row, link) + Task 5. Provider tab flat list ordered needsYou → lastEventAt: Task 3 (`flat`) + Task 5. Row content (provider icon, project, activity or state, elapsed): Task 2. Row click = jump to session with the Terminal/iTerm2 tty tab select, `NSAppleEventsUsageDescription`, and Finder fallback: Task 1. Segmented control amber dot from `sessions(for:)`: Task 5. Security-and-privacy line "hook payload content is displayed truncated": `lineLimit(1)` + `truncationMode` in Task 2, plus AppleScript escaping tests in Task 1. Out of scope by design: the agents pill and notifications (package 5), the tile's "2 agents · 1 needs you" line in the mockup (phase-1 `OMProviderTile`), the Settings → Agents tab itself (package 3), CHANGELOG and version bump (phase-2 release step).
- **Interface additions beyond the contract**, all listed under their task's *Produces*: `AgentRowText` (5 statics), `AgentGroup`, `AgentsSection.groups/flat/sessionsCaption/groupTitle/groupColor/rowOpacity/maxListHeight`, the defaulted `AgentsSection.title` (the contract's 4-argument call site still compiles), `SessionActivator.script(for:tty:)` + the two bundle-id constants + `@MainActor` on `jump`, `SettingsRoute`, `AgentPreviewData` (DEBUG only), `Fixture.agentSession` (tests only). No contract name is renamed.
- **Type consistency.** `OMSectionHeader(title:trailing:)` is the phase-1 memberwise label — not the shorthand `OMSectionHeader("Agents", …)` used in prose. `TimelineView(.periodic(from:by:))` needs the `from:` argument. `OMSegmentItem` field order is `id, title, serviceID, sfFallback, showsDot`. `ProviderIconView(serviceID:sfFallback:size:)` takes a `String` fallback symbol. `AgentSource.rawValue` is `"claude"` / `"codex"`, which is exactly the service id used by the popover tabs, so `AgentSource(rawValue: service.id)` is the whole provider mapping.
- **Swift 6 pitfalls avoided.** Measurement uses `.task(id:)` rather than `onPreferenceChange` (whose action is `@Sendable`); the detached hook-status task returns `(Bool, Bool)` rather than the non-`Sendable` `HookInstallStatus`; `NSAppleScript` and `NSRunningApplication` are only touched from `@MainActor` code.
- **Known warning.** `NSApplicationActivationOptions.activateIgnoringOtherApps` is deprecated on macOS 14; the plan keeps it (the spec asks for it and it is still the behaviour we want for a background terminal) and documents `[.activateAllWindows]` as the drop-in replacement if the warning is ever cleaned up.
