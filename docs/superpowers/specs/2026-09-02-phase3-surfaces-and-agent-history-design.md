# Phase 3 — remaining surfaces in the new style + agent run history

Part of the [agent control plane roadmap](2026-09-02-agent-control-plane-roadmap.md).
Ships as **2.1.0**. Owner approved the phase scope on 2026-09-02; visual decisions
below follow the phase-1 direction ("Apple-authored": tokens, rings, battery
colours, quiet fills for content, glass for controls) and were made by the
orchestrator without new mockups.

## Goals

1. Every surface reads as one product: dashboard, settings, floating window,
   onboarding and the desktop widgets use the phase-1 design system.
2. The dashboard gets an **Agents** tab: live sessions plus the run history that
   phase 2 already records in `agent-sessions.jsonl`.
3. No new data sources; no behaviour change outside what is listed.

Non-goals: approve/deny (phase 4), rules inventory (phase 5), new providers,
menu-bar changes (done in phases 1–2).

## Package 1 — shared UI for the widget

The widget extension compiles its own sources, so the phase-1 components are not
available to it. Move the pure, AppKit-free pieces into a directory both targets
compile (the pattern `project.yml` already uses for `UsageTrackerWidget/ProviderIconView.swift`
and `SharedAssets/ProviderIcons.xcassets`):

```
SharedUI/
  OMTokens.swift      (moved from UsageTracker/UI/DesignSystem/; unchanged API)
  OMRing.swift        (moved; gains `case widget` = 110 pt / 10 pt line, label heroNumeral)
  BarSegment.swift    (moved from UsageTracker/UI/Components/)
```
`project.yml`: add `- path: SharedUI` under `sources:` of BOTH the app and the
widget target (in the app target it replaces nothing — the files simply move).
Delete the widget's private `statusColor(_:)` and `ProgressBar`; `SmallProviderView`
draws `OMRing(percent:size: .widget)`, `WidgetBucketRow` uses `BarSegment`.
Colours therefore come from one function. Widget previews updated. No visual
change beyond the ring caps and bar shape matching the app.

Tests: `WindowRankingTests` colour cases keep passing from the app target; add
`UsageTrackerWidget`-independent proof by building both targets. (The widget has
no test target; the move is verified by `xcodebuild build` of the app, which
builds the appex.)

## Package 2 — dashboard restyle + Agents tab

### Chrome
- `UsageTracker/UI/Components/CardStyle.swift`: `dashboardCard(padding:)` keeps its
  name and call sites but draws `OMSurface.tile` + `OMRadius.tile` + `OMSurface.hairline`.
- `DashboardHeader`: title `OMFont.screenTitle` (new token: `.system(size: 22, weight: .semibold)`),
  subtitle `OMFont.body` secondary; `ServicePicker` unchanged (menu style is native).
- Sidebar list unchanged (native). Selection persists (`@AppStorage("dashboardTab")`).
- `OverviewView`: hero row = `OMRing(.hero)` + `OMHero`-style texts (reuse `OMHero`
  where the service has a session window, via `WindowRanking.detailHero`), window
  rows = `OMKeyValueRow` with bars. Section labels = `OMSectionHeader`.
- `SessionHistoryView`, `ActivityGridView`, `InsightsView`: keep Swift Charts and
  the heatmap; recolour series with `usageStatusColor` semantics where a series is
  a utilisation, `Color.accentColor` for cost lines; cards via `dashboardCard`;
  headings via `OMSectionHeader`; numerals `OMFont.numeral`/`heroNumeral`.

### Agents tab (`UsageTracker/UI/Dashboard/AgentsHistoryView.swift`)
- Added to `DashboardWindow.Tab` as `case agents = "Agents"`, icon `bolt.horizontal.circle`,
  placed after Overview.
- Header: `DashboardHeader(title: "Agents", subtitle: "Live sessions and run history")`
  with an `OMSegmentedControl` for the source filter: `All · Claude · Codex`
  (`@AppStorage("agentsHistorySource")`, values `all|claude|codex`).
- **Summary strip** (four `dashboardCard` tiles in an `HStack`): *Sessions*
  (count in range), *Agent time* (sum of `endedAt − startedAt`, "3h 12m"),
  *Approvals waited* (sum of `needsYouCount`), *Busiest project* (name + count).
  Range = `dashboard.range` (`TimeRange`, existing picker reused in the header
  `trailing` slot).
- **Live** section: `AgentsSection(sessions: filtered live sessions, grouped: true,
  hooksInstalled: true, onEnable: {})` — the dashboard never nags about hooks.
- **History** section: rows grouped by day ("Today", "Yesterday", "Mon 1 Sep"),
  each row `OMAgentHistoryRow`: provider icon, project, started time (`HH:mm`),
  duration, `N turns`, `⚠︎ M` when `needsYouCount > 0`. Empty state: "No finished
  sessions in this range" (+ "Hooks give exact durations" caption when the
  Claude hooks are not installed).
- Pure aggregation, unit-tested:
  ```swift
  struct AgentHistorySummary: Equatable {
      let sessions: Int; let agentTime: TimeInterval; let approvalsWaited: Int
      let busiestProject: (name: String, sessions: Int)?
      static func make(records: [AgentSessionRecord], source: AgentSource?, range: TimeRange, now: Date) -> AgentHistorySummary
      static func days(records: [AgentSessionRecord], source: AgentSource?, range: TimeRange, now: Date, calendar: Calendar) -> [(day: Date, records: [AgentSessionRecord])]   // newest first
      static func dayTitle(_ day: Date, now: Date, calendar: Calendar) -> String
      static func duration(_ interval: TimeInterval) -> String   // "3h 12m", "45m", "<1m"
  }
  ```
- Data flow: `DashboardState` gains `@Published private(set) var agentRecords: [AgentSessionRecord]`
  loaded in `refreshAll()` from `AgentHistoryStore(fileURL: AgentPaths.historyURL).load()`
  off-main; live sessions come from `AgentSessionStore.shared`.
- **Rotation**: `AgentHistoryStore.rotate(keepDays: Int = 90, now: Date = Date()) throws`
  rewrites the file atomically keeping records with `endedAt` inside the window;
  called once per launch from `AgentChannel.start()` (same place the symlink is
  refreshed) on a background task. Unit-tested on temp files.

## Package 3 — settings, onboarding, floating window

- **Settings** (`SettingsView.swift`, `AgentsSettingsView.swift`): keep `Form`
  `.grouped`; section footers and captions on `OMFont.caption`; every status line
  (keychain, hooks, providers) becomes an `OMChip`; the Account tab's tier picker
  and the Providers list unchanged. One-line copy edits only where a chip replaces
  a coloured dot.
- **Onboarding** (`OnboardingView.swift`): cards on `OMSurface.tile`/`OMRadius.tile`
  inside the 520×480 window; the welcome page shows `OMRing(.hero)` at 37 % as the
  illustration instead of the app icon alone; `permissionRow` uses `OMFont`
  roles; page dots and buttons on glass (`glassButtonStyle`/`glassProminentButtonStyle`).
  Copy unchanged.
- **Floating mini window** (`FloatingWindow.swift`): `FloatingMiniView` rebuilt on the
  kit — `OMRing(.medium)` for the hero (via `WindowRanking.detailHero`), up to two
  `BarSegment` rows for the next windows, and a trailing agents count using
  `OMAgentsPill.Appearance.make(...)` (dot + number) when sessions exist. Same size
  class, drag/dock behaviour untouched (`FloatingWindowController` not modified).

## Release prep (package 3 executor)

`MARKETING_VERSION` 2.1.0 / `CURRENT_PROJECT_VERSION` 31 in both targets;
CHANGELOG `[2.1.0] — unreleased` with Added (Agents tab, history rotation) and
Changed (dashboard/settings/onboarding/floating/widgets on the design system).

## Testing

- Unit: `AgentHistorySummaryTests` (range filtering, source filter, day grouping
  across midnight and DST, duration formatting, busiest project tie → first seen),
  `AgentHistoryStoreTests` rotation cases, widget-free colour tests unchanged.
- Build both targets; previews for every touched view in light and dark.
- Manual: owner walks dashboard tabs, opens the floating window, replays the
  tour, adds each widget size.

## Package dependencies

Package 1 first (file moves); packages 2 and 3 in parallel after it (disjoint
files: 2 owns `Dashboard/`, `DashboardState`, `AgentHistoryStore`, `AgentChannel`;
3 owns `SettingsView`, `AgentsSettingsView`, `OnboardingView`, `FloatingWindow`,
`project.yml`/`CHANGELOG.md`).
