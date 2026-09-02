# Phase 3 Package 3 — Settings, Onboarding, Floating Window + Release Prep

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put the last three app surfaces — Settings, the welcome tour and the floating mini window — on the phase-1 design system, and prepare the 2.1.0 release.

**Architecture:** The floating window's selection rules (which windows fit in 130 pt, what the agents count says) are extracted into a pure `FloatingMiniLayout` enum with unit tests, and `FloatingMiniView` is rebuilt as a thin observer plus a singleton-free `FloatingMiniContent` that previews in both colour schemes. Settings and onboarding are edited in place: coloured status dots become `OMChip`, hand-rolled font literals become `OMFont` roles, onboarding groups its permission blocks into `OMSurface.tile` cards. Nothing in `SharedUI/`, `UI/Dashboard/`, `DashboardState`, `AgentHistoryStore` or `AgentChannel` is touched — packages 1 and 2 own those.

**Tech Stack:** Swift 6 (strict concurrency `minimal`), SwiftUI, macOS 14 floor with `#available(macOS 26)` Liquid Glass paths (`UsageTracker/UI/Components/LiquidGlass.swift`), XCTest (`UsageTrackerTests`, `@testable import Omelette`), xcodegen-generated project.

**Spec:** `docs/superpowers/specs/2026-09-02-phase3-surfaces-and-agent-history-design.md` (sections "Package 3" and "Release prep"; roadmap: `docs/superpowers/specs/2026-09-02-agent-control-plane-roadmap.md`)

## Global Constraints

- Deployment target macOS 14.0; every glass effect goes through the helpers in `UsageTracker/UI/Components/LiquidGlass.swift` (`liquidGlass(in:tint:)`, `GlassGroup`, `glassButtonStyle()`, `glassProminentButtonStyle()`), never a bare `glassEffect` call.
- Colour semantics: `usageStatusColor` returns `.green` below 70, `.orange` from 70, `.red` from 90. Agent-state colours come from `OMAgentColor`.
- Every user-visible string that exists today keeps its wording. The one sanctioned exception in this package: where an `OMChip` replaces a coloured dot, a redundant tick or separator inside the label may go (each such edit is spelled out in the task that makes it).
- Package 1 already moved `OMTokens`, `OMRing` and `BarSegment` to `SharedUI/` (commit `a1fd6bc`); their type names and APIs are unchanged. Reference them by name, never by path, and do not edit anything under `SharedUI/`.
- Package 2 owns `UsageTracker/UI/Dashboard/`, `DashboardState`, `AgentHistoryStore`, `AgentChannel` and `UI/Components/CardStyle.swift`. Do not modify them. Reading `DashboardState.shared.selectedService` from the floating window is fine — it already does.
- `OMFont.screenTitle` is a Package 2 addition to `SharedUI/OMTokens.swift`. Do **not** use it and do not add it; onboarding page titles keep `.title2.weight(.semibold)`.
- New source files are picked up by xcodegen from `sources: - path: UsageTracker` / `- path: UsageTrackerTests`; run `xcodegen generate` after adding a file and before building. `UsageTracker.xcodeproj/` is generated and gitignored — never `git add` it.
- Build: `xcodebuild -project UsageTracker.xcodeproj -scheme UsageTracker -configuration Debug -derivedDataPath build/DerivedData build`
- Tests: `xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData` (add `-only-testing:UsageTrackerTests/<Class>` for one class). **Always append `ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS=""` to every `xcodebuild test` invocation** — `signing.xcconfig` turns on the hardened runtime, which blocks the `DYLD_INSERT_LIBRARIES` injection XCTest needs, and the runner then hangs for ~6 min with "The test runner hung before establishing connection". Plain `build` keeps the real settings.
- The build must stay warning-free: `xcodebuild ... build 2>&1 | grep -c "warning:"` must print `0`.
- Commits end with the trailer lines
  `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` and
  `Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X`.
- Other sessions may commit the working tree while you work: re-read a file right before editing it, and prefer targeted edits over whole-file rewrites.
- No release build in this plan: the owner runs the local build/notarize flow after testing.

---

## File structure

```
UsageTracker/UI/
  FloatingMiniLayout.swift   NEW — pure: which windows the 260×130 panel shows, agents appearance
  FloatingWindow.swift       MODIFY — FloatingMiniView rebuilt + new FloatingMiniContent; controller untouched
  SettingsView.swift         MODIFY — status chips, OMFont roles, previews
  AgentsSettingsView.swift   MODIFY — hook status chips, OMFont roles, previews
  OnboardingView.swift       MODIFY — tile cards, hero ring, chips, glass dots/buttons, previews
UsageTrackerTests/
  FloatingMiniLayoutTests.swift  NEW
project.yml                  MODIFY — 2.1.0 / 31 in both targets
CHANGELOG.md                 MODIFY — [2.1.0] — unreleased
```

| Task | Deliverable | Depends on |
|---|---|---|
| 1 | `FloatingMiniLayout` + tests | — |
| 2 | `FloatingMiniView` rebuilt on the kit | 1 |
| 3 | Settings on chips and type roles | — |
| 4 | Settings → Agents on chips and type roles | — |
| 5 | Onboarding on tiles, ring, chips, glass | — |
| 6 | Version bump + CHANGELOG | 1–5 |

---

## Task 1: Floating-window layout rules (pure)

**Files:**
- Create: `UsageTracker/UI/FloatingMiniLayout.swift`
- Test: `UsageTrackerTests/FloatingMiniLayoutTests.swift`

**Interfaces:**
- Consumes: `WindowRanking.detailHero(for:)`, `WindowRanking.sessionRows(for:hero:)` (`UsageTracker/Core/WindowRanking.swift`); `OMAgentsPill.Appearance.make(needsYou:working:total:)` (`UsageTracker/UI/DesignSystem/OMAgentsPill.swift`); `UsageBucket`, `ServiceSnapshot` (`UsageTracker/Core/UsageSnapshot.swift`); `AgentSession`, `AgentState` (`UsageTracker/Agents/AgentModels.swift`).
- Produces:
  ```swift
  enum FloatingMiniLayout {
      struct Content: Equatable {
          let hero: UsageBucket?
          let rows: [UsageBucket]
          let emptyText: String?
      }
      static func content(for service: ServiceSnapshot?, maxRows: Int = 2) -> Content
      static func agents(_ sessions: [AgentSession]) -> OMAgentsPill.Appearance?
  }
  ```

- [ ] **Step 1: Write the failing tests**

Create `UsageTrackerTests/FloatingMiniLayoutTests.swift`:

```swift
import XCTest
@testable import Omelette

/// The mini window is a fixed 260 × 130 panel that never scrolls, so "which
/// windows get a row" is a rule rather than a layout accident. It lives outside
/// the view so it can be tested without a hosting window.
final class FloatingMiniLayoutTests: XCTestCase {
    private let session = Fixture.bucket(id: "five_hour", label: "Current session", percent: 37, kind: .session)
    private let session2 = Fixture.bucket(id: "one_hour", label: "Hourly", percent: 5, kind: .session)
    private let weekly = Fixture.bucket(id: "seven_day", label: "All models", percent: 76, kind: .weekly)
    private let opus = Fixture.bucket(id: "seven_day_opus", label: "Opus only", percent: 12, kind: .modelSpecific)
    private let promo = Fixture.bucket(id: "seven_day_promotional", label: "Promo pool", percent: 99, kind: .other)

    private func content(_ buckets: [UsageBucket], maxRows: Int = 2) -> FloatingMiniLayout.Content {
        FloatingMiniLayout.content(for: Fixture.snapshot(buckets: buckets), maxRows: maxRows)
    }

    // MARK: hero and rows

    func testHeroIsTheSessionWindowEvenWhenAWeeklyIsHotter() {
        // Same rule as a provider tab: the window that answers "can I keep
        // working right now" leads, whatever the weekly says.
        XCTAssertEqual(content([session, weekly]).hero?.id, "five_hour")
    }

    func testRowsAreTheRemainingWindowsWorstFirst() {
        XCTAssertEqual(content([session, opus, weekly]).rows.map(\.id), ["seven_day", "seven_day_opus"])
    }

    func testASecondSessionWindowKeepsItsSeatAgainstAHotterWeekly() {
        // The 5-hour-style windows are the numbers people check; a calm one must
        // not lose its row to a weekly that happens to be higher.
        XCTAssertEqual(content([session, session2, weekly]).rows.map(\.id), ["one_hour", "seven_day"])
    }

    func testNoMoreThanTwoRowsFit() {
        let extra = Fixture.bucket(id: "monthly", label: "Monthly", percent: 40, kind: .other)
        XCTAssertEqual(content([session, weekly, opus, extra]).rows.count, 2)
    }

    func testPromotionalPoolsNeverTakeARow() {
        // A free bonus pool at 99% costs nothing to run dry, so it never displaces
        // a real limit in two rows of space.
        XCTAssertEqual(content([session, promo, weekly]).rows.map(\.id), ["seven_day"])
    }

    func testTheHeroIsNeverRepeatedAsARow() {
        XCTAssertEqual(content([weekly, opus]).hero?.id, "seven_day")
        XCTAssertEqual(content([weekly, opus]).rows.map(\.id), ["seven_day_opus"])
    }

    // MARK: empty states

    func testNoSnapshotYetSaysLoading() {
        let content = FloatingMiniLayout.content(for: nil)
        XCTAssertNil(content.hero)
        XCTAssertTrue(content.rows.isEmpty)
        XCTAssertEqual(content.emptyText, "Loading…")
    }

    func testAServiceWithoutWindowsNamesItself() {
        let content = FloatingMiniLayout.content(for: Fixture.snapshot(id: "claude", buckets: []))
        XCTAssertNil(content.hero)
        XCTAssertEqual(content.emptyText, "You haven't used Claude yet")
    }

    func testAServiceWithWindowsHasNoEmptyText() {
        XCTAssertNil(content([session]).emptyText)
    }

    // MARK: agents count

    func testNoSessionsMeansNoAgentsCount() {
        XCTAssertNil(FloatingMiniLayout.agents([]))
    }

    func testWorkingSessionsAreCountedAndBlue() {
        let look = FloatingMiniLayout.agents([
            Fixture.agentSession(sessionID: "a", state: .working),
            Fixture.agentSession(sessionID: "b", state: .working),
            Fixture.agentSession(sessionID: "c", state: .idle),
        ])
        XCTAssertEqual(look?.dot, OMAgentColor.working)
        XCTAssertEqual(look?.text, "2")
    }

    func testAWaitingSessionOutranksTheWorkingOnes() {
        let look = FloatingMiniLayout.agents([
            Fixture.agentSession(sessionID: "a", state: .needsYou),
            Fixture.agentSession(sessionID: "b", state: .working),
        ])
        XCTAssertEqual(look?.dot, OMAgentColor.needsYou)
        XCTAssertEqual(look?.text, "1 needs you")
    }

    func testQuietSessionsShowTheTotal() {
        let look = FloatingMiniLayout.agents([
            Fixture.agentSession(sessionID: "a", state: .idle),
            Fixture.agentSession(sessionID: "b", state: .done),
        ])
        XCTAssertEqual(look?.dot, OMAgentColor.idle)
        XCTAssertEqual(look?.text, "2")
    }
}
```

- [ ] **Step 2: Run the tests and watch them fail**

```bash
cd "<repo>"
xcodegen generate
xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData \
  -only-testing:UsageTrackerTests/FloatingMiniLayoutTests \
  ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS="" 2>&1 | tail -30
```
Expected: `** TEST BUILD FAILED **` with `cannot find 'FloatingMiniLayout' in scope`.

- [ ] **Step 3: Write the layout rules**

Create `UsageTracker/UI/FloatingMiniLayout.swift`:

```swift
import SwiftUI

/// What the floating mini window draws, as a pure function of one service
/// snapshot and the live agent sessions.
///
/// The panel is a fixed 260 × 130 (`FloatingWindowController.open`) and never
/// scrolls, so a hero ring leaves room for exactly two bar rows. Deciding which
/// two here — rather than inside the view — is what makes the rule testable.
enum FloatingMiniLayout {
    /// The ring, the windows drawn as bars under it, and the sentence to show
    /// when there is no ring to draw. `hero` and `emptyText` are never both set.
    struct Content: Equatable {
        let hero: UsageBucket?
        let rows: [UsageBucket]
        let emptyText: String?
    }

    /// `maxRows` is 2 because that is what fits at 130 pt; it is a parameter only
    /// so the tests can pin the truncation without depending on the panel size.
    static func content(for service: ServiceSnapshot?, maxRows: Int = 2) -> Content {
        guard let service else {
            return Content(hero: nil, rows: [], emptyText: "Loading…")
        }
        guard let hero = WindowRanking.detailHero(for: service) else {
            return Content(hero: nil, rows: [], emptyText: "You haven't used \(service.displayName) yet")
        }
        return Content(hero: hero, rows: rows(for: service, hero: hero, maxRows: maxRows), emptyText: nil)
    }

    /// The trailing agents count. `OMAgentsPill.Appearance` already owns the
    /// needs-you → working → quiet precedence and the VoiceOver wording, so the
    /// window borrows both instead of inventing a second rule. It deliberately
    /// does not consult `agentsShowInMenuBar`: that switch is about the menu bar
    /// and says nothing about a window the user opened on purpose.
    static func agents(_ sessions: [AgentSession]) -> OMAgentsPill.Appearance? {
        OMAgentsPill.Appearance.make(
            needsYou: sessions.reduce(0) { $0 + ($1.state == .needsYou ? 1 : 0) },
            working: sessions.reduce(0) { $0 + ($1.state == .working ? 1 : 0) },
            total: sessions.count
        )
    }

    // MARK: - Private

    /// Other session windows first — mid-week a weekly often reads higher than the
    /// 5-hour window, and the 5-hour window is the one people check — then the rest
    /// worst-first with ties keeping API order. Promotional pools never take a seat:
    /// running a free bonus dry costs nothing.
    private static func rows(for service: ServiceSnapshot, hero: UsageBucket, maxRows: Int) -> [UsageBucket] {
        let sessions = WindowRanking.sessionRows(for: service, hero: hero).filter { !$0.isPromotional }
        let taken = Set(sessions.map(\.id) + [hero.id])
        let rest = service.buckets.filter { !taken.contains($0.id) && !$0.isPromotional }
        // `sorted` is not stable, so the API index is carried along and breaks ties.
        let ordered = rest.enumerated()
            .sorted { a, b in
                if a.element.clampedPercent != b.element.clampedPercent {
                    return a.element.clampedPercent > b.element.clampedPercent
                }
                return a.offset < b.offset
            }
            .map { $0.element }
        return Array((sessions + ordered).prefix(max(0, maxRows)))
    }
}
```

- [ ] **Step 4: Run the tests and watch them pass**

```bash
cd "<repo>"
xcodegen generate
xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData \
  -only-testing:UsageTrackerTests/FloatingMiniLayoutTests \
  ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS="" 2>&1 | tail -20
```
Expected: `Executed 13 tests, with 0 failures` and `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
cd "<repo>"
git add UsageTracker/UI/FloatingMiniLayout.swift UsageTrackerTests/FloatingMiniLayoutTests.swift
git commit -m "$(cat <<'EOF'
Floating window: pure rules for the two windows it shows and its agents count

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X
EOF
)"
```

---

## Task 2: Rebuild `FloatingMiniView` on the design system

**Files:**
- Modify: `UsageTracker/UI/FloatingWindow.swift:73-164` (replace `FloatingMiniView`'s body and `row(label:bucket:)`; `FloatingWindowController` at lines 1–71 stays byte-for-byte identical)

**Interfaces:**
- Consumes: `FloatingMiniLayout.content(for:maxRows:)`, `FloatingMiniLayout.agents(_:)` (Task 1); `OMRing`, `BarSegment`, `OMFont`, `OMSpacing`, `OMRadius`, `OMSurface` (`SharedUI/`); `WindowRanking.remainingText(until:now:)`, `WindowRanking.shortWindowLabel(_:)`; `ProviderIconView(serviceID:sfFallback:size:)` (`UsageTrackerWidget/ProviderIconView.swift`, compiled into the app); `AgentSessionStore.shared`, `DashboardState.shared`.
- Produces: `FloatingMiniView(state:onClose:)` — unchanged initializer, so `FloatingWindowController.open()` keeps compiling; `FloatingMiniContent(service:agents:onClose:)` for previews.

- [ ] **Step 1: Replace `FloatingMiniView` and add `FloatingMiniContent`**

Re-read the file first (another session may have touched it). Replace everything from `struct FloatingMiniView: View {` (line 73) to the end of the file with:

```swift
struct FloatingMiniView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var dashboard = DashboardState.shared
    /// Observed here rather than in a slot view: the whole window is four rows,
    /// so re-evaluating it on a hook event costs less than the extra view does.
    @ObservedObject private var agents = AgentSessionStore.shared
    let onClose: () -> Void

    init(state: AppState, onClose: @escaping () -> Void) {
        self.state = state
        self.onClose = onClose
    }

    /// Follows the dashboard's provider selection, so the two windows never
    /// disagree about whose numbers are on screen.
    private var service: ServiceSnapshot? {
        state.snapshot.services.first(where: { $0.id == dashboard.selectedService })
            ?? state.snapshot.services.first
    }

    var body: some View {
        FloatingMiniContent(
            service: service,
            agents: FloatingMiniLayout.agents(agents.sessions),
            onClose: onClose
        )
    }
}

/// Everything the window draws, with no singletons in it — which is what lets
/// both colour schemes and every empty state be previewed without a running app.
struct FloatingMiniContent: View {
    let service: ServiceSnapshot?
    var agents: OMAgentsPill.Appearance? = nil
    let onClose: () -> Void

    /// The panel is a fixed 260 × 130 (`FloatingWindowController.open`). A hero
    /// ring plus two bar rows fits at 6 pt; at `OMSpacing.s` the second row
    /// clips. This window is the one place where the token is too generous.
    private static let stackSpacing: CGFloat = 6
    /// Wide enough for "All models" shortened to "All" and for "Opus only" → "Opus".
    private static let rowLabelWidth: CGFloat = 62

    private var content: FloatingMiniLayout.Content {
        FloatingMiniLayout.content(for: service)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.stackSpacing) {
            header
            if let hero = content.hero {
                heroRow(hero)
                ForEach(content.rows) { bucket in
                    windowRow(bucket)
                }
            } else if let emptyText = content.emptyText {
                Text(emptyText)
                    .font(OMFont.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, OMSpacing.m)
        .padding(.vertical, OMSpacing.s)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: OMRadius.tile, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: OMRadius.tile, style: .continuous)
                .strokeBorder(OMSurface.hairline, lineWidth: 0.5)
        )
        .padding(2)
    }

    private var header: some View {
        HStack(spacing: OMSpacing.xs) {
            if let service {
                ProviderIconView(serviceID: service.id, sfFallback: service.icon, size: 12)
                    .foregroundStyle(.tint)
                    .frame(width: 14)
                Text(service.plan ?? service.displayName)
                    .font(OMFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text("Omelette")
                    .font(OMFont.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: OMSpacing.xs)
            if let agents {
                HStack(spacing: OMSpacing.xs) {
                    Circle()
                        .fill(agents.dot)
                        .frame(width: 6, height: 6)
                    Text(agents.text)
                        .font(OMFont.menuNumeral)
                        .monospacedDigit()
                        .foregroundStyle(agents.textColor)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(agents.accessibilityLabel)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Close")
        }
    }

    private func heroRow(_ hero: UsageBucket) -> some View {
        HStack(spacing: OMSpacing.m) {
            OMRing(percent: hero.clampedPercent, size: .medium, pace: hero.elapsedFraction())
            VStack(alignment: .leading, spacing: 2) {
                Text(hero.label)
                    .font(OMFont.bodyStrong)
                    .lineLimit(1)
                if let remaining = WindowRanking.remainingText(until: hero.resetsAt) {
                    Text(remaining)
                        .font(OMFont.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(hero.label), \(Int(hero.clampedPercent.rounded())) percent used")
    }

    private func windowRow(_ bucket: UsageBucket) -> some View {
        HStack(spacing: OMSpacing.s) {
            Text(WindowRanking.shortWindowLabel(bucket.label))
                .font(OMFont.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: Self.rowLabelWidth, alignment: .leading)
            BarSegment(
                percent: bucket.clampedPercent,
                height: 4,
                showsLabel: false,
                pace: bucket.elapsedFraction()
            )
            Text("\(Int(bucket.clampedPercent.rounded()))%")
                .font(OMFont.caption.weight(.semibold))
                .monospacedDigit()
                .frame(width: 32, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(bucket.label), \(Int(bucket.clampedPercent.rounded())) percent used")
    }
}
```

- [ ] **Step 2: Add the previews**

Append to `UsageTracker/UI/FloatingWindow.swift`:

```swift
#if DEBUG
private func floatingPreviewService(buckets: [UsageBucket]) -> ServiceSnapshot {
    ServiceSnapshot(
        id: "claude",
        displayName: "Claude",
        icon: "sparkles",
        plan: "Max 20x",
        accountLabel: nil,
        buckets: buckets,
        extraUsage: nil,
        weekCost: 12.4,
        state: .ok,
        stateMessage: nil,
        fetchedAt: Date()
    )
}

private var floatingPreviewBuckets: [UsageBucket] {
    [
        UsageBucket(id: "five_hour", label: "Current session", utilization: 37,
                    resetsAt: Date().addingTimeInterval(8100), kind: .session),
        UsageBucket(id: "seven_day", label: "All models", utilization: 76,
                    resetsAt: Date().addingTimeInterval(3 * 24 * 3600), kind: .weekly),
        UsageBucket(id: "seven_day_opus", label: "Opus only", utilization: 12,
                    resetsAt: Date().addingTimeInterval(3 * 24 * 3600), kind: .modelSpecific),
    ]
}

#Preview("Floating — two agents, light") {
    FloatingMiniContent(
        service: floatingPreviewService(buckets: floatingPreviewBuckets),
        agents: OMAgentsPill.Appearance.make(needsYou: 0, working: 2, total: 3),
        onClose: {}
    )
    .frame(width: 260, height: 130)
}

#Preview("Floating — two agents, dark") {
    FloatingMiniContent(
        service: floatingPreviewService(buckets: floatingPreviewBuckets),
        agents: OMAgentsPill.Appearance.make(needsYou: 0, working: 2, total: 3),
        onClose: {}
    )
    .frame(width: 260, height: 130)
    .preferredColorScheme(.dark)
}

#Preview("Floating — one needs you") {
    FloatingMiniContent(
        service: floatingPreviewService(buckets: floatingPreviewBuckets),
        agents: OMAgentsPill.Appearance.make(needsYou: 1, working: 2, total: 4),
        onClose: {}
    )
    .frame(width: 260, height: 130)
}

#Preview("Floating — no agents") {
    FloatingMiniContent(
        service: floatingPreviewService(buckets: floatingPreviewBuckets),
        agents: nil,
        onClose: {}
    )
    .frame(width: 260, height: 130)
}

#Preview("Floating — nothing tracked yet") {
    FloatingMiniContent(service: floatingPreviewService(buckets: []), agents: nil, onClose: {})
        .frame(width: 260, height: 130)
}
#endif
```

- [ ] **Step 3: Build and check for warnings**

```bash
cd "<repo>"
xcodebuild -project UsageTracker.xcodeproj -scheme UsageTracker -configuration Debug \
  -derivedDataPath build/DerivedData build 2>&1 | tee /tmp/p3-build.log | tail -5
grep -c "warning:" /tmp/p3-build.log
```
Expected: `** BUILD SUCCEEDED **`, and the grep prints `0`.

- [ ] **Step 4: Run the whole test suite**

```bash
cd "<repo>"
xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData \
  ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS="" 2>&1 | tail -15
```
Expected: `** TEST SUCCEEDED **` with 0 failures.

- [ ] **Step 5: Check the previews in Xcode**

Open `UsageTracker/UI/FloatingWindow.swift` in Xcode, open the canvas (⌥⌘↩) and step through all five previews. Every one must render at 260 × 130 with **no clipped row** and no truncated hero label. If the second window row clips, reduce `stackSpacing` to 5 before changing anything else.

- [ ] **Step 6: Commit**

```bash
cd "<repo>"
git add UsageTracker/UI/FloatingWindow.swift
git commit -m "$(cat <<'EOF'
Floating window: ring hero, two window bars and a live agents count

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X
EOF
)"
```

---

## Task 3: Settings on chips and type roles

**Files:**
- Modify: `UsageTracker/UI/SettingsView.swift` (Account tab status lines; every caption; previews)

**Interfaces:**
- Consumes: `OMChip(text:tint:)`, `OMFont`, `OMSpacing` (design system).
- Produces: `SettingsView` unchanged from the outside — same `Tab` enum, same `frame(width: 520, height: 540)`, same routing.

Copy rules for this task: every string stays as it is **except** the two edits called out in steps 2 and 3, both of which are a chip replacing a dot or a redundant glyph.

- [ ] **Step 1: Move every caption to the type scale**

Re-read the file, then apply three replace-all edits:

1. `.font(.caption)` → `.font(OMFont.caption)` (21 occurrences — all of them are section footers, hints and secondary values).
2. `.font(.caption.monospaced())` → `.font(OMFont.caption.monospaced())` (1 occurrence — the masked admin key).
3. `Text(svc.displayName).font(.system(size: 12, weight: .medium))` → `Text(svc.displayName).font(OMFont.bodyStrong)` (1 occurrence — the connected-service name).

Leave `.font(.system(.body, design: .monospaced))` on the `anthropic-beta` text field alone: it is an input field, not a caption.

- [ ] **Step 2: Turn the connected-service state into a chip**

In `accountTab`, replace

```swift
                            VStack(alignment: .leading, spacing: 1) {
                                Text(svc.displayName).font(OMFont.bodyStrong)
                                Text(stateLabel(svc.state) + (svc.plan.map { " · \($0)" } ?? ""))
                                    .font(OMFont.caption)
                                    .foregroundStyle(.secondary)
                            }
```

with

```swift
                            VStack(alignment: .leading, spacing: 3) {
                                Text(svc.displayName).font(OMFont.bodyStrong)
                                HStack(spacing: OMSpacing.xs) {
                                    OMChip(text: stateLabel(svc.state), tint: stateTint(svc.state))
                                    if let plan = svc.plan {
                                        Text(plan)
                                            .font(OMFont.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
```

Copy edit: the `" · "` between the state and the plan goes — the chip is its own shape and no longer needs a separator. Both strings themselves are unchanged.

Add the tint next to `stateLabel(_:)` (around line 469):

```swift
    /// Same battery semantics as everywhere else: green is fine, amber wants an
    /// action from you, red is broken, grey is "nothing to say".
    private func stateTint(_ s: ServiceState) -> Color {
        switch s {
        case .ok: return .green
        case .notSignedIn: return .orange
        case .notRunning: return .secondary
        case .error: return .red
        }
    }
```

- [ ] **Step 3: Turn the keychain result into a chip**

Replace the `@State private var keychainReadStatus: String?` declaration (line 12) with

```swift
    @State private var keychainReadStatus: KeychainReadStatus?
```

and add the type just below the `Tab` enum:

```swift
    /// The keychain button reports two very different things: a one-word success
    /// that belongs in a chip, and a system error message that does not.
    private enum KeychainReadStatus: Equatable {
        case granted
        case failed(String)
    }
```

In the "Claude keychain access" section, replace the whole span from `Button("Request keychain access now") {` down to and including the `if let status = keychainReadStatus { … }` block — the four assignments and the status text are all in it — with:

```swift
                    Button("Request keychain access now") {
                        do {
                            try ClaudeOAuthProvider.forceKeychainRead()
                            keychainReadStatus = .granted
                            AppState.shared.refreshNow()
                            // Confirmation, not a progress claim — clear it after a beat.
                            Task {
                                try? await Task.sleep(nanoseconds: 5_000_000_000)
                                keychainReadStatus = nil
                            }
                        } catch {
                            keychainReadStatus = .failed(error.localizedDescription)
                        }
                    }
                    Spacer()
                    keychainStatusView
```

and add the view next to the other helpers:

```swift
    @ViewBuilder
    private var keychainStatusView: some View {
        switch keychainReadStatus {
        case .granted:
            OMChip(text: "Access granted", tint: .green)
        case .failed(let message):
            Text("Failed: \(message)")
                .font(OMFont.caption)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        case nil:
            EmptyView()
        }
    }
```

Copy edit: `"Access granted ✓"` loses its tick — the green chip says the same thing twice otherwise. `"Failed: …"` is unchanged.

- [ ] **Step 4: Add light/dark previews**

Append to the end of `UsageTracker/UI/SettingsView.swift` (after the `Notification.Name` extension):

```swift
#if DEBUG
// The window reads the real stores, which is the point: this preview is how the
// tabs get checked in both schemes. It touches the keychain on appear (the
// masked admin key), so macOS may show one access dialog the first time.
#Preview("Settings — light") {
    SettingsView()
}

#Preview("Settings — dark") {
    SettingsView()
        .preferredColorScheme(.dark)
}
#endif
```

- [ ] **Step 5: Build and check for warnings**

```bash
cd "<repo>"
xcodebuild -project UsageTracker.xcodeproj -scheme UsageTracker -configuration Debug \
  -derivedDataPath build/DerivedData build 2>&1 | tee /tmp/p3-build.log | tail -5
grep -c "warning:" /tmp/p3-build.log
```
Expected: `** BUILD SUCCEEDED **`, grep prints `0`.

- [ ] **Step 6: Prove no caption was missed**

```bash
cd "<repo>"
grep -n "font(\.caption" UsageTracker/UI/SettingsView.swift
```
Expected: no output.

- [ ] **Step 7: Commit**

```bash
cd "<repo>"
git add UsageTracker/UI/SettingsView.swift
git commit -m "$(cat <<'EOF'
Settings: status chips for services and the keychain, captions on the type scale

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X
EOF
)"
```

---

## Task 4: Settings → Agents on chips and type roles

**Files:**
- Modify: `UsageTracker/UI/AgentsSettingsView.swift` (`statusRow`, captions, previews)

**Interfaces:**
- Consumes: `OMChip(text:tint:)`, `OMFont`, `OMSpacing`; the view's own `label(_:)` and `tint(_:)` for `HookInstallStatus`.
- Produces: nothing new — `AgentsSettingsView()` keeps its signature and its place in `SettingsView`'s `TabView`.

- [ ] **Step 1: Turn the hook status row into a chip**

Re-read the file, then replace `statusRow` (lines 102–108):

```swift
    private func statusRow(_ status: HookInstallStatus) -> some View {
        HStack(spacing: OMSpacing.s) {
            OMChip(text: label(status), tint: tint(status))
            Spacer()
        }
    }
```

The four labels are unchanged ("Installed", "Installed — older than this build", "Not installed", "Can't write — something else owns this"); the dot they used to sit next to is now the chip's own tint.

- [ ] **Step 2: Move every caption to the type scale**

Two replace-all edits:

1. `.font(.caption)` → `.font(OMFont.caption)` (7 occurrences: the install failure, both source footers, the Codex conflict hint, the alerts footer, the socket start error and the diagnostics footer).
2. `.font(.caption.monospaced())` → `.font(OMFont.caption.monospaced())` (1 occurrence — the socket path).

Leave both `.font(.system(size: 10, design: .monospaced))` blocks alone: they render JSON and a TOML line, where a smaller monospaced face is deliberate.

- [ ] **Step 3: Add light/dark previews**

Append to the end of `UsageTracker/UI/AgentsSettingsView.swift`:

```swift
#if DEBUG
// Shows the real install status of this machine's hooks — which is what the tab
// is for. The 2 s diagnostics poll keeps running while the canvas is open.
#Preview("Agents settings — light") {
    AgentsSettingsView()
        .frame(width: 520, height: 540)
}

#Preview("Agents settings — dark") {
    AgentsSettingsView()
        .frame(width: 520, height: 540)
        .preferredColorScheme(.dark)
}
#endif
```

- [ ] **Step 4: Build and check for warnings**

```bash
cd "<repo>"
xcodebuild -project UsageTracker.xcodeproj -scheme UsageTracker -configuration Debug \
  -derivedDataPath build/DerivedData build 2>&1 | tee /tmp/p3-build.log | tail -5
grep -c "warning:" /tmp/p3-build.log
```
Expected: `** BUILD SUCCEEDED **`, grep prints `0`.

- [ ] **Step 5: Prove the dot is gone and no caption was missed**

```bash
cd "<repo>"
grep -n "font(\.caption\|Circle()" UsageTracker/UI/AgentsSettingsView.swift
```
Expected: no output.

- [ ] **Step 6: Commit**

```bash
cd "<repo>"
git add UsageTracker/UI/AgentsSettingsView.swift
git commit -m "$(cat <<'EOF'
Settings → Agents: hook status as a chip, captions on the type scale

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X
EOF
)"
```

---

## Task 5: Onboarding on tiles, the hero ring, chips and glass

**Files:**
- Modify: `UsageTracker/UI/OnboardingView.swift` (init, chrome, all four pages, `permissionRow`, `tip`, previews)

**Interfaces:**
- Consumes: `OMRing(percent:size:)`, `OMChip(text:tint:)`, `OMFont`, `OMSpacing`, `OMRadius`, `OMSurface`, `glassButtonStyle()`, `glassProminentButtonStyle()`, `liquidGlass(in:tint:)`.
- Produces: `OnboardingView(page:onFinish:)` — `page` defaults to 0, so the existing call site `OnboardingView { … }` in `UsageTracker/UsageTrackerApp.swift:132` keeps compiling; the parameter exists so each page can be previewed.

All copy is unchanged in this task. The status labels move into chips verbatim.

- [ ] **Step 1: Add the previewable page initializer**

Re-read the file, then replace

```swift
    @State private var page: Int = 0
```

with

```swift
    @State private var page: Int
```

and add, right after `let onFinish: () -> Void`:

```swift
    /// `page` is a parameter only so each page can be previewed on its own; the
    /// app always starts the tour at the beginning.
    init(page: Int = 0, onFinish: @escaping () -> Void) {
        _page = State(initialValue: page)
        self.onFinish = onFinish
    }
```

- [ ] **Step 2: Put the page dots on glass and the chrome buttons on the glass styles**

Replace the dots row and the button row in `body`:

```swift
            HStack(spacing: OMSpacing.s) {
                ForEach(0..<totalPages, id: \.self) { i in
                    Circle()
                        .fill(i == page ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, OMSpacing.m)
            .padding(.vertical, OMSpacing.xs)
            .liquidGlass(in: Capsule())
            .padding(.vertical, OMSpacing.s)

            Divider()

            HStack {
                if page > 0 {
                    Button("Back") {
                        withAnimation { page -= 1 }
                    }
                    .glassButtonStyle()
                } else {
                    Button("Skip") {
                        settings.hasSeenOnboarding = true
                        onFinish()
                    }
                    .glassButtonStyle()
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if page < totalPages - 1 {
                    Button("Continue") {
                        withAnimation { page += 1 }
                    }
                    .keyboardShortcut(.return)
                    .glassProminentButtonStyle()
                } else {
                    Button("Start tracking") {
                        settings.hasSeenOnboarding = true
                        onFinish()
                    }
                    .keyboardShortcut(.return)
                    .glassProminentButtonStyle()
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
```

- [ ] **Step 3: Add the card helper**

Add next to `permissionRow` (both are layout helpers of this file):

```swift
    /// One onboarding block on the same quiet tile the rest of the app uses for
    /// content. Glass is for controls; a card that holds text is not one.
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: OMSpacing.s) { content() }
            .padding(OMSpacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: OMRadius.tile, style: .continuous)
                    .fill(OMSurface.tile)
            )
    }
```

- [ ] **Step 4: Give the welcome page the hero ring**

Replace `welcomePage`:

```swift
    private var welcomePage: some View {
        VStack(spacing: OMSpacing.xl) {
            HStack(spacing: OMSpacing.l) {
                // The real app icon (the omelette), not a drawn stand-in — it
                // tracks icon updates for free.
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 84, height: 84)
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
                // The gauge the whole product is built on, at a comfortable
                // reading — the first screen shows what it is about to do.
                OMRing(percent: 37, size: .hero)
            }
            Text("Welcome to Omelette")
                .font(.title2.weight(.semibold))
            Text("A menu bar widget that watches your AI usage limits in real time — Claude, Codex, Grok, Antigravity — so you never get surprised by hitting a limit mid-task.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
            Spacer()
        }
    }
```

- [ ] **Step 5: Put the permissions page in cards with chips**

Replace `permissionsPage`:

```swift
    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: OMSpacing.l) {
            Text("Two permissions")
                .font(.title2.weight(.semibold))

            card {
                permissionRow(
                    icon: "key.fill",
                    title: "Keychain access",
                    description: "We read the OAuth token that Claude Code stored in your macOS Keychain. Click **Grant access** and macOS will ask you to allow it — choose **Always Allow**. Omelette then works from its own copy and never raises that dialog on its own; Settings → Account → **Request keychain access now** brings it back if it's ever needed again."
                )

                HStack(spacing: OMSpacing.s) {
                    OMChip(
                        text: keychainGranted ? "Access granted" : "Not granted yet",
                        tint: keychainGranted ? .green : .orange
                    )
                    Spacer()
                    Button(keychainGranted ? "Re-check" : "Grant access") {
                        requestKeychainAccess()
                    }
                    .glassButtonStyle()
                }

                if let keychainError {
                    Text(keychainError)
                        .font(OMFont.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }

            card {
                permissionRow(
                    icon: "bell.fill",
                    title: "Notifications",
                    description: "Alerts at 80% / 95% of any limit, plus an optional daily summary. You can opt out in Settings."
                )

                HStack(spacing: OMSpacing.s) {
                    OMChip(text: notificationStatusLabel, tint: notificationStatusColor)
                    Spacer()
                    Button(notificationButtonLabel) {
                        handleNotificationButton()
                    }
                    .glassButtonStyle()
                }
            }

            Spacer()
        }
        .task { await refreshNotificationStatus() }
    }
```

- [ ] **Step 6: Put the agents page in a card with a chip**

Replace `agentsPage`:

```swift
    private var agentsPage: some View {
        VStack(alignment: .leading, spacing: OMSpacing.l) {
            Text("Your agents, at a glance")
                .font(.title2.weight(.semibold))

            card {
                permissionRow(
                    icon: "bolt.horizontal.circle",
                    title: "Agent status (optional)",
                    description: "Omelette can also show which Claude Code sessions are running, which one is **waiting for your approval**, and take you back to it in one click. Turning this on adds eight hooks to `~/.claude/settings.json` that call a small helper inside Omelette. They send the session id, the tool name and the folder — never your prompts or your files — and Claude Code never waits on them. Settings → Agents shows the exact JSON, adds Codex, and removes all of it again."
                )

                HStack(spacing: OMSpacing.s) {
                    // `.conflict` carries whatever reason the installer found, which
                    // can be a whole sentence; the chip keeps one line and the tooltip
                    // holds the rest.
                    OMChip(text: agentHooksLabel, tint: agentHooksColor)
                        .lineLimit(1)
                        .help(agentHooksLabel)
                    Spacer()
                    Button(agentHooksButtonLabel) {
                        enableAgentHooks()
                    }
                    .glassButtonStyle()
                    .disabled(agentHooksInstalled)
                }

                if let agentHooksError {
                    Text(agentHooksError)
                        .font(OMFont.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }

            Spacer()
        }
        .onAppear(perform: refreshAgentHooks)
    }
```

- [ ] **Step 7: Move `permissionRow`, `tip` and the ready page onto the type scale**

Replace `permissionRow`, `readyPage` and `tip`:

```swift
    private func permissionRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: OMSpacing.m) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(OMFont.title)
                Text(.init(description))
                    .font(OMFont.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var readyPage: some View {
        VStack(spacing: OMSpacing.l) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("You're all set!")
                .font(.title2.weight(.semibold))
            card {
                tip("Click", "menu bar icon to open the popover")
                tip("Hover", "menu bar icon for a quick summary tooltip")
                tip("From popover", "open Dashboard, Settings, or Refresh")
                tip("Updates", "install themselves — signed and notarized")
            }
            Spacer()
        }
    }

    private func tip(_ label: String, _ description: String) -> some View {
        HStack(spacing: OMSpacing.s) {
            Text(label)
                .font(OMFont.caption.weight(.semibold))
                .padding(.horizontal, OMSpacing.s).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.18)))
                .frame(minWidth: 90, alignment: .leading)
            Text(description).font(OMFont.body).foregroundStyle(.secondary)
            Spacer()
        }
    }
```

- [ ] **Step 8: Add a preview per page, light and dark**

Append to the end of `UsageTracker/UI/OnboardingView.swift`:

```swift
#if DEBUG
#Preview("Tour — welcome") { OnboardingView(onFinish: {}) }
#Preview("Tour — welcome, dark") { OnboardingView(onFinish: {}).preferredColorScheme(.dark) }
#Preview("Tour — permissions") { OnboardingView(page: 1, onFinish: {}) }
#Preview("Tour — permissions, dark") { OnboardingView(page: 1, onFinish: {}).preferredColorScheme(.dark) }
#Preview("Tour — agents") { OnboardingView(page: 2, onFinish: {}) }
#Preview("Tour — agents, dark") { OnboardingView(page: 2, onFinish: {}).preferredColorScheme(.dark) }
#Preview("Tour — ready") { OnboardingView(page: 3, onFinish: {}) }
#Preview("Tour — ready, dark") { OnboardingView(page: 3, onFinish: {}).preferredColorScheme(.dark) }
#endif
```

- [ ] **Step 9: Build and check for warnings**

```bash
cd "<repo>"
xcodebuild -project UsageTracker.xcodeproj -scheme UsageTracker -configuration Debug \
  -derivedDataPath build/DerivedData build 2>&1 | tee /tmp/p3-build.log | tail -5
grep -c "warning:" /tmp/p3-build.log
```
Expected: `** BUILD SUCCEEDED **`, grep prints `0`.

- [ ] **Step 10: Check every page in the canvas**

Open the eight previews. The window is a fixed 520 × 480 and the cards add 24 pt of horizontal padding, so the check that matters is **no clipping**: on the permissions page the second card and its button must be fully visible above the dots row. If it clips, drop the page's `.padding(.horizontal, 40)` to 28 — that is the only measurement in this file allowed to change.

- [ ] **Step 11: Commit**

```bash
cd "<repo>"
git add UsageTracker/UI/OnboardingView.swift
git commit -m "$(cat <<'EOF'
Onboarding: tile cards, the hero ring, status chips and glass controls

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X
EOF
)"
```

---

## Task 6: Release prep — 2.1.0 (31) and the CHANGELOG

**Files:**
- Modify: `project.yml:104-105` (app target) and `project.yml:159-160` (widget target)
- Modify: `CHANGELOG.md` (new entry above `## [2.0.0] — 2026-09-02` on line 8)

**Interfaces:**
- Consumes: nothing.
- Produces: `CFBundleShortVersionString` `2.1.0` and `CFBundleVersion` `31` in the built app and appex.

Run this task **last**: the CHANGELOG describes packages 1–3, so it should only be written once all three are on `main`.

- [ ] **Step 1: Bump both targets**

Re-read `project.yml`, then apply two replace-all edits (two occurrences each — the app target and the widget target must not drift apart, which is why both are replaced at once):

1. `MARKETING_VERSION: "2.0.0"` → `MARKETING_VERSION: "2.1.0"`
2. `CURRENT_PROJECT_VERSION: "30"` → `CURRENT_PROJECT_VERSION: "31"`

- [ ] **Step 2: Write the CHANGELOG entry**

Insert directly above `## [2.0.0] — 2026-09-02`:

```markdown
## [2.1.0] — unreleased

### Added
- **An Agents tab in the dashboard.** Live sessions and the run history the app
  has been recording since 2.0.0: a summary strip (sessions, agent time,
  approvals waited, busiest project) over the range you pick, the live list, and
  finished sessions grouped by day with their project, start time, duration,
  turns and how often they stopped for you. Filter by source — All · Claude ·
  Codex.
- The agent run history is trimmed to the last 90 days once per launch, so
  `agent-sessions.jsonl` can't grow without a bound.

### Changed
- The dashboard, Settings, the welcome tour, the floating window and the desktop
  widgets are drawn with the design system the popover got in 2.0.0 — the same
  ring gauges, bars, section headers, status chips and battery colours. The
  widgets now share the app's ring and bar code instead of keeping their own.
- The floating window shows the leading window as a ring with the next two under
  it, and how many agent sessions are running — amber when one needs you.

```

- [ ] **Step 3: Regenerate and build**

```bash
cd "<repo>"
xcodegen generate
xcodebuild -project UsageTracker.xcodeproj -scheme UsageTracker -configuration Debug \
  -derivedDataPath build/DerivedData build 2>&1 | tee /tmp/p3-build.log | tail -5
grep -c "warning:" /tmp/p3-build.log
```
Expected: `** BUILD SUCCEEDED **`, grep prints `0`.

- [ ] **Step 4: Prove the version reached both bundles**

```bash
cd "<repo>"
APP=build/DerivedData/Build/Products/Debug/Omelette.app
plutil -p "$APP/Contents/Info.plist" | grep -E "CFBundleShortVersionString|CFBundleVersion"
find "$APP" -name "*.appex" -maxdepth 3 -exec plutil -p {}/Contents/Info.plist \; \
  | grep -E "CFBundleShortVersionString|CFBundleVersion"
```
Expected, from the app and from the widget appex: `"CFBundleShortVersionString" => "2.1.0"` and `"CFBundleVersion" => "31"`.

- [ ] **Step 5: Run the whole test suite one last time**

```bash
cd "<repo>"
xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData \
  ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS="" 2>&1 | tail -15
```
Expected: `** TEST SUCCEEDED **` with 0 failures.

- [ ] **Step 6: Commit**

```bash
cd "<repo>"
git add project.yml CHANGELOG.md
git commit -m "$(cat <<'EOF'
Prepare 2.1.0: version bump and CHANGELOG for the phase-3 surfaces

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X
EOF
)"
```

---

## Manual checklist (owner, after all six tasks)

Run the app from Xcode (⌘R) and walk these. Every item is a pass/fail, not a judgement call.

**Settings**
- [ ] General: every footer reads at the same size as the popover's captions; nothing wraps oddly at 520 pt.
- [ ] Account → Connected services: each provider shows a coloured chip ("Connected" green, "Sign in needed" amber, "Not running" grey, "Error" red) with the plan next to it.
- [ ] Account → Claude keychain access: click **Request keychain access now**; a green "Access granted" chip appears and clears itself after ~5 s. Deny the dialog once and confirm the orange "Failed: …" line appears instead and stays selectable.
- [ ] Agents: the Claude and Codex rows each show one status chip; **Enable**, then **Disable**, and confirm the chip flips green → grey.
- [ ] Notifications and Advanced still behave exactly as before.

**Onboarding**
- [ ] Advanced → **Replay welcome tour**. Page 1 shows the app icon next to a 37 % ring. Pages 2 and 3 show their text in tiles with a chip and a glass button. Page 4's tips sit in a tile.
- [ ] Nothing clips at 520 × 480 on any page, and the page dots sit in a glass capsule.
- [ ] **Skip** on page 1 and **Start tracking** on page 4 both close the window and don't reopen it on the next launch.

**Floating window**
- [ ] With no agent sessions: the header shows the provider logo + plan and no count; the hero ring matches the popover's leading window; up to two bars underneath.
- [ ] Start two Claude Code sessions: a blue dot with "2" appears in the header. Trigger an approval and confirm it turns amber and reads "1 needs you".
- [ ] Drag the window and dock it; close it with ✕ and reopen it from the popover — position and behaviour are unchanged from 2.0.0.
- [ ] Switch the dashboard's provider: the floating window follows.

---

## Self-review

**Spec coverage (Package 3 + Release prep):**

| Spec requirement | Task |
|---|---|
| Settings keep `Form .grouped`, captions/footers on `OMFont.caption` | 3 (steps 1, 5), 4 (step 2) — `.formStyle(.grouped)` untouched |
| Every status line (keychain, hooks, providers) becomes an `OMChip` | 3 (steps 2, 3), 4 (step 1) |
| Account tier picker and Providers list unchanged | 3 — neither is edited |
| One-line copy edits only where a chip replaces a dot | 3 (the `" · "` separator, the `✓`); both called out inline |
| Onboarding cards on `OMSurface.tile` / `OMRadius.tile` in 520 × 480 | 5 (steps 3, 5, 6, 7) |
| Welcome page shows `OMRing(.hero)` at 37 % | 5 (step 4) |
| `permissionRow` on `OMFont` roles | 5 (step 7) |
| Page dots and buttons on glass | 5 (step 2) |
| Onboarding copy unchanged | 5 — every string is reproduced verbatim |
| `FloatingMiniView` rebuilt: `OMRing(.medium)` via `WindowRanking.detailHero` | 1 (`content`), 2 (`heroRow`) |
| Up to two `BarSegment` rows for the next windows | 1 (`rows`), 2 (`windowRow`) |
| Trailing agents count from `OMAgentsPill.Appearance.make`, when sessions exist | 1 (`agents`), 2 (`header`) |
| Same size class; drag/dock untouched; `FloatingWindowController` not modified | 2 — the controller is explicitly out of the edited range |
| `MARKETING_VERSION` 2.1.0 / `CURRENT_PROJECT_VERSION` 31 in both targets | 6 (steps 1, 4) |
| CHANGELOG `[2.1.0] — unreleased` with the stated Added/Changed | 6 (step 2) |
| Unit tests for the extracted pure helpers | 1 |
| Previews light/dark for every touched view | 2 (step 2), 3 (step 4), 4 (step 3), 5 (step 8) |
| Manual: Settings tabs, replay the tour, floating window with 0/2 sessions | Manual checklist |

**Type consistency:** `FloatingMiniLayout.Content(hero:rows:emptyText:)` and `FloatingMiniLayout.agents(_:)` are declared in Task 1 and used with those exact names in Task 2. `FloatingMiniContent(service:agents:onClose:)` is declared and previewed in Task 2 only. `stateTint(_:)` (Task 3) and `card(_:)` (Task 5) are private to their files. `OnboardingView(page:onFinish:)` keeps the trailing-closure call site in `UsageTrackerApp.swift:132` valid.

**Out of scope, deliberately:** `SharedUI/`, `UI/Dashboard/`, `DashboardState`, `AgentHistoryStore`, `AgentChannel`, `UI/Components/CardStyle.swift`, `PopoverView`, `MenuBarLabel`, the widget extension, and the release/notarize flow.
