# Design System + New Popover (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Omelette a named design system and rebuild the popover as the approved `All` / provider layout, with the menu bar picking up the new colour semantics.

**Architecture:** Pure window-ranking logic is extracted from `PopoverView` into a unit-tested enum; a component kit under `UI/DesignSystem/` (tokens, ring, segmented control, tiles, hero, rows) is built on top of it with previews; `PopoverView` is then rebuilt from those components; finally the shared colour function and the old ring are replaced at every call site.

**Tech Stack:** Swift 6 (strict concurrency `minimal`), SwiftUI, macOS 14 floor with `#available(macOS 26)` Liquid Glass paths (`LiquidGlass.swift`), XCTest (`UsageTrackerTests`, `@testable import Omelette`), xcodegen-generated project.

**Spec:** `docs/superpowers/specs/2026-09-02-design-system-popover-design.md` (roadmap: `docs/superpowers/specs/2026-09-02-agent-control-plane-roadmap.md`)

## Global Constraints

- Deployment target macOS 14.0; every glass effect goes through the existing helpers in `UsageTracker/UI/Components/LiquidGlass.swift` (`liquidGlass(in:tint:)`, `GlassGroup`, `glassButtonStyle()`), never a bare `glassEffect` call.
- Colour semantics (spec): `usageStatusColor` returns `.green` below 70, `.orange` from 70, `.red` from 90. Agent-state colours are tokens only in this phase.
- Popover width stays 360 pt; `NSPopover.contentSize` in `StatusBarController.swift:21` stays 340×460.
- Persisted tab key stays `selectedProviderTab`; the value `"all"` (`WindowRanking.allTab`) is the default and the self-heal target.
- Every user-visible string that exists today keeps its wording (status phrases, burn verdict, "N unused windows", "You haven't used X yet", "Server responded but returned no usage data.", state help texts).
- The widget extension keeps its own colour copy (`UsageTrackerWidget.swift:468`) — do not touch the widget in this phase.
- New source files are picked up by xcodegen from `sources: - path: UsageTracker`; run `xcodegen generate` after adding files and before building. `UsageTracker.xcodeproj/` is generated and gitignored — never `git add` it.
- Build: `xcodebuild -project UsageTracker.xcodeproj -scheme UsageTracker -configuration Debug -derivedDataPath build/DerivedData build`.
  Tests: `xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData` (add `-only-testing:UsageTrackerTests/<Class>` for a single class). If local signing of the test host fails, append `CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO`.
- Commits end with the trailer lines
  `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` and
  `Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X`.
- Other sessions may commit the working tree while you work: re-read a file right before editing it; prefer targeted edits over whole-file rewrites (see memory note in `project_usage_checker`).
- No release in this plan: the owner runs the local build/notarize flow after testing.

---

## Package map (for parallel planning / execution)

| Package | Tasks | Depends on | Deliverable |
|---|---|---|---|
| **P1 Foundations** | 1–3 | — | `OMTokens.swift`, `WindowRanking.swift`, `BurnVerdict.swift` + tests; no visible change except the green colour |
| **P2 Components** | 4–9 | P1 | `UI/DesignSystem/` component kit with previews; unused by screens yet |
| **P3 Popover** | 10–13 | P2 | `PopoverView.swift` rebuilt on the kit, regression checklist green |
| **P4 Call sites + menu bar + release prep** | 14–16 | P2 (OMRing) | `MenuBarLabel`, `OverviewView`, `SessionHistoryView` migrated, `UsageRing` deleted, CHANGELOG + version bump |

P3 and P4 can run in parallel once P2 is merged. Executors of P3 and P4 both touch nothing in each other's files except that P4 deletes `UsageRing` — P3 must not reference `UsageRing`.

## File structure

```
UsageTracker/UI/DesignSystem/
  OMTokens.swift          spacing, radii, fonts, surfaces, usageStatusColor, agent colours
  OMRing.swift            ring gauge (replaces UsageRing)
  OMSegmentedControl.swift  All · providers capsule control
  OMSectionHeader.swift   micro uppercase header + trailing caption
  OMChip.swift            tinted capsule badge
  OMKeyValueRow.swift     label · value (+ optional bar)
  OMProviderTile.swift    tile for the All tab
  OMCostTile.swift        full-width "Last 7 days"
  OMHero.swift            provider-tab hero (ring + texts + burn verdict)
  OMRingRow.swift         weekly windows as a grid of small rings
UsageTracker/Core/
  WindowRanking.swift     pure selection/formatting helpers
  BurnVerdict.swift       pure burn-verdict text (moved out of PopoverView)
UsageTracker/UI/
  PopoverView.swift       rebuilt (header, segment, All tab, provider tab, footer)
  MenuBarLabel.swift      colours + reserved leading slot
UsageTracker/UI/Components/
  CardStyle.swift         loses usageStatusColor (moved)
  BarSegment.swift        loses UsageRing (deleted); BarSegment stays
UsageTrackerTests/
  WindowRankingTests.swift
  BurnVerdictTests.swift
```

---

## P1 — Foundations

### Task 1: Tokens and the new colour semantics

**Files:**
- Create: `UsageTracker/UI/DesignSystem/OMTokens.swift`
- Modify: `UsageTracker/UI/Components/CardStyle.swift:22-29` (remove `usageStatusColor`)
- Test: `UsageTrackerTests/WindowRankingTests.swift` (colour cases live here; file created in this task)

**Interfaces:**
- Produces:
  ```swift
  enum OMSpacing { static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 20 }
  enum OMRadius  { static let tile: CGFloat = 16, row: CGFloat = 12 }
  enum OMFont {
      static let title: Font, body: Font, bodyStrong: Font, caption: Font, micro: Font
      static let heroNumeral: Font, numeral: Font, menuNumeral: Font
  }
  enum OMSurface { static let tile: AnyShapeStyle; static let row: AnyShapeStyle; static let hairline: AnyShapeStyle }
  enum OMAgentColor { static let needsYou: Color, working: Color, done: Color, idle: Color }
  func usageStatusColor(_ percent: Double) -> Color   // green < 70, orange < 90, red ≥ 90
  ```

- [ ] **Step 1: Write the failing tests**

```swift
// UsageTrackerTests/WindowRankingTests.swift
import XCTest
import SwiftUI
@testable import Omelette

final class WindowRankingTests: XCTestCase {
    // MARK: usageStatusColor
    func testStatusColorIsGreenWhenComfortable() {
        XCTAssertEqual(usageStatusColor(0), .green)
        XCTAssertEqual(usageStatusColor(69.9), .green)
    }
    func testStatusColorIsOrangeFrom70() {
        XCTAssertEqual(usageStatusColor(70), .orange)
        XCTAssertEqual(usageStatusColor(89.9), .orange)
    }
    func testStatusColorIsRedFrom90() {
        XCTAssertEqual(usageStatusColor(90), .red)
        XCTAssertEqual(usageStatusColor(150), .red)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/WindowRankingTests`
Expected: FAIL — `testStatusColorIsGreenWhenComfortable` fails because the current function returns `.accentColor` below 70.

- [ ] **Step 3: Create the tokens file and move the colour function**

```swift
// UsageTracker/UI/DesignSystem/OMTokens.swift
import SwiftUI

/// Omelette design tokens. Every surface (popover, floating window, dashboard,
/// settings, onboarding) reads spacing, radii, type roles and colours from here.
enum OMSpacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 20
}

enum OMRadius {
    static let tile: CGFloat = 16
    static let row: CGFloat = 12
}

enum OMFont {
    static let title = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 12)
    static let bodyStrong = Font.system(size: 12, weight: .semibold)
    static let caption = Font.system(size: 11)
    /// Section labels: apply `.textCase(.uppercase)` and `.tracking(0.6)` at the use site (OMSectionHeader does).
    static let micro = Font.system(size: 10, weight: .semibold)
    static let heroNumeral = Font.system(size: 21, weight: .bold, design: .rounded)
    static let numeral = Font.system(size: 13, weight: .bold, design: .rounded)
    static let menuNumeral = Font.system(size: 11, weight: .semibold, design: .rounded)
}

/// Content surfaces use quiet system fills; Liquid Glass is reserved for controls
/// so glass is never stacked on the popover's own material.
enum OMSurface {
    static let tile = AnyShapeStyle(.fill.tertiary)
    static let row = AnyShapeStyle(.fill.quaternary)
    static let hairline = AnyShapeStyle(.separator.opacity(0.5))
}

/// Agent states (phase 2 uses them; defined now so no tokens are added later).
enum OMAgentColor {
    static let needsYou = Color.orange
    static let working = Color.blue
    static let done = Color.green
    static let idle = Color.secondary
}

/// Battery-style status colour for a usage percentage: green while comfortable,
/// amber when high, red when critical. Shared by every gauge in the app.
func usageStatusColor(_ percent: Double) -> Color {
    if percent >= 90 { return .red }
    if percent >= 70 { return .orange }
    return .green
}
```

Then delete lines 22–29 of `UsageTracker/UI/Components/CardStyle.swift` (the old `usageStatusColor` and its doc comment) so the file keeps only the `dashboardCard` extension.

- [ ] **Step 4: Regenerate the project, run the tests**

Run: `xcodegen generate && xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:UsageTrackerTests/WindowRankingTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add UsageTracker/UI/DesignSystem/OMTokens.swift UsageTracker/UI/Components/CardStyle.swift UsageTrackerTests/WindowRankingTests.swift
git commit -m "Design system: tokens file, battery-green status colour

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

### Task 2: `WindowRanking` — hero / secondary window, labels, tab resolution

**Files:**
- Create: `UsageTracker/Core/WindowRanking.swift`
- Test: `UsageTrackerTests/WindowRankingTests.swift` (extend)

**Interfaces:**
- Consumes: `ServiceSnapshot`, `UsageBucket`, `ExtraUsage`, `extraUsageTitle(plan:)` from `UsageTracker/Core/UsageSnapshot.swift`.
- Produces:
  ```swift
  enum WindowRanking {
      static let allTab = "all"
      static func heroBucket(for service: ServiceSnapshot) -> UsageBucket?
      static func secondaryBucket(for service: ServiceSnapshot) -> UsageBucket?
      static func shortWindowLabel(_ label: String) -> String
      static func resolveTab(stored: String, displayed: [ServiceSnapshot]) -> String
      static func remainingText(until resetsAt: Date, now: Date = Date()) -> String?
  }
  ```

- [ ] **Step 1: Write the failing tests**

Append to `WindowRankingTests`:

```swift
    // MARK: hero
    private func claude(_ buckets: [UsageBucket], extra: ExtraUsage? = nil) -> ServiceSnapshot {
        Fixture.snapshot(id: "claude", buckets: buckets, extraUsage: extra)
    }
    private let session = Fixture.bucket(id: "five_hour", label: "Current session", percent: 37, kind: .session)
    private let weekly  = Fixture.bucket(id: "seven_day", label: "All models", percent: 52, kind: .weekly)
    private let opus    = Fixture.bucket(id: "seven_day_opus", label: "Opus only", percent: 90, kind: .modelSpecific)
    private let promo   = Fixture.bucket(id: "seven_day_promotional", label: "Promo pool", percent: 99, kind: .other)

    func testHeroIsWorstCoreWindowIgnoringModelScoped() {
        XCTAssertEqual(WindowRanking.heroBucket(for: claude([session, weekly, opus]))?.id, "seven_day")
    }
    func testHeroTieGoesToFirstInAPIOrder() {
        let a = Fixture.bucket(id: "five_hour", percent: 0, kind: .session)
        let b = Fixture.bucket(id: "seven_day", percent: 0, kind: .weekly)
        XCTAssertEqual(WindowRanking.heroBucket(for: claude([a, b]))?.id, "five_hour")
    }
    func testHeroIgnoresPromotionalUnlessAlone() {
        XCTAssertEqual(WindowRanking.heroBucket(for: claude([session, promo]))?.id, "five_hour")
        XCTAssertEqual(WindowRanking.heroBucket(for: claude([promo]))?.id, "seven_day_promotional")
    }
    func testHeroFallsBackToModelScopedWhenNothingElse() {
        XCTAssertEqual(WindowRanking.heroBucket(for: claude([opus]))?.id, "seven_day_opus")
    }
    func testExtraUsageCompetesWhenEnabled() {
        let extra = ExtraUsage(isEnabled: true, monthlyLimit: 50, usedCredits: 40, utilization: 80)
        let hero = WindowRanking.heroBucket(for: claude([session, weekly], extra: extra))
        XCTAssertEqual(hero?.id, "claude_extra_usage")
        XCTAssertEqual(hero?.label, "Extra usage credits")
        XCTAssertEqual(hero?.kind, .other)
    }
    func testExtraUsageIgnoredWhenDisabled() {
        let extra = ExtraUsage(isEnabled: false, monthlyLimit: 50, usedCredits: 40, utilization: 80)
        XCTAssertEqual(WindowRanking.heroBucket(for: claude([session, weekly], extra: extra))?.id, "seven_day")
    }
    func testHeroNilWithoutWindows() {
        XCTAssertNil(WindowRanking.heroBucket(for: claude([])))
    }

    // MARK: secondary
    func testSecondaryPrefersAllModelsWeeklyWhenNotHero() {
        let hotSession = Fixture.bucket(id: "five_hour", label: "Current session", percent: 60, kind: .session)
        XCTAssertEqual(WindowRanking.secondaryBucket(for: claude([hotSession, weekly, opus]))?.id, "seven_day")
    }
    func testSecondaryIsNextWorstCoreWhenWeeklyIsHero() {
        XCTAssertEqual(WindowRanking.secondaryBucket(for: claude([session, weekly, opus]))?.id, "five_hour")
    }
    func testSecondaryNilWithSingleWindow() {
        XCTAssertNil(WindowRanking.secondaryBucket(for: claude([session])))
    }

    // MARK: labels
    func testShortWindowLabel() {
        XCTAssertEqual(WindowRanking.shortWindowLabel("All models"), "All")
        XCTAssertEqual(WindowRanking.shortWindowLabel("Opus only"), "Opus")
        XCTAssertEqual(WindowRanking.shortWindowLabel("Fable only"), "Fable")
        XCTAssertEqual(WindowRanking.shortWindowLabel("Current session"), "Current session")
    }

    // MARK: tabs
    func testResolveTabDefaultsToAll() {
        let services = [Fixture.snapshot(id: "claude"), Fixture.snapshot(id: "codex")]
        XCTAssertEqual(WindowRanking.resolveTab(stored: "", displayed: services), "all")
        XCTAssertEqual(WindowRanking.resolveTab(stored: "grok", displayed: services), "all")
        XCTAssertEqual(WindowRanking.resolveTab(stored: "all", displayed: services), "all")
        XCTAssertEqual(WindowRanking.resolveTab(stored: "codex", displayed: services), "codex")
    }

    // MARK: remaining
    func testRemainingText() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(WindowRanking.remainingText(until: now.addingTimeInterval(2 * 3600 + 15 * 60), now: now), "2h 15m left")
        XCTAssertEqual(WindowRanking.remainingText(until: now.addingTimeInterval(-5), now: now), "resets now")
        XCTAssertNil(WindowRanking.remainingText(until: .distantFuture, now: now))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test ... -only-testing:UsageTrackerTests/WindowRankingTests`
Expected: compile error "cannot find 'WindowRanking' in scope".

- [ ] **Step 3: Implement `WindowRanking`**

```swift
// UsageTracker/Core/WindowRanking.swift
import Foundation

/// Pure selection and formatting rules shared by the popover, tiles and menu bar.
/// Extracted from PopoverView so they can be unit-tested and reused by the
/// widget/floating window later.
enum WindowRanking {
    /// Sentinel for the "All providers" segment.
    static let allTab = "all"

    /// The most-constrained window of a service — the one that answers "can I
    /// keep working right now?". Promotional pools and model-scoped windows do
    /// not compete unless they are all the account has; enabled extra usage
    /// (spend limit) does compete. Ties resolve to the first in API order.
    static func heroBucket(for service: ServiceSnapshot) -> UsageBucket? {
        var candidates = coreCandidates(for: service)
        if candidates.isEmpty {
            candidates = service.buckets.filter { !$0.isPromotional }
        }
        if candidates.isEmpty {
            candidates = service.buckets
        }
        return worst(of: candidates)
    }

    /// The window shown under the hero on a tile: the all-models weekly when it
    /// is not already the hero, otherwise the next-worst core window. nil when
    /// the service has nothing else worth showing.
    static func secondaryBucket(for service: ServiceSnapshot) -> UsageBucket? {
        guard let hero = heroBucket(for: service) else { return nil }
        if hero.id != "seven_day", let weekly = service.buckets.first(where: { $0.id == "seven_day" }) {
            return weekly
        }
        let rest = coreCandidates(for: service).filter { $0.id != hero.id }
        return worst(of: rest)
    }

    /// "All models" → "All", "Opus only" → "Opus"; other labels untouched.
    static func shortWindowLabel(_ label: String) -> String {
        if label == "All models" { return "All" }
        if label.hasSuffix(" only") { return String(label.dropLast(" only".count)) }
        return label
    }

    /// Persisted tab self-heal: a stored id that is not on screen falls back to All.
    static func resolveTab(stored: String, displayed: [ServiceSnapshot]) -> String {
        if displayed.contains(where: { $0.id == stored }) { return stored }
        return allTab
    }

    /// "2h 15m left"; "resets now" once the reset time has passed; nil when unknown.
    static func remainingText(until resetsAt: Date, now: Date = Date()) -> String? {
        guard resetsAt < .distantFuture else { return nil }
        let delta = resetsAt.timeIntervalSince(now)
        if delta <= 0 { return "resets now" }
        let f = DateComponentsFormatter()
        f.allowedUnits = [.day, .hour, .minute]
        f.maximumUnitCount = 2
        f.unitsStyle = .abbreviated
        return f.string(from: delta).map { "\($0) left" }
    }

    // MARK: - Private

    private static func coreCandidates(for service: ServiceSnapshot) -> [UsageBucket] {
        var candidates = service.buckets.filter { !$0.isPromotional && $0.kind != .modelSpecific }
        if let extra = service.extraUsage, extra.isEnabled {
            candidates.append(UsageBucket(
                id: "\(service.id)_extra_usage",
                label: extraUsageTitle(plan: service.plan),
                utilization: extra.utilization,
                resetsAt: .distantFuture,
                kind: .other
            ))
        }
        return candidates
    }

    private static func worst(of buckets: [UsageBucket]) -> UsageBucket? {
        buckets.enumerated().max { a, b in
            if a.element.clampedPercent != b.element.clampedPercent {
                return a.element.clampedPercent < b.element.clampedPercent
            }
            return a.offset > b.offset
        }?.element
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test ... -only-testing:UsageTrackerTests/WindowRankingTests`
Expected: PASS (all WindowRanking tests).

- [ ] **Step 5: Commit**

```bash
git add UsageTracker/Core/WindowRanking.swift UsageTrackerTests/WindowRankingTests.swift
git commit -m "Core: WindowRanking — hero/secondary window, labels, tab self-heal

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

### Task 3: `BurnVerdict` — move the verdict text out of the view

**Files:**
- Create: `UsageTracker/Core/BurnVerdict.swift`
- Test: `UsageTrackerTests/BurnVerdictTests.swift`
- Reference (read only): `UsageTracker/UI/PopoverView.swift:566-590` (current `burnVerdict` + `formatBurn`), `UsageTracker/Core/Analytics.swift:4-14` (`BurnRatePrediction`: `secondsToLimit`, `percentPerMinute`, `bucketId`, `isStale`), `UsageTrackerTests/Fixtures.swift:88-101` (existing builder `Fixture.prediction(secondsToLimit:percentPerMinute:bucketId:isStale:)` — reuse it, do not add another).

**Interfaces:**
- Produces:
  ```swift
  struct BurnVerdict: Equatable { let willHit: Bool; let text: String }
  extension BurnVerdict {
      static func make(burn: BurnRatePrediction?, sessionBuckets: [UsageBucket], now: Date = Date()) -> BurnVerdict?
      static func formatBurn(_ secs: TimeInterval) -> String   // "2h 15m", "45m", "3d"
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
// UsageTrackerTests/BurnVerdictTests.swift
import XCTest
@testable import Omelette

final class BurnVerdictTests: XCTestCase {
    func testFormatBurn() {
        XCTAssertEqual(BurnVerdict.formatBurn(2 * 3600 + 15 * 60), "2h 15m")
        XCTAssertEqual(BurnVerdict.formatBurn(45 * 60), "45m")
        XCTAssertEqual(BurnVerdict.formatBurn(3 * 86400 + 3600), "3d")
    }

    func testNilWithoutPrediction() {
        let session = Fixture.bucket(id: "five_hour", percent: 40, resetsAt: Date().addingTimeInterval(3600), kind: .session)
        XCTAssertNil(BurnVerdict.make(burn: nil, sessionBuckets: [session]))
    }

    func testWillHitWhenLimitComesBeforeReset() {
        let now = Date()
        let session = Fixture.bucket(id: "five_hour", percent: 40, resetsAt: now.addingTimeInterval(2 * 3600), kind: .session)
        let burn = Fixture.prediction(secondsToLimit: 30 * 60, bucketId: "five_hour")
        let verdict = BurnVerdict.make(burn: burn, sessionBuckets: [session], now: now)
        XCTAssertEqual(verdict, BurnVerdict(willHit: true, text: "At this pace, limit in ~30m"))
    }

    func testSafeWhenResetComesFirst() {
        let now = Date()
        let session = Fixture.bucket(id: "five_hour", percent: 40, resetsAt: now.addingTimeInterval(30 * 60), kind: .session)
        let burn = Fixture.prediction(secondsToLimit: 2 * 3600, bucketId: "five_hour")
        let verdict = BurnVerdict.make(burn: burn, sessionBuckets: [session], now: now)
        XCTAssertEqual(verdict, BurnVerdict(willHit: false, text: "At this pace you won't hit the limit before reset"))
    }

    func testNilWhenPredictionIsStaleOrForAnotherBucket() {
        let now = Date()
        let session = Fixture.bucket(id: "five_hour", percent: 40, resetsAt: now.addingTimeInterval(3600), kind: .session)
        XCTAssertNil(BurnVerdict.make(burn: Fixture.prediction(secondsToLimit: 60, bucketId: "seven_day"), sessionBuckets: [session], now: now))
        XCTAssertNil(BurnVerdict.make(burn: Fixture.prediction(secondsToLimit: 60, bucketId: "five_hour", isStale: true), sessionBuckets: [session], now: now))
    }
}
```

- [ ] **Step 2: Confirm the fixture exists**

`UsageTrackerTests/Fixtures.swift` already has `Fixture.prediction(secondsToLimit:percentPerMinute:bucketId:isStale:)` (defaults: `percentPerMinute: 1`, `bucketId: "five_hour"`, `isStale: false`). The tests above use it; nothing to add.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `xcodebuild test ... -only-testing:UsageTrackerTests/BurnVerdictTests`
Expected: compile error "cannot find 'BurnVerdict' in scope".

- [ ] **Step 4: Implement `BurnVerdict`**

```swift
// UsageTracker/Core/BurnVerdict.swift
import Foundation

/// Answers the question the burn rate is actually for: will I hit the limit
/// before the window resets, or can I keep going at this pace?
struct BurnVerdict: Equatable {
    let willHit: Bool
    let text: String

    static func make(burn: BurnRatePrediction?, sessionBuckets: [UsageBucket], now: Date = Date()) -> BurnVerdict? {
        guard let burn, !burn.isStale,
              let secs = burn.secondsToLimit,
              let bucket = sessionBuckets.first(where: { $0.id == burn.bucketId })
        else { return nil }
        if bucket.resetsAt < .distantFuture, secs >= bucket.resetsAt.timeIntervalSince(now) {
            return BurnVerdict(willHit: false, text: "At this pace you won't hit the limit before reset")
        }
        return BurnVerdict(willHit: true, text: "At this pace, limit in ~\(formatBurn(secs))")
    }

    static func formatBurn(_ secs: TimeInterval) -> String {
        let h = Int(secs / 3600)
        let m = Int((secs.truncatingRemainder(dividingBy: 3600)) / 60)
        if h > 24 { return "\(h / 24)d" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test ... -only-testing:UsageTrackerTests/BurnVerdictTests`
Expected: PASS (5 tests).

- [ ] **Step 6: Commit**

```bash
git add UsageTracker/Core/BurnVerdict.swift UsageTrackerTests/BurnVerdictTests.swift
git commit -m "Core: BurnVerdict extracted from PopoverView

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

## P2 — Components

Every component file ends with `#Preview("…")` blocks for light and dark
(`.preferredColorScheme(.dark)`) at popover width (`.frame(width: 328)` = 360 − 2×16).
Components are verified by building and by the Xcode canvas; there is no
snapshot-test infrastructure in this repo, so each task's "test" step is the
build plus a preview review.

### Task 4: `OMRing`

**Files:**
- Create: `UsageTracker/UI/DesignSystem/OMRing.swift`

**Interfaces:**
- Consumes: `usageStatusColor` (Task 1), `OMFont`.
- Produces:
  ```swift
  struct OMRing: View {
      enum Size { case hero, medium, small, mini
          var diameter: CGFloat   // 84, 52, 44, 26
          var lineWidth: CGFloat  // 9, 6, 5, 4
          var labelFont: Font?    // heroNumeral, numeral, caption-bold-rounded, nil
      }
      let percent: Double
      var size: Size = .medium
      var pace: Double? = nil      // 0...1 elapsed fraction → 3 pt marker dot on the track
      var color: Color? = nil      // nil → usageStatusColor(percent)
  }
  ```

- [ ] **Step 1: Implement**

```swift
// UsageTracker/UI/DesignSystem/OMRing.swift
import SwiftUI

/// Ring gauge: quiet track, status-coloured arc with round caps, optional
/// centre percent and an optional pace marker (a dot on the track at the
/// fraction of the window already elapsed — usage ahead of the dot is "hot").
struct OMRing: View {
    enum Size {
        case hero, medium, small, mini

        var diameter: CGFloat {
            switch self { case .hero: 84; case .medium: 52; case .small: 44; case .mini: 26 }
        }
        var lineWidth: CGFloat {
            switch self { case .hero: 9; case .medium: 6; case .small: 5; case .mini: 4 }
        }
        var labelFont: Font? {
            switch self {
            case .hero: OMFont.heroNumeral
            case .medium: OMFont.numeral
            case .small: Font.system(size: 11, weight: .bold, design: .rounded)
            case .mini: nil
            }
        }
    }

    let percent: Double
    var size: Size = .medium
    var pace: Double? = nil
    var color: Color? = nil

    private var clamped: Double { max(0, min(100, percent)) }
    private var arcColor: Color { color ?? usageStatusColor(clamped) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: size.lineWidth)
            Circle()
                .trim(from: 0, to: max(0.004, clamped / 100))
                .stroke(arcColor, style: StrokeStyle(lineWidth: size.lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let pace, pace > 0.02, pace < 0.98 {
                Circle()
                    .fill(Color.primary.opacity(0.55))
                    .frame(width: 3, height: 3)
                    .offset(y: -(size.diameter / 2))
                    .rotationEffect(.degrees(pace * 360))
            }
            if let font = size.labelFont {
                Text("\(Int(clamped.rounded()))%")
                    .font(font)
                    .monospacedDigit()
            }
        }
        .frame(width: size.diameter, height: size.diameter)
        .animation(.smooth(duration: 0.35), value: clamped)
        .accessibilityElement(children: .ignore)
        .accessibilityValue("\(Int(clamped.rounded())) percent used")
    }
}

#Preview("Rings — light") {
    HStack(spacing: 16) {
        OMRing(percent: 37, size: .hero, pace: 0.45)
        OMRing(percent: 74, size: .medium)
        OMRing(percent: 92, size: .small)
        OMRing(percent: 12, size: .mini)
    }
    .padding()
}

#Preview("Rings — dark") {
    HStack(spacing: 16) {
        OMRing(percent: 37, size: .hero, pace: 0.45)
        OMRing(percent: 74, size: .medium)
        OMRing(percent: 92, size: .small)
        OMRing(percent: 12, size: .mini)
    }
    .padding()
    .preferredColorScheme(.dark)
}
```

- [ ] **Step 2: Build and review the previews**

Run: `xcodegen generate && xcodebuild -project UsageTracker.xcodeproj -scheme UsageTracker -configuration Debug -derivedDataPath build/DerivedData build`
Expected: BUILD SUCCEEDED. In Xcode, both previews render four rings; the hero ring shows a dot at ~5 o'clock.

- [ ] **Step 3: Commit**

```bash
git add UsageTracker/UI/DesignSystem/OMRing.swift
git commit -m "Design system: OMRing gauge with pace marker

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

### Task 5: `OMSectionHeader`, `OMChip`, `OMKeyValueRow`

**Files:**
- Create: `UsageTracker/UI/DesignSystem/OMSectionHeader.swift`
- Create: `UsageTracker/UI/DesignSystem/OMChip.swift`
- Create: `UsageTracker/UI/DesignSystem/OMKeyValueRow.swift`

**Interfaces:**
- Consumes: `OMFont`, `BarSegment` (`UI/Components/BarSegment.swift`), `liquidGlass(in:tint:)`.
- Produces:
  ```swift
  struct OMSectionHeader: View { let title: String; var trailing: String? = nil }
  struct OMChip: View { let text: String; let tint: Color }
  struct OMKeyValueRow: View { let label: String; let value: String; var barPercent: Double? = nil }
  ```

- [ ] **Step 1: Implement the three files**

```swift
// UsageTracker/UI/DesignSystem/OMSectionHeader.swift
import SwiftUI

/// "WEEKLY LIMITS · resets Thu" — micro uppercase label with an optional caption.
struct OMSectionHeader: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(OMFont.micro)
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(OMFont.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, OMSpacing.xs)
        .accessibilityAddTraits(.isHeader)
    }
}

#Preview { OMSectionHeader(title: "Weekly limits", trailing: "resets Thu").padding().frame(width: 328) }
```

```swift
// UsageTracker/UI/DesignSystem/OMChip.swift
import SwiftUI

/// Tinted capsule badge ("Sign in", "Not running", "Error"). Glass on macOS 26.
struct OMChip: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, OMSpacing.s)
            .padding(.vertical, 3)
            .foregroundStyle(tint)
            .liquidGlass(in: Capsule(), tint: tint)
    }
}

#Preview {
    HStack { OMChip(text: "Sign in", tint: .orange); OMChip(text: "Not running", tint: .secondary); OMChip(text: "Error", tint: .red) }
        .padding()
}
```

```swift
// UsageTracker/UI/DesignSystem/OMKeyValueRow.swift
import SwiftUI

/// "Extra usage   $12.40 / $50" with an optional level bar underneath.
struct OMKeyValueRow: View {
    let label: String
    let value: String
    var barPercent: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: OMSpacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(OMFont.bodyStrong)
                Spacer()
                Text(value)
                    .font(OMFont.body)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if let barPercent {
                BarSegment(percent: barPercent, height: 6, showsLabel: false)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(value)")
    }
}

#Preview {
    VStack(spacing: 12) {
        OMKeyValueRow(label: "Extra usage credits", value: "$12.40 / $50", barPercent: 25)
        OMKeyValueRow(label: "Last 7 days", value: "$15.60")
    }
    .padding().frame(width: 328)
}
```

- [ ] **Step 2: Build and review the previews**

Run: `xcodegen generate && xcodebuild ... build`
Expected: BUILD SUCCEEDED; previews render.

- [ ] **Step 3: Commit**

```bash
git add UsageTracker/UI/DesignSystem/OMSectionHeader.swift UsageTracker/UI/DesignSystem/OMChip.swift UsageTracker/UI/DesignSystem/OMKeyValueRow.swift
git commit -m "Design system: section header, chip, key-value row

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

### Task 6: `OMSegmentedControl`

**Files:**
- Create: `UsageTracker/UI/DesignSystem/OMSegmentedControl.swift`

**Interfaces:**
- Consumes: `ProviderIconView(serviceID:sfFallback:size:)` (`UsageTrackerWidget/ProviderIconView.swift`, compiled into the app), `GlassGroup`, `liquidGlass(in:)`, `OMSurface`, `OMFont`.
- Produces:
  ```swift
  struct OMSegmentItem: Identifiable, Equatable {
      let id: String            // "all" or a service id
      let title: String         // "All", "Claude", …
      var serviceID: String? = nil   // nil → text only
      var sfFallback: String = "sparkles"
      var showsDot: Bool = false     // amber dot (phase 2 "needs you")
  }
  struct OMSegmentedControl: View {
      let items: [OMSegmentItem]
      @Binding var selection: String
  }
  ```
  Keyboard: ⌘1…⌘9 selects the nth item.

- [ ] **Step 1: Implement**

```swift
// UsageTracker/UI/DesignSystem/OMSegmentedControl.swift
import SwiftUI

struct OMSegmentItem: Identifiable, Equatable {
    let id: String
    let title: String
    var serviceID: String? = nil
    var sfFallback: String = "sparkles"
    var showsDot: Bool = false
}

/// Capsule segmented control ("All · Claude · Codex …"). The selected item is a
/// glass capsule inside a GlassGroup so selection morphs between items on
/// macOS 26; on 14+ it is a quiet material capsule.
struct OMSegmentedControl: View {
    let items: [OMSegmentItem]
    @Binding var selection: String

    var body: some View {
        GlassGroup(spacing: 2) {
            HStack(spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    segment(item, index: index)
                }
            }
        }
        .padding(3)
        .background(Capsule(style: .continuous).fill(OMSurface.row))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Provider")
    }

    @ViewBuilder
    private func segment(_ item: OMSegmentItem, index: Int) -> some View {
        let isSelected = item.id == selection
        Button {
            withAnimation(.smooth(duration: 0.2)) { selection = item.id }
        } label: {
            HStack(spacing: 5) {
                if let serviceID = item.serviceID {
                    ProviderIconView(serviceID: serviceID, sfFallback: item.sfFallback, size: 12)
                }
                Text(item.title)
                    .font(OMFont.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topTrailing) {
                if item.showsDot {
                    Circle().fill(OMAgentColor.needsYou).frame(width: 6, height: 6).offset(x: -2, y: 1)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .modifier(SelectedCapsule(isSelected: isSelected))
        .modifier(SegmentShortcut(index: index))
        .help(item.title)
        .accessibilityLabel("\(item.title) tab")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Glass capsule behind the selected segment, nothing behind the others.
private struct SelectedCapsule: ViewModifier {
    let isSelected: Bool
    func body(content: Content) -> some View {
        if isSelected {
            content.liquidGlass(in: Capsule(style: .continuous))
        } else {
            content
        }
    }
}

/// ⌘1…⌘9 for the first nine segments; further items have no shortcut.
private struct SegmentShortcut: ViewModifier {
    let index: Int
    func body(content: Content) -> some View {
        if index < 9 {
            content.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
        } else {
            content
        }
    }
}

#Preview("Segments") {
    struct Host: View {
        @State var selection = "all"
        var body: some View {
            OMSegmentedControl(items: [
                OMSegmentItem(id: "all", title: "All"),
                OMSegmentItem(id: "claude", title: "Claude", serviceID: "claude", showsDot: true),
                OMSegmentItem(id: "codex", title: "Codex", serviceID: "codex"),
                OMSegmentItem(id: "antigravity", title: "Antigravity", serviceID: "antigravity"),
            ], selection: $selection)
            .padding().frame(width: 328)
        }
    }
    return Host()
}
```

- [ ] **Step 2: Build and review the preview**

Run: `xcodegen generate && xcodebuild ... build`
Expected: BUILD SUCCEEDED; clicking segments in the canvas moves the selected capsule; the Claude item shows an amber dot.

- [ ] **Step 3: Commit**

```bash
git add UsageTracker/UI/DesignSystem/OMSegmentedControl.swift
git commit -m "Design system: OMSegmentedControl (All · providers)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

### Task 7: `OMProviderTile` and `OMCostTile`

**Files:**
- Create: `UsageTracker/UI/DesignSystem/OMProviderTile.swift`
- Create: `UsageTracker/UI/DesignSystem/OMCostTile.swift`

**Interfaces:**
- Consumes: `WindowRanking.heroBucket/secondaryBucket/shortWindowLabel/remainingText` (Task 2), `OMRing` (Task 4), `OMChip` (Task 5), `BarSegment`, `ProviderIconView`, `OMSurface`, `OMRadius`, `ServiceSnapshot`, `ServiceState`.
- Produces:
  ```swift
  struct OMProviderTile: View { let service: ServiceSnapshot; let action: () -> Void }
  struct OMCostTile: View {
      let services: [ServiceSnapshot]
      static func total(_ services: [ServiceSnapshot]) -> Double        // sum of weekCost, 0 when none
      static func breakdown(_ services: [ServiceSnapshot]) -> String    // "Claude $15.60 · Codex $8.20"
  }
  ```

- [ ] **Step 1: Write the failing tests for the cost helpers**

Append to `WindowRankingTests`:

```swift
    // MARK: cost tile
    func testCostTotalAndBreakdown() {
        let services = [
            Fixture.snapshot(id: "claude", displayName: "Claude", weekCost: 15.6),
            Fixture.snapshot(id: "codex", displayName: "Codex", weekCost: 8.2),
            Fixture.snapshot(id: "grok", displayName: "Grok", weekCost: nil),
        ]
        XCTAssertEqual(OMCostTile.total(services), 23.8, accuracy: 0.001)
        XCTAssertEqual(OMCostTile.breakdown(services), "Claude $15.60 · Codex $8.20")
        XCTAssertEqual(OMCostTile.total([Fixture.snapshot(id: "grok", weekCost: nil)]), 0)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test ... -only-testing:UsageTrackerTests/WindowRankingTests/testCostTotalAndBreakdown`
Expected: compile error "cannot find 'OMCostTile' in scope".

- [ ] **Step 3: Implement both tiles**

```swift
// UsageTracker/UI/DesignSystem/OMProviderTile.swift
import SwiftUI

/// Control-Center style tile for the All tab: icon · name · plan, the hero
/// window as a ring with its label and time left, the secondary window as a
/// thin bar. A provider that can't report right now shows its state chip
/// instead of the ring and dims. The whole tile is a button (→ provider tab).
struct OMProviderTile: View {
    let service: ServiceSnapshot
    let action: () -> Void

    private var hero: UsageBucket? { WindowRanking.heroBucket(for: service) }
    private var secondary: UsageBucket? { WindowRanking.secondaryBucket(for: service) }
    private var isHealthy: Bool { service.state == .ok }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: OMSpacing.s) {
                header
                middle
                footer
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: OMRadius.tile, style: .continuous).fill(OMSurface.tile))
            .overlay(RoundedRectangle(cornerRadius: OMRadius.tile, style: .continuous).strokeBorder(OMSurface.hairline, lineWidth: 0.5))
            .opacity(isHealthy ? 1 : 0.7)
            .contentShape(RoundedRectangle(cornerRadius: OMRadius.tile, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var header: some View {
        HStack(spacing: 6) {
            ProviderIconView(serviceID: service.id, sfFallback: service.icon, size: 16)
                .foregroundStyle(.tint)
            Text(service.displayName).font(OMFont.bodyStrong).lineLimit(1)
            Spacer(minLength: 4)
            if let plan = service.plan {
                Text(plan).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var middle: some View {
        HStack(spacing: 9) {
            if isHealthy, let hero {
                OMRing(percent: hero.clampedPercent, size: .medium, pace: hero.elapsedFraction())
                VStack(alignment: .leading, spacing: 2) {
                    Text(WindowRanking.shortWindowLabel(hero.label))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(WindowRanking.remainingText(until: hero.resetsAt) ?? "")
                        .font(OMFont.caption.weight(.semibold))
                }
            } else if isHealthy, let cost = service.weekCost {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last 7 days").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(cost, format: .currency(code: "USD").precision(.fractionLength(2)))
                        .font(OMFont.numeral).monospacedDigit()
                }
            } else {
                OMChip(text: stateText, tint: stateTint)
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var footer: some View {
        if isHealthy, let secondary {
            VStack(alignment: .leading, spacing: 3) {
                BarSegment(percent: secondary.clampedPercent, height: 5, showsLabel: false)
                Text("\(WindowRanking.shortWindowLabel(secondary.label)) \(Int(secondary.clampedPercent.rounded()))%")
                    .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
            }
        } else {
            Color.clear.frame(height: 1)
        }
    }

    private var stateText: String {
        switch service.state {
        case .notSignedIn: "Sign in"
        case .notRunning: "Not running"
        case .error: "Error"
        case .ok: "OK"
        }
    }
    private var stateTint: Color {
        switch service.state {
        case .notSignedIn: .orange
        case .notRunning: .secondary
        case .error: .red
        case .ok: .green
        }
    }
    private var accessibilityText: String {
        if let hero, isHealthy {
            return "\(service.displayName), \(hero.label) \(Int(hero.clampedPercent.rounded())) percent used"
        }
        return "\(service.displayName), \(stateText)"
    }
}

#Preview("Tiles") {
    let session = UsageBucket(id: "five_hour", label: "Current session", utilization: 37, resetsAt: Date().addingTimeInterval(8100), kind: .session)
    let weekly = UsageBucket(id: "seven_day", label: "All models", utilization: 52, resetsAt: Date().addingTimeInterval(86400 * 2), kind: .weekly)
    let ok = ServiceSnapshot(id: "claude", displayName: "Claude", icon: "sparkles", plan: "Max 20x", accountLabel: nil, buckets: [session, weekly], extraUsage: nil, weekCost: 15.6, state: .ok, stateMessage: nil, fetchedAt: Date())
    let signedOut = ServiceSnapshot(id: "codex", displayName: "Codex", icon: "terminal", plan: nil, accountLabel: nil, buckets: [], extraUsage: nil, weekCost: nil, state: .notSignedIn, stateMessage: "Sign in", fetchedAt: Date())
    return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
        OMProviderTile(service: ok) {}
        OMProviderTile(service: signedOut) {}
    }
    .padding().frame(width: 328)
}
```

```swift
// UsageTracker/UI/DesignSystem/OMCostTile.swift
import SwiftUI

/// Full-width "Last 7 days" tile on the All tab: total local $ accounting across
/// providers plus a per-provider breakdown. Callers hide it when `total == 0`.
struct OMCostTile: View {
    let services: [ServiceSnapshot]

    static func total(_ services: [ServiceSnapshot]) -> Double {
        services.compactMap(\.weekCost).reduce(0, +)
    }

    static func breakdown(_ services: [ServiceSnapshot]) -> String {
        services.compactMap { s -> String? in
            guard let cost = s.weekCost, cost > 0 else { return nil }
            return "\(s.displayName) \(money(cost))"
        }
        .joined(separator: " · ")
    }

    static func money(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Last 7 days").font(OMFont.bodyStrong)
                Text(Self.breakdown(services)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(Self.money(Self.total(services)))
                .font(OMFont.heroNumeral)
                .monospacedDigit()
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: OMRadius.tile, style: .continuous).fill(OMSurface.tile))
        .overlay(RoundedRectangle(cornerRadius: OMRadius.tile, style: .continuous).strokeBorder(OMSurface.hairline, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Last 7 days \(Self.money(Self.total(services)))")
    }
}

#Preview {
    let a = ServiceSnapshot(id: "claude", displayName: "Claude", icon: "sparkles", plan: nil, accountLabel: nil, buckets: [], extraUsage: nil, weekCost: 15.6, state: .ok, stateMessage: nil, fetchedAt: Date())
    let b = ServiceSnapshot(id: "codex", displayName: "Codex", icon: "terminal", plan: nil, accountLabel: nil, buckets: [], extraUsage: nil, weekCost: 8.2, state: .ok, stateMessage: nil, fetchedAt: Date())
    return OMCostTile(services: [a, b]).padding().frame(width: 328)
}
```

- [ ] **Step 4: Run the tests and build**

Run: `xcodegen generate && xcodebuild test ... -only-testing:UsageTrackerTests/WindowRankingTests`
Expected: PASS including `testCostTotalAndBreakdown`; previews render two tiles and the cost tile.

- [ ] **Step 5: Commit**

```bash
git add UsageTracker/UI/DesignSystem/OMProviderTile.swift UsageTracker/UI/DesignSystem/OMCostTile.swift UsageTrackerTests/WindowRankingTests.swift
git commit -m "Design system: provider tile and cost tile for the All tab

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

### Task 8: `OMHero`

**Files:**
- Create: `UsageTracker/UI/DesignSystem/OMHero.swift`
- Reference: `UsageTracker/UI/PopoverView.swift:181-192` (`statusPhrase`, `heroDetail` wording)

**Interfaces:**
- Consumes: `OMRing`, `BurnVerdict` (Task 3), `WindowRanking.remainingText`, `OMFont`.
- Produces:
  ```swift
  struct OMHero: View {
      let hero: UsageBucket
      var verdict: BurnVerdict? = nil
      static func statusPhrase(_ percent: Double) -> String   // existing wording
  }
  ```

- [ ] **Step 1: Write the failing test**

Append to `WindowRankingTests`:

```swift
    // MARK: hero phrase
    func testStatusPhraseWording() {
        XCTAssertEqual(OMHero.statusPhrase(10), "Plenty of headroom")
        XCTAssertEqual(OMHero.statusPhrase(50), "On track")
        XCTAssertEqual(OMHero.statusPhrase(70), "Running hot")
        XCTAssertEqual(OMHero.statusPhrase(90), "Almost at the limit")
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test ... -only-testing:UsageTrackerTests/WindowRankingTests/testStatusPhraseWording`
Expected: compile error "cannot find 'OMHero' in scope".

- [ ] **Step 3: Implement**

```swift
// UsageTracker/UI/DesignSystem/OMHero.swift
import SwiftUI

/// Provider-tab header: the hero window as a large ring next to its name,
/// time to reset, the status phrase, and the burn verdict when there is one.
struct OMHero: View {
    let hero: UsageBucket
    var verdict: BurnVerdict? = nil

    static func statusPhrase(_ percent: Double) -> String {
        if percent >= 90 { return "Almost at the limit" }
        if percent >= 70 { return "Running hot" }
        if percent >= 50 { return "On track" }
        return "Plenty of headroom"
    }

    var body: some View {
        HStack(spacing: 14) {
            OMRing(percent: hero.clampedPercent, size: .hero, pace: hero.elapsedFraction())
            VStack(alignment: .leading, spacing: 3) {
                Text(hero.label).font(.system(size: 14, weight: .semibold))
                if let remaining = WindowRanking.remainingText(until: hero.resetsAt) {
                    Text(remaining).font(OMFont.caption).foregroundStyle(.secondary)
                        .help("Resets \(hero.resetsAt.formatted(date: .abbreviated, time: .shortened))")
                }
                Text(Self.statusPhrase(hero.clampedPercent))
                    .font(OMFont.caption.weight(.semibold))
                    .foregroundStyle(usageStatusColor(hero.clampedPercent))
                if let verdict {
                    HStack(spacing: 5) {
                        Image(systemName: verdict.willHit ? "flame.fill" : "checkmark.circle")
                            .font(.caption2)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(verdict.willHit ? Color.orange : Color.secondary)
                        Text(verdict.text)
                            .font(.caption2)
                            .foregroundStyle(verdict.willHit ? Color.primary : Color.secondary)
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, OMSpacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(hero.label), \(Int(hero.clampedPercent.rounded())) percent used, \(Self.statusPhrase(hero.clampedPercent))")
    }
}

#Preview("Hero") {
    let session = UsageBucket(id: "five_hour", label: "Current session", utilization: 37, resetsAt: Date().addingTimeInterval(8100), kind: .session)
    return OMHero(hero: session, verdict: BurnVerdict(willHit: true, text: "At this pace, limit in ~1h 40m"))
        .padding().frame(width: 328)
}
```

- [ ] **Step 4: Run the test and build**

Run: `xcodegen generate && xcodebuild test ... -only-testing:UsageTrackerTests/WindowRankingTests`
Expected: PASS; preview renders the hero.

- [ ] **Step 5: Commit**

```bash
git add UsageTracker/UI/DesignSystem/OMHero.swift UsageTrackerTests/WindowRankingTests.swift
git commit -m "Design system: OMHero for the provider tab

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

### Task 9: `OMRingRow`

**Files:**
- Create: `UsageTracker/UI/DesignSystem/OMRingRow.swift`
- Reference: `UsageTracker/UI/PopoverView.swift:600-640` (unused-windows disclosure wording) and `:665-673` (`emptyHint`)

**Interfaces:**
- Consumes: `OMRing`, `WindowRanking.shortWindowLabel`.
- Produces:
  ```swift
  struct OMRingRow: View {
      let buckets: [UsageBucket]     // already ordered; caller decides folding
  }
  ```
  Renders a 4-column `LazyVGrid` of `OMRing(.small)` + shortened label; buckets at 0 % get the label only in `.tertiary` with the empty hint as a tooltip.

- [ ] **Step 1: Implement**

```swift
// UsageTracker/UI/DesignSystem/OMRingRow.swift
import SwiftUI

/// Weekly / model-scoped windows as a grid of small rings. Four per row; an
/// untouched window keeps its ring (so the grid stays aligned) but dims.
struct OMRingRow: View {
    let buckets: [UsageBucket]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: OMSpacing.s), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, spacing: OMSpacing.m) {
            ForEach(buckets) { bucket in
                VStack(spacing: 5) {
                    OMRing(percent: bucket.clampedPercent, size: .small, pace: bucket.elapsedFraction())
                    Text(WindowRanking.shortWindowLabel(bucket.label))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .opacity(bucket.clampedPercent == 0 ? 0.55 : 1)
                .help(helpText(bucket))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(bucket.label), \(Int(bucket.clampedPercent.rounded())) percent used")
            }
        }
    }

    private func helpText(_ bucket: UsageBucket) -> String {
        if bucket.resetsAt < .distantFuture {
            return "\(bucket.label) · resets \(bucket.resetsAt.formatted(date: .abbreviated, time: .shortened))"
        }
        return bucket.label
    }
}

#Preview("Ring row") {
    let mk = { (id: String, label: String, p: Double) in
        UsageBucket(id: id, label: label, utilization: p, resetsAt: Date().addingTimeInterval(86400 * 3), kind: .weekly)
    }
    return OMRingRow(buckets: [mk("seven_day", "All models", 52), mk("seven_day_fable", "Fable only", 12), mk("seven_day_opus", "Opus only", 8), mk("seven_day_sonnet", "Sonnet only", 74), mk("seven_day_haiku", "Haiku only", 0)])
        .padding().frame(width: 328)
}
```

- [ ] **Step 2: Build and review the preview**

Run: `xcodegen generate && xcodebuild ... build`
Expected: BUILD SUCCEEDED; five rings wrap onto two rows, the Haiku one dimmed.

- [ ] **Step 3: Commit**

```bash
git add UsageTracker/UI/DesignSystem/OMRingRow.swift
git commit -m "Design system: OMRingRow for weekly windows

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

## P3 — Popover

The rebuild keeps `PopoverView.swift` as the single screen file but shrinks it:
window logic lives in `WindowRanking`/`BurnVerdict`, visuals in the kit. The
per-service state-help popover (`StateHelp`, `stateHelp`, `stateHelpContent`,
`PopoverView.swift:472-556`) is kept verbatim inside a new `ServiceStateChip`
view in the same file.

### Task 10: Header, segmented control and tab state

**Files:**
- Modify: `UsageTracker/UI/PopoverView.swift` (top of file through `header`, lines 1–178)

**Interfaces:**
- Consumes: `OMSegmentedControl`/`OMSegmentItem`, `WindowRanking.resolveTab/allTab`, `AppState` (`snapshot`, `isLoading`, `refreshNow()`), `DashboardState.shared.burn(for:)`.
- Produces (private to the view, used by Tasks 11–12):
  ```swift
  private var displayedServices: [ServiceSnapshot]
  private var showsSegments: Bool               // displayedServices.count > 1
  private var currentTab: String                // WindowRanking.resolveTab(stored:displayed:)
  private var selectedService: ServiceSnapshot? // nil on All
  ```

- [ ] **Step 1: Replace the tab bar and header**

Edit `PopoverView` so the body becomes:

```swift
    @AppStorage("selectedProviderTab") private var selectedProviderTab: String = WindowRanking.allTab

    var body: some View {
        VStack(alignment: .leading, spacing: OMSpacing.m) {
            header
            if state.snapshot.isStale && state.snapshot.hasAnyData { staleNotice }
            if showsSegments { segments }
            content
            footer
        }
        .padding(OMSpacing.l)
        .frame(width: 360)
    }

    private var displayedServices: [ServiceSnapshot] { state.snapshot.services }
    private var showsSegments: Bool { displayedServices.count > 1 }
    private var currentTab: String {
        showsSegments
            ? WindowRanking.resolveTab(stored: selectedProviderTab, displayed: displayedServices)
            : (displayedServices.first?.id ?? WindowRanking.allTab)
    }
    private var selectedService: ServiceSnapshot? {
        displayedServices.first { $0.id == currentTab }
    }

    private var segments: some View {
        OMSegmentedControl(
            items: [OMSegmentItem(id: WindowRanking.allTab, title: "All")]
                + displayedServices.map { OMSegmentItem(id: $0.id, title: $0.displayName, serviceID: $0.id, sfFallback: $0.icon) },
            selection: Binding(
                get: { currentTab },
                set: { selectedProviderTab = $0 }
            )
        )
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text("Omelette").font(OMFont.title)
                TimelineView(.periodic(from: .now, by: 5)) { ctx in
                    Text(metaLine(now: ctx.date))
                }
                .font(OMFont.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if state.isLoading { ProgressView().controlSize(.small) }
        }
        .accessibilityElement(children: .combine)
    }

    private func metaLine(now: Date) -> String {
        let updated = updatedText(now: now)
        if let plan = selectedService?.plan { return "\(plan) · \(updated)" }
        return updated
    }
```

Keep `updatedText(now:)` unchanged. Delete `tabBar`, `providerTab`, `tabDotColor`, `heroServices`, `heroBucket`, `showsHero`, `statusPhrase`, `heroDetail` from the view (their logic now lives in `WindowRanking` / `OMHero`). Move the existing `noticeRow(icon:tint:text:)` into a `staleNotice` computed view with the same wording:

```swift
    private var staleNotice: some View {
        noticeRow(
            icon: "wifi.exclamationmark", tint: .orange,
            text: "Can't refresh — showing data from \(state.snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))"
        )
        .help(state.snapshot.lastError ?? "The last refresh attempt failed.")
    }
```

- [ ] **Step 2: Build**

Run: `xcodebuild ... build`
Expected: compile errors only in `content` (it still references removed members) — fix in Task 11; do not commit yet.

---

### Task 11: All tab and provider tab content

**Files:**
- Modify: `UsageTracker/UI/PopoverView.swift` (`content`, `ServiceSection`)

**Interfaces:**
- Consumes: Task 10 properties, `OMProviderTile`, `OMCostTile`, `OMHero`, `OMRingRow`, `OMSectionHeader`, `OMKeyValueRow`, `OMChip`, `BurnVerdict.make`, `WindowRanking`.
- Produces: `private struct ProviderDetail: View` (replaces `ServiceSection`), `private struct ServiceStateChip: View` (chip + help popover).

- [ ] **Step 1: Rewrite `content`**

```swift
    @ViewBuilder
    private var content: some View {
        if displayedServices.isEmpty {
            HStack {
                ProgressView().controlSize(.small)
                Text("Loading…").font(OMFont.body).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, OMSpacing.xs)
        } else if let service = selectedService {
            ProviderDetail(service: service, burn: dashboard.burn(for: service.id))
        } else {
            allTab
        }
    }

    private var allTab: some View {
        VStack(alignment: .leading, spacing: OMSpacing.s) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: OMSpacing.s), GridItem(.flexible(), spacing: OMSpacing.s)], spacing: OMSpacing.s) {
                ForEach(displayedServices) { service in
                    OMProviderTile(service: service) {
                        withAnimation(.smooth(duration: 0.2)) { selectedProviderTab = service.id }
                    }
                }
            }
            if OMCostTile.total(displayedServices) > 0 {
                OMCostTile(services: displayedServices)
            }
        }
    }
```

- [ ] **Step 2: Replace `ServiceSection` with `ProviderDetail`**

Delete `private struct ServiceSection` (lines 341–735 of the current file) and add:

```swift
// MARK: - Provider tab

private struct ProviderDetail: View {
    let service: ServiceSnapshot
    let burn: BurnRatePrediction?

    @State private var showUnusedWindows = false

    private var sessionBuckets: [UsageBucket] { service.buckets.filter { $0.kind == .session } }
    private var weeklyBuckets: [UsageBucket] { service.buckets.filter { $0.kind == .weekly || $0.kind == .modelSpecific } }
    /// Untouched model-specific windows are noise most of the day — fold them
    /// behind a disclosure row. "All models" stays visible even at zero.
    private var visibleWeekly: [UsageBucket] { weeklyBuckets.filter { $0.clampedPercent >= 0.05 || $0.id == "seven_day" } }
    private var unusedWeekly: [UsageBucket] { weeklyBuckets.filter { $0.clampedPercent < 0.05 && $0.id != "seven_day" } }
    private var hero: UsageBucket? { WindowRanking.heroBucket(for: service) }
    /// Weekly windows other than the one already shown as the hero.
    private var weeklyForRow: [UsageBucket] {
        let shown = visibleWeekly + (showUnusedWindows ? unusedWeekly : (unusedWeekly.count == 1 ? unusedWeekly : []))
        return shown.filter { $0.id != hero?.id }
    }
    private var nothingToShow: Bool {
        service.buckets.isEmpty && service.extraUsage == nil && (service.weekCost ?? 0) == 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OMSpacing.m) {
            if service.state != .ok {
                HStack {
                    if let msg = service.stateMessage, !msg.isEmpty {
                        Text(msg).font(OMFont.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                    Spacer()
                    ServiceStateChip(service: service)
                }
            }
            if let hero {
                OMHero(hero: hero, verdict: BurnVerdict.make(burn: burn, sessionBuckets: sessionBuckets))
            } else if service.state == .ok, let cost = service.weekCost, cost > 0 {
                // Pay-as-you-go without windows: the 7-day spend is the headline.
                OMKeyValueRow(label: "Last 7 days", value: OMCostTile.money(cost))
            }
            if !weeklyForRow.isEmpty {
                OMSectionHeader(title: "Weekly limits", trailing: weeklyReset)
                OMRingRow(buckets: weeklyForRow)
                unusedToggle
            } else if unusedWeekly.count > 1 {
                unusedToggle
            }
            if let extra = service.extraUsage, extra.isEnabled {
                OMKeyValueRow(
                    label: extraUsageTitle(plan: service.plan),
                    value: "\(OMCostTile.money(extra.usedCredits)) / \(extra.monthlyLimit.formatted(.currency(code: "USD").precision(.fractionLength(0))))",
                    barPercent: extra.utilization
                )
            }
            if hero != nil, let week = service.weekCost, week > 0 {
                OMKeyValueRow(label: "Last 7 days", value: OMCostTile.money(week))
            }
            if service.state == .ok, nothingToShow {
                Text("Server responded but returned no usage data.")
                    .font(OMFont.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    /// "resets in 2d 4h" for the all-models weekly; nil when unknown.
    private var weeklyReset: String? {
        guard let weekly = weeklyBuckets.first(where: { $0.id == "seven_day" }) ?? weeklyBuckets.first,
              let text = WindowRanking.remainingText(until: weekly.resetsAt) else { return nil }
        return "resets in \(text.replacingOccurrences(of: " left", with: ""))"
    }

    // A toggle row costs as much space as a ring row, so only fold when there
    // are at least two untouched windows (a single one is shown inline).
    @ViewBuilder
    private var unusedToggle: some View {
        if unusedWeekly.count > 1 {
            Button {
                withAnimation(.smooth(duration: 0.2)) { showUnusedWindows.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(showUnusedWindows ? 90 : 0))
                    Text(showUnusedWindows ? "Hide unused windows" : "\(unusedWeekly.count) unused windows")
                        .font(OMFont.caption)
                }
                .foregroundStyle(.secondary)
                .frame(minHeight: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - State chip with recovery help

/// The capsule reads as a button, so it must act like one: clicking walks the
/// user through fixing the state instead of doing nothing.
private struct ServiceStateChip: View {
    let service: ServiceSnapshot
    @State private var showsStateHelp = false

    var body: some View {
        let (text, color): (String, Color) = {
            switch service.state {
            case .notSignedIn: return ("Sign in", .orange)
            case .notRunning: return ("Not running", .secondary)
            case .error: return ("Error", .red)
            case .ok: return ("OK", .green)
            }
        }()
        Group {
            if let help = stateHelp {
                Button { showsStateHelp.toggle() } label: { OMChip(text: text, tint: color) }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showsStateHelp, arrowEdge: .bottom) { stateHelpContent(help) }
            } else {
                OMChip(text: text, tint: color)
            }
        }
    }

    // ⬇ Move `StateHelp`, `stateHelp` and `stateHelpContent(_:)` here VERBATIM
    //    from the current PopoverView.swift:472-556 (they reference `service`
    //    and `showsStateHelp`, both available in this struct).
}
```

The `emptyHint(for:)` wording ("You haven't used Opus yet", "No OAuth apps yet") moves into `OMRingRow.helpText` for zero-percent buckets: add to `OMRingRow` (Task 9 file) the function below and call it when `bucket.clampedPercent == 0`:

```swift
    private func emptyHint(for bucket: UsageBucket) -> String {
        if bucket.id == "seven_day_oauth_apps" { return "No OAuth apps yet" }
        guard bucket.kind == .modelSpecific else { return bucket.label }
        var name = bucket.label
        if name.hasSuffix(" only") { name.removeLast(" only".count) }
        return "You haven't used \(name) yet"
    }
```

- [ ] **Step 3: Delete the now-unused `formatReset` and the old `#Preview("Service section")`; add new previews**

```swift
#Preview("Popover — All") {
    PopoverView(state: AppState.shared)
}
```

- [ ] **Step 4: Build, run all tests**

Run: `xcodegen generate && xcodebuild ... build && xcodebuild test ...`
Expected: BUILD SUCCEEDED, all tests PASS (including the unchanged `DashboardSelectionTests`, `UsageNotifierRulesTests`).

- [ ] **Step 5: Commit**

```bash
git add UsageTracker/UI/PopoverView.swift UsageTracker/UI/DesignSystem/OMRingRow.swift
git commit -m "Popover: All tab with provider tiles, provider tab on the design system

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

### Task 12: Footer polish and keyboard

**Files:**
- Modify: `UsageTracker/UI/PopoverView.swift` (`footer`)

- [ ] **Step 1: Keep the footer, align spacing to tokens**

The footer (`Dashboard ⌘D`, floating toggle, `⌘,`, `⌘R`, `Quit ⌘Q`) stays functionally identical. Change its `VStack(spacing: 10)` to `OMSpacing.s`, the divider to `Rectangle().fill(OMSurface.hairline).frame(height: 0.5)`, and the Quit label font to `OMFont.caption`. Verify ⌘1 selects All and ⌘2 the first provider (from `OMSegmentedControl`).

- [ ] **Step 2: Build and run the app**

Run: `xcodebuild ... build && open build/DerivedData/Build/Products/Debug/Omelette.app`
Expected: popover opens on All with tiles; ⌘2 switches to the first provider; footer shortcuts work.

- [ ] **Step 3: Commit**

```bash
git add UsageTracker/UI/PopoverView.swift
git commit -m "Popover: footer on design tokens

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

### Task 13: Regression checklist (manual, recorded in the PR/commit body)

**Files:** none (verification only). Use the running Debug build; for keychain-backed Claude data either click "Always Allow" once for the Debug signature or run the exported release app (see memory: local builds are signed "Apple Development").

- [ ] Hero ring, status phrase, "Xh Ym left" on the Claude tab.
- [ ] Burn verdict line appears under the hero when `DashboardState` has a fresh prediction.
- [ ] Weekly rings: All + used model windows; "N unused windows" toggle reveals dimmed rings; hovering a 0 % ring shows "You haven't used X yet".
- [ ] Extra usage / Spend limit row with bar; title switches for Enterprise/Team plans.
- [ ] Last 7 days row on the provider tab; cost tile on All sums providers.
- [ ] Signed-out provider: All tile shows the chip and dims; provider tab shows message + chip; clicking the chip opens the help popover with Copy / Open Antigravity / link as before.
- [ ] Stale notice row under the header when the network is off; last-good data remains visible.
- [ ] Single enabled provider: no segmented control, provider tab shown directly.
- [ ] Stored tab "grok" with Grok disabled → opens on All (self-heal).
- [ ] Light and dark appearance; Reduce Transparency on (glass falls back cleanly).
- [ ] VoiceOver reads tiles, rings and tabs with the labels above.

Record the checklist result in the final commit message of P3 (`Popover: regression checklist passed — …`), no code change.

---

## P4 — Call sites, menu bar, release prep

### Task 14: Migrate `UsageRing` call sites and delete it

**Files:**
- Modify: `UsageTracker/UI/Dashboard/OverviewView.swift:63`
- Modify: `UsageTracker/UI/Components/BarSegment.swift` (delete `UsageRing`, lines 55–83)

- [ ] **Step 1: Replace the dashboard ring**

In `OverviewView.swift:63` change
`UsageRing(percent: bucket?.clampedPercent ?? 0, size: 48)` to
`OMRing(percent: bucket?.clampedPercent ?? 0, size: .medium)`.

- [ ] **Step 2: Delete `UsageRing`**

Remove the `/// Circular gauge…` doc comment and the whole `struct UsageRing` from `BarSegment.swift`. `BarSegment` itself stays.

- [ ] **Step 3: Build, grep, test**

Run: `grep -rn "UsageRing" UsageTracker UsageTrackerWidget; xcodebuild ... build && xcodebuild test ...`
Expected: grep prints nothing; build and tests green.

- [ ] **Step 4: Commit**

```bash
git add UsageTracker/UI/Dashboard/OverviewView.swift UsageTracker/UI/Components/BarSegment.swift
git commit -m "Replace UsageRing with OMRing everywhere

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

### Task 15: Menu bar restyle and the reserved agents slot

**Files:**
- Modify: `UsageTracker/UI/MenuBarLabel.swift`

**Interfaces:**
- Consumes: `usageStatusColor` (already used at line 71 — colour change is automatic), `OMFont.menuNumeral`.
- Produces: `private var leadingSlot: some View` in `MenuBarLabel` — phase 2 replaces its `EmptyView()` with the agents pill.

- [ ] **Step 1: Add the slot and switch fonts**

In `MenuBarLabel.body`, change the outer `HStack(spacing: 4)` content to:

```swift
        HStack(spacing: 4) {
            leadingSlot
            if displayServices.isEmpty {
                Image(systemName: "chart.bar")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(displayServices) { service in
                    if service.buckets.isEmpty, let cost = service.weekCost {
                        MiniCostPill(service: service, weekCost: cost, isStale: snapshot.isStale)
                    } else {
                        MiniServiceBar(service: service, isStale: snapshot.isStale, showsNumber: showsNumber)
                    }
                }
            }
        }
```

and add:

```swift
    /// Reserved for the phase-2 agents pill (count of live agent sessions).
    @ViewBuilder
    private var leadingSlot: some View {
        EmptyView()
    }
```

Replace both `.font(.system(size: 11, weight: .semibold, design: .rounded))` occurrences (`MiniCostPill` and `MiniServiceBar.content`) with `.font(OMFont.menuNumeral)`.

- [ ] **Step 2: Build and look at the menu bar**

Run: `xcodebuild ... build && open build/DerivedData/Build/Products/Debug/Omelette.app`
Expected: pills are green below 70 %, amber/red above; numbers unchanged in size.

- [ ] **Step 3: Commit**

```bash
git add UsageTracker/UI/MenuBarLabel.swift
git commit -m "Menu bar: token fonts, battery colours, reserved agents slot

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

### Task 16: CHANGELOG and version bump

**Files:**
- Modify: `CHANGELOG.md` (top)
- Modify: `project.yml` (`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in BOTH the `UsageTracker` and `UsageTrackerWidget` targets)

- [ ] **Step 1: Bump versions**

Set `MARKETING_VERSION: "1.14.0"` and `CURRENT_PROJECT_VERSION: "30"` in both targets; run `xcodegen generate`.

- [ ] **Step 2: Add the changelog entry**

Prepend to `CHANGELOG.md` (match the existing heading style of the file):

```markdown
## 1.14.0 — unreleased

### Changed
- New popover: an **All** tab with a tile per provider (ring for the leading window, bar for the weekly, plan) and a 7-day cost tile; provider tabs with a large session ring, weekly windows as rings, extra usage and cost rows. `All` is the default tab.
- Design system (`UI/DesignSystem/`): tokens, ring gauge with pace marker, segmented control, tiles, hero, section headers, chips.
- Usage colours are now battery-style: green while comfortable, amber from 70 %, red from 90 % (was accent blue below 70 %).
- Dashboard overview ring and menu-bar pills use the same components/colours.

### Internal
- `WindowRanking` and `BurnVerdict` extracted from the popover and unit-tested.
```

- [ ] **Step 3: Full build + tests, commit**

Run: `xcodebuild ... build && xcodebuild test ...`
Expected: green.

```bash
git add CHANGELOG.md project.yml
git commit -m "Prepare 1.14.0: design system and All/provider popover

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

The owner runs `scripts/build_dmg.sh` / `notarize_dmg.sh` and the GitHub release after testing; not part of this plan.

---

## Self-review notes

- Spec coverage: tokens (T1), components (T4–T9), popover header/segment/All/provider/footer (T10–T12), window selection helpers + tests (T2, T7, T8), burn verdict (T3), menu bar (T15), colour migration + `UsageRing` removal (T1, T14), regression checklist (T13), changelog (T16). Pace marker (spec) is in `OMRing` and fed from `elapsedFraction()` in `OMHero`, `OMProviderTile`, `OMRingRow`.
- The spec's "hero for accounts with only `weekCost`" is handled in `ProviderDetail` (cost row as headline) and in `OMProviderTile.middle`.
- Names used consistently: `WindowRanking.heroBucket(for:)`, `secondaryBucket(for:)`, `shortWindowLabel(_:)`, `resolveTab(stored:displayed:)`, `remainingText(until:now:)`, `BurnVerdict.make(burn:sessionBuckets:now:)`, `OMCostTile.total/breakdown/money`, `OMHero.statusPhrase(_:)`, `OMSegmentItem`, `OMSegmentedControl(items:selection:)`.
- No new test fixtures: `BurnVerdictTests` reuse the existing `Fixture.prediction(...)`; `WindowRankingTests` reuse `Fixture.snapshot(...)` / `Fixture.bucket(...)`.
