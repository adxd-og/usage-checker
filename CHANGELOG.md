# Changelog

All notable changes to Omelette (formerly Usage Checker) will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.14.0] — unreleased

### Changed
- New popover: an **All** tab with a tile per provider (ring for the leading
  window, bar for the weekly, plan) and a 7-day cost tile; provider tabs with a
  large ring for the most-constrained window, the other session window as a
  row, weekly windows as rings, extra usage and cost rows. `All` is the default
  tab. With more than four providers the segments go icon-only.
- Design system (`UI/DesignSystem/`): tokens, ring gauge with pace marker,
  segmented control, tiles, hero, section headers, chips.
- Usage colours are now battery-style everywhere — popover, dashboard, menu-bar
  pills and the desktop widgets: green while comfortable, amber from 70 %, red
  from 90 % (was accent blue below 70 %).

### Internal
- `WindowRanking` and `BurnVerdict` extracted from the popover and unit-tested.

## [1.13.1] — 2026-08-31

### Fixed
- Claude went signed-out roughly once per token lifetime and only came back after
  pressing "Request keychain access now". A keychain ACL trusts *binaries*, so the
  rename to Omelette dropped the app off `Claude Code-credentials`' trust list: with
  the prompt suppressed (1.12.0's silent keychain) its background read could only ever
  fail, leaving the app's own cache as the sole source and nothing able to refresh it.
  The item's ACL does trust `/usr/bin/security` — the tool Claude Code writes it with —
  so the read is now delegated there when the direct one fails, guarded by an ACL
  preflight so an untrusted `security` is never invoked and can't raise a panel.

## [1.13.0] — 2026-08-28

### Added
- **Quota over time for providers without a cost log.** Antigravity and
  Gemini keep no local token log and bill by subscription, so a dollar figure
  can't exist for them — but consumption can. Their dashboard tabs now chart
  the quota history the app has been recording since 1.12.0:
  - **History** — one line per window on a fixed 0–100% axis (rescaling would
    hide the headroom), binned by time keeping each bin's *peak*, plus a table
    of daily peaks.
  - **Activity** — a day grid coloured by the day's peak utilization; a day
    the app wasn't running is shown as unobserved, not as 0%.
  - **Insights** — days at capacity (≥95%: providers round and stop updating
    at the cap), average daily peak, busiest day, today's peak, and average
    daily *consumption* — the sum of positive increments, so a window driven
    to 60% twice counts as 120% spent, taken over the largest window only so
    a session window and the weekly it rolls into aren't billed twice.
  History-only windows (ones the provider has stopped reporting) keep their
  line, end early, and never colour the grid. 24 new tests (200 total).

### Changed
- The "no cost log" note for such providers now reads "Quota over time is
  charted instead" and sits as a footnote beside the chart.

## [1.12.1] — 2026-08-28

Patch from a five-part external code review of 1.12.0 (keychain, aggregators,
notifier, dashboard, test quality), every finding verified against the code
before being fixed and several refuted. Tests: 96 → 176.

### Fixed
- **Keychain writes are gated like reads.** `save()`/`clear()` on the
  credentials cache checked nothing; with a locked login keychain and a
  `~/.claude/.credentials.json` present, a background poll could still raise
  the password panel through the cache *write*. A user who clicks Deny on the
  interactive dialog now gets the permission message, not "status -128".
- **A 401 can't replace the cache with an older token.** The renewal read
  after a 401 accepted whatever Claude Code's sources held — a stale
  credentials file could overwrite the newer cached token.
- **Burn rate survives a session reset.** The prediction used the first and
  last points of the 30-minute lookback; after a reset (92% → 4% → 38%) the
  delta was negative and "burning fast" stayed silent for up to half an hour —
  exactly when it matters. The rate is now measured on the window that is open
  now. Staleness is also reachable again (10 minutes), and the minimum legal
  30-second spacing between points counts.
- **Threshold alerts don't re-fire on a rounding wobble** (80 → 79 → 80). The
  fired level clears only after usage drops a few points below the threshold.
- **Claude Code's last log line is never lost.** The Claude aggregator marked
  a partially written last line as consumed; it now advances only past the
  last newline (as the Grok aggregator already did). A line whose timestamp
  can't be parsed is dropped instead of being billed as "now".
- **Grok costs: `costUsdTicks: 0` means unpriced, not free**, negative token
  counts are clamped, and a turn total larger than its per-model split is no
  longer silently discarded.
- **Dashboard selection can't paint one provider's costs under another's
  title.** Switching providers mid-scan discarded nothing; a refresh started
  for the previous selection could publish after the switch. Refreshes now
  carry the service and generation they were started for.
- **A Grok-only user is no longer stuck on Claude in the dashboard**, and a
  provider disabled in Settings is no longer selectable there. The popover's
  burn-rate verdict follows the popover's own tab, not the dashboard's.
- **Reset all settings also resets** the dashboard and popover selections,
  the peek shortcut, remembered alert levels, and Launch at Login.
- **The last visible provider can't be hidden from the menu bar.**
- **Unfunded dollar pools no longer appear as windows.** The usage payload
  carries codenamed pools (`nimbus_quill` and friends) with dollar fields;
  one of them reported `utilization: 0` and showed up as a 0% window. A pool
  renders only when it has a limit. The daily-summary day key is a local
  calendar day (the GMT rendering was fragile across timezone changes).

### Changed
- Test suite hardened per the review: a tautological test removed, two
  coincidental fixtures replaced with ones where the alternatives disagree,
  `NotNil` assertions replaced with exact values, boundary and guard cases
  added for pacing, burn rate, payload decoding, history, pricing parse, and
  the notifier; new `UsageSnapshot` tests for the headline rule. Every group
  mutation-checked.

## [1.12.0] — 2026-08-28

The keychain release. The permission dialog that came back every few hours
was never the ACL reset the code assumed — Claude Code *updates* its item and
has since April. Two other things were prompting, and this release measures
rather than guesses: what actually silences a background keychain read on
macOS 26, and what can't be silenced at all (a locked login keychain — so we
stop asking). Also the first unit-test suite: 96 tests, each group verified to
go red when its logic is broken.

### Fixed
- **Background polling never shows a keychain dialog.** Every background read
  runs with keychain UI disabled at the process level and is skipped outright
  while the login keychain is locked. `LAContext.interactionNotAllowed` and
  `kSecUseAuthenticationUIFail` — the previous approach, and CodexBar's — were
  measured to still raise the legacy Allow/Deny panel; they stay as a
  belt-and-braces layer, but the guarantee comes from
  `SecKeychainSetUserInteractionAllowed`. The only reads allowed to prompt are
  the onboarding **Grant access** button and Settings → **Request keychain
  access now**.
- **Omelette no longer refreshes the Anthropic token itself.** Claude Code
  rotates its refresh token, so a refresh from a second app either stole the
  CLI's session or lost the race and killed ours — that race, not an ACL, was
  the "every ~8 hours" cadence. Credentials are now read-only: own cache →
  `~/.claude/.credentials.json` → silent probe of Claude Code's item. A 401 no
  longer clears the cache (on machines without the credentials file it was the
  only copy), it re-reads Claude Code's sources once and otherwise shows a
  signed-out state with a hint to run `claude`.
- **Gemini's threshold notifications fire.** Providers whose every window is
  model-scoped (Gemini's daily Pro/Flash quotas) had nothing left to alert on
  after the model-scoped filter; those windows are now watchable when they're
  all a provider has.
- **Gemini's pace indicator is right.** Window length is carried in the model
  (from CodexBarCore's `windowMinutes`) instead of being inferred as "weekly"
  for every model-scoped window; Gemini's are daily.
- **Threshold alerts don't replay after a restart.** Fired levels persist.
- **Pay-as-you-go accounts appear in the widget** — a spend limit renders as a
  window, and a windowless account shows its 7-day CLI spend instead of being
  filtered out entirely.
- **A 401 response body never reaches the UI.** Error text is a short status
  description; the body goes to the log only.
- **Reset all settings resets all settings** — providers, budget, menu bar
  options, session alerts and onboarding included, behind a confirmation. A
  single `SettingsStore.Defaults` is the source of truth for every default.
- Settings → Account describes each provider in plain words ("Session 42% ·
  Week 18%") instead of "N buckets". Onboarding and Settings no longer promise
  off-peak reminders that didn't exist. README no longer claims the keychain
  dialog appears exactly once.
- `signing.xcconfig.example` now produces a notarizable build
  (`ENABLE_HARDENED_RUNTIME` + `OTHER_CODE_SIGN_FLAGS`), and `project.yml` no
  longer sets a project-level `ENABLE_HARDENED_RUNTIME = NO` that outranked the
  xcconfig.

### Added
- **Session-timing alerts.** "Burning fast" fires when, at the current pace,
  the session window hits 100% *before* it resets — a fast pace that resets in
  time is deliberately silent. "Resets in N min" fires in the last 15 minutes
  of a window you're already pressed against. Each nudges once per window;
  lead time is configurable in Settings → Notifications.
- **"Current session window" in Insights** — what ran while the open session
  window filled: cost, turns, models and projects from the CLI logs. Honest
  about its limits: when the log shows nothing, it says the usage came from
  elsewhere (the Claude apps, another machine) rather than implying nothing
  happened.
- **Grok costs in the dashboard.** A new incremental aggregator reads the Grok
  CLI's session logs (`~/.grok/sessions`), using the CLI's own `costUsdTicks`
  as the cost — no price table involved — with per-model and per-project
  breakdowns. Cold scan of 400 MB of logs: 0.66 s; subsequent polls: 0.04 s.
  The popover gains a "Last 7 days" row for Grok.
- **Dashboard and floating window for every provider.** History is recorded
  for each provider (old records read as Claude), with a service picker in the
  dashboard header. Where a provider has no local cost log — Antigravity keeps
  none, Codex's logs give only totals — the dashboard says exactly that instead
  of a generic "Claude only".
- **Menu bar options** — choose which providers occupy the menu bar, and
  whether the percentage shows always, never, or only with a single provider.
- **Global "peek at usage" shortcut** (Settings → General), via
  KeyboardShortcuts. Unset by default.
- **models.dev pricing now covers xAI and Google** models, alongside Anthropic
  and OpenAI. Models without a published price (image/video) are skipped;
  models known only to models.dev keep a readable display name.
- **Unit-test target** (`UsageTrackerTests`, XCTest, 96 tests): pacing and
  burn-rate rules, both log aggregators on fixture logs, the Claude usage
  payload decoder, notifier bucket selection, window lengths, history
  round-trips and per-service throttling, settings reset, error descriptions,
  pricing parse. The app's launch side effects are gated off under XCTest.

### Changed
- Onboarding asks for keychain access with an explicit **Grant access** button
  and shows whether it was granted — since background polling never prompts,
  the dialog has to be requested.
- User-Agent for the usage endpoint tracks the current Claude Code release.
- The unused `writeBack` into Claude Code's keychain item and the
  `OAuthRefreshClient` are gone.

## [1.11.0] — 2026-08-04

Performance release: an Opus 5 audit of a 4.8-day-uptime process (4.75% constant
CPU, 1.34 GB peak memory) traced every hot spot; all of them are fixed here.
Verified against the previous code on real logs — every cost figure matches to
the cent, first-scan peak memory drops from 1134 MB to 302 MB.

### Fixed
- **Menu bar no longer redraws twice a second forever.** The critical-state
  pulse animation drove a continuous redraw loop even in the normal state, for
  every visible provider — the main source of the constant CPU burn. The
  animation timeline now exists only while a window is actually ≥95%.
- **History no longer rewrites the whole file every minute.** Usage history is
  now an append-only JSONL log (~300 bytes per poll instead of re-serializing
  megabytes — about 9.5 GB of disk writes per day at 90 days of history).
  Existing `history.json` migrates automatically; the migration is
  rollback-safe (an older build's file, being a complete rewrite, supersedes
  the log when it's newer).
- **First scan of Claude Code logs no longer spikes memory past 1 GB.** Session
  files are parsed and folded one at a time; turns older than a month collapse
  into per-day aggregates instead of being held forever; the dedup set keeps
  8-byte hashes instead of id strings.
- **The poll path stopped hauling the full history array onto the main actor
  every minute.** Burn rate reads only the last half hour from the store; the
  dashboard loads the full history only while its window is open (and now
  refreshes live while it is).
- **Polling pauses during sleep and screen lock** — no more waking CLI
  subprocesses to update a menu bar nobody can see — and refreshes immediately
  on wake/unlock.
- **Changing the refresh interval applies immediately** instead of after the
  old interval elapsed one last time.
- **Codex session parsing is incremental**: the active session file has only
  its new tail read on each poll (carrying the cumulative-counter baseline),
  and cache entries for files that aged out of the window are evicted.
- Removed a redundant 10-second tooltip timer (the snapshot notification
  already covers it); narrowed the popover header's clock tick to the
  "Updated Xs ago" text; Insights recompute off the main thread only when
  their inputs change; model-pricing normalization and project-name resolution
  are memoized off the per-turn hot path.

## [1.10.0] — 2026-07-13

### Added
- **Provider tabs in the popover.** One provider on screen at a time, switched
  by a row of brand-logo tabs with battery-style status dots — no more
  stacking every card. The selection is remembered; with a single provider
  enabled the popover looks exactly as before, and the hero ring now speaks
  for the selected provider in multi-provider mode.

### Changed
- **Model-scoped windows inform, never drive.** "Fable only" / "Opus only"
  caps keep their card row but no longer move the menu-bar percent, the hero
  ring, tab dots, the widget ring, or threshold notifications — the all-models
  weekly is "the" limit.

## [1.9.0] — 2026-07-13

### Added
- **Model-scoped Claude limits (Fable).** The usage endpoint's new `limits`
  array is now parsed, so model-scoped weekly windows — like Fable's cap —
  appear as their own rows, drive the menu-bar headline when they're the
  binding limit, and flow into the widget and history. Windows appear and
  disappear with the server payload; the next scoped model needs no app
  update.

## [1.8.1] — 2026-07-12

### Changed
- **Provider cards show real brand logos.** The popover, Settings list, and
  desktop widget now render each provider's monochrome logo (Claude, Codex,
  Gemini, Antigravity, Grok) instead of generic system symbols. Logos are
  tinted like the old icons and fall back to a system symbol for entries
  without one (e.g. the Anthropic admin card).

## [1.8.0] — 2026-07-12

### Added
- **Grok (xAI) usage tracking.** A new provider card shows billing-period
  credit usage from the local Grok CLI (`grok agent stdio` RPC), falling back
  to grok.com web billing when the CLI is unavailable. Includes a Settings
  toggle (on by default when the Grok CLI is signed in), a sign-in recovery
  popover (`grok login` + dashboard link), and Grok as a selectable provider
  in the desktop widget.

## [1.7.7] — 2026-07-11

### Changed
- **The popover header shows the app icon** (with several providers) instead
  of a generic gauge symbol.
- **The menu bar tooltip covers every provider** — it was hardcoded to Claude;
  now each provider with data gets its own block, plus the $ figure for
  pay-as-you-go.

## [1.7.6] — 2026-07-11

### Changed
- **The Dashboard now says "Claude data only".** Its charts are built from
  Claude usage history and Claude Code session logs; the sidebar badge makes
  that honest instead of implying every provider is included.

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
