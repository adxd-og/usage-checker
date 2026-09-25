import XCTest
@testable import Omelette

/// Liquid-glass spec § Design → Settings: "Sidebar window (780 pt wide, height per tab)
/// … switches use the accent, status is a dot + text (no `OMChip`)". Values from
/// `Settings-*(-Light).dc.html`: the window `<div>`, the page column, the groups and rows.
final class SettingsKitTests: XCTestCase {
    // MARK: Window

    func testTheWindowIsTheMockupsWidth() {
        XCTAssertEqual(SettingsWindowLayout.width, 780)
    }

    /// `WindowButtonsPlacement` puts the traffic lights by the dashboard's layout, so the
    /// Settings sidebar has to float exactly as far inside its window.
    func testTheSidebarFloatsAsTheDashboardsDoSoTheTrafficLightsLandInIt() {
        XCTAssertEqual(SettingsWindowLayout.windowInset, DashboardShellLayout.windowInset)
        XCTAssertEqual(SettingsWindowLayout.windowInset, 10)
    }

    func testEachTabIsAsTallAsItsMockup() {
        XCTAssertEqual(
            SettingsTab.allCases.map { SettingsWindowLayout.height(for: $0, availableHeight: 2000) },
            [600, 680, 560, 960, 840, 810]
        )
    }

    func testWithNoScreenKnownTheTabKeepsItsMockupHeight() {
        XCTAssertEqual(SettingsWindowLayout.height(for: .notifications, availableHeight: nil), 960)
    }

    func testATabTallerThanTheScreenIsCutToItAndItsPageScrolls() {
        // A 13" screen's visible height, less the 40 pt margin.
        XCTAssertEqual(SettingsWindowLayout.height(for: .notifications, availableHeight: 875), 835)
    }

    func testAShortTabIsNotStretchedToTheScreen() {
        XCTAssertEqual(SettingsWindowLayout.height(for: .providers, availableHeight: 875), 560)
    }

    func testTheWindowNeverShrinksBelowItsFloor() {
        XCTAssertEqual(SettingsWindowLayout.height(for: .advanced, availableHeight: 300), 420)
    }

    func testThePageSitsOnTheMockupsGutters() {
        // `padding: 22px 28px 28px 30px; gap: 22px`, a 22 pt bold title at -0.3 tracking.
        XCTAssertEqual(SettingsWindowLayout.columnTop, 22)
        XCTAssertEqual(SettingsWindowLayout.columnTrailing, 28)
        XCTAssertEqual(SettingsWindowLayout.columnBottom, 28)
        XCTAssertEqual(SettingsWindowLayout.columnLeading, 30)
        XCTAssertEqual(SettingsWindowLayout.sectionSpacing, 22)
        XCTAssertEqual(SettingsWindowLayout.titleSize, 22)
        XCTAssertEqual(SettingsWindowLayout.titleTracking, -0.3)
    }

    // MARK: Groups and rows

    func testAGroupIsTheContentFillAtTheGroupCorner() {
        XCTAssertEqual(OMRadius.corner(for: SettingsRowRules.groupCorner), .rounded(16))
        XCTAssertEqual(SettingsRowRules.groupFill, .contentFill)
        XCTAssertEqual(SettingsRowRules.groupBorder, .contentBorder)
        XCTAssertEqual(SettingsRowRules.separator, .hairline)
    }

    func testRowMetricsAreTheMockups() {
        XCTAssertEqual(SettingsRowRules.horizontalPadding, 16)
        XCTAssertEqual(SettingsRowRules.verticalPadding, 11)
        XCTAssertEqual(SettingsRowRules.minimumContentHeight, 30)
        XCTAssertEqual(SettingsRowRules.spacing, 12)
        XCTAssertEqual(SettingsRowRules.trailingSpacing, 8)
        XCTAssertEqual(SettingsRowRules.titleSize, 13.5)
        XCTAssertEqual(SettingsRowRules.captionSize, 12)
        XCTAssertEqual(SettingsRowRules.captionSpacing, 2)
        XCTAssertEqual(SettingsRowRules.headerSize, 13)
        XCTAssertEqual(SettingsRowRules.headerInset, 4)
        XCTAssertEqual(SettingsRowRules.sectionSpacing, 8)
        XCTAssertEqual(SettingsRowRules.valueSize, 12.5)
    }

    func testSwitchesUseTheAccent() {
        XCTAssertEqual(SettingsRowRules.switchTint, .accent)
    }

    func testStatusIsASevenPointDotBesideItsWords() {
        XCTAssertEqual(SettingsRowRules.statusDotSize, 7)
        XCTAssertEqual(SettingsRowRules.statusSpacing, 7)
    }

    func testButtonsAreThePopoversSmallCapsule() {
        XCTAssertEqual(SettingsRowRules.buttonSize, .small)
        XCTAssertEqual(OMButtonRules.height(SettingsRowRules.buttonSize), 28)
        XCTAssertEqual(SettingsRowRules.disabledOpacity, 0.45)
    }

    func testTheOneDestructiveLabelIsTheCriticalRed() {
        XCTAssertEqual(SettingsRowRules.destructiveLabel, .critical)
    }

    /// Session ruling on the plan review: a failure is not a status. It reads in red at
    /// the caption size and wraps (`SettingsErrorText`, no line limit).
    func testAFailureReadsInTheCriticalRed() {
        XCTAssertEqual(SettingsRowRules.errorToken, .critical)
    }

    func testFieldsAreTwentyEightPointsWithEightPointCorners() {
        XCTAssertEqual(SettingsRowRules.fieldHeight, 28)
        XCTAssertEqual(SettingsRowRules.fieldCornerRadius, 8)
        XCTAssertEqual(SettingsRowRules.fieldHorizontalPadding, 10)
        XCTAssertEqual(SettingsRowRules.fieldFill, .track)
        XCTAssertEqual(SettingsRowRules.fieldBorder, .hairline)
    }

    /// Ruling S12: a focused field wears the yolk ring, concentric with its corner.
    /// `SettingsFieldRules.showsFocusRing(isFocused:)` is the identity and has no test of
    /// its own.
    func testAFocusedFieldWearsTheYolkRingAroundItsCorner() {
        XCTAssertEqual(SettingsFieldRules.focusRingToken, .focusRing)
        XCTAssertEqual(SettingsFieldRules.focusRingCornerRadius, SettingsRowRules.fieldCornerRadius + OMFocusRing.width)
        XCTAssertEqual(SettingsFieldRules.focusRingCornerRadius, 11)
    }

    // MARK: Stepper

    func testAStepMovesByTheStepSize() {
        XCTAssertEqual(SettingsStepperRules.stepped(80, by: 1, in: 50...90, step: 5), 85)
        XCTAssertEqual(SettingsStepperRules.stepped(80, by: -1, in: 50...90, step: 5), 75)
        XCTAssertEqual(SettingsStepperRules.stepped(95, by: 1, in: 80...99, step: 1), 96)
    }

    func testAStepStopsAtTheEndsOfTheRangeAsTheSystemStepperDoes() {
        XCTAssertEqual(SettingsStepperRules.stepped(90, by: 1, in: 50...90, step: 5), 90)
        XCTAssertEqual(SettingsStepperRules.stepped(50, by: -1, in: 50...90, step: 5), 50)
        XCTAssertEqual(SettingsStepperRules.stepped(99, by: 1, in: 80...99, step: 1), 99)
    }

    func testTheButtonAtAnEndOfTheRangeIsOff() {
        XCTAssertFalse(SettingsStepperRules.canStep(90, by: 1, in: 50...90, step: 5))
        XCTAssertTrue(SettingsStepperRules.canStep(90, by: -1, in: 50...90, step: 5))
        XCTAssertFalse(SettingsStepperRules.canStep(80, by: -1, in: 80...99, step: 1))
    }

    func testTheFigureIsAPercentage() {
        XCTAssertEqual(SettingsStepperRules.figure(80), "80%")
    }

    func testTheStepperIsTheMockups() {
        XCTAssertEqual(SettingsStepperRules.valueSize, 15)
        XCTAssertEqual(SettingsStepperRules.unitSize, 10)
        XCTAssertEqual(SettingsStepperRules.buttonWidth, 26)
        XCTAssertEqual(SettingsStepperRules.buttonHeight, 24)
        XCTAssertEqual(SettingsStepperRules.trackPadding, 2)
    }

    // MARK: Shared copy

    func testAnAgeReadsInTheAppsShortUnits() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertEqual(SettingsCopy.ago(from: now.addingTimeInterval(-3), now: now), "just now")
        XCTAssertEqual(SettingsCopy.ago(from: now.addingTimeInterval(-12), now: now), "12s ago")
        XCTAssertEqual(SettingsCopy.ago(from: now.addingTimeInterval(-250), now: now), "4m ago")
        XCTAssertEqual(SettingsCopy.ago(from: now.addingTimeInterval(-7_300), now: now), "2h ago")
        XCTAssertEqual(SettingsCopy.ago(from: now.addingTimeInterval(-259_205), now: now), "3d ago")
    }

    func testAClockBehindTheDateCountsAsJustNow() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertEqual(SettingsCopy.ago(from: now.addingTimeInterval(30), now: now), "just now")
    }

    func testTheHomeDirectoryIsWrittenAsATilde() {
        XCTAssertEqual(
            SettingsCopy.tildePath("/Users/tester/Library/Application Support/UsageTracker/bin", home: "/Users/tester"),
            "~/Library/Application Support/UsageTracker/bin"
        )
        XCTAssertEqual(SettingsCopy.tildePath("/Users/tester/a", home: "/Users/tester/"), "~/a")
        XCTAssertEqual(SettingsCopy.tildePath("/Users/tester", home: "/Users/tester"), "~")
    }

    func testAPathOutsideHomeIsLeftAlone() {
        XCTAssertEqual(SettingsCopy.tildePath("/Users/testerx/a", home: "/Users/tester"), "/Users/testerx/a")
        XCTAssertEqual(SettingsCopy.tildePath("/tmp/a", home: "/Users/tester"), "/tmp/a")
        XCTAssertEqual(SettingsCopy.tildePath("/tmp/a", home: ""), "/tmp/a")
    }
}
