import XCTest
@testable import Omelette

/// Independent verification of `ActivityGridView.cellTooltip` and `.statsCaption`,
/// derived from `docs/superpowers/specs/2026-09-24-2.7.0-hardening.md` § Design
/// "Agents, CLI, scripts (report C)" and the plan's session ruling #1 ("the Activity
/// stat cards carry the caption too"). Not from `ActivityCostCaptionTests`. Focus: each
/// of `cellTooltip`'s four independent guard conditions is falsified on its own
/// (holding the other three at their "would append" value) so a single broken `&&`
/// cannot hide behind the others, and the claim that the quota grid's cards and
/// squares get neither caption "whatever the caption value is" — including a caption
/// that is present but should still be suppressed.
final class ActivityGridViewVerificationTests: XCTestCase {
    private let caption = "API-equivalent cost of your CLI usage — not what your subscription bills."
    private let day = "Sep 12, 2026: $9.40"

    // MARK: - statsCaption

    func testStatsCaptionIsSuppressedOnAQuotaGridEvenWithACaptionPresent() {
        XCTAssertNil(ActivityGridView.statsCaption(isQuota: true, caption: caption))
    }

    func testStatsCaptionPassesThroughUnchangedOnACostGrid() {
        XCTAssertEqual(ActivityGridView.statsCaption(isQuota: false, caption: caption), caption)
    }

    func testStatsCaptionIsNilOnACostGridWithNoCaption() {
        XCTAssertNil(ActivityGridView.statsCaption(isQuota: false, caption: nil))
    }

    // MARK: - cellTooltip: each guard falsified alone

    /// Baseline: every condition true, so the caption is appended on its own line.
    func testEveryConditionTrueAppendsTheCaptionOnASecondLine() {
        XCTAssertEqual(
            ActivityGridView.cellTooltip(day, hasReading: true, isQuota: false, caption: caption),
            "\(day)\n\(caption)"
        )
    }

    func testIsQuotaAloneSuppressesTheCaption() {
        XCTAssertEqual(ActivityGridView.cellTooltip(day, hasReading: true, isQuota: true, caption: caption), day)
    }

    func testHasReadingFalseAloneSuppressesTheCaption() {
        XCTAssertEqual(ActivityGridView.cellTooltip(day, hasReading: false, isQuota: false, caption: caption), day)
    }

    func testAnEmptyTooltipAloneSuppressesTheCaption() {
        XCTAssertEqual(ActivityGridView.cellTooltip("", hasReading: true, isQuota: false, caption: caption), "")
    }

    func testANilCaptionAloneLeavesTheTooltipAsBuilt() {
        XCTAssertEqual(ActivityGridView.cellTooltip(day, hasReading: true, isQuota: false, caption: nil), day)
    }
}
