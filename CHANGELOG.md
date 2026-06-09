# Changelog

All notable changes to Usage Checker will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- **Popover answers "am I OK?" at a glance.** The header is now a hero status:
  a ring gauge of the most-constrained window, a plain-words verdict ("On track",
  "Running hot", "Almost at the limit"), which window binds, and when it resets.
- **Burn-rate moved next to the session bar** and now gives a verdict instead of
  a raw number: "At this pace, limit in ~1h 20m" when you'll hit the wall before
  the reset, or "you won't hit the limit before reset" when you're safe.
- **Pace tick on every usage bar** (popover, dashboard, floating window): a small
  marker shows how much of the window has elapsed, so 60% used reads as fine late
  in the window and as trouble early in it.
- Untouched weekly windows are folded behind a "N unused windows" disclosure in
  the popover instead of stacking zero-percent bars.
- Floating mini window's second row now shows the most-constrained weekly window
  (e.g. "Opus only") instead of always "7-day".
- When a refresh fails, the popover shows "Can't refresh — showing data from
  HH:MM" (hover for the error) instead of silently dimming.
- Keyboard shortcuts in the popover: ⌘D dashboard, ⌘R refresh, ⌘, settings,
  ⌘Q quit; exact reset times on hover over "resets in …".
- VoiceOver labels for the menu bar pill, usage bars, ring gauges and floating
  window rows.

## [1.1.0] — 2026-06-10

### Added
- **Claude Fable 5 support.** The new model is recognized everywhere: correct
  "Fable 5" labels in the CLI breakdown (was showing the raw `claude-fable-5` id)
  and accurate cost accounting at its real rates ($10/$50 per MTok, including the
  `[1m]` long-context variant at standard pricing). Mythos 5 is covered too.
- **Future-proof limit windows.** Rate-limit windows are now decoded dynamically
  from the usage API instead of a fixed list — when Anthropic ships a new weekly
  window (e.g. a "Fable only" cap), it appears in the popover, history, burn-rate
  analytics and the large desktop widget without an app update.
- Future-proof model names: any new `claude-<family>-<version>` id labels itself
  correctly (e.g. a hypothetical `claude-zephyr-6-1` → "Zephyr 6.1").
- Time-bound banner: "Fable 5 included until Jun 22 — then uses extra credits"
  (auto-hides after June 22, 2026).

### Fixed
- **Opus CLI costs were 3× too high.** Opus 4.6–4.8 are billed at $5/$25 per MTok,
  but the app still used the old Opus 4/4.1 rates ($15/$75). The deprecated Opus
  4 / 4.1 keep their historical $15/$75 rates for old log entries.
- Dated model ids (e.g. `claude-haiku-4-5-20251001`) now match their exact pricing
  table entry instead of relying on the family fallback.

## [1.0.3] — 2026-05-30

### Fixed
- Weekly-limit windows with very low usage (≤ 1%) no longer jump to 100%. The usage
  API now reports percentages as 0–100 (a value of `1.0` means 1%); the app was still
  multiplying values ≤ 1.0 by 100, which pinned low-usage windows like "Sonnet only"
  at 100%. Percentages are now used as-is.

## [1.0.2] — 2026-05-29

### Fixed
- New Claude models now label themselves correctly — the display name is derived
  from the model ID (e.g. `claude-opus-4-8` → "Opus 4.8") instead of a hardcoded
  list, so a freshly-released model no longer shows up as a generic "Opus".
- Extra-usage credits bar was rendering at ~1% of its true fill (a 0–1 fraction
  wasn't scaled to a percentage); it now matches the "$X / $Y" figure beside it.
- CLI cost & token totals are now accurate: Claude Code logs each API response
  several times, so usage is de-duplicated by message id and summed over distinct
  responses (the old 10-second "max" grouping mixed and under-counted them).
- Usage percentages no longer blank out on a transient network/API error — the
  last known values stay visible (dimmed as stale) until the next good poll.
- Rate-limit (HTTP 429) handling now honours `Retry-After` and stops retrying
  within a poll cycle, so the app no longer contributes to its own rate limiting.
- "5h window observed peak" can no longer display a value above 100%.
- Activity heatmap no longer risks a crash on duplicate day entries.
- Project names containing spaces are recovered correctly (e.g. "Orion Gate
  mobile app" instead of "mobile / app").
- Fixed a brief "Updated -1s ago" flicker in the popover header.

## [1.0.1] — 2026-05-25

### Fixed
- App crash on launch caused by Swift 6 strict concurrency assertion in the
  `DispatchSourceTimer` background callback. The refresh loop now runs in a
  proper `Task.sleep` loop, fully isolated to the main actor.
- Sparkle automatic update checks disabled at launch (they were dialling an
  unconfigured appcast URL). The Settings → Updates → "Check for updates"
  button is still present; auto-checks will be re-enabled in 1.1 alongside the
  appcast and EdDSA key setup.

## [1.0.0] — 2026-05-25

### Added
- Menu bar widget showing Claude AI subscription usage
- Real-time percentages for current 5-hour session and weekly limits
- Per-model weekly limits: Opus, Sonnet, Claude Design, Cowork, OAuth apps
- Extra usage credits indicator (for plans that support it)
- Native macOS notifications at configurable thresholds (default 80% / 95%) with critical sound and time-sensitive interruption
- Quiet hours toggle (default 23:00–09:00)
- Daily summary notification (default 09:00 local) — "Yesterday: $X across N turns"
- Auto-refresh every 60 seconds (configurable: 30s / 1m / 5m)
- Liquid Glass styling on macOS 26+, graceful fallback to ultra-thin material on macOS 14+
- Dashboard window with sidebar:
  - **Overview** — burn rate prediction, today's CLI usage, usage windows
  - **Activity** — GitHub-style 52-week heatmap with 30d / 90d / 1y stat cards
  - **History** — daily cost chart with 5h / 24h / 7d / 30d / 90d range filter
  - **Insights** — week-over-week comparison, top project, biggest day, most-used model
- Desktop widgets via WidgetKit (Small / Medium / Large) with App Group sync
- Floating mini window — always-on-top compact view
- Burn rate prediction — "Hit limit in ~Xh Ym at current rate"
- Claude Code CLI stats from local JSONL parsing with smart turn grouping
- Optional Anthropic Admin API support for Team/Enterprise organisations
- Hover tooltip on menu bar icon with quick multi-line summary
- Launch at login via `SMAppService`
- Onboarding tour shown on first launch (skippable, replayable from Settings)
- Settings → Updates: Sparkle auto-update with "Check now" button
- Override of the `anthropic-beta` OAuth header for forward-compatibility
- Universal binary (arm64 + x86_64)
- Time-bound announcement banner for the May 13 — Jul 13, 2026 weekly +50% bonus (auto-hides after the end date)
