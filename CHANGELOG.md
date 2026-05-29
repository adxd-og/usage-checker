# Changelog

All notable changes to Usage Checker will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
