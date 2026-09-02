# Phase 2 · Package 6 — hooks prompt on first launch, session-first hero

Owner decisions (2026-09-02): (1) hooks stay opt-in, but existing users get a
**soft prompt** — a one-time row in the popover and a one-time notification, both
with an Enable action that installs the Claude Code hooks directly; nothing is
written without a click. (2) On a provider tab the big ring is the **session
window**, and the "Weekly limits" ring row always includes "All models" — the
owner saw only "Fable only" because the weekly All-models window had won the hero
contest and left the row.

Global constraints: those of `2026-09-02-agent-overview-p3-installer-settings.md`
(test command with `ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS=""`, trailers,
xcodegen, warning-free Swift 6, no `nonisolated(unsafe)`).

## Task A — session-first hero on the provider tab

**Files:** `UsageTracker/Core/WindowRanking.swift`, `UsageTrackerTests/WindowRankingTests.swift`,
`UsageTracker/UI/PopoverView.swift` (`ProviderDetail`).

**Produces:**
```swift
extension WindowRanking {
    /// Provider-tab hero: the session window when the service has one (it answers
    /// "can I keep working right now" and the mockup shows it big), otherwise the
    /// most-constrained window (`heroBucket`). Tiles on the All tab keep `heroBucket`.
    static func detailHero(for service: ServiceSnapshot) -> UsageBucket?
}
```
Rule: first bucket with `kind == .session && !isPromotional` in API order; else `heroBucket(for:)`.

`ProviderDetail`: `hero` → `WindowRanking.detailHero(for: service)`. `weeklyForRow`
keeps its `$0.id != hero?.id` filter (a no-op when the hero is the session; still
prevents duplication when a weekly is the hero because there is no session).
`sessionRows` stays (`WindowRanking.sessionRows(for:hero:)`) — it now lists only
*additional* session windows, usually none. Burn verdict keeps using `sessionBuckets`.

**Tests (WindowRankingTests):**
- `testDetailHeroPrefersTheSessionEvenWhenTheWeeklyIsHotter`: session 37 %, weekly 52 % → `detailHero.id == "five_hour"`, and the weekly is still in `service.buckets` for the ring row.
- `testDetailHeroFallsBackToTheWorstWindowWithoutASession`: weekly + model-scoped only → `detailHero.id == "seven_day"`.
- `testDetailHeroIgnoresAPromotionalSession`: a promo `.session` bucket + a real session → the real one.

Also update `#Preview("Provider detail")` expectations if they mention the hero.

## Task B — one-time hooks prompt

**Files:** `UsageTracker/Core/Settings.swift` + `UsageTrackerTests/SettingsStoreTests.swift`
(new key), `UsageTracker/Agents/AgentHooksPrompt.swift` (new, pure rule) +
`UsageTrackerTests/AgentHooksPromptTests.swift`, `UsageTracker/UI/DesignSystem/OMHooksPromptRow.swift`
(new view), `UsageTracker/UI/PopoverView.swift`, `UsageTracker/Services/UsageNotifier.swift`,
`UsageTracker/UsageTrackerApp.swift`.

**Settings key** (same `Defaults` / `@AppStorage` / `resetToDefaults()` / scramble-test pattern):
```swift
@AppStorage("agentsHooksPromptDismissed") var agentsHooksPromptDismissed: Bool = false
@AppStorage("agentsHooksPromptNotified") var agentsHooksPromptNotified: Bool = false
```

**Pure rule:**
```swift
enum AgentHooksPrompt {
    /// Show the prompt only when there is something to gain and the user has not
    /// answered: Claude Code has been used on this machine (its projects dir or
    /// settings file exists), our hooks are not installed, and the prompt was not
    /// dismissed. `.outdated`, `.installed` and `.conflict` never prompt.
    static func shouldShow(claudePresent: Bool, status: HookInstallStatus, dismissed: Bool) -> Bool
    static func claudeIsPresent(projectsURL: URL = AgentPaths.claudeProjectsURL,
                                settingsURL: URL = AgentPaths.claudeSettingsURL) -> Bool
}
```
Tests: the 2×4×2 table for `shouldShow` (only `notInstalled` + present + not dismissed → true);
`claudeIsPresent` against a temp dir with/without the two paths.

**View** `OMHooksPromptRow(onEnable: () -> Void, onDismiss: () -> Void)`: an `OMSurface.row`
/ `OMRadius.row` row with a `bolt.horizontal.circle` symbol, title "See what your agents are
doing" (`OMFont.bodyStrong`), one caption line "Adds hooks to ~/.claude/settings.json so
sessions show live status and you get a ping when one needs you. Reversible in Settings →
Agents." (`OMFont.caption`, secondary), and two buttons: **Enable** (`glassProminentButtonStyle()`)
and **Not now** (`.buttonStyle(.plain)`, secondary). Light/dark previews.

**PopoverView:** state `@State private var hooksPromptVisible = false`, recomputed in
`refreshHookStatus()` from `AgentHooksPrompt.shouldShow(claudePresent:status:dismissed:)`
using the real Claude status (compute the status once in the detached task and derive both
`claudeHooksInstalled` and the prompt from it). Render the row on the **All tab** directly
above `AgentsSection`, and on the **Claude provider tab** above its `AgentsSection` (pass
`showsHooksPrompt` + the two closures into `ProviderDetail`). `onEnable`: call
`AgentHooksInstaller.installClaude(settingsURL: AgentPaths.claudeSettingsURL,
helperPath: AgentPaths.helperSymlinkURL.path)` on the main actor; on success re-run
`refreshHookStatus()` (row disappears, precise status starts on the next hook event); on
error set `agentsHooksPromptDismissed = false` (keep showing), and open Settings → Agents via
`SettingsRoute` so the user sees the error there. `onDismiss`: `settings.agentsHooksPromptDismissed = true`.
When the prompt row is visible, hide `AgentsSection`'s own "Enable precise status" link
(pass `hooksInstalled: true` for that render, or add a `showsEnableLink` flag — pick the
smaller change and say which).

**Notification (once):** in `UsageNotifier`, category `AGENT_HOOKS_PROMPT` with a
`.foreground` action `AGENT_HOOKS_ENABLE` titled "Enable" (register alongside the existing
`AGENT_NEEDS_YOU` category in `startAgentNotifications`). New method
`func promptForHooksIfNeeded()` called from `applicationDidFinishLaunching` right after
`startAgentNotifications()`: if `AgentHooksPrompt.shouldShow(...)` with the live status and
`!settings.agentsHooksPromptNotified`, fire title "See what your agents are doing", body
"Omelette can show which Claude Code session is working or waiting for you. Enable adds hooks to
~/.claude/settings.json; reversible in Settings → Agents.", identifier `agent-hooks-prompt`,
category `AGENT_HOOKS_PROMPT`, not time-sensitive, then set `agentsHooksPromptNotified = true`
(one notification per install, ever). Quiet hours apply (use the existing quiet-hours check).
In `handleAgentResponse` (or a sibling), action `AGENT_HOOKS_ENABLE` on identifier
`agent-hooks-prompt` → install exactly as the popover's `onEnable`; a body click
(`UNNotificationDefaultActionIdentifier`) → `.showPopover`. Pure rule test:
`AgentNotificationRules` gains nothing; put the identifier/category constants on
`UsageNotifier` and test `AgentHooksPrompt` only.

**Manual checklist (report verified / not verifiable headless):** fresh defaults + Claude
present + hooks absent → row on All and on the Claude tab, one notification at launch;
Enable → hooks installed (verify against a scratch copy, never leave the owner's
`settings.json` modified: restore byte-identically and remove the `.omelette-backup`);
Not now → row gone, stays gone after relaunch; Settings → Advanced → Reset settings brings
the row back; installed hooks → no row, no notification.
