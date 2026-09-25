import XCTest
@testable import Omelette

/// Second-round independent verification of `OverviewLink`, for the `fix/3.0-followups`
/// package contract item 1: `viewMode` — `.tokensByDay` opens History on
/// `HistoryViewMode.chart`, `.history` leaves the user's own view alone (nil) — and that
/// `OverviewView` keeps that choice under `HistoryRules.viewModeKey`, the same key
/// `SessionHistoryView` reads its `@AppStorage` from. Independent of
/// `OverviewLinkTests.swift` and of the round-1 `OverviewLinkVerificationTests.swift`
/// (P3, ruling D13), which predate `viewMode` and never exercise it.
final class OverviewLinkVerification2Tests: XCTestCase {
    private static func repoRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent() // this file
        url.deleteLastPathComponent() // UsageTrackerTests/
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("UsageTracker.xcodeproj").path) else {
            throw XCTSkip("could not locate the repo root from #filePath")
        }
        return url
    }

    func testTokensByDayOpensHistoryOnTheChartView() {
        XCTAssertEqual(OverviewLink.tokensByDay.viewMode, .chart)
    }

    func testHistoryLinkKeepsWhicheverViewTheUserLeftHistoryOn() {
        XCTAssertNil(OverviewLink.history.viewMode, "the plain History link must not force a view switch")
    }

    /// Walks every case through `CaseIterable` rather than naming the two by hand, so a
    /// case added to `OverviewLink` later without a matching arm in `viewMode`'s switch
    /// is caught here rather than only at whichever call site forgets to handle it.
    func testEveryLinkCaseHasAnExplicitViewModeMapping() {
        for link in OverviewLink.allCases {
            switch link {
            case .history:
                XCTAssertNil(link.viewMode, "\(link)")
            case .tokensByDay:
                XCTAssertEqual(link.viewMode, .chart, "\(link)")
            }
        }
    }

    /// `HistoryViewMode.chart`'s raw value is the storage contract `HistoryRules
    /// .viewModeKey` persists under (`SessionHistoryView`'s own `@AppStorage`); confirm
    /// the string that would land in `UserDefaults` reads back as the case the spec means.
    func testTheChartViewModesRawValueRoundTripsThroughStorage() throws {
        let mode = try XCTUnwrap(OverviewLink.tokensByDay.viewMode)
        XCTAssertEqual(HistoryViewMode(rawValue: mode.rawValue), .chart)
        XCTAssertEqual(HistoryRules.viewModeKey, "historyView")
    }

    /// `follow` is a private method on a SwiftUI view, so the rule under test here is
    /// the *key* it writes to and that it applies `viewMode` before the tab switch,
    /// confirmed by reading the source rather than instantiating the view (CLAUDE.md:
    /// "test the rule, not the view").
    func testOverviewViewWritesTheViewModeUnderHistoryRulesViewModeKeyBeforeSwitchingTabs() throws {
        let url = try Self.repoRoot().appendingPathComponent("UsageTracker/UI/Dashboard/OverviewView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(
            source.contains(#"@AppStorage(HistoryRules.viewModeKey) private var historyViewMode: String = HistoryViewMode.chart.rawValue"#),
            "OverviewView's History view-mode storage must stay under HistoryRules.viewModeKey"
        )
        XCTAssertTrue(
            source.contains("if let view = link.viewMode { historyViewMode = view.rawValue }"),
            "follow(_:) must apply OverviewLink.viewMode"
        )

        // A straight-line function body: the view-mode write appears before the tab
        // switch in the source, so it also runs first — a History window already open
        // flips to the right chart instead of switching tabs on the old view first.
        let viewModeRange = try XCTUnwrap(source.range(of: "if let view = link.viewMode"))
        let tabRange = try XCTUnwrap(source.range(of: "storedTab = link.tab.rawValue"))
        XCTAssertTrue(viewModeRange.lowerBound < tabRange.lowerBound, "the view mode must be set before the tab switch")
    }
}
