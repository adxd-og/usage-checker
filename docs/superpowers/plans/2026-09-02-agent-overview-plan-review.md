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
