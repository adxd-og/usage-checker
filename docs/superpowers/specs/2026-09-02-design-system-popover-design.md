# Phase 1 — Design system, new popover, menu bar restyle

Part of the [agent control plane roadmap](2026-09-02-agent-control-plane-roadmap.md).
Ships as one release. No data-model or provider changes.

## Goals

1. A small, named design system every later surface reuses.
2. The popover becomes the approved `All` / provider layout.
3. Menu-bar pills pick up the new colour semantics.
4. Nothing regresses: every fact the popover shows today is still shown.

Non-goals: agents (phase 2), dashboard / settings / floating / onboarding /
widgets (phase 3), new data sources.

## Design system (`UsageTracker/UI/DesignSystem/`)

### Tokens — `OMTokens.swift`

- **Spacing**: `xs 4, s 8, m 12, l 16, xl 20`.
- **Radii**: `tile 16, row 12, chip capsule`. The popover shape itself belongs to `NSPopover`.
- **Type roles** (all system font; numerals `design: .rounded` + `monospacedDigit`):
  `title 13 semibold`, `body 12 regular`, `bodyStrong 12 semibold`, `caption 11`,
  `micro 10 semibold uppercase tracking 0.6`, `heroNumeral 21 bold`, `numeral 13 bold`.
- **Usage status colour** — `usageStatusColor(_:)` moves here and changes meaning:
  `< 70 → .green`, `70..<90 → .orange`, `≥ 90 → .red`. Every caller in the app
  (bars, rings, pills, dashboard) inherits the change; the widget keeps its own
  copy until phase 3.
- **Agent state colours** are defined now (`needsYou .orange`, `working .blue`,
  `done .green`, `idle .secondary`) so phase 2 adds no tokens, but no component
  uses them yet.
- **Surfaces**: `tileFill = .fill.tertiary`, `rowFill = .fill.quaternary`,
  hairline `.separator.opacity(0.5)`. Liquid Glass is reserved for controls
  (segmented control, footer buttons, chips); content tiles use quiet system
  fills so glass is not stacked on the popover's own material.

### Components

| Component | Purpose | Notes |
|---|---|---|
| `OMRing` | Ring gauge | Sizes `hero 84/9`, `medium 52/6`, `small 44/5`, `mini 26/4` (diameter/line). Round caps, track `.quaternary`, colour from status. Optional centre label (percent) and optional **pace marker**: a 3 pt dot on the track at the elapsed fraction, replacing the bar's pace tick. Replaces `UsageRing`. |
| `BarSegment` | Thin level bar | Kept as is (weekly bar inside tiles, extra usage). Colour via the token function. |
| `OMSegmentedControl` | `All · Claude · …` | Capsule track `.fill.quaternary`; selected item is a glass capsule (`liquidGlass(in: Capsule())`, `.bordered`-like fallback) inside a `GlassGroup` so selection morphs. Items: `All` (text) + provider icon + short name. Supports an optional trailing dot per item (unused until phase 2). Keyboard: ⌘1…⌘9 select items. |
| `OMProviderTile` | Tile on the All tab | Icon · name · plan (trailing). Middle: `OMRing.medium` of the hero window + two-line label (window name, "2h 15m left"). Bottom: `BarSegment` of the secondary window with a caption. Non-ok state: ring replaced by the state chip, tile dimmed to 70 %. Whole tile is a button → selects that provider tab. |
| `OMCostTile` | Full-width "Last 7 days" | Total of `weekCost` across services + per-service breakdown line ("Claude $15.60 · Codex $8.20"). Hidden when no service reports a cost. No sparkline in this phase. |
| `OMHero` | Provider-tab header | `OMRing.hero` + title ("Session · 5h"), reset line, status phrase (existing wording), burn verdict line (existing wording) below. |
| `OMRingRow` | Weekly windows | `LazyVGrid` 4 columns of `OMRing.small` + short label. Labels shortened: "All models" → "All", "Opus only" → "Opus"; anything else kept. The existing "N unused windows" disclosure stays and hides untouched model windows. |
| `OMSectionHeader` | "WEEKLY LIMITS · resets Thu" | Micro label + trailing caption. Replaces `blockTitle`. |
| `OMChip` | Tinted capsule | State badges (`Sign in` / `Not running` / `Error`); keeps today's help-popover behaviour. |
| `OMKeyValueRow` | "Extra usage  $12.40 / $50" | Label + trailing numeral, optional bar underneath. |

All components get `#Preview`s in light and dark.

## Popover (`PopoverView.swift`, rebuilt)

Width stays 360. Structure top to bottom:

1. **Header**: app icon 26 pt, "Omelette", meta line. Meta line = `Updated Xs ago` on All, `Plan · Updated Xs ago` on a provider tab. Loading spinner trailing. The stale-data notice row stays under the header.
2. **Segmented control**, shown only when more than one service is displayed. Selection persists in the existing `selectedProviderTab` key; value `"all"` is the new default. Self-heal: a stored id that is not displayed resolves to `all`. Providers appear in snapshot order.
3. **All tab**: 2-column grid of `OMProviderTile`, then `OMCostTile`. Order = snapshot order. Tile hero/secondary window selection is a pure function (below).
4. **Provider tab**: `OMHero` → `Weekly limits` (`OMRingRow`) → extra usage (`OMKeyValueRow` + bar) → `Last 7 days` (`OMKeyValueRow`) → state message when state ≠ ok (data retained through transient failures, as today). Pay-as-you-go accounts (no windows, a weekly budget) keep their synthesised budget bucket, so the hero ring shows budget use; accounts with only `weekCost` show the cost row as the hero text instead of a ring.
5. **Footer**: unchanged buttons (Dashboard ⌘D, floating, settings ⌘,, refresh ⌘R, Quit ⌘Q) — already glass.

### Window selection (pure, unit-tested) — `WindowRanking.swift`

- `heroBucket(for service)`: today's `heroBucket` rule, extracted from the view:
  worst non-promotional, non-model-scoped window; extra usage competes when enabled;
  fallbacks to promotional, then any bucket. Ties → first in API order.
- `secondaryBucket(for service)`: the all-models weekly (`seven_day`) when it is not
  the hero; otherwise the next-worst window by the same filter; nil when none.
- `remaining(bucket, now)`: "2h 15m left" formatting = existing `formatReset` without the "in".
- `shortWindowLabel(_:)`: the label shortening above.
- `resolveTab(stored:displayed:) -> String`: `"all"` unless `stored` is a displayed id.

## Menu bar (`MenuBarLabel.swift`)

- Pills keep their shape; fill colour comes from the token function (green when comfortable).
- Number text uses `numeral` role.
- A reserved leading slot for the phase-2 agents pill; nothing rendered in phase 1.

## Behaviour that must not regress (checklist for the plan)

- Hero ring status phrase and reset time.
- Burn verdict under the session.
- Weekly windows, "N unused windows" disclosure, "You haven't used X yet" hints.
- Extra usage / spend-limit row and title logic (`extraUsageTitle`).
- 7-day cost row.
- State chip → help popover with command copy / Open Antigravity / link.
- Stale notice row, loading row, "no usage data" text.
- Keyboard shortcuts in the footer, `focusEffectDisabled` on tab buttons.
- Accessibility labels/values on rings, bars, tiles, tabs.

## Testing

- Unit: `WindowRankingTests` (hero, secondary, shortening, tab resolution) using
  the existing `Fixture` builders.
- Build: `xcodebuild -scheme UsageTracker build` and `xcodebuild test` both green.
- Visual: previews for every component in light/dark; the owner tests the built app.

## Out of scope reminders

Dashboard, floating window, settings, onboarding, widgets keep today's look; the
only visible change there is the green "comfortable" colour.
