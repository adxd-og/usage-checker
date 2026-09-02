# Phase 2 — plan review notes (orchestrator)

Verdicts on the package plans before executors are dispatched. Executors read
the note for their package first; it overrides the plan where they disagree.

## Package 5 — pill + notifications (`…-p5-pill-notifications.md`) — APPROVED

Contract fidelity verified: every consumed name matches the interfaces doc; the
additions are all listed. Reviewer notes for the executor:

1. **Run order:** P5 executes only after packages 1–4 and phase 1 are merged
   (the plan's precondition grep is mandatory, not advisory).
2. **Actor isolation:** before using `MainActor.assumeIsolated` inside the
   `onNeedsYou` / `onDone` closures, check `UsageNotifier`'s own isolation. If the
   class is already `@MainActor`, drop `assumeIsolated` and call directly; if it is
   not isolated, keep the plan's version. Do not add `@unchecked Sendable`.
3. **`willPresent` change** (banners shown while the app is frontmost) is
   accepted — Omelette is an accessory app, this only matters right after the
   Open action foregrounds it.
4. **`fire` widening:** keep the existing critical-alert path byte-identical
   (`interruptionLevel` only when `critical || timeSensitive`, as written).
5. CHANGELOG/version bump is intentionally absent here; the phase-2 release
   commit carries it.

## Global note for every executor (found in phase 1, P1)

`xcodebuild test` must carry `ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS=""`
on this machine: `signing.xcconfig` enables the hardened runtime, which blocks the
`DYLD_INSERT_LIBRARIES` injection XCTest uses, and the runner hangs for ~6 min
("The test runner hung before establishing connection"). `CODE_SIGN_IDENTITY=-`
does not help. Plain `xcodebuild build` keeps the real settings. Treat this as
part of every package plan's Global Constraints.

## Package 2 — session store + passive scan (`…-p2-session-store.md`) — APPROVED (amended)

Full read done. Amendments applied to the plan text: Task 6 no longer constructs/starts a server — it assigns `AgentChannel.shared.onEvent = { AgentSessionStore.shared.apply($0) }` in `AppState.bootstrap()`; Global Constraints carry the test override. Notes:

1. **Server ownership must be settled with package 1:** P2's Task 6 wires
   `startAgentChannel()` into `AppState.bootstrap()`. Package 1 also wires the
   server start. Rule: package 1 owns creating/starting `AgentEventServer` and
   exposes the event callback; package 2 only replaces the log-only consumer
   with `AgentSessionStore.shared.apply(_:)`. P2's grep-and-decide guard stays.
2. Passive Claude scan must accept only `<root>/<project-slug>/<uuid>.jsonl`
   (subagent transcripts live under `<uuid>/subagents/**`; 2,137 vs 165 real
   transcripts on the owner's machine) — planner already handles this; keep it.
3. Approximate (passive-only) sessions are NOT written to history on prune —
   accepted.
4. Codex `thread-id` == rollout uuid is an assumption; verify during package 3's
   manual Codex test and add a mapping in `mergePassive` if it fails.
5. `ProjectName.display(path:)` addition accepted.

## Package 4 — popover agents + jump (`…-p4-popover-agents.md`) — APPROVED (amended)

Full read done. Amendments applied to the plan text: `AgentRowText.subtitle(for:showsState:)` with the provider-tab prefix rule (+1 test); `activate(from: .current, options: [.activateAllWindows])`; the session fixture moves to `UsageTrackerTests/AgentSessionFixtures.swift` (package 1 owns `AgentFixtures.swift`); test override in Global Constraints. Decisions:

1. **Row subtitle:** All tab (grouped — the heading already says the state):
   `activity ?? statePhrase`. Provider tab (flat): `"\(statePhrase) · \(activity)"`
   when activity exists, else `statePhrase` — this is the mockup's
   "Needs approval · Bash: xcodegen generate". Implement as a `showsState` flag
   on `AgentRowText.subtitle`.
2. **Activation API:** do not use the deprecated `.activateIgnoringOtherApps`.
   Use `NSRunningApplication.activate(from: .current, options: [.activateAllWindows])`
   (macOS 14+, hands our activation to the terminal — Omelette is active because the
   user just clicked the row). Keep the AppleScript tab selection as planned.
3. **Settings tab name:** package 3 must declare `case agents = "Agents"` in the
   Settings tab enum so `SettingsRoute` lands on it (see package 3 note).
4. Popover height bound = self-measuring scroll capped at 260 pt inside
   `AgentsSection`; `NSPopover.contentSize` untouched — accepted.
5. Apple Events entitlement + `NSAppleEventsUsageDescription` in `project.yml`
   `info.properties` — accepted; the build-step verification stays.

## Package 3 — installer + Settings → Agents (`…-p3-installer-settings.md`) — APPROVED (amended)

Full read done. Amendments applied to the plan text: `AgentDiagnostics` is no longer declared here (package 1 creates it, `@MainActor`); the diagnostics block also shows `AgentChannel.shared.startError`; test override in Global Constraints. Notes:

1. Template accepted: eight events, `Notification` as two literal-matcher groups
   (`permission_prompt`, `idle_prompt`), `PermissionRequest` sync with `timeout: 5`,
   everything else `async: true` without timeout.
2. **`AgentDiagnostics` is owned by package 1** (Task 7 creates the `@MainActor`
   enum and `AgentChannel` sets `AgentDiagnostics.server` after `start()`);
   package 3 only reads it. (Earlier wording here said the opposite — superseded.)
3. `SettingsView.Tab.agents` must be `case agents = "Agents"` (package 4's
   `SettingsRoute` depends on the raw value).
4. Install pretty-prints `settings.json` (sorted keys) — accepted given the
   one-time backup; `removeClaude` must not rewrite when nothing of ours is present.
5. Unparsable settings.json → status `.conflict(reason)` — accepted.
6. Tasks 1–3 are independent of packages 1–2 and may be executed first.

## Package 1 — helper + transport (`…-p1-helper-transport.md`) — APPROVED

The first planner run was cut off by a rate limit after Tasks 1–6; the
orchestrator read Tasks 5–6 in full (server, helper, embedding) and added Task 7
(`AgentChannel` + `AgentDiagnostics` + AppDelegate wiring) and the self-review.
Decisions confirmed: POSIX sockets on both sides; `copy: {destination: wrapper,
subpath: Contents/Helpers}` embedding with `SKIP_INSTALL: YES` on the tool;
`sysctl` parent walk; oversized `tool_input` shrunk in the helper. Executor notes:

1. Runs in a git worktree on branch `agents/p1-helper-transport`; copy
   `signing.xcconfig` first; worktree-local DerivedData.
2. Every `xcodebuild test` carries `ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS=""`.
3. If the embed spelling in Task 6 Step 3 does not produce `Contents/Helpers/omelette-hook`
   with xcodegen's installed version, inspect the generated pbxproj (`dstSubfolderSpec`,
   `dstPath`) and adjust `copy:` — do not fall back to a Run Script phase.

## Phase 2 code review (2026-09-02, after all five packages merged) — fixed

Critical: Claude hook `command` is a shell string and the helper path contains
a space → now shell-quoted (`AgentHooksInstaller.shellQuoted`, tested through
`/bin/sh`). Important, fixed: `OMELETTE_AGENT_SOCKET` override honoured only under
the temp dir / App Support dir; `SessionEnd` tombstones stop the passive scan from
resurrecting an ended session for 30 min; the All-tab "Enable precise status" link
counts a missing CLI config or a conflict as satisfied; `AgentHistoryStore.append`
no longer overwrites the log when the file merely fails to open; helper watchdog
uses `_exit`; Claude passive scan accepts only `<uuid>.jsonl`. Phase-4 server /
helper prerequisites recorded in the roadmap. Left for later: `stop()` inode guard,
Codex date-partition pruning, `mergePassive` no-op guard, status refresh while the
Agents tab is open.

## Phase 3 code review (2026-09-02, after packages 1–3 merged)

No critical findings. Fixed in a follow-up: `AgentChannelTests` rotating the real
log (temp `historyURL`), `rotate`/`append` race (flock on a sidecar lock file),
duplicate `ForEach` ids in the history list, the Overview burn-rate line missing
when there is no verdict, the 260 pt `AgentsSection` cap inside the dashboard,
reload keyed on `lastEventAt`, once-per-launch rotation guard, VoiceOver on the
summary tiles, remaining `.caption`/`.callout`/`.title2` stragglers.
Left for later (minor): day titles go stale at midnight in an open dashboard; the
cost bar gradient in `SessionHistoryView`; `OMSegmentedControl` a11y label says
"Provider" on the Agents tab; `DashboardAgentRecordsTests` use the shared
singleton; `OnboardingView.init(page:onFinish:)` is preview-only API in
production; Settings keychain status auto-clear can wipe a newer message; the
widget ring's 110 pt assumes WidgetKit's 16 pt content margins; a few test gaps
(`inRange` at the exact cutoff, `days([])`, `content(maxRows: 0)`).

## Phase 4 · Package 2 — UI + settings + hook (`…-phase4-p2-ui-settings-hook.md`) — APPROVED (amended)

Checked against the phase-4 spec and the code: `fire(title:body:critical:identifier:category:timeSensitive:)`,
`truncate(_:limit:)`, `sessionID(fromIdentifier:)`, and `claudeStatus` comparing whole entries
(so `timeout` 5 → 150 reads `.outdated`) all exist as the plan assumes. The row restructure
(jump `Button` around the first line only, buttons on a sibling line) is the right fix for
buttons-inside-a-button; background (non-`.foreground`) actions are right for an
`LSUIElement` app; `.authenticationRequired` on Allow is cheap insurance for the locked-screen
hold. Amended: (1) **ordering** — the store fires `onNeedsYou` synchronously inside `apply`,
so the needs-you veto only works if the broker registers first; the spec now fixes
register-before-apply in `AppState` (package 1) and the plan's `agentPermissionPending`
withdraws a stray needs-you banner (pending + delivered) as belt and braces; (2) **expiry
leaves nothing on screen** — `onResolved` now carries a `PermissionResolution`, and on
`.expired` the notifier re-fires the plain needs-you banner through `agentNeedsYou` so an
absent user still finds an **Open** banner; (3) the `agentsAnswerPermissions` key moves to
package 1 (the broker reads it) — Task 3 keeps the tests and adds the key only if missing;
(4) settings caption reworded ("Allow / Deny appear … only while the terminal … isn't in
front"; Omelette itself never answers). Risk to watch in review: the nine `OMAgentRow`
call sites must pass `action:` by label.
