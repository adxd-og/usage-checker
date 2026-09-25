import SwiftUI
import XCTest
@testable import Omelette

/// Independent verification of `fix/3.0-followups` package contract item 4:
/// `OMFont.dashboardSubtitle` is 12.5 pt, `DashboardHeader` gained an optional `leading`
/// slot used only by Overview, `OverviewHeaderRules` holds the logo tile metrics from
/// `docs/superpowers/specs/2026-09-24-liquid-glass-redesign/mockups/Dashboard-Overview
/// .dc.html` (40 pt tile, 13 pt corner, 14 pt gap), and the tile is nil only for an empty
/// service id.
///
/// Rather than hard-coding the three numbers a second time (which would only catch a
/// typo that changed both the code and this file the same way), this file re-reads the
/// mockup's own inline CSS for the header's logo box and parses the numbers back out of
/// it, so a future edit to the mockup that the code does not follow fails here.
final class OverviewHeaderRulesVerificationTests: XCTestCase {
    private static func repoRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()
        url.deleteLastPathComponent()
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("UsageTracker.xcodeproj").path) else {
            throw XCTSkip("could not locate the repo root from #filePath")
        }
        return url
    }

    private static func firstDouble(matching pattern: String, in text: String) throws -> Double {
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let numberRange = Range(match.range(at: 1), in: text)
        else { throw XCTSkip("pattern \(pattern) not found in the mockup") }
        return try XCTUnwrap(Double(text[numberRange]))
    }

    // MARK: - Metrics read back out of the mockup's own CSS

    /// `Dashboard-Overview.dc.html` lines 28–29: the header row that holds the logo tile
    /// and the title block (`gap: 14px`), immediately followed by the tile itself
    /// (`width: 40px; height: 40px; … border-radius: 13px`).
    ///
    /// A bare "width: 40px; height: 40px; flex-shrink: 0; border-radius: 13px" also
    /// matches a *different*, unrelated 24×24/7px box earlier in the same file (the
    /// sidebar's own "Omelette" mark, line 21) if the two searches run independently —
    /// `firstMatch` would silently pick that one up instead, since it comes first in the
    /// file. One combined pattern anchored on the header row's own `gap: 14px;
    /// flex-grow: 1` immediately before the tile rules that out.
    func testTheLeadingGapTileSizeAndCornerMatchTheMockupsHeaderRowAndLogoBox() throws {
        let repo = try Self.repoRoot()
        let mockup = repo.appendingPathComponent(
            "docs/superpowers/specs/2026-09-24-liquid-glass-redesign/mockups/Dashboard-Overview.dc.html"
        )
        let source = try String(contentsOf: mockup, encoding: .utf8)
        let pattern = #"align-items: center; gap: (\d+(?:\.\d+)?)px; flex-grow: 1">\s*<div style="width: (\d+(?:\.\d+)?)px; height: \d+(?:\.\d+)?px; flex-shrink: 0; border-radius: (\d+(?:\.\d+)?)px"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..., in: source)
        let match = try XCTUnwrap(regex.firstMatch(in: source, range: range), "the header row + logo box CSS was not found together in the mockup")
        let gap = try XCTUnwrap(Double(source[try XCTUnwrap(Range(match.range(at: 1), in: source))]))
        let size = try XCTUnwrap(Double(source[try XCTUnwrap(Range(match.range(at: 2), in: source))]))
        let radius = try XCTUnwrap(Double(source[try XCTUnwrap(Range(match.range(at: 3), in: source))]))

        XCTAssertEqual(gap, 14)
        XCTAssertEqual(size, 40)
        XCTAssertEqual(radius, 13)
        XCTAssertEqual(DashboardHeader.leadingSpacing, CGFloat(gap))
        XCTAssertEqual(OverviewHeaderRules.tileSize, CGFloat(size))
        XCTAssertEqual(OverviewHeaderRules.tileRadius, CGFloat(radius))
    }

    /// The unrelated 24×24/7px box this file also contains (the sidebar's own
    /// "Omelette" mark) must not be the one the rules were pinned to — a sanity check
    /// that the anchored pattern above did not just get lucky.
    func testTheOverviewRulesDoNotMatchTheUnrelatedSidebarMarkSize() {
        XCTAssertNotEqual(OverviewHeaderRules.tileSize, 24)
        XCTAssertNotEqual(OverviewHeaderRules.tileRadius, 7)
    }

    /// Line 32, the subtitle right under the 26 pt title: `font-size: 12.5px`.
    func testTheSubtitleSizeMatchesTheMockupsLineUnderTheTitle() throws {
        let repo = try Self.repoRoot()
        let mockup = repo.appendingPathComponent(
            "docs/superpowers/specs/2026-09-24-liquid-glass-redesign/mockups/Dashboard-Overview.dc.html"
        )
        let source = try String(contentsOf: mockup, encoding: .utf8)
        // The line that follows the 26 pt title line, itself carrying a font-size.
        let titlePattern = #"font-size: 26px; font-weight: 700; color: #F5F5F7;[^<]*</div>\s*<div style="font-size: (\d+(?:\.\d+)?)px"#
        let subtitleSize = try Self.firstDouble(matching: titlePattern, in: source)
        XCTAssertEqual(subtitleSize, 12.5)
        XCTAssertEqual(OMFont.dashboardSubtitle, Font.system(size: CGFloat(subtitleSize)))
        XCTAssertEqual(DashboardHeader.subtitleFont, OMFont.dashboardSubtitle)
    }

    // MARK: - The tile is nil only for an empty service id

    func testTheTileIsNilOnlyForAnEmptyServiceID() {
        XCTAssertNil(OverviewHeaderRules.logo(serviceID: "", service: nil))
        XCTAssertNil(OverviewHeaderRules.logo(serviceID: "", service: Fixture.snapshot(id: "claude")))
    }

    /// Independent fixtures from `OverviewHeaderRulesTests.swift` (codex/grok): a
    /// provider with a live snapshot takes the snapshot's own icon, and every
    /// non-empty id gets a tile regardless of provider.
    func testANonEmptyIDWithALiveSnapshotUsesTheSnapshotsOwnIcon() throws {
        let service = Fixture.snapshot(id: "fable", icon: "book", plan: "Fable")
        let logo = try XCTUnwrap(OverviewHeaderRules.logo(serviceID: "fable", service: service))
        XCTAssertEqual(logo, OverviewHeaderLogo(serviceID: "fable", sfFallback: "book"))
    }

    func testANonEmptyIDWithNoLiveSnapshotFallsBackToSparkles() throws {
        let logo = try XCTUnwrap(OverviewHeaderRules.logo(serviceID: "anthropic_admin", service: nil))
        XCTAssertEqual(logo, OverviewHeaderLogo(serviceID: "anthropic_admin", sfFallback: "sparkles"))
    }

    func testTheIconSitsInsideTheTileWithRoomOnEveryEdge() {
        XCTAssertLessThan(OverviewHeaderRules.iconSize, OverviewHeaderRules.tileSize)
        XCTAssertGreaterThan(OverviewHeaderRules.iconSize, 0)
    }

    // MARK: - DashboardHeader's leading slot exists and Overview alone supplies it

    func testOverviewViewIsTheOnlyCallerThatPassesLeadingToDashboardHeader() throws {
        let repo = try Self.repoRoot()
        let overviewSource = try String(
            contentsOf: repo.appendingPathComponent("UsageTracker/UI/Dashboard/OverviewView.swift"), encoding: .utf8
        )
        XCTAssertTrue(
            overviewSource.contains("leading: OverviewHeaderRules.logo(serviceID: dashboard.selectedService, service: service)"),
            "OverviewView must pass its provider's logo tile as DashboardHeader's leading slot"
        )

        let headerSource = try String(
            contentsOf: repo.appendingPathComponent("UsageTracker/UI/Dashboard/DashboardWindow.swift"), encoding: .utf8
        )
        XCTAssertTrue(
            headerSource.contains("var leading: AnyView? = nil"),
            "DashboardHeader.leading must default to nil so every other screen is unaffected"
        )
    }
}
