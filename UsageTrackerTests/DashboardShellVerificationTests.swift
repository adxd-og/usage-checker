import SwiftUI
import XCTest
@testable import Omelette

/// Independent verification of P2 (dashboard shell) against the liquid-glass redesign
/// spec (`docs/superpowers/specs/2026-09-24-liquid-glass-redesign.md`, § Packages P2,
/// § Removals, § Components "Sidebar" / "Segmented controls") and the P2 plan's session
/// rulings of 2026-09-25 (`docs/superpowers/plans/2026-09-25-3.0-P2-dashboard-shell.md`).
/// Written from the spec and the diff, not from the executor's own test files.
final class DashboardTabRouteVerificationTests: XCTestCase {
    /// The real risk this package could get wrong: `DashboardWindow` used to declare
    /// `@AppStorage("dashboardTab") private var selection: Tab = .overview` where `Tab`
    /// is a `RawRepresentable` enum. SwiftUI's `AppStorage` decodes a `RawRepresentable`
    /// itself: it reads the stored string, calls `Tab(rawValue:)`, and — if that fails —
    /// silently substitutes the wrapper's own initial value, never handing the raw string
    /// to any app code. Had P2 kept that shape and simply dropped `.activity` from the
    /// enum, a 2.x window stored on "Activity" would decode to nil, AppStorage would fall
    /// back to `.overview` on its own, and `DashboardTab.route(storedValue:)` would never
    /// see "Activity" at all — the routing rule would be correct in isolation and dead in
    /// the running app. P2 sidesteps this by storing the raw `String` itself
    /// (`storedTab`) and routing by hand, so this test drives a real `UserDefaults` suite
    /// through the exact same property-wrapper declaration the production code uses.
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "DashboardTabRouteVerificationTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    /// Mirrors `DashboardWindow`'s own declaration exactly: a `String`-typed
    /// `@AppStorage(DashboardTab.storageKey)`, not an enum-typed one.
    private struct StoredTabProbe {
        @AppStorage(DashboardTab.storageKey) var storedTab: String = DashboardTab.overview.rawValue

        init(store: UserDefaults) {
            _storedTab = AppStorage(wrappedValue: DashboardTab.overview.rawValue,
                                     DashboardTab.storageKey, store: store)
        }
    }

    func testAStoredActivityStringSurvivesAppStorageAndReachesRoute() {
        defaults.set("Activity", forKey: DashboardTab.storageKey)

        let probe = StoredTabProbe(store: defaults)

        // If this were the old enum-typed AppStorage, SwiftUI's own RawRepresentable
        // decode would already have swallowed "Activity" and handed back "Overview".
        XCTAssertEqual(probe.storedTab, "Activity",
                        "AppStorage must hand back the raw stored string, not decode-and-fall-back")
        XCTAssertEqual(DashboardTab.route(storedValue: probe.storedTab), .history)
    }

    func testAStoredHistoryStringRoundTripsToItself() {
        defaults.set("History", forKey: DashboardTab.storageKey)
        let probe = StoredTabProbe(store: defaults)
        XCTAssertEqual(DashboardTab.route(storedValue: probe.storedTab), .history)
    }

    func testWritingThroughAppStoragePersistsTheRawValueForTheNextLaunch() {
        var probe = StoredTabProbe(store: defaults)
        probe.storedTab = DashboardTab.insights.rawValue

        // A fresh probe over the same suite stands in for the next launch reading the
        // same UserDefaults domain.
        let relaunched = StoredTabProbe(store: defaults)
        XCTAssertEqual(relaunched.storedTab, "Insights")
        XCTAssertEqual(DashboardTab.route(storedValue: relaunched.storedTab), .insights)
    }

    func testNothingStoredYetDefaultsToOverviewThroughAppStorageItself() {
        // No key written at all: AppStorage's own initial value applies before route()
        // ever runs.
        let probe = StoredTabProbe(store: defaults)
        XCTAssertEqual(probe.storedTab, DashboardTab.overview.rawValue)
        XCTAssertEqual(DashboardTab.route(storedValue: probe.storedTab), .overview)
    }

    // MARK: - route(storedValue:) edge cases the spec implies but the executor's tests skip

    func testRouteIsCaseSensitiveSoALowercasedActivityDoesNotRouteToHistory() {
        // route(storedValue:) compares by exact string equality against
        // `retiredActivityValue` ("Activity") and against each case's rawValue. Neither
        // matches "activity", so this must fall through to the "no tab answers" branch,
        // not silently land on History too.
        XCTAssertEqual(DashboardTab.route(storedValue: "activity"), .overview)
    }

    func testRouteTrimsNoWhitespaceSoAPaddedActivityValueIsUnrecognised() {
        XCTAssertEqual(DashboardTab.route(storedValue: " Activity"), .overview)
        XCTAssertEqual(DashboardTab.route(storedValue: "Activity "), .overview)
    }

    func testEveryFourTabRoutesToItselfIncludingViaTheStorageKeyConstant() {
        for tab in DashboardTab.allCases {
            XCTAssertEqual(DashboardTab.route(storedValue: tab.rawValue), tab)
        }
        XCTAssertEqual(DashboardTab.storageKey, "dashboardTab")
        XCTAssertEqual(DashboardTab.retiredActivityValue, "Activity")
    }
}

/// `DashboardTab.step(from:by:)` drives the sidebar's arrow-key navigation
/// (spec § Components, "Sidebar"; plan Task 5). Verifies offsets beyond ±1 and both
/// directions clamp rather than wrap or crash, since a list's arrow keys never wrap.
final class DashboardTabStepVerificationTests: XCTestCase {
    func testALargeDownwardOffsetClampsAtTheLastTabNotPastIt() {
        XCTAssertEqual(DashboardTab.step(from: .overview, by: 100), .insights)
    }

    func testALargeUpwardOffsetClampsAtTheFirstTabNotPastIt() {
        XCTAssertEqual(DashboardTab.step(from: .insights, by: -100), .overview)
    }

    func testAZeroOffsetIsANoOp() {
        for tab in DashboardTab.allCases {
            XCTAssertEqual(DashboardTab.step(from: tab, by: 0), tab)
        }
    }

    func testSteppingTwoAtOnceSkipsExactlyOneTab() {
        XCTAssertEqual(DashboardTab.step(from: .overview, by: 2), .history)
        XCTAssertEqual(DashboardTab.step(from: .insights, by: -2), .agents)
    }
}

/// Liquid-glass spec § Removals: the dashboard sidebar's footnote reads "Updated Ns ago"
/// with a status dot, "in the popover header's words" (plan, Task 2). `PopoverView`'s own
/// `updatedText(now:)` (private, `UsageTracker/UI/PopoverView.swift:185`) computes:
/// `delta < 5 → "Just updated"`, `delta < 60 → "Updated Xs ago"`, `delta < 3600 →
/// "Updated Xm ago"`, else `"Updated Xh ago"`, with `fetchedAt < 1 → "Never updated"`.
/// `UpdatedCopy.text` must produce byte-identical strings for the same inputs so the
/// popover header and the dashboard footnote never disagree. The private function itself
/// cannot be called from a test, so these are pinned against the literal thresholds read
/// from its source.
final class UpdatedCopyVerificationTests: XCTestCase {
    private let fetched = Date(timeIntervalSince1970: 1_800_000_000)

    func testTheJustUpdatedBoundaryIsExclusiveOfFiveSeconds() {
        // PopoverView.updatedText: `if delta < 5 { "Just updated" }` — delta == 5.0 must
        // NOT still read "Just updated".
        XCTAssertEqual(UpdatedCopy.text(fetchedAt: fetched, now: fetched.addingTimeInterval(4.999)), "Just updated")
        XCTAssertEqual(UpdatedCopy.text(fetchedAt: fetched, now: fetched.addingTimeInterval(5.0)), "Updated 5s ago")
    }

    func testTheMinuteBoundaryIsExclusiveOfSixtySeconds() {
        XCTAssertEqual(UpdatedCopy.text(fetchedAt: fetched, now: fetched.addingTimeInterval(59.999)), "Updated 59s ago")
        XCTAssertEqual(UpdatedCopy.text(fetchedAt: fetched, now: fetched.addingTimeInterval(60.0)), "Updated 1m ago")
    }

    func testTheHourBoundaryIsExclusiveOfThirtySixHundredSeconds() {
        XCTAssertEqual(UpdatedCopy.text(fetchedAt: fetched, now: fetched.addingTimeInterval(3599.999)), "Updated 59m ago")
        XCTAssertEqual(UpdatedCopy.text(fetchedAt: fetched, now: fetched.addingTimeInterval(3600.0)), "Updated 1h ago")
    }

    func testFetchedAtExactlyOneSecondPastEpochCountsAsARealReading() {
        // The guard is `fetchedAt.timeIntervalSince1970 >= 1`, not `> 0`.
        let almostEpoch = Date(timeIntervalSince1970: 1)
        XCTAssertEqual(UpdatedCopy.text(fetchedAt: almostEpoch, now: almostEpoch), "Just updated")
        let justUnderEpoch = Date(timeIntervalSince1970: 0.999)
        XCTAssertEqual(UpdatedCopy.text(fetchedAt: justUnderEpoch, now: justUnderEpoch), "Never updated")
    }

    // MARK: - status / dot: spec ruling R3 (stale = system orange, live = ok green,
    // never = secondary) and D8 (VoiceOver hears ", can't refresh" only when stale)

    private func snapshot(fetchedAt: Date, isStale: Bool) -> UsageSnapshot {
        UsageSnapshot(services: [], fetchedAt: fetchedAt, isStale: isStale, lastError: nil)
    }

    func testUsageSnapshotEmptyIsNeverEvenThoughItsOwnIsStaleFlagIsTrue() {
        // UsageSnapshot.empty sets isStale: true, but status(of:) must read that as
        // "never", not "stale" — fetchedAt at epoch 0 gates first, per ruling D8's third
        // bullet ("secondary before the first reading").
        XCTAssertTrue(UsageSnapshot.empty.isStale)
        XCTAssertEqual(UpdatedCopy.status(of: .empty), .never)
        XCTAssertEqual(UpdatedCopy.dot(for: .never), .token(.secondary))
    }

    func testAStaleSnapshotWithARealFetchDateIsStaleNotNever() {
        let snap = snapshot(fetchedAt: fetched, isStale: true)
        XCTAssertEqual(UpdatedCopy.status(of: snap), .stale)
        XCTAssertEqual(UpdatedCopy.dot(for: .stale), .systemOrange)
    }

    func testALiveSnapshotIsLiveWithTheOkGreenDot() {
        let snap = snapshot(fetchedAt: fetched, isStale: false)
        XCTAssertEqual(UpdatedCopy.status(of: snap), .live)
        XCTAssertEqual(UpdatedCopy.dot(for: .live), .token(.ok))
    }

    func testOnlyTheStaleStatusAddsTheCantRefreshSuffix() {
        XCTAssertEqual(UpdatedCopy.accessibilityLabel(text: "Updated 3m ago", status: .live), "Updated 3m ago")
        XCTAssertEqual(UpdatedCopy.accessibilityLabel(text: "Never updated", status: .never), "Never updated")
        XCTAssertEqual(UpdatedCopy.accessibilityLabel(text: "Updated 3m ago", status: .stale),
                       "Updated 3m ago, can't refresh")
    }

    /// Ruling R3: "no new token" for the stale dot — it must reuse the popover's exact
    /// system orange, not a 3.0 colour role that could drift from it independently.
    func testTheStaleDotIsPlainSystemOrangeNotA3PointOColourRole() {
        XCTAssertEqual(UpdatedCopy.dot(for: .stale), .systemOrange)
        if case .token = UpdatedCopy.dot(for: .stale) {
            XCTFail("ruling R3 says the stale dot has no new token; it must be .systemOrange")
        }
    }
}

/// Liquid-glass spec § Components, "Segmented controls": `RangePicker` sits on
/// `OMSegmentedControl`. Verifies every `TimeRange` case round-trips through
/// `items(for:)` / `timeRange(forSegment:current:)`, not just the three the executor's
/// own tests sampled.
final class RangePickerVerificationTests: XCTestCase {
    func testEveryTimeRangeProducesASegmentThatRoundTripsBackToItself() {
        for range in TimeRange.allCases {
            let items = RangePicker.items(for: [range])
            XCTAssertEqual(items.count, 1)
            guard let item = items.first else { continue }
            XCTAssertEqual(item.id, range.rawValue)
            XCTAssertEqual(item.title, range.displayName)
            XCTAssertNil(item.serviceID)
            XCTAssertEqual(RangePicker.timeRange(forSegment: item.id, current: .sevenDays), range,
                            "segment \(item.id) must round-trip back to \(range)")
        }
    }

    func testAllFiveRangesAppearInTheirDeclaredOrder() {
        let items = RangePicker.items(for: TimeRange.allCases)
        XCTAssertEqual(items.map(\.id), ["5h", "24h", "7d", "30d", "90d"])
    }

    func testAnUnrecognisedSegmentIdLeavesTheCurrentRangeAlone() {
        for current in TimeRange.allCases {
            XCTAssertEqual(RangePicker.timeRange(forSegment: "not-a-range", current: current), current)
        }
    }

    func testAnEmptySegmentIdAlsoChangesNothing() {
        XCTAssertEqual(RangePicker.timeRange(forSegment: "", current: .ninetyDays), .ninetyDays)
    }
}

/// Liquid-glass spec § Tokens: the sidebar uses chrome glass (system glass), so it must
/// not carry the raised pill's own drop shadow — `OMGlassRules.usesSystemGlass` gates
/// that in `OMGlassSurface`. `DashboardSidebarRules.surface` must be a system-glass kind
/// or the sidebar would double up its own `sidebarShadows` caster with a second,
/// automatic recipe shadow.
final class DashboardSidebarSurfaceVerificationTests: XCTestCase {
    func testTheSidebarsSurfaceIsSystemGlassSoItsOwnShadowCasterIsTheOnlyOne() {
        XCTAssertTrue(OMGlassRules.usesSystemGlass(DashboardSidebarRules.surface))
    }

    func testTheSidebarsCornerRadiusMatchesTheSpecsRadiiTable() {
        // spec § Design → Tokens, "Radii": "sidebar 18".
        XCTAssertEqual(OMRadius.corner(for: DashboardSidebarRules.corner), .rounded(18))
    }

    /// D3: floor is windowInset + sidebar width + minimumDetailWidth + windowInset, and
    /// must equal 2.7's own floor (820 - 180) so the detail column never gets narrower
    /// than it was.
    func testTheWindowFloorLeavesTheDetailColumnAtLeastAsWideAs27() {
        let detailAtFloor = DashboardShellLayout.minWidth - DashboardShellLayout.windowInset
            - DashboardSidebarRules.width - DashboardShellLayout.windowInset
        XCTAssertEqual(detailAtFloor, 820 - 180)
    }
}

/// Liquid-glass spec § Removals: "Agents: ... subtitle" and "Insights: ... subtitle" are
/// dropped, but "History keeps its subtitle" (P2 plan, ruling R1 / D9). `DashboardHeader`
/// itself no longer forces every caller to pass one.
final class DashboardHeaderSubtitleVerificationTests: XCTestCase {
    /// `DashboardHeader.subtitle` must default to nil so a caller that says nothing
    /// really shows nothing, not an empty string that still reserves a line.
    func testDashboardHeaderSubtitleDefaultsToNil() {
        let header = DashboardHeader(title: "Insights")
        XCTAssertNil(header.subtitle)
    }

    func testDashboardHeaderStillAcceptsAnExplicitSubtitleForHistory() {
        let header = DashboardHeader(title: "History", subtitle: "Some sentence")
        XCTAssertEqual(header.subtitle, "Some sentence")
    }
}
