# Phase 3 Package 2 — Dashboard restyle + Agents tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put the dashboard on the phase-1 design system and give it an **Agents** tab that shows live sessions plus the run history phase 2 already records in `agent-sessions.jsonl`.

**Architecture:** The aggregation is pure and unit-tested (`AgentHistorySummary`) so the new screen is a thin renderer; the log is loaded off-main into `DashboardState.agentRecords` by the same `refreshAll()` that loads usage history, and trimmed once per launch by `AgentHistoryStore.rotate(keepDays:now:)` (a mirror of `HistoryStore`'s 90-day rotation) fired from `AgentChannel.start()`. The existing dashboard screens keep their structure — Swift Charts and the heat map stay — and only swap ad-hoc fonts, cards and colours for `OMTokens` / `OMSectionHeader` / `OMKeyValueRow` / `OMRing` / `OMHero` / `usageStatusColor`.

**Tech Stack:** Swift 6 (strict concurrency `minimal`), SwiftUI, Swift Charts, macOS 14 floor with `#available(macOS 26)` Liquid Glass paths, XCTest (`UsageTrackerTests`, `@testable import Omelette`), xcodegen-generated project.

**Spec:** `docs/superpowers/specs/2026-09-02-phase3-surfaces-and-agent-history-design.md` (Package 2). Roadmap: `docs/superpowers/specs/2026-09-02-agent-control-plane-roadmap.md`.

## Global Constraints

- Deployment target macOS 14.0; every glass effect goes through the helpers in `UsageTracker/UI/Components/LiquidGlass.swift` (`liquidGlass(in:tint:)`, `GlassGroup`, `glassButtonStyle()`), never a bare `glassEffect` call. `OMSegmentedControl` already does this — use the component, do not re-roll it.
- Colour semantics: `usageStatusColor` returns `.green` below 70, `.orange` from 70, `.red` from 90. Agent-state colours come from `OMAgentColor`.
- Package 1 (moving `OMTokens` / `OMRing` / `BarSegment` into `SharedUI/`) lands before this package. **Type names and APIs are unchanged** — write `OMTokens.swift`-facing code exactly as it is today and do not move, copy or edit those three files here.
- Package 3 runs in parallel and owns `SettingsView.swift`, `AgentsSettingsView.swift`, `OnboardingView.swift`, `FloatingWindow.swift`, `project.yml` and `CHANGELOG.md`. **Do not touch those files** — no version bump and no changelog entry in this package.
- Every user-visible string that exists today keeps its wording (status phrases, burn verdict, "N unused windows", the `costSource.reason` sentences, the placeholder copy in the three chart views).
- New copy introduced here is fixed by the spec: `"Agents"`, `"Live sessions and run history"`, section titles `"Live"` and `"History"`, day titles `"Today"` / `"Yesterday"` / `"Mon 1 Sep"`, empty state `"No finished sessions in this range"`, caption `"Hooks give exact durations"`, tiles `"Sessions"` / `"Agent time"` / `"Approvals waited"` / `"Busiest project"`.
- Persisted keys: `@AppStorage("dashboardTab")` (dashboard tab, values are `DashboardWindow.Tab` raw values) and `@AppStorage("agentsHistorySource")` (values `all` | `claude` | `codex`). The dashboard's provider key stays `dashboardSelectedService`; do not rename it.
- Swift 6, warning-free. `View` initialisers are `@MainActor`; any `static` on a `View` type that a test calls must be marked `nonisolated` (see `AgentsSection.groups(_:)` for the pattern).
- New source files are picked up by xcodegen from `sources: - path: UsageTracker` / `- path: UsageTrackerTests`; run `xcodegen generate` after adding a file and before building. `UsageTracker.xcodeproj/` is generated and gitignored — never `git add` it.
- Build: `xcodebuild -project UsageTracker.xcodeproj -scheme UsageTracker -configuration Debug -derivedDataPath build/DerivedData build`.
  Tests: `xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData` (add `-only-testing:UsageTrackerTests/<Class>` for one class). **Always append `ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS=""` to every `xcodebuild test` invocation** — `signing.xcconfig` turns on the hardened runtime, which blocks the `DYLD_INSERT_LIBRARIES` injection XCTest needs, and the runner then hangs for ~6 min with "The test runner hung before establishing connection". Plain `build` keeps the real settings.
- Commits end with the trailer lines
  `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` and
  `Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X`.
- Other sessions may commit the working tree while you work: re-read a file right before editing it; prefer targeted edits over whole-file rewrites.
- No release in this plan: the owner runs the local build/notarize flow after testing.

---

## File structure

```
UsageTracker/Agents/
  AgentHistorySummary.swift     NEW — pure aggregation for the Agents tab (range/source filter,
                                day grouping, day titles, duration strings, busiest project)
  AgentHistoryStore.swift       + rotate(keepDays:now:) and a shared parse pass
  AgentChannel.swift            + one detached rotation call in start()
UsageTracker/Core/
  DashboardState.swift          + agentRecords, refreshAgentHistory(historyURL:)
UsageTracker/UI/DesignSystem/
  OMTokens.swift                + OMFont.screenTitle
  OMAgentHistoryRow.swift       NEW — one finished session as a row
UsageTracker/UI/Components/
  CardStyle.swift               dashboardCard() drawn from OMSurface/OMRadius
UsageTracker/UI/Dashboard/
  DashboardWindow.swift         Tab.agents, persisted selection, restyled DashboardHeader
  AgentsHistoryView.swift       NEW — the Agents tab
  OverviewView.swift            rebuilt on OMHero / OMKeyValueRow / OMSectionHeader
  ActivityGridView.swift        heat-map colour rule split into two tested statics
  InsightsView.swift            OMSectionHeader + OMFont numerals
  SessionHistoryView.swift      OMSectionHeader + OMFont numerals
UsageTrackerTests/
  AgentHistorySummaryTests.swift  NEW
  AgentsHistoryViewTests.swift    NEW (row + source-tab statics)
  DashboardAgentRecordsTests.swift NEW
  ActivityGridColorTests.swift     NEW
  AgentHistoryStoreTests.swift    + rotation cases
  AgentChannelTests.swift         + "start rotates the log" case
```

Task order: 1 (chrome) → 2 (summary) → 3 (rotation) → 4 (rotation wiring) → 5 (state) → 6 (row) → 7 (screen) → 8 (Overview) → 9 (charts) → 10 (manual pass). Tasks 2–6 are independent of 8–9; 7 needs 1, 2, 5 and 6.

---

## Task 1: Dashboard chrome on the design system

Card fill, screen title and a persisted tab selection. No behaviour changes beyond the tab surviving a relaunch.

**Files:**
- Modify: `UsageTracker/UI/DesignSystem/OMTokens.swift:18-28` (add `screenTitle`)
- Modify: `UsageTracker/UI/Components/CardStyle.swift:6-18`
- Modify: `UsageTracker/UI/Dashboard/DashboardWindow.swift:6` (selection), `:84-110` (`DashboardHeader`)

**Interfaces:**
- Consumes: `OMSpacing`, `OMRadius.tile`, `OMSurface.tile`, `OMSurface.hairline` (already in `OMTokens.swift`).
- Produces:
  ```swift
  extension OMFont { static let screenTitle: Font }          // .system(size: 22, weight: .semibold)
  extension View { func dashboardCard(padding: CGFloat = OMSpacing.l) -> some View }   // same name, same call sites
  struct DashboardHeader: View {                              // gains one parameter, default keeps every call site
      let title: String
      let subtitle: String?
      var trailing: AnyView? = nil
      var showsServicePicker: Bool = true
  }
  ```

- [ ] **Step 1: Add the screen-title token**

In `UsageTracker/UI/DesignSystem/OMTokens.swift`, inside `enum OMFont`, add it above `heroNumeral`:

```swift
    /// Dashboard screen titles. The popover's `title` (13 pt) is far too small for a
    /// 920 pt window, and `.title2` is a dynamic role the rest of the kit doesn't use.
    static let screenTitle = Font.system(size: 22, weight: .semibold)
```

- [ ] **Step 2: Draw `dashboardCard` from the tokens**

Replace the body of `UsageTracker/UI/Components/CardStyle.swift`:

```swift
import SwiftUI

extension View {
    /// System-Settings-style inset card: continuous corners, quiet system fill,
    /// hairline separator stroke. One look for every dashboard card, and the same
    /// surface tokens the popover's tiles use.
    func dashboardCard(padding: CGFloat = OMSpacing.l) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: OMRadius.tile, style: .continuous)
                    .fill(OMSurface.tile)
            )
            .overlay(
                RoundedRectangle(cornerRadius: OMRadius.tile, style: .continuous)
                    .strokeBorder(OMSurface.hairline, lineWidth: 0.5)
            )
    }
}
```

- [ ] **Step 3: Restyle `DashboardHeader` and let a tab hide the provider picker**

In `UsageTracker/UI/Dashboard/DashboardWindow.swift`, replace `struct DashboardHeader` with:

```swift
struct DashboardHeader: View {
    let title: String
    let subtitle: String?
    var trailing: AnyView? = nil
    /// The Agents tab is not about one provider, so it hides the picker rather than
    /// showing a control that changes nothing on screen.
    var showsServicePicker: Bool = true

    @ObservedObject private var dashboard = DashboardState.shared

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(OMFont.screenTitle)
                if let subtitle {
                    Text(subtitle)
                        .font(OMFont.body)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if showsServicePicker {
                ServicePicker(dashboard: dashboard)
            }
            trailing
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 12)
    }
}
```

- [ ] **Step 4: Persist the tab selection**

In the same file, replace the `selection` property of `DashboardWindow`:

```swift
    /// Survives a relaunch. `Tab` is `String`-backed, so a raw value that no longer
    /// exists (a tab removed in a later release) falls back to `.overview` on its own.
    @AppStorage("dashboardTab") private var selection: Tab = .overview
```

(`@State private var selection: Tab = .overview` on line 6 is what this replaces; `List(Tab.allCases, selection: $selection)` needs no change — `AppStorage`'s projected value is a `Binding` too.)

- [ ] **Step 5: Build**

Run: `xcodebuild -project UsageTracker.xcodeproj -scheme UsageTracker -configuration Debug -derivedDataPath build/DerivedData build`
Expected: `** BUILD SUCCEEDED **`, no new warnings.

- [ ] **Step 6: Eyeball the cards**

Open `UsageTracker/UI/DesignSystem/OMHero.swift` in Xcode and resume the canvas (any file with a `#Preview` warms the same module). Then run the app from Xcode, open the dashboard (menu bar → Dashboard) and confirm: title is noticeably larger, cards have 16 pt corners and a visible hairline, the provider picker still appears on Overview when more than one provider is available. Switch to Insights, quit, relaunch, reopen the dashboard — Insights is still selected.

- [ ] **Step 7: Commit**

```bash
git add UsageTracker/UI/DesignSystem/OMTokens.swift UsageTracker/UI/Components/CardStyle.swift UsageTracker/UI/Dashboard/DashboardWindow.swift
git commit -m "Dashboard: chrome on the design system, persisted tab

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

## Task 2: `AgentHistorySummary` — the pure aggregation

Everything the Agents tab computes lives here, so the arithmetic is tested instead of eyeballed. Signatures are fixed by the spec.

**Files:**
- Create: `UsageTracker/Agents/AgentHistorySummary.swift`
- Test: `UsageTrackerTests/AgentHistorySummaryTests.swift`

**Interfaces:**
- Consumes: `AgentSessionRecord` (`UsageTracker/Agents/AgentHistoryStore.swift`), `AgentSource` (`AgentModels.swift`), `TimeRange` (`UsageTracker/Core/DashboardState.swift`, `.seconds` gives the window length).
- Produces:
  ```swift
  struct AgentHistorySummary: Equatable {
      let sessions: Int
      let agentTime: TimeInterval
      let approvalsWaited: Int
      let busiestProject: (name: String, sessions: Int)?

      static func make(records: [AgentSessionRecord], source: AgentSource?, range: TimeRange, now: Date) -> AgentHistorySummary
      static func days(records: [AgentSessionRecord], source: AgentSource?, range: TimeRange, now: Date, calendar: Calendar) -> [(day: Date, records: [AgentSessionRecord])]
      static func dayTitle(_ day: Date, now: Date, calendar: Calendar) -> String
      static func duration(_ interval: TimeInterval) -> String
      static func inRange(_ records: [AgentSessionRecord], source: AgentSource?, range: TimeRange, now: Date) -> [AgentSessionRecord]
  }
  ```
  `busiestProject` is a tuple, so `Equatable` cannot be synthesised — `==` is written by hand (Step 3).

- [ ] **Step 1: Write the failing tests**

Create `UsageTrackerTests/AgentHistorySummaryTests.swift`:

```swift
import XCTest
@testable import Omelette

/// Everything the Agents tab shows is computed here, so every number and every
/// string on that screen is pinned by one of these cases. Dates are fixed epochs
/// and calendars carry an explicit time zone: "which day did this end on" is a
/// question with a different answer in every zone.
final class AgentHistorySummaryTests: XCTestCase {
    /// 2026-09-02 12:00:00 UTC — a Wednesday.
    private let now = Date(timeIntervalSince1970: 1_788_350_400)

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    private func record(
        id: String = "claude:s1",
        source: AgentSource = .claude,
        project: String = "Usage tracker",
        startedAt: TimeInterval,
        endedAt: TimeInterval,
        turns: Int = 4,
        needsYouCount: Int = 0
    ) -> AgentSessionRecord {
        AgentSessionRecord(
            id: id, source: source, project: project,
            startedAt: Date(timeIntervalSince1970: startedAt),
            endedAt: Date(timeIntervalSince1970: endedAt),
            turns: turns, needsYouCount: needsYouCount
        )
    }

    /// Ends 2026-09-02 09:30 UTC after 3h 12m.
    private var today: AgentSessionRecord {
        record(id: "claude:today", startedAt: 1_788_329_880, endedAt: 1_788_341_400, needsYouCount: 2)
    }
    /// Ends 2026-09-01 23:30 UTC — yesterday in UTC, today in Warsaw.
    private var lateYesterday: AgentSessionRecord {
        record(id: "claude:late", project: "Orion Gate", startedAt: 1_788_303_600, endedAt: 1_788_305_400)
    }
    /// Started 2026-09-01 23:40 UTC, ended 2026-09-02 00:20 UTC — crosses midnight.
    private var acrossMidnight: AgentSessionRecord {
        record(id: "codex:cross", source: .codex, project: "Jaravis", startedAt: 1_788_306_000, endedAt: 1_788_308_400)
    }
    /// Ends 2026-08-20 12:00 UTC — outside a 7-day window, inside 30d.
    private var old: AgentSessionRecord {
        record(id: "claude:old", project: "Ancient", startedAt: 1_787_223_600, endedAt: 1_787_227_200)
    }

    // MARK: - Range and source filtering

    func testOnlySessionsThatEndedInsideTheRangeCount() {
        let summary = AgentHistorySummary.make(
            records: [today, lateYesterday, old], source: nil, range: .sevenDays, now: now
        )
        XCTAssertEqual(summary.sessions, 2, "the 2026-08-20 session is 13 days old")
    }

    func testAWiderRangeLetsTheOldSessionBackIn() {
        let summary = AgentHistorySummary.make(
            records: [today, lateYesterday, old], source: nil, range: .thirtyDays, now: now
        )
        XCTAssertEqual(summary.sessions, 3)
    }

    func testTheRangeIsMeasuredFromEndedAtNotStartedAt() {
        // Started 8 days ago, ended 10 minutes ago: the run belongs to today.
        let marathon = record(id: "claude:long", startedAt: 1_787_659_200, endedAt: 1_788_349_800)
        let summary = AgentHistorySummary.make(records: [marathon], source: nil, range: .oneDay, now: now)
        XCTAssertEqual(summary.sessions, 1)
    }

    func testTheSourceFilterKeepsOnlyThatProvider() {
        let all = AgentHistorySummary.make(records: [today, acrossMidnight], source: nil, range: .sevenDays, now: now)
        let codex = AgentHistorySummary.make(records: [today, acrossMidnight], source: .codex, range: .sevenDays, now: now)
        XCTAssertEqual(all.sessions, 2)
        XCTAssertEqual(codex.sessions, 1)
        XCTAssertEqual(codex.approvalsWaited, 0)
    }

    // MARK: - The four tiles

    func testAgentTimeSumsEveryRunInRange() {
        let summary = AgentHistorySummary.make(
            records: [today, acrossMidnight], source: nil, range: .sevenDays, now: now
        )
        XCTAssertEqual(summary.agentTime, 11_520 + 2_400, accuracy: 0.5)
    }

    func testApprovalsWaitedSumsNeedsYouCounts() {
        let another = record(id: "claude:two", startedAt: 1_788_330_000, endedAt: 1_788_333_600, needsYouCount: 3)
        let summary = AgentHistorySummary.make(records: [today, another], source: nil, range: .sevenDays, now: now)
        XCTAssertEqual(summary.approvalsWaited, 5)
    }

    func testBusiestProjectCountsSessionsNotTime() {
        let a1 = record(id: "claude:a1", project: "alpha", startedAt: 1_788_330_000, endedAt: 1_788_330_600)
        let a2 = record(id: "claude:a2", project: "alpha", startedAt: 1_788_331_000, endedAt: 1_788_331_600)
        let b1 = record(id: "claude:b1", project: "beta", startedAt: 1_788_300_000, endedAt: 1_788_340_000)
        let summary = AgentHistorySummary.make(records: [b1, a1, a2], source: nil, range: .sevenDays, now: now)
        XCTAssertEqual(summary.busiestProject?.name, "alpha")
        XCTAssertEqual(summary.busiestProject?.sessions, 2)
    }

    func testATieGoesToTheProjectSeenFirst() {
        let b1 = record(id: "claude:b1", project: "beta", startedAt: 1_788_300_000, endedAt: 1_788_300_600)
        let a1 = record(id: "claude:a1", project: "alpha", startedAt: 1_788_301_000, endedAt: 1_788_301_600)
        let b2 = record(id: "claude:b2", project: "beta", startedAt: 1_788_302_000, endedAt: 1_788_302_600)
        let a2 = record(id: "claude:a2", project: "alpha", startedAt: 1_788_303_000, endedAt: 1_788_303_600)
        let summary = AgentHistorySummary.make(records: [b1, a1, b2, a2], source: nil, range: .sevenDays, now: now)
        XCTAssertEqual(summary.busiestProject?.name, "beta")
        XCTAssertEqual(summary.busiestProject?.sessions, 2)
    }

    func testNothingInRangeIsAllZeroes() {
        let summary = AgentHistorySummary.make(records: [old], source: nil, range: .oneDay, now: now)
        XCTAssertEqual(summary, AgentHistorySummary(sessions: 0, agentTime: 0, approvalsWaited: 0, busiestProject: nil))
    }

    // MARK: - Day grouping

    func testDaysAreNewestFirstAndRecordsInsideADayToo() {
        let earlier = record(id: "claude:early", startedAt: 1_788_318_000, endedAt: 1_788_321_600) // ends 04:00 UTC today
        let groups = AgentHistorySummary.days(
            records: [earlier, today, lateYesterday], source: nil, range: .sevenDays, now: now, calendar: utc
        )
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].day, Date(timeIntervalSince1970: 1_788_307_200)) // 2026-09-02 00:00 UTC
        XCTAssertEqual(groups[0].records.map(\.id), ["claude:today", "claude:early"])
        XCTAssertEqual(groups[1].records.map(\.id), ["claude:late"])
    }

    func testASessionThatCrossedMidnightIsFiledUnderTheDayItEnded() {
        let groups = AgentHistorySummary.days(
            records: [acrossMidnight], source: nil, range: .sevenDays, now: now, calendar: utc
        )
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].day, Date(timeIntervalSince1970: 1_788_307_200))
    }

    func testGroupingFollowsTheCalendarsTimeZone() {
        // 2026-09-01 23:30 UTC is 2026-09-02 01:30 in Warsaw: same instant, different day.
        var warsaw = Calendar(identifier: .gregorian)
        warsaw.timeZone = TimeZone(identifier: "Europe/Warsaw")!
        warsaw.locale = Locale(identifier: "en_US_POSIX")

        let inUTC = AgentHistorySummary.days(records: [lateYesterday], source: nil, range: .sevenDays, now: now, calendar: utc)
        let inWarsaw = AgentHistorySummary.days(records: [lateYesterday], source: nil, range: .sevenDays, now: now, calendar: warsaw)
        XCTAssertEqual(AgentHistorySummary.dayTitle(inUTC[0].day, now: now, calendar: utc), "Yesterday")
        XCTAssertEqual(AgentHistorySummary.dayTitle(inWarsaw[0].day, now: now, calendar: warsaw), "Today")
    }

    func testDSTDoesNotMergeOrSplitDays() {
        // Europe/Warsaw springs forward at 02:00 on 2026-03-29.
        var warsaw = Calendar(identifier: .gregorian)
        warsaw.timeZone = TimeZone(identifier: "Europe/Warsaw")!
        warsaw.locale = Locale(identifier: "en_US_POSIX")
        let before = record(id: "claude:before", startedAt: 1_774_735_200, endedAt: 1_774_737_000) // 28th, 23:30 local
        let after = record(id: "claude:after", startedAt: 1_774_747_200, endedAt: 1_774_747_800)   // 29th, 03:30 local
        let dstNow = Date(timeIntervalSince1970: 1_774_778_400)                                     // 29th, 12:00 local

        let groups = AgentHistorySummary.days(
            records: [before, after], source: nil, range: .sevenDays, now: dstNow, calendar: warsaw
        )
        XCTAssertEqual(groups.count, 2, "the short day is still one day")
        XCTAssertEqual(groups[0].records.map(\.id), ["claude:after"])
        XCTAssertEqual(AgentHistorySummary.dayTitle(groups[0].day, now: dstNow, calendar: warsaw), "Today")
        XCTAssertEqual(AgentHistorySummary.dayTitle(groups[1].day, now: dstNow, calendar: warsaw), "Yesterday")
    }

    func testAnOlderDayReadsAsWeekdayDayMonth() {
        let monday = AgentHistorySummary.days(
            records: [record(id: "claude:mon", startedAt: 1_788_166_800, endedAt: 1_788_170_400)],
            source: nil, range: .sevenDays, now: now, calendar: utc
        )[0].day
        XCTAssertEqual(AgentHistorySummary.dayTitle(monday, now: now, calendar: utc), "Mon 31 Aug")
    }

    // MARK: - Duration strings

    func testDurationReadsAsHoursAndMinutes() {
        XCTAssertEqual(AgentHistorySummary.duration(11_520), "3h 12m")
    }

    func testDurationPadsMinutesUnderTenLikeTheLiveRows() {
        XCTAssertEqual(AgentHistorySummary.duration(11_100), "3h 05m")
    }

    func testDurationUnderAnHourIsMinutesOnly() {
        XCTAssertEqual(AgentHistorySummary.duration(2_700), "45m")
        XCTAssertEqual(AgentHistorySummary.duration(3_599), "59m")
    }

    func testAnythingUnderAMinuteIsTheFloorMarker() {
        XCTAssertEqual(AgentHistorySummary.duration(59), "<1m")
        XCTAssertEqual(AgentHistorySummary.duration(0), "<1m")
        XCTAssertEqual(AgentHistorySummary.duration(-30), "<1m", "a clock that stepped back is not negative time")
    }

    func testAnExactHourKeepsItsZeroMinutes() {
        XCTAssertEqual(AgentHistorySummary.duration(3_600), "1h 00m")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodegen generate
xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/AgentHistorySummaryTests ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS=""
```
Expected: `** TEST FAILED **` — compile errors, `cannot find 'AgentHistorySummary' in scope`.

- [ ] **Step 3: Write the implementation**

Create `UsageTracker/Agents/AgentHistorySummary.swift`:

```swift
import Foundation

/// What the dashboard's Agents tab says about finished sessions: the four summary
/// tiles, the day grouping under them, and the strings both use.
///
/// Pure and static on purpose — the screen is a renderer, and every rule here
/// ("which day did this end on", "does a tie go to alpha or beta") is a decision
/// that deserves a test rather than a preview.
struct AgentHistorySummary: Equatable {
    let sessions: Int
    let agentTime: TimeInterval
    let approvalsWaited: Int
    /// nil when nothing is in range. A tuple, so `Equatable` is written by hand below.
    let busiestProject: (name: String, sessions: Int)?

    static func == (lhs: AgentHistorySummary, rhs: AgentHistorySummary) -> Bool {
        lhs.sessions == rhs.sessions
            && lhs.agentTime == rhs.agentTime
            && lhs.approvalsWaited == rhs.approvalsWaited
            && lhs.busiestProject?.name == rhs.busiestProject?.name
            && lhs.busiestProject?.sessions == rhs.busiestProject?.sessions
    }

    /// Records the tab is about: ended inside the range, from the chosen source
    /// (`nil` = every source).
    ///
    /// The window is measured from `endedAt`, not `startedAt`: a run that began last
    /// week and finished ten minutes ago is something you did today. There is no upper
    /// bound — a record stamped slightly in the future by a clock adjustment should
    /// show up, not vanish.
    static func inRange(
        _ records: [AgentSessionRecord],
        source: AgentSource?,
        range: TimeRange,
        now: Date
    ) -> [AgentSessionRecord] {
        let cutoff = now.addingTimeInterval(-range.seconds)
        return records.filter { record in
            record.endedAt >= cutoff && (source == nil || record.source == source)
        }
    }

    static func make(
        records: [AgentSessionRecord],
        source: AgentSource?,
        range: TimeRange,
        now: Date
    ) -> AgentHistorySummary {
        let scoped = inRange(records, source: source, range: range, now: now)

        var time: TimeInterval = 0
        var approvals = 0
        // Counted in log order so a tie resolves to whichever project was seen first.
        var counts: [String: Int] = [:]
        var order: [String] = []
        for record in scoped {
            time += max(0, record.endedAt.timeIntervalSince(record.startedAt))
            approvals += record.needsYouCount
            if counts[record.project] == nil { order.append(record.project) }
            counts[record.project, default: 0] += 1
        }

        var busiest: (name: String, sessions: Int)?
        for name in order {
            let count = counts[name] ?? 0
            if count > (busiest?.sessions ?? 0) { busiest = (name, count) }
        }

        return AgentHistorySummary(
            sessions: scoped.count,
            agentTime: time,
            approvalsWaited: approvals,
            busiestProject: busiest
        )
    }

    /// The history list: one entry per day that has records, newest day first, and the
    /// newest session first inside each day. Grouped by the day the session *ended*, so
    /// an overnight run appears once, on the morning it finished.
    static func days(
        records: [AgentSessionRecord],
        source: AgentSource?,
        range: TimeRange,
        now: Date,
        calendar: Calendar
    ) -> [(day: Date, records: [AgentSessionRecord])] {
        let scoped = inRange(records, source: source, range: range, now: now)
            .sorted { $0.endedAt > $1.endedAt }
        var days: [(day: Date, records: [AgentSessionRecord])] = []
        for record in scoped {
            let day = calendar.startOfDay(for: record.endedAt)
            if let index = days.firstIndex(where: { $0.day == day }) {
                days[index].records.append(record)
            } else {
                days.append((day: day, records: [record]))
            }
        }
        return days
    }

    /// "Today" / "Yesterday" / "Mon 1 Sep". The weekday form is pinned to
    /// `en_US_POSIX` and to the calendar's own zone: the app's strings are English,
    /// and a title has to name the same day the grouping used.
    static func dayTitle(_ day: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        // Built per call rather than cached: a section header asks once per day shown,
        // and a shared mutable formatter would have to be locked (this is nonisolated).
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE d MMM"
        return formatter.string(from: day)
    }

    /// "3h 12m" / "45m" / "<1m". Minutes are zero-padded inside an hours string to
    /// match `AgentRowText.elapsed`, which draws the live rows on the same screen.
    static func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, interval)
        if seconds < 60 { return "<1m" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        return String(format: "%dh %02dm", minutes / 60, minutes % 60)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
xcodegen generate
xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/AgentHistorySummaryTests ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS=""
```
Expected: `** TEST SUCCEEDED **`, 19 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add UsageTracker/Agents/AgentHistorySummary.swift UsageTrackerTests/AgentHistorySummaryTests.swift
git commit -m "Agents: AgentHistorySummary — range, source, day grouping, durations

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

## Task 3: `AgentHistoryStore.rotate(keepDays:now:)`

The agent log is append-only and nothing has ever trimmed it. This mirrors `HistoryStore`'s 90-day rotation (`HistoryStore.swift:236-275`): keep what is inside the window, rewrite atomically, and only when there is something to change.

**Files:**
- Modify: `UsageTracker/Agents/AgentHistoryStore.swift:6` (`AgentSessionRecord` gains `Sendable`), `:65-74` (`load()` gets a shared parse pass), and append `rotate`
- Test: `UsageTrackerTests/AgentHistoryStoreTests.swift` (append cases; keep the existing ones untouched)

**Interfaces:**
- Consumes: `AgentSessionRecord`.
- Produces: `func rotate(keepDays: Int = 90, now: Date = Date()) throws` on `AgentHistoryStore`.

- [ ] **Step 1: Write the failing tests**

Append these to `final class AgentHistoryStoreTests` in `UsageTrackerTests/AgentHistoryStoreTests.swift`, above the closing brace (the `record(...)` helper and the private `String.appendTo` extension already in that file are reused):

```swift
    // MARK: - Rotation

    /// 2026-09-02 12:00:00 UTC.
    private var rotationNow: Date { Date(timeIntervalSince1970: 1_788_350_400) }

    func testRotationKeepsRecordsInsideTheWindow() throws {
        let store = AgentHistoryStore(fileURL: fileURL)
        // 2026-08-01 12:00 UTC — 32 days old, comfortably inside 90.
        try store.append(record(id: "claude:recent", endedAt: Date(timeIntervalSince1970: 1_785_585_600)))
        try store.rotate(keepDays: 90, now: rotationNow)
        XCTAssertEqual(try store.load().map(\.id), ["claude:recent"])
    }

    func testRotationDropsRecordsOlderThanTheWindow() throws {
        let store = AgentHistoryStore(fileURL: fileURL)
        // 2026-01-01 12:00 UTC — 244 days old.
        try store.append(record(id: "claude:ancient", endedAt: Date(timeIntervalSince1970: 1_767_268_800)))
        try store.append(record(id: "claude:recent", endedAt: Date(timeIntervalSince1970: 1_785_585_600)))
        try store.rotate(keepDays: 90, now: rotationNow)
        XCTAssertEqual(try store.load().map(\.id), ["claude:recent"])
    }

    func testRotationIsMeasuredFromEndedAt() {
        // A session that started before the window but ended inside it is kept.
        let store = AgentHistoryStore(fileURL: fileURL)
        XCTAssertNoThrow(try store.append(record(
            id: "claude:marathon",
            startedAt: Date(timeIntervalSince1970: 1_767_268_800),
            endedAt: Date(timeIntervalSince1970: 1_788_000_000)
        )))
        XCTAssertNoThrow(try store.rotate(keepDays: 90, now: rotationNow))
        XCTAssertEqual(try? store.load().map(\.id), ["claude:marathon"])
    }

    func testRotationDropsACorruptLineWithoutLosingTheGoodOnes() throws {
        let store = AgentHistoryStore(fileURL: fileURL)
        try store.append(record(id: "claude:good1", endedAt: Date(timeIntervalSince1970: 1_785_585_600)))
        try "{not json at all\n".appendTo(fileURL)
        try store.append(record(id: "claude:good2", endedAt: Date(timeIntervalSince1970: 1_785_589_200)))

        try store.rotate(keepDays: 90, now: rotationNow)

        let text = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(text.contains("not json"), "the rewrite is what finally clears it out")
        XCTAssertEqual(try store.load().map(\.id), ["claude:good1", "claude:good2"])
    }

    func testRotationLeavesAHealthyLogByteIdentical() throws {
        let store = AgentHistoryStore(fileURL: fileURL)
        try store.append(record(id: "claude:recent", endedAt: Date(timeIntervalSince1970: 1_785_585_600)))
        let before = try Data(contentsOf: fileURL)

        try store.rotate(keepDays: 90, now: rotationNow)

        XCTAssertEqual(try Data(contentsOf: fileURL), before, "nothing to drop means nothing to write")
    }

    func testRotatingAMissingLogDoesNothingAndCreatesNoFile() throws {
        let store = AgentHistoryStore(fileURL: fileURL)
        XCTAssertNoThrow(try store.rotate(keepDays: 90, now: rotationNow))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testRotationCanEmptyTheLogEntirely() throws {
        let store = AgentHistoryStore(fileURL: fileURL)
        try store.append(record(id: "claude:ancient", endedAt: Date(timeIntervalSince1970: 1_767_268_800)))
        try store.rotate(keepDays: 90, now: rotationNow)
        XCTAssertEqual(try store.load(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path), "an empty log is still a log")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/AgentHistoryStoreTests ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS=""
```
Expected: `** TEST FAILED **` — `value of type 'AgentHistoryStore' has no member 'rotate'`.

- [ ] **Step 3: Write the implementation**

In `UsageTracker/Agents/AgentHistoryStore.swift`, first mark the record `Sendable` — it now crosses a task boundary in both `AgentChannel` (Task 4) and `DashboardState` (Task 5), and `HistoryRecord` next door already declares it:

```swift
struct AgentSessionRecord: Codable, Equatable, Sendable {
```

Then replace `load()` with the shared parse pass and add `rotate`:

```swift
    func load() throws -> [AgentSessionRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return parse(try Data(contentsOf: fileURL)).records
    }

    /// Trims the log to the last `keepDays` of finished sessions, the same 90-day
    /// window `HistoryStore` keeps for usage points. Records are kept on `endedAt`:
    /// a run that started before the window but finished inside it is recent work.
    ///
    /// The rewrite is atomic and happens only when there is something to change — a
    /// dropped record or a corrupt line — so the common launch touches no bytes at all.
    /// A missing file is a no-op: rotation must never be what creates the log.
    func rotate(keepDays: Int = 90, now: Date = Date()) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let parsed = parse(try Data(contentsOf: fileURL))
        let cutoff = now.addingTimeInterval(-Double(keepDays) * 24 * 3600)
        let kept = parsed.records.filter { $0.endedAt >= cutoff }
        guard kept.count != parsed.records.count || parsed.corrupt > 0 else { return }

        var data = Data()
        for record in kept {
            guard let line = try? encoder.encode(record) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        try data.write(to: fileURL, options: [.atomic])
    }

    /// One line per record; a line that fails to decode is counted and skipped rather
    /// than discarding everything after it.
    private func parse(_ data: Data) -> (records: [AgentSessionRecord], corrupt: Int) {
        var records: [AgentSessionRecord] = []
        var corrupt = 0
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            if let record = try? decoder.decode(AgentSessionRecord.self, from: Data(line)) {
                records.append(record)
            } else {
                corrupt += 1
            }
        }
        return (records, corrupt)
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/AgentHistoryStoreTests ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS=""
```
Expected: `** TEST SUCCEEDED **`, 13 tests (6 pre-existing + 7 new), 0 failures.

- [ ] **Step 5: Commit**

```bash
git add UsageTracker/Agents/AgentHistoryStore.swift UsageTrackerTests/AgentHistoryStoreTests.swift
git commit -m "Agents: rotate the session log to 90 days, atomically

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

## Task 4: Rotate once per launch from `AgentChannel.start()`

Same place the helper symlink is refreshed, on a detached utility task so a large log never delays the socket coming up.

**Files:**
- Modify: `UsageTracker/Agents/AgentChannel.swift:25-50`
- Test: `UsageTrackerTests/AgentChannelTests.swift`

**Interfaces:**
- Consumes: `AgentHistoryStore.rotate(keepDays:now:)` (Task 3), `AgentPaths.historyURL`.
- Produces: `func start(socketURL: URL = AgentPaths.socketURL, refreshSymlink: Bool = true, historyURL: URL = AgentPaths.historyURL)` — one new parameter with a default, so `UsageTrackerApp.swift:57`'s `AgentChannel.shared.start()` is unchanged.

- [ ] **Step 1: Write the failing test**

Append to `final class AgentChannelTests` in `UsageTrackerTests/AgentChannelTests.swift`:

```swift
    func testStartRotatesTheSessionLogInTheBackground() throws {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentChannelRotation-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: logURL) }

        let store = AgentHistoryStore(fileURL: logURL)
        // 2024-01-01 — years outside any 90-day window.
        try store.append(AgentSessionRecord(
            id: "claude:ancient", source: .claude, project: "Ancient",
            startedAt: Date(timeIntervalSince1970: 1_704_100_000),
            endedAt: Date(timeIntervalSince1970: 1_704_103_600),
            turns: 2, needsYouCount: 0
        ))
        try store.append(AgentSessionRecord(
            id: "claude:fresh", source: .claude, project: "Fresh",
            startedAt: Date().addingTimeInterval(-3600), endedAt: Date(),
            turns: 2, needsYouCount: 0
        ))

        channel.start(socketURL: socketURL, refreshSymlink: false, historyURL: logURL)

        // The rotation is detached, so poll the main run loop instead of assuming it ran.
        XCTAssertTrue(waitOnMain { ((try? store.load()) ?? []).map(\.id) == ["claude:fresh"] })
    }
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/AgentChannelTests ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS=""
```
Expected: `** TEST FAILED **` — `extra argument 'historyURL' in call`.

- [ ] **Step 3: Write the implementation**

In `UsageTracker/Agents/AgentChannel.swift`, replace the signature and insert the rotation right after the symlink block:

```swift
    func start(
        socketURL: URL = AgentPaths.socketURL,
        refreshSymlink: Bool = true,
        historyURL: URL = AgentPaths.historyURL
    ) {
        if refreshSymlink {
            do {
                try AgentPaths.refreshHelperSymlink()
            } catch {
                // Hooks keep pointing at the old symlink target; Settings → Agents shows "outdated".
                NSLog("[UT] helper symlink refresh failed: %@", String(describing: error))
            }
        }
        // Once per launch, off the main actor: the run history is append-only, and
        // trimming it here is the only thing that keeps `agent-sessions.jsonl` from
        // growing forever. Detached because a long log must not delay the socket.
        Task.detached(priority: .utility) {
            do {
                try AgentHistoryStore(fileURL: historyURL).rotate()
            } catch {
                NSLog("[UT] agent history rotation failed: %@", String(describing: error))
            }
        }
        guard server == nil else { return }
```

(The rest of `start()` — the `AgentEventServer` construction and the `do/catch` around `server.start()` — is unchanged.)

- [ ] **Step 4: Run the test to verify it passes**

```bash
xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/AgentChannelTests ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS=""
```
Expected: `** TEST SUCCEEDED **`, 6 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add UsageTracker/Agents/AgentChannel.swift UsageTrackerTests/AgentChannelTests.swift
git commit -m "Agents: rotate the run history once per launch

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

## Task 5: `DashboardState.agentRecords`

The Agents tab reads the log through the same state object every other tab uses, loaded off-main by `refreshAll()`.

**Files:**
- Modify: `UsageTracker/Core/DashboardState.swift:65-84` (property), `:115-122` (`clearProviderScopedState`, comment only), `:212-221` (`refreshAll`), and append `refreshAgentHistory`
- Test: `UsageTrackerTests/DashboardAgentRecordsTests.swift`

**Interfaces:**
- Consumes: `AgentHistoryStore(fileURL:).load()`, `AgentPaths.historyURL`, `AgentSessionRecord`.
- Produces:
  ```swift
  @Published private(set) var agentRecords: [AgentSessionRecord]   // on DashboardState
  func refreshAgentHistory(historyURL: URL = AgentPaths.historyURL) async
  ```

- [ ] **Step 1: Write the failing tests**

Create `UsageTrackerTests/DashboardAgentRecordsTests.swift`:

```swift
import XCTest
@testable import Omelette

/// The dashboard's copy of the agent run history. `DashboardState` is a main-actor
/// singleton, so these drive `.shared` directly and hand it a temp log — the same
/// injection point `AgentSessionStore` uses in its own tests.
@MainActor
final class DashboardAgentRecordsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DashboardAgentRecords-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func record(_ id: String) -> AgentSessionRecord {
        AgentSessionRecord(
            id: id, source: .claude, project: "Usage tracker",
            startedAt: Date(timeIntervalSince1970: 1_788_329_880),
            endedAt: Date(timeIntervalSince1970: 1_788_341_400),
            turns: 4, needsYouCount: 1
        )
    }

    func testTheLogIsPublishedAsAgentRecords() async throws {
        let url = directory.appendingPathComponent("agent-sessions.jsonl")
        let store = AgentHistoryStore(fileURL: url)
        try store.append(record("claude:s1"))
        try store.append(record("claude:s2"))

        await DashboardState.shared.refreshAgentHistory(historyURL: url)

        XCTAssertEqual(DashboardState.shared.agentRecords.map(\.id), ["claude:s1", "claude:s2"])
    }

    func testAMissingLogPublishesNothingRatherThanFailing() async throws {
        let url = directory.appendingPathComponent("does-not-exist.jsonl")
        await DashboardState.shared.refreshAgentHistory(historyURL: url)
        XCTAssertEqual(DashboardState.shared.agentRecords, [])
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodegen generate
xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/DashboardAgentRecordsTests ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS=""
```
Expected: `** TEST FAILED **` — `value of type 'DashboardState' has no member 'refreshAgentHistory'`.

- [ ] **Step 3: Add the published property**

In `UsageTracker/Core/DashboardState.swift`, after `@Published private(set) var isLoadingHistory = false`:

```swift
    /// Finished agent sessions, for the dashboard's Agents tab. Not provider-scoped —
    /// an agent run belongs to Claude Code or Codex, not to the usage provider the
    /// picker is on — so switching providers neither clears nor reloads it.
    @Published private(set) var agentRecords: [AgentSessionRecord] = []
```

And extend the doc comment on `clearProviderScopedState()` so the omission is deliberate rather than an oversight:

```swift
    /// Everything on screen that belongs to one provider and no other. `agentRecords`
    /// is deliberately absent: agent runs are not a provider's data.
    private func clearProviderScopedState() {
```

- [ ] **Step 4: Load it in `refreshAll()`**

Replace the body of `refreshAll()`:

```swift
    func refreshAll() {
        refreshGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshHistory()
            await self.refreshCLI()
            await self.refreshDerived()
            // Last: the usage charts are what the window opens on, and the agent log
            // is a separate file nothing else on screen is waiting for.
            await self.refreshAgentHistory()
        }
    }
```

And append the loader next to `refreshSessionWindow()` (before the closing brace of the class):

```swift
    /// Reads `agent-sessions.jsonl` off the main actor. Guarded by the generation
    /// alone, not `canPublish(_:)`: the log is not provider-scoped, so a pass started
    /// under another provider's tab still holds the right answer.
    func refreshAgentHistory(historyURL: URL = AgentPaths.historyURL) async {
        let generation = refreshGeneration
        let loaded = await Task.detached(priority: .utility) { () -> [AgentSessionRecord] in
            (try? AgentHistoryStore(fileURL: historyURL).load()) ?? []
        }.value
        guard refreshGeneration == generation, !Task.isCancelled else { return }
        agentRecords = loaded
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/DashboardAgentRecordsTests ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS=""
```
Expected: `** TEST SUCCEEDED **`, 2 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add UsageTracker/Core/DashboardState.swift UsageTrackerTests/DashboardAgentRecordsTests.swift
git commit -m "Dashboard: load the agent run history into DashboardState

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

## Task 6: `OMAgentHistoryRow`

One finished session: provider icon, project, the time it started, how long it ran, turns, and an approvals marker.

**Files:**
- Create: `UsageTracker/UI/DesignSystem/OMAgentHistoryRow.swift`
- Test: `UsageTrackerTests/AgentsHistoryViewTests.swift` (this task adds the row half; Task 7 appends the source-tab half)

**Interfaces:**
- Consumes: `AgentSessionRecord`, `AgentHistorySummary.duration(_:)` (Task 2), `AgentRowText.sourceName(_:)`, `ProviderIconView(serviceID:sfFallback:size:)`, `OMFont`, `OMSpacing`, `OMRadius.row`, `OMSurface.row`, `OMAgentColor.needsYou`.
- Produces:
  ```swift
  struct OMAgentHistoryRow: View {
      let record: AgentSessionRecord
      nonisolated static func turnsText(_ turns: Int) -> String            // "1 turn" / "4 turns"
      nonisolated static func approvalsText(_ count: Int) -> String?       // "⚠︎ 2", nil at zero
      nonisolated static func accessibilityLabel(for record: AgentSessionRecord, startedAt: String) -> String
  }
  ```

- [ ] **Step 1: Write the failing tests**

Create `UsageTrackerTests/AgentsHistoryViewTests.swift`:

```swift
import XCTest
@testable import Omelette

/// The strings on the Agents tab's history rows. `View` statics are `nonisolated`
/// so the test can call them without hopping to the main actor.
final class OMAgentHistoryRowTests: XCTestCase {
    private func record(turns: Int = 4, needsYouCount: Int = 0) -> AgentSessionRecord {
        AgentSessionRecord(
            id: "claude:s1", source: .claude, project: "Usage tracker",
            startedAt: Date(timeIntervalSince1970: 1_788_329_880),
            endedAt: Date(timeIntervalSince1970: 1_788_341_400),
            turns: turns, needsYouCount: needsYouCount
        )
    }

    func testTurnsArePluralised() {
        XCTAssertEqual(OMAgentHistoryRow.turnsText(0), "0 turns")
        XCTAssertEqual(OMAgentHistoryRow.turnsText(1), "1 turn")
        XCTAssertEqual(OMAgentHistoryRow.turnsText(9), "9 turns")
    }

    func testApprovalsOnlyShowWhenThereWereAny() {
        XCTAssertNil(OMAgentHistoryRow.approvalsText(0))
        XCTAssertEqual(OMAgentHistoryRow.approvalsText(1), "⚠︎ 1")
        XCTAssertEqual(OMAgentHistoryRow.approvalsText(3), "⚠︎ 3")
    }

    func testTheSpokenLabelCarriesEverythingTheRowShows() {
        let label = OMAgentHistoryRow.accessibilityLabel(for: record(needsYouCount: 2), startedAt: "09:18")
        XCTAssertEqual(
            label,
            "Usage tracker, Claude Code, started 09:18, ran 3h 12m, 4 turns, 2 approvals waited"
        )
    }

    func testASessionWithNoApprovalsSaysNothingAboutThem() {
        let label = OMAgentHistoryRow.accessibilityLabel(for: record(turns: 1), startedAt: "09:18")
        XCTAssertEqual(label, "Usage tracker, Claude Code, started 09:18, ran 3h 12m, 1 turn")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodegen generate
xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/OMAgentHistoryRowTests ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS=""
```
Expected: `** TEST FAILED **` — `cannot find 'OMAgentHistoryRow' in scope`.

- [ ] **Step 3: Write the implementation**

Create `UsageTracker/UI/DesignSystem/OMAgentHistoryRow.swift`:

```swift
import SwiftUI

/// One finished agent session in the dashboard's history list. The live counterpart
/// is `OMAgentRow`; this one is deliberately quieter — nothing here is still moving,
/// so there is no state dot, no pulse and no ticking clock.
struct OMAgentHistoryRow: View {
    let record: AgentSessionRecord

    /// Rendered through the machine's own clock format: "14:20" is the wrong answer
    /// on a Mac that shows 2:20 PM everywhere else (same rule as `InsightsView`).
    private var startedAt: String {
        record.startedAt.formatted(date: .omitted, time: .shortened)
    }

    var body: some View {
        HStack(spacing: OMSpacing.s + 1) {
            ProviderIconView(
                serviceID: record.source.rawValue,
                sfFallback: Self.sfFallback(record.source),
                size: 18
            )
            .foregroundStyle(.secondary)
            .frame(width: 20, height: 20)

            Text(record.project)
                .font(OMFont.bodyStrong)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: OMSpacing.s)

            if let approvals = Self.approvalsText(record.needsYouCount) {
                Text(approvals)
                    .font(OMFont.caption)
                    .monospacedDigit()
                    .foregroundStyle(OMAgentColor.needsYou)
                    .help("Waited for you \(record.needsYouCount) time\(record.needsYouCount == 1 ? "" : "s")")
            }
            Text(Self.turnsText(record.turns))
                .font(OMFont.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 64, alignment: .trailing)
            Text(AgentHistorySummary.duration(record.endedAt.timeIntervalSince(record.startedAt)))
                .font(OMFont.numeral)
                .monospacedDigit()
                .frame(width: 68, alignment: .trailing)
            Text(startedAt)
                .font(OMFont.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: OMRadius.row, style: .continuous).fill(OMSurface.row))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(for: record, startedAt: startedAt))
    }

    nonisolated static func turnsText(_ turns: Int) -> String {
        "\(turns) turn\(turns == 1 ? "" : "s")"
    }

    /// nil at zero: a marker that is always there stops meaning anything.
    nonisolated static func approvalsText(_ count: Int) -> String? {
        count > 0 ? "⚠︎ \(count)" : nil
    }

    /// VoiceOver reads the glyphs and the columns as one sentence.
    nonisolated static func accessibilityLabel(for record: AgentSessionRecord, startedAt: String) -> String {
        var parts = [
            record.project,
            AgentRowText.sourceName(record.source),
            "started \(startedAt)",
            "ran \(AgentHistorySummary.duration(record.endedAt.timeIntervalSince(record.startedAt)))",
            turnsText(record.turns)
        ]
        if record.needsYouCount > 0 {
            parts.append("\(record.needsYouCount) approval\(record.needsYouCount == 1 ? "" : "s") waited")
        }
        return parts.joined(separator: ", ")
    }

    /// Both sources ship a bundled logo; these only matter to a stripped catalog.
    nonisolated private static func sfFallback(_ source: AgentSource) -> String {
        switch source {
        case .claude: return "sparkles"
        case .codex: return "terminal"
        }
    }
}

#if DEBUG
@MainActor
private func historyRowPreviewStack() -> some View {
    func record(_ project: String, source: AgentSource, minutes: Double, turns: Int, needsYou: Int) -> AgentSessionRecord {
        let ended = Date(timeIntervalSince1970: 1_788_341_400)
        return AgentSessionRecord(
            id: "\(source.rawValue):\(project)", source: source, project: project,
            startedAt: ended.addingTimeInterval(-minutes * 60), endedAt: ended,
            turns: turns, needsYouCount: needsYou
        )
    }
    return VStack(spacing: 5) {
        OMAgentHistoryRow(record: record("Usage tracker", source: .claude, minutes: 192, turns: 14, needsYou: 2))
        OMAgentHistoryRow(record: record("Orion Gate / mobile-app", source: .claude, minutes: 45, turns: 1, needsYou: 0))
        OMAgentHistoryRow(record: record("orion-gemini", source: .codex, minutes: 0.5, turns: 3, needsYou: 0))
    }
    .padding()
    .frame(width: 560)
}

#Preview("History rows — light") { historyRowPreviewStack() }
#Preview("History rows — dark") { historyRowPreviewStack().preferredColorScheme(.dark) }
#endif
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
xcodegen generate
xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/OMAgentHistoryRowTests ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS=""
```
Expected: `** TEST SUCCEEDED **`, 4 tests, 0 failures.

- [ ] **Step 5: Check both previews**

Open `UsageTracker/UI/DesignSystem/OMAgentHistoryRow.swift` in Xcode, resume the canvas, and confirm the light and dark previews: columns line up, the amber `⚠︎ 2` only appears on the first row, the 30-second run reads `<1m`.

- [ ] **Step 6: Commit**

```bash
git add UsageTracker/UI/DesignSystem/OMAgentHistoryRow.swift UsageTrackerTests/AgentsHistoryViewTests.swift
git commit -m "Design system: OMAgentHistoryRow for finished sessions

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

## Task 7: The Agents tab

Source filter, four summary tiles, the live section, and the history grouped by day.

**Files:**
- Create: `UsageTracker/UI/Dashboard/AgentsHistoryView.swift`
- Modify: `UsageTracker/UI/Dashboard/DashboardWindow.swift:8-23` (the `Tab` enum), `:67-79` (`content`)
- Test: `UsageTrackerTests/AgentsHistoryViewTests.swift` (append the source-tab class)

**Interfaces:**
- Consumes: `AgentHistorySummary.make/days/dayTitle/duration` (Task 2), `OMAgentHistoryRow` (Task 6), `DashboardState.agentRecords` + `range` (Task 5), `DashboardHeader(title:subtitle:trailing:showsServicePicker:)` (Task 1), `RangePicker(range:)`, `OMSegmentedControl(items:selection:)`, `OMSegmentItem`, `AgentsSection(sessions:grouped:hooksInstalled:title:onEnable:)`, `AgentsSection.sessionsCaption(_:)`, `AgentSessionStore.shared.sessions`, `AgentHooksInstaller.claudeStatus(settingsURL:helperPath:)`, `AgentPaths.claudeSettingsURL` / `.helperSymlinkURL`.
- Produces:
  ```swift
  struct AgentsHistoryView: View {
      init(dashboard: DashboardState)
      nonisolated static func selectedSource(_ stored: String) -> AgentSource?   // "all"/junk → nil
      nonisolated static let sourceKey = "agentsHistorySource"
  }
  extension DashboardWindow.Tab { case agents }   // rawValue "Agents", icon "bolt.horizontal.circle"
  ```

- [ ] **Step 1: Write the failing tests**

Append to `UsageTrackerTests/AgentsHistoryViewTests.swift`:

```swift
/// The persisted source filter. The stored value is a raw string, so it has to
/// survive a value written by a future build (or a hand-edited defaults plist).
final class AgentsHistorySourceTests: XCTestCase {
    func testAllMeansNoFilter() {
        XCTAssertNil(AgentsHistoryView.selectedSource("all"))
    }

    func testAProviderIdSelectsThatSource() {
        XCTAssertEqual(AgentsHistoryView.selectedSource("claude"), .claude)
        XCTAssertEqual(AgentsHistoryView.selectedSource("codex"), .codex)
    }

    func testAnUnknownStoredValueFallsBackToAll() {
        XCTAssertNil(AgentsHistoryView.selectedSource("antigravity"))
        XCTAssertNil(AgentsHistoryView.selectedSource(""))
    }

    func testTheStoredKeyIsTheOneTheSpecFixed() {
        XCTAssertEqual(AgentsHistoryView.sourceKey, "agentsHistorySource")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/AgentsHistorySourceTests ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS=""
```
Expected: `** TEST FAILED **` — `cannot find 'AgentsHistoryView' in scope`.

- [ ] **Step 3: Write the view**

Create `UsageTracker/UI/Dashboard/AgentsHistoryView.swift`:

```swift
import SwiftUI

/// The dashboard's Agents tab: what is running right now, and what has finished
/// inside the selected range. Live rows come from `AgentSessionStore`; the history
/// comes from `agent-sessions.jsonl` via `DashboardState.agentRecords`.
struct AgentsHistoryView: View {
    @ObservedObject var dashboard: DashboardState
    @ObservedObject private var agents = AgentSessionStore.shared

    nonisolated static let sourceKey = "agentsHistorySource"

    @AppStorage(AgentsHistoryView.sourceKey) private var storedSource: String = "all"

    /// Only used for one caption in the empty state, so it is read once per
    /// appearance off the main thread (same pattern as `PopoverView`). Starts `true`
    /// so the caption never flashes before the read lands.
    @State private var claudeHooksInstalled = true

    /// nil = every source. An unknown stored value (a provider that never shipped, a
    /// hand-edited plist) reads as All rather than filtering everything away.
    nonisolated static func selectedSource(_ stored: String) -> AgentSource? {
        stored == "all" ? nil : AgentSource(rawValue: stored)
    }

    private var source: AgentSource? { Self.selectedSource(storedSource) }
    private var calendar: Calendar { Calendar.current }

    private var liveSessions: [AgentSession] {
        guard let source else { return agents.sessions }
        return agents.sessions.filter { $0.source == source }
    }

    var body: some View {
        // One clock for the whole pass: the tiles and the day titles must agree on
        // where "today" ends.
        let now = Date()
        let summary = AgentHistorySummary.make(
            records: dashboard.agentRecords, source: source, range: dashboard.range, now: now
        )
        let days = AgentHistorySummary.days(
            records: dashboard.agentRecords, source: source,
            range: dashboard.range, now: now, calendar: calendar
        )

        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                DashboardHeader(
                    title: "Agents",
                    subtitle: "Live sessions and run history",
                    trailing: AnyView(RangePicker(range: $dashboard.range)),
                    showsServicePicker: false
                )

                OMSegmentedControl(items: Self.sourceItems, selection: $storedSource)
                    .frame(width: 260)
                    .padding(.horizontal, 24)

                AgentsSummaryStrip(summary: summary)
                    .padding(.horizontal, 24)

                AgentsSection(
                    sessions: liveSessions,
                    grouped: true,
                    // The dashboard never nags about hooks — Settings → Agents owns that.
                    hooksInstalled: true,
                    title: "Live",
                    onEnable: {}
                )
                .padding(.horizontal, 24)

                history(days: days, now: now)
                    .padding(.horizontal, 24)

                Spacer(minLength: 24)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        // A session ending is what appends to the log, so the live list changing is
        // the cheapest signal that the history is stale. Also runs on first appearance.
        .task(id: agents.sessions.count) {
            await dashboard.refreshAgentHistory()
        }
        .task { await refreshHookStatus() }
    }

    private static let sourceItems = [
        OMSegmentItem(id: "all", title: "All"),
        OMSegmentItem(id: "claude", title: "Claude", serviceID: "claude"),
        OMSegmentItem(id: "codex", title: "Codex", serviceID: "codex", sfFallback: "terminal"),
    ]

    @ViewBuilder
    private func history(days: [(day: Date, records: [AgentSessionRecord])], now: Date) -> some View {
        VStack(alignment: .leading, spacing: OMSpacing.s) {
            OMSectionHeader(
                title: "History",
                trailing: days.isEmpty ? nil : AgentsSection.sessionsCaption(days.reduce(0) { $0 + $1.records.count })
            )
            if days.isEmpty {
                emptyHistory
            } else {
                ForEach(days, id: \.day) { group in
                    Text(AgentHistorySummary.dayTitle(group.day, now: now, calendar: calendar))
                        .font(OMFont.micro)
                        .textCase(.uppercase)
                        .tracking(0.5)
                        .foregroundStyle(.secondary)
                        .padding(.top, OMSpacing.xs)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(group.records, id: \.id) { record in
                        OMAgentHistoryRow(record: record)
                    }
                }
            }
        }
    }

    private var emptyHistory: some View {
        VStack(alignment: .leading, spacing: OMSpacing.xs) {
            Text("No finished sessions in this range")
                .font(OMFont.caption)
                .foregroundStyle(.secondary)
            if !claudeHooksInstalled {
                Text("Hooks give exact durations")
                    .font(OMFont.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: OMRadius.row, style: .continuous).fill(OMSurface.row))
    }

    private func refreshHookStatus() async {
        let settingsURL = AgentPaths.claudeSettingsURL
        let helperPath = AgentPaths.helperSymlinkURL.path
        let status = await Task.detached(priority: .utility) {
            AgentHooksInstaller.claudeStatus(settingsURL: settingsURL, helperPath: helperPath)
        }.value
        claudeHooksInstalled = status == .installed
    }
}

/// The four numbers above the lists: how many sessions, how long they ran in total,
/// how often they stopped to ask, and where the work happened.
private struct AgentsSummaryStrip: View {
    let summary: AgentHistorySummary

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            tile(label: "Sessions", value: "\(summary.sessions)", sub: nil)
            tile(label: "Agent time", value: AgentHistorySummary.duration(summary.agentTime), sub: nil)
            tile(label: "Approvals waited", value: "\(summary.approvalsWaited)", sub: nil)
            tile(
                label: "Busiest project",
                value: summary.busiestProject?.name ?? "—",
                sub: summary.busiestProject.map { AgentsSection.sessionsCaption($0.sessions) }
            )
        }
    }

    private func tile(label: String, value: String, sub: String?) -> some View {
        VStack(alignment: .leading, spacing: OMSpacing.xs) {
            Text(label)
                .font(OMFont.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(OMFont.heroNumeral)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
            Text(sub ?? " ")
                .font(OMFont.caption)
                .foregroundStyle(.tertiary)
                .opacity(sub == nil ? 0 : 1)
        }
        .dashboardCard(padding: 12)
    }
}

#if DEBUG
@MainActor
private func summaryStripPreview() -> some View {
    AgentsSummaryStrip(summary: AgentHistorySummary(
        sessions: 12,
        agentTime: 41_520,
        approvalsWaited: 7,
        busiestProject: (name: "Usage tracker", sessions: 5)
    ))
    .padding()
    .frame(width: 780)
}

#Preview("Agents summary — light") { summaryStripPreview() }
#Preview("Agents summary — dark") { summaryStripPreview().preferredColorScheme(.dark) }
#Preview("Agents summary — empty") {
    AgentsSummaryStrip(summary: AgentHistorySummary(sessions: 0, agentTime: 0, approvalsWaited: 0, busiestProject: nil))
        .padding()
        .frame(width: 780)
}
#endif
```

- [ ] **Step 4: Add the tab**

In `UsageTracker/UI/Dashboard/DashboardWindow.swift`, extend the enum (the new case goes straight after `overview`, which is where it appears in the sidebar — `Tab.allCases` follows declaration order):

```swift
    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case agents = "Agents"
        case activity = "Activity"
        case history = "History"
        case insights = "Insights"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .overview: return "chart.bar.doc.horizontal"
            case .agents: return "bolt.horizontal.circle"
            case .activity: return "square.grid.4x3.fill"
            case .history: return "clock"
            case .insights: return "lightbulb"
            }
        }
    }
```

and the switch in `content`:

```swift
        case .agents:
            AgentsHistoryView(dashboard: dashboard)
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
xcodegen generate
xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/AgentsHistorySourceTests ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS=""
```
Expected: `** TEST SUCCEEDED **`, 4 tests, 0 failures.

- [ ] **Step 6: Build and run the app**

```bash
xcodebuild -project UsageTracker.xcodeproj -scheme UsageTracker -configuration Debug -derivedDataPath build/DerivedData build
```
Expected: `** BUILD SUCCEEDED **`, no new warnings.

Then run from Xcode, open the dashboard → **Agents** and confirm: the tab is second in the sidebar with a bolt icon; the header has no provider picker but does have the range picker; the segmented control switches All/Claude/Codex and the choice survives a relaunch; with no history the four tiles read `0`, `<1m`, `0`, `—` and the History block shows "No finished sessions in this range".

- [ ] **Step 7: Commit**

```bash
git add UsageTracker/UI/Dashboard/AgentsHistoryView.swift UsageTracker/UI/Dashboard/DashboardWindow.swift UsageTrackerTests/AgentsHistoryViewTests.swift
git commit -m "Dashboard: Agents tab — live sessions and run history

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

## Task 8: `OverviewView` on the component kit

The hero becomes the popover's `OMHero` (same window selection, same verdict), the window list becomes `OMKeyValueRow`s, and the section labels become `OMSectionHeader`.

**Files:**
- Modify: `UsageTracker/UI/Dashboard/OverviewView.swift` (whole file — every private view in it changes)

**Interfaces:**
- Consumes: `OMHero(hero:verdict:)`, `OMRing(percent:size:pace:)`, `OMKeyValueRow(label:value:barPercent:)`, `OMSectionHeader(title:trailing:)`, `WindowRanking.detailHero(for:)`, `BurnVerdict.make(burn:sessionBuckets:now:)`, `OMFont`, `dashboardCard(padding:)`.
- Produces: nothing new — no other file reads `OverviewView`'s internals.

- [ ] **Step 1: Replace the hero and today cards**

In `UsageTracker/UI/Dashboard/OverviewView.swift`, replace `body`'s card row and both card properties. `burnCard` becomes `heroCard(service:)`, which uses `OMHero` when the provider has a window and keeps the old burn wording when it does not:

```swift
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                DashboardHeader(
                    title: service?.displayName ?? dashboard.displayName(for: dashboard.selectedService),
                    subtitle: service?.plan ?? "—"
                )

                HStack(alignment: .top, spacing: 16) {
                    heroCard
                    if dashboard.costSource.hasBreakdown { todayCard }
                }
                .padding(.horizontal, 24)

                if let service {
                    bucketsBlock(service: service)
                        .padding(.horizontal, 24)
                }

                if dashboard.costSource.hasBreakdown, let cli = dashboard.cliBreakdown {
                    cliBlock(cli: cli)
                        .padding(.horizontal, 24)
                }

                Spacer(minLength: 24)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    /// The provider tab's hero, reused verbatim: the session window when the provider
    /// has one, otherwise its most-constrained window, with the burn verdict under it.
    /// A provider with no windows at all (nothing polled yet) keeps the old burn-rate
    /// wording rather than showing an empty card.
    @ViewBuilder
    private var heroCard: some View {
        if let service, let hero = WindowRanking.detailHero(for: service) {
            OMHero(
                hero: hero,
                verdict: BurnVerdict.make(
                    burn: dashboard.sessionBurn,
                    sessionBuckets: service.buckets.filter { $0.kind == .session }
                )
            )
            .dashboardCard(padding: 14)
        } else {
            burnCard
        }
    }

    /// Titled after the window it actually predicts — with several providers a
    /// fixed "5-hour" was wrong for anyone whose leading window isn't five hours.
    private var burnCard: some View {
        let burn = dashboard.sessionBurn
        let bucket = dashboard.burnBucket
        let value: String = {
            guard let burn else { return "Not enough data" }
            guard let secs = burn.secondsToLimit else {
                if burn.percentPerMinute > 0 { return "Stable" }
                return "Idle"
            }
            return "Hit limit in \(formatDuration(secs))"
        }()

        return HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(bucket.map { "\($0.label) burn rate" } ?? "Burn rate")
                    .font(OMFont.body)
                    .foregroundStyle(.secondary)
                Text(value).font(OMFont.bodyStrong)
            }
            Spacer()
            OMRing(percent: bucket?.clampedPercent ?? 0, size: .medium)
        }
        .dashboardCard(padding: 14)
    }

    private var todayCard: some View {
        let cli = dashboard.cliBreakdown
        let cost = cli?.todayCost ?? 0
        let turns = cli?.todayTurns ?? 0
        let tokens = cli?.todayTokens ?? 0

        return VStack(alignment: .leading, spacing: 10) {
            Text("Today's CLI usage")
                .font(OMFont.body)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(format: "$%.2f", cost))
                    .font(OMFont.heroNumeral)
                    .monospacedDigit()
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("\(turns) turn\(turns == 1 ? "" : "s")")
                    .font(OMFont.body)
                    .foregroundStyle(.secondary)
            }
            Text("\(formatTokens(tokens)) tokens")
                .font(OMFont.caption)
                .foregroundStyle(.tertiary)
        }
        .dashboardCard(padding: 14)
    }
```

- [ ] **Step 2: Put the window list on `OMKeyValueRow` and `OMSectionHeader`**

Replace `bucketsBlock`, `cliBlock` and `stat` in the same file:

```swift
    private func bucketsBlock(service: ServiceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: OMSpacing.m) {
            OMSectionHeader(title: "Usage windows")
            ForEach(service.buckets) { b in
                // Same wording as before ("resets in 2h 15m" / "resets —"), now on the
                // component: the label, the reset time and the bar are one row.
                OMKeyValueRow(
                    label: b.label,
                    value: "resets \(formatRelative(b.resetsAt))",
                    barPercent: b.clampedPercent
                )
            }
        }
        .dashboardCard()
    }

    private func cliBlock(cli: CLIBreakdown) -> some View {
        VStack(alignment: .leading, spacing: OMSpacing.m) {
            HStack {
                OMSectionHeader(title: dashboard.costSource.shortName ?? "CLI")
                if dashboard.isLoadingCLI {
                    ProgressView().controlSize(.small)
                }
            }
            HStack(spacing: 24) {
                stat(label: "Today", value: String(format: "$%.2f", cli.todayCost), sub: "\(cli.todayTurns) turns")
                stat(label: "7d", value: String(format: "$%.2f", cli.weekCost), sub: nil)
                stat(label: "30d", value: String(format: "$%.2f", cli.monthCost), sub: nil)
            }
            if !cli.byModelToday.isEmpty {
                Divider()
                ForEach(cli.byModelToday.prefix(5), id: \.model) { entry in
                    OMKeyValueRow(label: entry.model, value: String(format: "$%.2f", entry.cost))
                }
            }
        }
        .dashboardCard()
    }

    private func stat(label: String, value: String, sub: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(OMFont.caption).foregroundStyle(.secondary)
            Text(value).font(OMFont.heroNumeral).monospacedDigit()
            if let sub { Text(sub).font(OMFont.caption).foregroundStyle(.tertiary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
```

`formatRelative(_:)` and `formatDuration(_:)` both stay — `bucketsBlock` and `burnCard` still call them, and their wording is what the Global Constraints protect. `formatTokens(_:)` stays too (`todayCard`).

- [ ] **Step 3: Build**

```bash
xcodebuild -project UsageTracker.xcodeproj -scheme UsageTracker -configuration Debug -derivedDataPath build/DerivedData build
```
Expected: `** BUILD SUCCEEDED **`, no `unused` or `never used` warnings.

- [ ] **Step 4: Run the whole suite — nothing here should move a test**

```bash
xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS=""
```
Expected: `** TEST SUCCEEDED **`, 0 failures.

- [ ] **Step 5: Eyeball Overview**

Run from Xcode, open the dashboard → Overview. Confirm: the hero card shows the big ring with the window name, "N left", the status phrase and (when the burn rate has one) the verdict line; the usage-window rows show a bar with the label above it; nothing overlaps at the 820 pt minimum width; switch to a provider with no session window (Grok/Gemini if signed in) and confirm the hero still renders.

- [ ] **Step 6: Commit**

```bash
git add UsageTracker/UI/Dashboard/OverviewView.swift
git commit -m "Dashboard: Overview on OMHero, OMKeyValueRow and OMSectionHeader

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

## Task 9: Recolour and re-type the three chart views

Charts and the heat map keep their structure. What changes: utilisation is coloured by `usageStatusColor`, cost stays `Color.accentColor`, headings become `OMSectionHeader`, numerals become `OMFont`.

**Files:**
- Modify: `UsageTracker/UI/Dashboard/ActivityGridView.swift:201-228` (cell + legend), `:269-281` (`GridCache` gains a flag), `:309-322` and `:352-377` (both builders set it)
- Modify: `UsageTracker/UI/Dashboard/InsightsView.swift:202-207`, `:213-224`, `:258-297`, `:299-318`
- Modify: `UsageTracker/UI/Dashboard/SessionHistoryView.swift:138-171`, `:233-257`
- Test: `UsageTrackerTests/ActivityGridColorTests.swift`

**Interfaces:**
- Consumes: `usageStatusColor(_:)`, `OMSectionHeader`, `OMFont`.
- Produces:
  ```swift
  extension ActivityGridView {
      nonisolated static func cellBase(intensity: Double, usesStatusColor: Bool, unobserved: Bool) -> Color
      nonisolated static func cellOpacity(intensity: Double, unobserved: Bool) -> Double
  }
  ```
  Split in two so both halves are testable with values that compare exactly — a
  `Color` carrying a computed opacity is awkward to assert against.

- [ ] **Step 1: Write the failing tests**

Create `UsageTrackerTests/ActivityGridColorTests.swift`:

```swift
import XCTest
import SwiftUI
@testable import Omelette

/// The heat map's colour rule. Dollars have no "too much" level, so they stay on one
/// accent ramp; a quota square is a utilisation and gets the battery colours, which is
/// what makes a 95 % day read as red instead of "a slightly darker blue".
final class ActivityGridColorTests: XCTestCase {
    func testCostSquaresStayOnTheAccentRamp() {
        XCTAssertEqual(ActivityGridView.cellBase(intensity: 0.5, usesStatusColor: false, unobserved: false), Color.accentColor)
        XCTAssertEqual(ActivityGridView.cellBase(intensity: 1.0, usesStatusColor: false, unobserved: false), Color.accentColor)
    }

    func testQuotaSquaresUseTheBatteryColours() {
        XCTAssertEqual(ActivityGridView.cellBase(intensity: 0.5, usesStatusColor: true, unobserved: false), Color.green)
        XCTAssertEqual(ActivityGridView.cellBase(intensity: 0.75, usesStatusColor: true, unobserved: false), Color.orange)
        XCTAssertEqual(ActivityGridView.cellBase(intensity: 0.95, usesStatusColor: true, unobserved: false), Color.red)
    }

    func testAnObservedZeroAndAnUnobservedDayAreBothGrey() {
        XCTAssertEqual(ActivityGridView.cellBase(intensity: 0, usesStatusColor: true, unobserved: false), Color.secondary)
        XCTAssertEqual(ActivityGridView.cellBase(intensity: 0.9, usesStatusColor: true, unobserved: true), Color.secondary)
    }

    func testAnUnobservedDayIsFainterThanAnEmptyOne() {
        XCTAssertEqual(ActivityGridView.cellOpacity(intensity: 0.9, unobserved: true), 0.05, accuracy: 0.0001)
        XCTAssertEqual(ActivityGridView.cellOpacity(intensity: 0, unobserved: false), 0.12, accuracy: 0.0001)
    }

    func testTheRampRunsFromAFifthToFull() {
        XCTAssertEqual(ActivityGridView.cellOpacity(intensity: 0.5, unobserved: false), 0.60, accuracy: 0.0001)
        XCTAssertEqual(ActivityGridView.cellOpacity(intensity: 1, unobserved: false), 1.00, accuracy: 0.0001)
    }

    func testIntensityIsClampedRatherThanTrusted() {
        XCTAssertEqual(ActivityGridView.cellOpacity(intensity: 4, unobserved: false), 1.00, accuracy: 0.0001)
        XCTAssertEqual(ActivityGridView.cellBase(intensity: -1, usesStatusColor: true, unobserved: false), Color.secondary)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodegen generate
xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/ActivityGridColorTests ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS=""
```
Expected: `** TEST FAILED **` — `type 'ActivityGridView' has no member 'cellBase'`.

- [ ] **Step 3: Implement the colour rule in `ActivityGridView`**

In `UsageTracker/UI/Dashboard/ActivityGridView.swift`, replace `cell(_:cache:)`, `color(for:unobserved:)` and `legend(_:)`:

```swift
    private func cell(_ day: Day, cache: GridCache) -> some View {
        let intensity = cache.scaleMax > 0 ? min(1.0, day.value / cache.scaleMax) : 0
        // A day the app never observed is not a day of no usage. Only the quota grid
        // can tell the two apart, so only it draws the difference.
        let unobserved = cache.dimsUnrecordedDays && !day.hasReading
        return RoundedRectangle(cornerRadius: 3)
            .fill(day.isFuture
                  ? Color.clear
                  : Self.cellBase(intensity: intensity, usesStatusColor: cache.usesStatusColor, unobserved: unobserved)
                      .opacity(Self.cellOpacity(intensity: intensity, unobserved: unobserved)))
            .frame(width: cellSize, height: cellSize)
            .help(day.tooltip)
    }

    /// The colour a square is built from. Dollars have no "too much" level, so cost
    /// stays on one accent ramp; a quota square *is* a utilisation, so it gets the
    /// battery colours and a day that ran at 95 % reads red.
    nonisolated static func cellBase(intensity: Double, usesStatusColor: Bool, unobserved: Bool) -> Color {
        if unobserved { return .secondary }
        let clamped = max(0, min(1, intensity))
        if clamped == 0 { return .secondary }
        return usesStatusColor ? usageStatusColor(clamped * 100) : .accentColor
    }

    /// A ghost for a day nothing was recorded, the empty-square grey for an observed
    /// zero, and a 0.20 → 1.00 ramp for everything else.
    nonisolated static func cellOpacity(intensity: Double, unobserved: Bool) -> Double {
        if unobserved { return 0.05 }
        let clamped = max(0, min(1, intensity))
        if clamped == 0 { return 0.12 }
        return 0.20 + clamped * 0.80
    }

    private func legend(_ c: GridCache) -> some View {
        HStack(spacing: 6) {
            Text(c.legendLow).font(OMFont.caption).foregroundStyle(.secondary)
            ForEach(0..<5, id: \.self) { i in
                let intensity = Double(i) / 4.0
                RoundedRectangle(cornerRadius: 3)
                    .fill(Self.cellBase(intensity: intensity, usesStatusColor: c.usesStatusColor, unobserved: false)
                        .opacity(Self.cellOpacity(intensity: intensity, unobserved: false)))
                    .frame(width: cellSize, height: cellSize)
            }
            Text(c.legendHigh).font(OMFont.caption).foregroundStyle(.secondary)
        }
    }
```

Add the flag to `GridCache` next to `dimsUnrecordedDays`:

```swift
    /// Whether the squares are a utilisation (battery colours) or dollars (accent ramp).
    let usesStatusColor: Bool
```

and set it in both builders — `usesStatusColor: false` in the `build(from dailies:weeks:)` return (next to `dimsUnrecordedDays: false`) and `usesStatusColor: true` in `build(records:buckets:weeks:)` (next to `dimsUnrecordedDays: true`).

- [ ] **Step 4: Re-type the stat cards in `ActivityGridView`**

Replace `statCard(_:)` in the same file:

```swift
    private func statCard(_ stat: GridStat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(stat.label).font(OMFont.caption).foregroundStyle(.secondary)
            Text(stat.value)
                .font(OMFont.heroNumeral)
                .monospacedDigit()
            if let sub = stat.sub {
                Text(sub).font(OMFont.caption).foregroundStyle(.tertiary)
            }
        }
        .dashboardCard(padding: 12)
    }
```

- [ ] **Step 5: Run the colour tests to verify they pass**

```bash
xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/ActivityGridColorTests ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS=""
```
Expected: `** TEST SUCCEEDED **`, 6 tests, 0 failures.

- [ ] **Step 6: Headings and numerals in `InsightsView`**

In `UsageTracker/UI/Dashboard/InsightsView.swift`:

Replace `sectionLabel(_:)` so every heading goes through the component:

```swift
    private func sectionLabel(_ text: String) -> some View {
        OMSectionHeader(title: text)
    }
```

Replace the `sessionWindowBlock` heading row (the `HStack` at the top of that block) with:

```swift
            OMSectionHeader(
                title: "Current session window",
                trailing: "since \(window.start.formatted(date: .omitted, time: .shortened))"
            )
```

Replace the `projectsBlock` heading row with:

```swift
            OMSectionHeader(title: "Projects · last 30 days", trailing: "\(projects.count) total")
```

And put the numerals on the tokens — in `card(title:value:sub:)`, `weekOverWeekCard(_:)` and `sessionWindowBlock`, every `.font(.title2.weight(.semibold))` becomes `.font(OMFont.heroNumeral)`, every `.font(.subheadline)` on a *label* becomes `.font(OMFont.body)`, and `projectRow`'s cost becomes `.font(OMFont.numeral)`:

```swift
    private func card(title: String, value: String, sub: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(OMFont.body).foregroundStyle(.secondary)
            Text(value)
                .font(OMFont.heroNumeral)
                .lineLimit(2)
                .truncationMode(.tail)
            if let sub { Text(sub).font(OMFont.caption).foregroundStyle(.tertiary) }
        }
        .dashboardCard()
    }

    private func projectRow(_ p: ProjectSummary, maxCost: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(p.displayName)
                    .font(OMFont.bodyStrong)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(String(format: "$%.2f", p.totalCost))
                    .font(OMFont.numeral)
                    .monospacedDigit()
            }
            HStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(.quaternary)
                        // Dollars, not utilisation: the accent colour, never the
                        // battery ramp — a big spend is not a warning.
                        Capsule(style: .continuous)
                            .fill(Color.accentColor)
                            .frame(width: geo.size.width * CGFloat(p.totalCost / max(maxCost, 0.01)))
                    }
                }
                .frame(height: 6)

                Text("\(p.turns) turn\(p.turns == 1 ? "" : "s")")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 70, alignment: .trailing)
            }
        }
        .help(p.slug)
    }
```

`weekOverWeekCard`'s up/down arrow keeps `Color.orange` / `Color.green`: that pair is a direction, not a utilisation, and the wording is unchanged.

- [ ] **Step 7: Headings and numerals in `SessionHistoryView`**

In `UsageTracker/UI/Dashboard/SessionHistoryView.swift`, put the two table headers on `OMFont` and the numeric columns on `OMFont.numeral`. The peak column already uses `usageStatusColor(peak.peak)` — that is the utilisation rule, keep it. The cost bars already use `Color.accentColor` — keep that too. Replace the header rows and the value cells:

```swift
    private var peakTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Day").font(OMFont.body).foregroundStyle(.secondary)
                    .frame(width: 120, alignment: .leading)
                Spacer()
                Text("Window").font(OMFont.body).foregroundStyle(.secondary)
                    .frame(width: 160, alignment: .trailing)
                Text("Peak").font(OMFont.body).foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
            }
            .padding(.bottom, 6)
            ForEach(quota.peaks.reversed()) { peak in
                HStack {
                    Text(peak.day.formatted(date: .abbreviated, time: .omitted)).font(OMFont.body)
                        .frame(width: 120, alignment: .leading)
                    Spacer()
                    Text(quota.label(for: peak.peakBucketID)).font(OMFont.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: 160, alignment: .trailing)
                    Text(String(format: "%.0f%%", peak.peak))
                        .font(OMFont.numeral)
                        .monospacedDigit()
                        .foregroundStyle(usageStatusColor(peak.peak))
                        .frame(width: 60, alignment: .trailing)
                }
                .padding(.vertical, 3)
                if peak.id != quota.peaks.first?.id { Divider().opacity(0.3) }
            }
        }
        .padding(.horizontal, 24)
    }

    private var table: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Day").font(OMFont.body).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
                Spacer()
                Text("Turns").font(OMFont.body).foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
                Text("Tokens").font(OMFont.body).foregroundStyle(.secondary).frame(width: 100, alignment: .trailing)
                Text("Cost").font(OMFont.body).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
            }
            .padding(.bottom, 6)
            ForEach(data.reversed()) { p in
                HStack {
                    Text(p.day.formatted(date: .abbreviated, time: .omitted)).font(OMFont.body)
                        .frame(width: 120, alignment: .leading)
                    Spacer()
                    Text("\(p.turns)").font(OMFont.numeral).monospacedDigit().frame(width: 60, alignment: .trailing)
                    Text(formatTokens(p.tokens)).font(OMFont.numeral).monospacedDigit().frame(width: 100, alignment: .trailing).foregroundStyle(.secondary)
                    Text(String(format: "$%.2f", p.cost)).font(OMFont.numeral).monospacedDigit().frame(width: 80, alignment: .trailing)
                }
                .padding(.vertical, 3)
                if p.id != data.first?.id { Divider().opacity(0.3) }
            }
        }
        .padding(.horizontal, 24)
    }
```

The multi-window quota chart keeps `.foregroundStyle(by: .value("Window", series.bucket.label))`: those lines are *different windows*, not different levels, and colouring them all by `usageStatusColor` would draw four indistinguishable green lines.

- [ ] **Step 8: Build and run the full suite**

```bash
xcodebuild -project UsageTracker.xcodeproj -scheme UsageTracker -configuration Debug -derivedDataPath build/DerivedData build
xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS=""
```
Expected: `** BUILD SUCCEEDED **` then `** TEST SUCCEEDED **`, 0 failures.

- [ ] **Step 9: Commit**

```bash
git add UsageTracker/UI/Dashboard/ActivityGridView.swift UsageTracker/UI/Dashboard/InsightsView.swift UsageTracker/UI/Dashboard/SessionHistoryView.swift UsageTrackerTests/ActivityGridColorTests.swift
git commit -m "Dashboard: charts and heat map on the design system colours

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

## Task 10: Manual pass

The spec's manual checklist for this package. Nothing here is automatable; record the result in the commit body so the next reader knows it was actually walked.

**Files:**
- No code changes. This task produces one empty commit carrying the checklist.

- [ ] **Step 1: Build and launch**

```bash
xcodebuild -project UsageTracker.xcodeproj -scheme UsageTracker -configuration Debug -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/Omelette.app
```
Expected: `** BUILD SUCCEEDED **`, the menu bar item appears.

- [ ] **Step 2: Walk every tab in light mode**

Open the dashboard and visit Overview, Agents, Activity, History, Insights. For each: cards have the new 16 pt corners and hairline, the screen title is 22 pt, nothing is clipped at the 820 pt minimum width, and no view shows the old 12 pt card next to a new one.

- [ ] **Step 3: Repeat in dark mode**

System Settings → Appearance → Dark, then walk the same five tabs. Check specifically: the hairline is visible but not a bright line, the heat map's "unobserved" squares are distinguishable from empty ones, the amber `⚠︎` on a history row is readable.

- [ ] **Step 4: The Agents tab with no history**

Move the log aside so the empty states render, then reopen the tab:

```bash
mv ~/Library/Application\ Support/UsageTracker/agent-sessions.jsonl /tmp/agent-sessions.backup.jsonl
```
Expected: tiles read `0`, `<1m`, `0`, `—`; History shows "No finished sessions in this range"; if Claude's hooks are not installed, the caption "Hooks give exact durations" is under it; the Live section still lists whatever is running.

- [ ] **Step 5: The Agents tab with history**

```bash
mv /tmp/agent-sessions.backup.jsonl ~/Library/Application\ Support/UsageTracker/agent-sessions.jsonl
```
Reopen the tab and confirm: rows are grouped under "Today" / "Yesterday" / "Mon 31 Aug"; the range picker changes the tile numbers and the number of days shown; the source segments filter both the Live and the History sections; the tab and the source both survive a quit and relaunch.

- [ ] **Step 6: Rotation ran**

```bash
wc -l ~/Library/Application\ Support/UsageTracker/agent-sessions.jsonl
log show --last 5m --predicate 'eventMessage CONTAINS "[UT] agent history rotation"' 2>/dev/null | tail -5
```
Expected: the file is intact (rotation only trims records older than 90 days) and no rotation-failure line was logged.

- [ ] **Step 7: Commit the record**

```bash
git commit --allow-empty -m "Dashboard: phase 3 package 2 manual pass

Walked Overview / Agents / Activity / History / Insights in light and dark,
with and without agent-sessions.jsonl. Tab and source selection persist across
relaunch; rotation logged no failure.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

## Self-review notes

- **Spec coverage.** Chrome (`dashboardCard`, `OMFont.screenTitle`, `DashboardHeader`, `@AppStorage("dashboardTab")`) → Task 1. `OverviewView` on `OMRing`/`OMHero`/`OMKeyValueRow`/`OMSectionHeader` → Task 8. Recolouring of the three chart views → Task 9. Agents tab (`AgentsHistoryView`, `OMAgentHistoryRow`, `@AppStorage("agentsHistorySource")`, summary strip, live `AgentsSection(grouped: true, hooksInstalled: true)`, day-grouped history, empty states) → Tasks 6 and 7. `AgentHistorySummary` with range/source/day/duration/busiest-project rules → Task 2. `DashboardState.agentRecords` in `refreshAll()` off-main → Task 5. `AgentHistoryStore.rotate(keepDays:now:)` + the `AgentChannel.start()` call → Tasks 3 and 4. Manual checklist → Task 10.
- **Deliberately out of scope** (spec assigns them elsewhere): `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`, `CHANGELOG.md`, settings/onboarding/floating window, and the `SharedUI/` move.
- **Names used consistently across tasks:** `AgentHistorySummary.make(records:source:range:now:)`, `.days(records:source:range:now:calendar:)`, `.dayTitle(_:now:calendar:)`, `.duration(_:)`, `.inRange(_:source:range:now:)`; `AgentHistoryStore.rotate(keepDays:now:)`; `DashboardState.refreshAgentHistory(historyURL:)` and `.agentRecords`; `AgentChannel.start(socketURL:refreshSymlink:historyURL:)`; `OMAgentHistoryRow.turnsText(_:)` / `.approvalsText(_:)` / `.accessibilityLabel(for:startedAt:)`; `AgentsHistoryView.selectedSource(_:)` / `.sourceKey`; `ActivityGridView.cellBase(intensity:usesStatusColor:unobserved:)` / `.cellOpacity(intensity:unobserved:)`; `OMFont.screenTitle`.
- **Additions beyond the spec's contract, and why.** (1) `AgentHistorySummary` gets a hand-written `==` — a stored tuple blocks synthesis. (2) `inRange` is exposed rather than private so `make` and `days` share one definition of the window and tests can pin it once. (3) `DashboardState.refreshAgentHistory` and `AgentChannel.start` each take an injectable URL with a default, which is the only way to test either without writing to the real Application Support log — every existing call site is unchanged. (4) `DashboardHeader.showsServicePicker` (default `true`) so the Agents tab does not show a provider picker that changes nothing on it. (5) `ActivityGridView.cellBase`/`cellOpacity` split the existing private `color(for:unobserved:)` in two so both halves compare exactly in a test. (6) `AgentSessionRecord` gains `Sendable` (all its members already are, and `HistoryRecord` next door declares it) because it now crosses two task boundaries.
- **Two deliberate readings of the spec.** The row's "started time (`HH:mm`)" renders through `formatted(date: .omitted, time: .shortened)`, i.e. the machine's own clock format — hard-coding 24-hour would be wrong on a Mac showing 2:20 PM everywhere else, and `InsightsView.formatHour` already set that precedent. The source segmented control sits on its own row under the header rather than sharing the `trailing` slot with the range picker, which would crowd two controls into one baseline.
- **`duration` never rolls hours into days**, per the spec's three forms — so a 90-day "Agent time" tile can read `512h 40m`. Flagged for the owner: adding a `21d 8h` form is a one-line change to `AgentHistorySummary.duration` plus one test.
- **Known risk:** `OMSegmentedControl` binds ⌘1…⌘3 to its segments. While the Agents tab is on screen those shortcuts change the source filter; they are unbound elsewhere in the dashboard, so nothing is shadowed, but it is a behaviour the owner should see during Task 10, Step 5.
