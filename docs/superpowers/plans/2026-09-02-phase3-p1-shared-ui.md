# Phase 3 · Package 1 — Shared UI for the widget Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the widget extension draw with the phase-1 design system instead of its private colour/ring/bar copies, by compiling the AppKit-free pieces (`OMTokens`, `OMRing`, `BarSegment`) into both targets from a new `SharedUI/` directory.

**Architecture:** The widget extension is a separate module and compiles its own sources, so "sharing" means compiling the same files twice — exactly the pattern `project.yml` already uses for `UsageTrackerWidget/ProviderIconView.swift` and `SharedAssets/ProviderIcons.xcassets`. The three pure SwiftUI files move (via `git mv`, history preserved) to a top-level `SharedUI/`, which is added to `sources:` of both the app and the widget target. Type names do not change, so every existing app-side reference keeps working with no edit. The widget's `statusColor(_:)` and `ProgressBar` are then deleted and their call sites redirected to `usageStatusColor` / `OMRing` / `BarSegment`.

**Tech Stack:** Swift 6 (strict concurrency `minimal`), SwiftUI + WidgetKit, macOS 14 floor, xcodegen 2.45.4-generated project, XCTest (`UsageTrackerTests`, `@testable import Omelette`).

**Spec:** `docs/superpowers/specs/2026-09-02-phase3-surfaces-and-agent-history-design.md` § "Package 1 — shared UI for the widget" (roadmap: `docs/superpowers/specs/2026-09-02-agent-control-plane-roadmap.md`)

## Global Constraints

- Deployment target macOS 14.0 for every target; nothing in this package may raise it.
- Colour semantics (phase-1 spec): `usageStatusColor` returns `.green` below 70, `.orange` from 70, `.red` from 90. After this package the widget uses that one function — no second copy anywhere in the repo.
- **Nothing in `SharedUI/` may `import AppKit`** (or UIKit): the files are compiled into a WidgetKit extension. SwiftUI + Foundation only. (`ProviderIconView.swift` does import AppKit and stays where it is — it is not part of this move.)
- No user-visible string changes anywhere in this package. "No visual change beyond the ring caps and bar shape matching the app" (spec).
- New/moved source files are picked up by xcodegen: run `xcodegen generate` after any `project.yml` or file-layout change and before building. `UsageTracker.xcodeproj/` is generated and **gitignored — never `git add` it**.
- Build: `xcodebuild -project UsageTracker.xcodeproj -scheme UsageTracker -configuration Debug -derivedDataPath build/DerivedData build` (this builds the appex as an embedded dependency — it is the only compile check the widget target gets, since it has no test target).
- Tests: `xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS=""` (add `-only-testing:UsageTrackerTests/<Class>` for a single class). **Always append `ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS=""` to every `xcodebuild test` invocation** — `signing.xcconfig` turns on the hardened runtime, which blocks the `DYLD_INSERT_LIBRARIES` injection XCTest needs, and the runner then hangs for ~6 min with "The test runner hung before establishing connection". Plain `build` keeps the real settings.
- Swift 6 warning-free: the build must produce no new warnings (unused symbols, unreachable code) after the deletions.
- Commits end with the trailer lines
  `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` and
  `Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X`.
- Other sessions may commit the working tree while you work: re-read a file right before editing it; prefer targeted edits over whole-file rewrites.
- **Not in this package:** no `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` bump and no `CHANGELOG.md` entry — package 3 owns both (spec § "Release prep"). Do not touch `CHANGELOG.md`.
- Package 1 must land before packages 2 and 3 start (they build on the moved files).

---

## File structure

```
SharedUI/                     NEW — compiled by BOTH the app and the widget target
  OMTokens.swift              moved from UsageTracker/UI/DesignSystem/ (API unchanged)
  OMRing.swift                moved from UsageTracker/UI/DesignSystem/ (+ Size.widget, showsLabel)
  BarSegment.swift            moved from UsageTracker/UI/Components/ (unchanged)
project.yml                   `- path: SharedUI` under sources: of UsageTracker and UsageTrackerWidget
UsageTrackerWidget/UsageTrackerWidget.swift
                              statusColor + ProgressBar deleted; SmallProviderView draws OMRing,
                              WidgetBucketRow draws BarSegment; previews updated
UsageTrackerTests/WindowRankingTests.swift
                              + OMRing.Size.widget assertions (colour cases untouched)
```

Nothing else changes. `UsageTracker/UI/DesignSystem/` keeps its other 13 files; `UsageTracker/UI/Components/` keeps `CardStyle.swift`, `LiquidGlass.swift` and the rest.

---

### Task 1: Move the three files into `SharedUI/` and compile them in both targets

**Files:**
- Move: `UsageTracker/UI/DesignSystem/OMTokens.swift` → `SharedUI/OMTokens.swift`
- Move: `UsageTracker/UI/DesignSystem/OMRing.swift` → `SharedUI/OMRing.swift`
- Move: `UsageTracker/UI/Components/BarSegment.swift` → `SharedUI/BarSegment.swift`
- Modify: `project.yml:43-53` (app target `sources:`) and `project.yml:141-147` (widget target `sources:`)

**Interfaces:**
- Consumes: nothing new.
- Produces: the symbols `OMSpacing`, `OMRadius`, `OMFont`, `OMSurface`, `OMAgentColor`, `usageStatusColor(_:)`, `OMRing`, `BarSegment` are now top-level in **both** the `Omelette` module and the `UsageTrackerWidget` module. Signatures are byte-identical to today — no app-side call site changes in this task.

- [ ] **Step 1: Move the files with git so history follows them**

```bash
mkdir -p SharedUI
git mv UsageTracker/UI/DesignSystem/OMTokens.swift SharedUI/OMTokens.swift
git mv UsageTracker/UI/DesignSystem/OMRing.swift   SharedUI/OMRing.swift
git mv UsageTracker/UI/Components/BarSegment.swift  SharedUI/BarSegment.swift
git status --short
```

Expected output (three staged renames, nothing else):

```
R  UsageTracker/UI/Components/BarSegment.swift -> SharedUI/BarSegment.swift
R  UsageTracker/UI/DesignSystem/OMRing.swift -> SharedUI/OMRing.swift
R  UsageTracker/UI/DesignSystem/OMTokens.swift -> SharedUI/OMTokens.swift
```

Do **not** edit the file contents in this step — a pure rename keeps `git log --follow` clean.

- [ ] **Step 2: Confirm the moved files are AppKit-free**

Run:

```bash
grep -n "^import" SharedUI/*.swift
```

Expected — exactly three lines, all SwiftUI:

```
SharedUI/BarSegment.swift:1:import SwiftUI
SharedUI/OMRing.swift:1:import SwiftUI
SharedUI/OMTokens.swift:1:import SwiftUI
```

If anything else appears, stop: an AppKit dependency cannot be compiled into the extension and the file must not move.

- [ ] **Step 3: Add `SharedUI` to the app target's sources**

In `project.yml`, the app target's `sources:` block currently reads:

```yaml
    sources:
      - path: UsageTracker
        excludes:
          - "**/*.entitlements"
      - path: UsageTrackerWidget/SharedWidgetData.swift
      - path: UsageTrackerWidget/ProviderIconView.swift
      # The shared logo catalog is deliberately under sources:, not resources: —
```

Insert the `SharedUI` entry after `ProviderIconView.swift` so the block becomes:

```yaml
    sources:
      - path: UsageTracker
        excludes:
          - "**/*.entitlements"
      - path: UsageTrackerWidget/SharedWidgetData.swift
      - path: UsageTrackerWidget/ProviderIconView.swift
      # Design tokens, OMRing and BarSegment: pure SwiftUI, no AppKit, so the widget
      # extension can compile them too. Same trick as ProviderIconView.swift above —
      # the appex is its own module, so "shared" means compiled into both targets.
      - path: SharedUI
      # The shared logo catalog is deliberately under sources:, not resources: —
```

- [ ] **Step 4: Add `SharedUI` to the widget target's sources**

The widget target's `sources:` block currently reads:

```yaml
    sources:
      - path: UsageTrackerWidget
        excludes:
          - "**/*.entitlements"
          - "Info.plist"
      # Via sources:, not resources: — see the app target's note on the same path.
      - path: SharedAssets/ProviderIcons.xcassets
```

Make it:

```yaml
    sources:
      - path: UsageTrackerWidget
        excludes:
          - "**/*.entitlements"
          - "Info.plist"
      # The app's design system (tokens, OMRing, BarSegment) — see the app target's
      # note on the same path. Colours must come from one usageStatusColor, not a copy.
      - path: SharedUI
      # Via sources:, not resources: — see the app target's note on the same path.
      - path: SharedAssets/ProviderIcons.xcassets
```

- [ ] **Step 5: Regenerate and verify both targets picked the files up**

Run:

```bash
xcodegen generate && for f in OMTokens OMRing BarSegment; do
  printf '%s: ' "$f"; grep -c "$f.swift in Sources" UsageTracker.xcodeproj/project.pbxproj
done
```

Expected — `4` for each (two lines per target: the `PBXBuildFile` entry and the `PBXSourcesBuildPhase` reference; an app-only file scores 2):

```
OMTokens: 4
OMRing: 4
BarSegment: 4
```

- [ ] **Step 6: Build the app (which builds the appex) and run the full suite**

Run:

```bash
xcodebuild -project UsageTracker.xcodeproj -scheme UsageTracker -configuration Debug -derivedDataPath build/DerivedData build
```

Expected: `** BUILD SUCCEEDED **`. This is the proof that `AnyShapeStyle(.fill.tertiary)`, `AnyShapeStyle(.separator.opacity(0.5))` and `usageStatusColor` compile inside a WidgetKit extension — all three are plain SwiftUI shape styles/functions with no AppKit dependency. If the appex fails here, the offending token is the finding; report it rather than working around it.

Then:

```bash
xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS=""
```

Expected: `** TEST SUCCEEDED **` — the whole suite, including `WindowRankingTests.testStatusColorIsGreenWhenComfortable` / `…IsOrangeFrom70` / `…IsRedFrom90`, which still resolve `usageStatusColor` through `@testable import Omelette`.

- [ ] **Step 7: Commit**

```bash
git add SharedUI project.yml UsageTracker/UI/DesignSystem UsageTracker/UI/Components
git commit -m "SharedUI: compile tokens, OMRing and BarSegment into the widget too

The appex is its own module, so the phase-1 kit was invisible to it. Move the
three AppKit-free files to SharedUI/ and list that path under sources: of both
targets — the same pattern ProviderIconView.swift already uses. No API change.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

`UsageTracker.xcodeproj/` is gitignored — it must not appear in `git status` after the commit; if it does, it was force-added by mistake and must be unstaged.

---

### Task 2: `OMRing.Size.widget` (110 pt / 10 pt line) and a label opt-out

**Files:**
- Modify: `SharedUI/OMRing.swift` (the `Size` enum, the `showsLabel` property, the label branch in `body`, previews)
- Test: `UsageTrackerTests/WindowRankingTests.swift` (append one test at the end of the class)

**Interfaces:**
- Consumes: `OMFont.heroNumeral` from `SharedUI/OMTokens.swift`.
- Produces:
  ```swift
  extension OMRing {
      // enum Size gains: case widget   // diameter 110, lineWidth 10, labelFont OMFont.heroNumeral
  }
  struct OMRing: View {
      let percent: Double
      var size: Size = .medium
      var pace: Double? = nil
      var color: Color? = nil
      var showsLabel: Bool = true      // NEW, appended last so every existing call site keeps compiling
  }
  ```
  Task 3 calls `OMRing(percent:size:showsLabel:)`. The existing call sites (`OMHero.swift:19`, `OMProviderTile.swift:51`, `OMRingRow.swift:14`, `OverviewView.swift:63`, the previews) use `percent`/`size`/`pace` in declaration order and are unaffected.

**Why `showsLabel` exists:** the small widget composes its own centre stack (provider name, 34 pt numeral, window label) *inside* the ring. Without an opt-out, `OMRing`'s own 21 pt "42%" would render behind that stack and read as a double exposure. `.widget` still carries `OMFont.heroNumeral` as its label font, per the spec, for any standalone use.

- [ ] **Step 1: Write the failing test**

Append inside `final class WindowRankingTests: XCTestCase` in `UsageTrackerTests/WindowRankingTests.swift`, immediately after `testStatusPhraseWording()` and before the class's closing brace:

```swift

    // MARK: OMRing sizes
    func testWidgetRingSizeMatchesTheSmallWidget() {
        // 158 pt widget − 2×16 pt default content margins − 2×8 pt pad ≈ the ring
        // the widget drew before it used OMRing; keep the number pinned.
        XCTAssertEqual(OMRing.Size.widget.diameter, 110)
        XCTAssertEqual(OMRing.Size.widget.lineWidth, 10)
        XCTAssertEqual(OMRing.Size.widget.labelFont, OMFont.heroNumeral)
        // The existing sizes must not shift while the case is added.
        XCTAssertEqual(OMRing.Size.hero.diameter, 84)
        XCTAssertEqual(OMRing.Size.mini.labelFont, nil)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS="" -only-testing:UsageTrackerTests/WindowRankingTests
```

Expected: FAIL — the test target does not compile: `error: type 'OMRing.Size' has no member 'widget'` (three times, one per `.widget` reference).

- [ ] **Step 3: Add the case and the opt-out**

In `SharedUI/OMRing.swift`, replace the `Size` enum (lines 7–34) with:

```swift
    enum Size {
        /// The desktop widget's small family: one ring filling the tile.
        case widget
        case hero, medium, small, mini

        var diameter: CGFloat {
            switch self {
            case .widget: 110
            case .hero: 84
            case .medium: 52
            case .small: 44
            case .mini: 26
            }
        }
        var lineWidth: CGFloat {
            switch self {
            case .widget: 10
            case .hero: 9
            case .medium: 6
            case .small: 5
            case .mini: 4
            }
        }
        var labelFont: Font? {
            switch self {
            case .widget: OMFont.heroNumeral
            case .hero: OMFont.heroNumeral
            case .medium: OMFont.numeral
            case .small: Font.system(size: 11, weight: .bold, design: .rounded)
            case .mini: nil
            }
        }
    }
```

Then add the stored property after `color` (line 39) so the memberwise init gains it last:

```swift
    let percent: Double
    var size: Size = .medium
    var pace: Double? = nil
    var color: Color? = nil
    /// The widget draws its own centre stack over the ring; `false` stops OMRing
    /// from stacking a second numeral underneath it.
    var showsLabel: Bool = true
```

And gate the label branch in `body` (line 59) on it:

```swift
            if showsLabel, let font = size.labelFont {
                Text("\(Int(clamped.rounded()))%")
                    .font(font)
                    .monospacedDigit()
            }
```

- [ ] **Step 4: Add a preview for the new size**

Append to `SharedUI/OMRing.swift`, after the existing "Rings — dark" preview:

```swift

#Preview("Ring — widget size") {
    HStack(spacing: 16) {
        OMRing(percent: 42, size: .widget)
        OMRing(percent: 42, size: .widget, showsLabel: false)
    }
    .padding()
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run:

```bash
xcodegen generate && xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS="" -only-testing:UsageTrackerTests/WindowRankingTests
```

Expected: `** TEST SUCCEEDED **`, `Executed 24 tests, with 0 failures` (23 before this task + the new one).

- [ ] **Step 6: Commit**

```bash
git add SharedUI/OMRing.swift UsageTrackerTests/WindowRankingTests.swift
git commit -m "OMRing: widget size (110 pt / 10 pt) and a label opt-out

The small widget composes its own centre stack inside the ring, so it asks for
the arc without OMRing's numeral. Existing call sites are untouched: showsLabel
is appended last in the memberwise init and defaults to true.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

### Task 3: The widget draws with `usageStatusColor`, `OMRing` and `BarSegment`

**Files:**
- Modify: `UsageTrackerWidget/UsageTrackerWidget.swift` — `SmallProviderView` (lines 197–248), `WidgetBucketRow` (lines 391–416), delete `ProgressBar` (lines 450–466) and `statusColor(_:)` (lines 468–475), previews (lines 477–487)

**Interfaces:**
- Consumes from `SharedUI/` (Tasks 1–2): `OMRing(percent:size:pace:color:showsLabel:)` with `Size.widget`, `BarSegment(percent:height:showsLabel:pace:)`, `usageStatusColor(_:)`.
- Consumes from `UsageTrackerWidget/SharedWidgetData.swift` (unchanged): `WidgetService.headlineBucket -> WidgetBucket?`, `WidgetService.spendLabel: String?`, `WidgetBucket.label: String`, `WidgetBucket.percent: Double`, `WidgetBucket.resetsAt: Date?`.
- Produces: no new symbols. `statusColor(_:)` and `ProgressBar` cease to exist.

- [ ] **Step 1: Redraw the small widget's ring with `OMRing`**

In `UsageTrackerWidget/UsageTrackerWidget.swift`, `SmallProviderView`'s `body` starts:

```swift
    var body: some View {
        ZStack {
            ringBar
            VStack(spacing: 0) {
```

Replace the `ringBar` line with the shared ring (everything else in the `ZStack`, including `.padding(.horizontal, 22)` on the `VStack`, stays exactly as it is):

```swift
    var body: some View {
        ZStack {
            OMRing(percent: service.headlineBucket?.percent ?? 0, size: .widget, showsLabel: false)
            VStack(spacing: 0) {
```

Then delete the whole private `ringBar` property (lines 232–247, from `private var ringBar: some View {` through its closing `}`), leaving `headlineText` as the struct's only remaining private member.

- [ ] **Step 2: Redraw the bucket rows with `BarSegment`**

In `WidgetBucketRow.body`, replace the last line of the `VStack`:

```swift
            ProgressBar(percent: bucket.percent, height: compact ? 5 : 6)
```

with:

```swift
            BarSegment(percent: bucket.percent, height: compact ? 5 : 6)
```

Nothing else in `WidgetBucketRow` changes — same `VStack(alignment: .leading, spacing: compact ? 2 : 4)`, same label/percent/reset `HStack`, same fonts.

- [ ] **Step 3: Delete the widget's private copies**

Delete both declarations near the bottom of the file:

```swift
struct ProgressBar: View {
    let percent: Double
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(.quaternary)
                Capsule(style: .continuous)
                    .fill(statusColor(percent))
                    .frame(width: geo.size.width * CGFloat(max(0, min(100, percent)) / 100))
            }
        }
        .frame(height: height)
    }
}

/// Battery-style status color, mirrors the main app's usageStatusColor
/// (OMTokens.swift): green while comfortable, amber from 70 %, red from 90 %.
/// Kept as a copy because the widget target doesn't compile the app's sources.
func statusColor(_ percent: Double) -> Color {
    if percent >= 90 { return .red }
    if percent >= 70 { return .orange }
    return .green
}
```

The `// MARK: - Helpers` section keeps `WidgetTime` unchanged.

- [ ] **Step 4: Update the previews**

Replace the file's two trailing previews:

```swift
#Preview("All providers") {
    AllProvidersWidgetView(snapshot: .placeholder)
        .frame(width: 338, height: 354)
        .background(.regularMaterial)
}

#Preview("Small") {
    SmallProviderView(service: WidgetSnapshot.placeholder.services[0])
        .frame(width: 158, height: 158)
        .background(.regularMaterial)
}
```

with a set that exercises every migrated component in both appearances:

```swift
#Preview("All providers") {
    AllProvidersWidgetView(snapshot: .placeholder)
        .frame(width: 338, height: 354)
        .background(.regularMaterial)
}

#Preview("Small") {
    SmallProviderView(service: WidgetSnapshot.placeholder.services[0])
        .frame(width: 158, height: 158)
        .background(.regularMaterial)
}

#Preview("Small — dark") {
    SmallProviderView(service: WidgetSnapshot.placeholder.services[0])
        .frame(width: 158, height: 158)
        .background(.regularMaterial)
        .preferredColorScheme(.dark)
}

#Preview("Medium") {
    MediumProviderView(service: WidgetSnapshot.placeholder.services[0], updatedAt: Date())
        .frame(width: 338, height: 158)
        .background(.regularMaterial)
}

#Preview("Medium — dark") {
    MediumProviderView(service: WidgetSnapshot.placeholder.services[0], updatedAt: Date())
        .frame(width: 338, height: 158)
        .background(.regularMaterial)
        .preferredColorScheme(.dark)
}
```

- [ ] **Step 5: Build the app (and therefore the appex)**

Run:

```bash
xcodebuild -project UsageTracker.xcodeproj -scheme UsageTracker -configuration Debug -derivedDataPath build/DerivedData build
```

Expected: `** BUILD SUCCEEDED **` with no warnings from `UsageTrackerWidget.swift` (an "unused" warning here would mean a leftover private helper).

- [ ] **Step 6: Commit**

```bash
git add UsageTrackerWidget/UsageTrackerWidget.swift
git commit -m "Widget: draw with OMRing, BarSegment and usageStatusColor

Deletes the extension's private statusColor(_:) and ProgressBar. Colours now
come from one function for the popover, dashboard, menu bar and widgets alike;
the small ring gains round caps and the bars the app's capsule shape.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

### Task 4: Leftover sweep, full verification, and the manual widget check

**Files:** none modified (this task ends in an empty commit that records the checklist result).

- [ ] **Step 1: Grep for leftover references to the deleted symbols**

Run (the `build/` exclusion keeps CodexBar's unrelated `UsageProgressBar` out of the result):

```bash
grep -rn "statusColor(" --include="*.swift" . | grep -v usageStatusColor | grep -v "^./build/"
grep -rn "ProgressBar" --include="*.swift" . | grep -v "^./build/"
grep -rn "ringBar" --include="*.swift" . | grep -v "^./build/"
```

Expected: **no output from any of the three** (exit status 1 each). Any hit is a missed call site — fix it before continuing.

- [ ] **Step 2: Confirm the old file paths are gone and the new ones exist**

Run:

```bash
ls SharedUI
ls UsageTracker/UI/DesignSystem/OMTokens.swift UsageTracker/UI/DesignSystem/OMRing.swift UsageTracker/UI/Components/BarSegment.swift 2>&1 | tail -3
git log --follow --oneline -- SharedUI/OMRing.swift | tail -3
```

Expected: `SharedUI` lists `BarSegment.swift  OMRing.swift  OMTokens.swift`; the three old paths report `No such file or directory`; `git log --follow` reaches commits made before the move (proof the rename kept history).

- [ ] **Step 3: Clean build + full test suite**

Run:

```bash
xcodegen generate && xcodebuild -project UsageTracker.xcodeproj -scheme UsageTracker -configuration Debug -derivedDataPath build/DerivedData build
```

Expected: `** BUILD SUCCEEDED **`.

Then:

```bash
xcodebuild test -project UsageTracker.xcodeproj -scheme UsageTracker -destination 'platform=macOS' -derivedDataPath build/DerivedData ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS=""
```

Expected: `** TEST SUCCEEDED **`, 0 failures, and the `WindowRankingTests` colour cases among the executed tests.

- [ ] **Step 4: Manual check — add the widgets and compare with the popover**

Report each line as **verified** or **not verifiable (headless)** — an agent without a logged-in GUI session cannot open the widget gallery, and must say so rather than claim a pass.

```bash
pgrep -fl Omelette        # any /Applications copy running? quit it first —
                          # WidgetKit resolves a widget kind to whichever registered
                          # copy the system picks, and the shipped app would win.
open build/DerivedData/Build/Products/Debug/Omelette.app
```

Checklist:
1. Right-click the desktop → Edit Widgets → **Provider usage** → add the **Small** size. The ring shows the headline window's percent with round caps, the provider name/percent/window label centred inside it, and exactly one numeral (no ghost 21 pt figure behind the big one).
2. Add the **Medium** size. Each row's bar is a capsule with the app's fill, and the row layout (label · percent · reset time above the bar) is unchanged from before.
3. Open the menu-bar popover next to the widgets: a window at the same percent is the same colour in both (green below 70, amber 70–89, red 90+). Check at least one green and one amber/red window; if the live account has none above 70, note that instead of guessing.
4. Switch System Settings → Appearance between Light and Dark: both widget sizes stay legible, the ring track and bar track are the quiet system fills.
5. Quit the Debug app afterwards, and relaunch the `/Applications` copy if it was running before step 4.

- [ ] **Step 5: Record the result**

```bash
git commit --allow-empty -m "Phase 3 P1: verification sweep passed

grep: no statusColor(/ProgressBar/ringBar left outside build/. Build of the app
(and the embedded appex) and the full test suite green. Manual widget checklist:
<verified | not verifiable headless — reason>.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013fBYuPqFyH6qKR5tcnXc8X"
```

---

## Self-review notes

- **Spec coverage.** `SharedUI/` with the three named files → Task 1 (moves) and its `project.yml` fragments. "`- path: SharedUI` under `sources:` of BOTH targets" → Task 1 steps 3–4, verified by the pbxproj count of 4 in step 5. "`OMRing` gains `case widget` = 110 pt / 10 pt line, label heroNumeral" → Task 2. "Delete the widget's private `statusColor(_:)` and `ProgressBar`; `SmallProviderView` draws `OMRing(percent:size: .widget)`, `WidgetBucketRow` uses `BarSegment`" → Task 3 steps 1–3. "Widget previews updated" → Task 3 step 4. "`WindowRankingTests` colour cases keep passing… verified by `xcodebuild build` of the app, which builds the appex" → Task 1 step 6 and Task 4 step 3. Manual widget check → Task 4 step 4. Out of scope by spec assignment (version bump, CHANGELOG) is called out in Global Constraints.
- **One addition beyond the spec text:** `OMRing.showsLabel` (Task 2). The spec gives `.widget` a `heroNumeral` label, but `SmallProviderView` keeps its own centre stack — which the spec also requires, since the only permitted visual change is "the ring caps and bar shape". A defaulted property appended last is the smallest change that satisfies both; it is stated in Task 2's rationale and in the commit body.
- **Type consistency.** `OMRing(percent:size:showsLabel:)` in Task 3 matches the property order declared in Task 2 (`percent`, `size`, `pace`, `color`, `showsLabel`) — skipping defaulted middle parameters is legal because the order is preserved. `BarSegment(percent:height:)` matches the existing declaration (`percent`, `height`, `showsLabel`, `pace`), so `height:` is reachable without naming the rest. `OMRing.Size.widget`, `OMFont.heroNumeral`, `usageStatusColor(_:)` are spelled identically in the test (Task 2), the widget (Task 3) and the greps (Task 4).
- **No placeholders.** Every code step carries the literal replacement text; every run step names the command and the expected output; the manual step names the artifact path and demands an explicit "not verifiable" answer instead of a silent pass.
- **Risk carried forward:** the widget has no test target, so Tasks 1 and 3 are proven only by compiling the appex through the app build — that is the spec's own stated method, and Task 4 step 4 is the only check that the rendering actually changed as intended.
