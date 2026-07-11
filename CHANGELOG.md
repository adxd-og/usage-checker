# Changelog

All notable changes to Omelette (formerly Usage Checker) will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.7.5] — 2026-07-11

### Fixed
- **Re-enabling a provider brings it back immediately.** A user-initiated
  refresh (provider toggles, Refresh buttons, keychain button) was silently
  dropped when a poll was already in flight or a 429 backoff was active — the
  provider then stayed hidden until the next timer tick, which with a 5-minute
  interval felt like forever. User requests now coalesce into a guaranteed
  follow-up poll and bypass the backoff; the timer still honors Retry-After.
- The keychain-access button status no longer claims "refreshing…" forever —
  it confirms and clears itself.

## [1.7.4] — 2026-07-11

### Changed
- **The popover hero ring shows only for a single provider.** With several
  providers the big percentage was anonymous (whose 33%?); the header now
  stays neutral and the per-provider sections carry the numbers — same rule
  the menu bar pills follow since 1.7.2.
- **Welcome tour refreshed.** The real omelette app icon instead of the old
  drawn placeholder, the keychain page mentions the "Request keychain access
  now" fallback button, and the final page notes that updates install
  themselves.

## [1.7.3] — 2026-07-11

### Added
- **Settings → Account → "Request keychain access now".** Shows the macOS
  dialog for the Claude Code-credentials item immediately, skipping the
  hourly retry limit — the cure for a fresh install stuck on errors until
  the next automatic prompt.

## [1.7.2] — 2026-07-11

### Changed
- **Quieter menu bar with several providers.** When more than one provider is
  shown, the pills drop their numbers and keep just the colored bars; a lone
  provider still shows its percent. (The number is that provider's hottest
  real window — session, weekly or spend limit; promo pools don't count.)

## [1.7.1] — 2026-07-11

### Added
- **Auto-updates via Sparkle are live.** The app now ships with the EdDSA
  public key and checks the appcast feed (GitHub Pages, `docs/appcast.xml`)
  automatically; each release DMG is signed with the private key from the
  release Mac's keychain (`scripts/update_appcast.sh`). Builds prior to this
  one must update by hand one last time.
- Settings → Updates now shows the app version and build number.

## [1.7.0] — 2026-07-11

### Changed
- **A face to match the name: new app icon.** A sunny-side-up egg whose yolk
  wears a progress ring — cut to Apple's 824/1024 icon grid at every size.
  Generated with Gemini (Antigravity), masked and sliced locally; the source
  artwork lives in `Design/`.
- **README hero banner** in the style of Dalí's "The Persistence of Memory":
  melting fried-egg gauges over bare branches — usage limits melt away too.

## [1.6.1] — 2026-07-11

### Fixed
- **Smooth migration from Usage Checker.** The credential cache heals itself
  after the app rename: no stray permission dialogs for the app's own cache,
  and the first successful fetch re-owns it. The one legitimate dialog left is
  the familiar "access Claude Code-credentials" — click Always Allow once.
- **A failing provider keeps its last-good data on screen.** A transient error
  (e.g. a rate-limited usage endpoint) used to replace the provider's bars with
  a bare "Error" tile; now the numbers stay and the badge says what's wrong.
- Codex free-plan windows span ~30 days and are now labeled "Monthly", not
  "Weekly".

## [1.6.0] — 2026-07-11

### Changed
- **Usage Checker is now Omelette 🍳** — named after Anthropic's internal
  codename for Claude Design that we found in their usage API. The app file is
  now `Omelette.app` (delete the old `UsageChecker.app` when upgrading);
  settings, history, keychain access and widgets carry over automatically.
- **Promotional quota pools no longer drive the headline.** A free promo
  window at 91% was winning the hero header, menu-bar percent and widget ring
  while the real constraint (the Enterprise spend limit at 78%) sat below.
  Promo windows keep their row but are informational; the spend limit now
  competes for the headline and fires 80/95% threshold notifications.

## [1.5.0] — 2026-07-11

### Added
- **Pay-as-you-go mode.** Accounts without session/weekly windows (Enterprise
  API billing) now get a "$X" menu-bar pill with the local 7-day CLI spend, and
  an optional weekly budget (Settings → Account) that turns spend into a
  percentage — bars, the hero header and 80/95% notifications work off it.

### Fixed
- **Spend limit was shown 100× too large.** The usage API reports extra-usage
  credits in cents; an Enterprise limit of "$156.40 of $200" displayed as
  "$15640.00 / $20000". Now shown correctly, with grouped thousands.
- The block is labeled "Spend limit" on Enterprise/Team plans (matching
  Claude's own UI) and "Extra usage credits" on subscription plans.
- Windows named with Anthropic's internal codename now display properly:
  "Omelette Promotional" → "Claude Design Promotional".

## [1.4.0] — 2026-07-10

### Added
- **Codex CLI cost accounting.** The Codex section in the popover now shows
  "Last 7 days $X", computed locally from `~/.codex/sessions` logs: per-turn
  token deltas are attributed to the model in use and priced at API rates
  (cached input bills at the cache-read rate; OpenAI doesn't bill cache writes).
- **Live model pricing from models.dev.** Claude and OpenAI rates (61 models)
  load from the public models.dev dataset — refreshed daily, cached on disk —
  so a newly launched model prices correctly without an app update. The
  hand-verified built-in table remains the offline fallback.

### Notes
- Antigravity/Gemini expose only quota percentages locally (no token logs),
  so dollar accounting isn't possible for them.

## [1.3.0] — 2026-07-10

### Added
- **Multi-provider desktop widgets.** The widget is now provider-configurable:
  right-click → Edit Widget → Provider to pick Claude, Codex, Gemini, or
  Antigravity — add several small widgets side by side, one per provider.
  A new **"All providers"** large widget shows every connected provider's
  session window and busiest limits at a glance. Existing widget placements
  keep working (they default to Claude).

### Removed
- The expired promo banners (+50% weekly limits; Fable 5 inclusion) and the
  announcements mechanism behind them.

## [1.2.0] — 2026-07-10

### Added
- **Multi-provider usage tracking.** Alongside Claude, the widget can now show:
  - **Codex (OpenAI)** — session and weekly limits from the local Codex CLI
    (requires ChatGPT sign-in; API-key auth doesn't expose limits).
  - **Antigravity** — "Gemini models" and "Claude & GPT models" pool quotas
    (weekly + 5-hour) read from a running Antigravity app, `agy` CLI, or IDE.
    This is the Gemini-quota path for personal Google accounts after the
    June 2026 Gemini CLI OAuth shutdown.
  - **Gemini CLI** — daily Pro / Flash / Flash Lite quotas, for accounts the
    OAuth shutdown didn't affect.
  Each provider has a toggle in Settings → General → Providers, enabled
  automatically when the corresponding tool is detected on the machine.
  Provider fetching is powered by CodexBarCore from
  [steipete/CodexBar](https://github.com/steipete/CodexBar) (MIT).

### Changed
- The state badge in the popover ("Sign in", "Not running") is now a button:
  clicking it explains what's wrong and offers the exact sign-in command with
  a Copy button, or launches Antigravity directly.

## [1.1.1] — 2026-07-10

### Fixed
- **No more keychain permission prompt every ~8 hours.** Claude Code re-creates its
  keychain item on every token refresh, which reset the ACL and re-triggered the
  macOS prompt. The app now caches credentials in its own keychain item (reading
  your own item never prompts), refreshes the access token itself, and only probes
  Claude Code's item silently in the background (plus the `~/.claude/.credentials.json`
  file as a prompt-free source). The interactive prompt remains only for first
  launch / re-login, and is rate-limited to once per hour.

## [1.1.0] — 2026-06-10

### Changed
- **Apple-native redesign across the app.** Flat battery-style bars (solid status
  color, no gradients or glows), semantic system typography, System-Settings-style
  cards with continuous corners, system-material backgrounds for the floating
  window and desktop widget (the widget finally looks right in light mode), and
  Reduce Motion is honored by the menu-bar critical pulse.
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
