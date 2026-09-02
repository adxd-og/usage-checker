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

## Package 2 — session store + passive scan (`…-p2-session-store.md`) — PENDING full read

Provisional notes from the planner's report (to be confirmed against the text):

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

## Package 4 — popover agents + jump (`…-p4-popover-agents.md`) — PENDING full read

Decisions on the planner's open questions:

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

## Package 3 — installer + Settings → Agents (`…-p3-installer-settings.md`) — PENDING full read

Provisional notes from the planner's report:

1. Template accepted: eight events, `Notification` as two literal-matcher groups
   (`permission_prompt`, `idle_prompt`), `PermissionRequest` sync with `timeout: 5`,
   everything else `async: true` without timeout.
2. **Cross-package line for package 1:** after `AgentEventServer.start()` the app
   must set `AgentDiagnostics.server = server` (package 3 owns
   `AgentDiagnostics`). Package 1's executor gets this as an explicit step.
3. `SettingsView.Tab.agents` must be `case agents = "Agents"` (package 4's
   `SettingsRoute` depends on the raw value).
4. Install pretty-prints `settings.json` (sorted keys) — accepted given the
   one-time backup; `removeClaude` must not rewrite when nothing of ours is present.
5. Unparsable settings.json → status `.conflict(reason)` — accepted.
6. Tasks 1–3 are independent of packages 1–2 and may be executed first.
