import SwiftUI
import XCTest
@testable import Omelette

/// Independent verification of P4 ("Show remaining instead of used"), written from
/// `docs/superpowers/specs/2026-09-10-remaining-mode-design.md` and the diff at
/// `aa1103b..HEAD`, not from the executor's own tests.
///
/// This file covers the core rule (`PercentDisplay`), the two shared gauges
/// (`OMRing`, `BarSegment`), the pace marker mirror, and the ranking invariant.
/// Spec: "Colours, pace hints, thresholds and notifications stay on the used
/// value." / "`OMRing.used` is optional and nil draws an empty ring."
final class RemainingModeVerificationTests: XCTestCase {

    // MARK: - PercentDisplay.shown — boundaries

    func testShownClampsAtTheZeroAndHundredBoundaries() {
        XCTAssertEqual(PercentDisplay.shown(0, mode: .used), 0)
        XCTAssertEqual(PercentDisplay.shown(0, mode: .remaining), 100)
        XCTAssertEqual(PercentDisplay.shown(100, mode: .used), 100)
        XCTAssertEqual(PercentDisplay.shown(100, mode: .remaining), 0)
    }

    /// Spec: "`used` clamped to 0…100, `remaining` = `100 - clamped`." A spend
    /// limit at 137% has nothing left, not −37%.
    func testShownClampsAboveAHundredBeforeInverting() {
        XCTAssertEqual(PercentDisplay.shown(137, mode: .used), 100)
        XCTAssertEqual(PercentDisplay.shown(137, mode: .remaining), 0)
    }

    func testShownClampsBelowZeroBeforeInverting() {
        XCTAssertEqual(PercentDisplay.shown(-5, mode: .used), 0)
        XCTAssertEqual(PercentDisplay.shown(-5, mode: .remaining), 100)
    }

    /// Not asked for by the spec, but worth pinning: `max`/`min` resolve a NaN
    /// input to a real number rather than propagating it, because of the order
    /// the two arguments are given in `PercentDisplay.shown`. Recorded here as
    /// today's behaviour, not as an endorsement of it.
    func testShownPinsWhatHappensToNaN() {
        XCTAssertEqual(PercentDisplay.shown(.nan, mode: .used), 100)
        XCTAssertEqual(PercentDisplay.shown(.nan, mode: .remaining), 0)
    }

    // MARK: - percentText / percentPhrase / spoken — rounding at .5

    /// `Double.rounded()` is "to nearest or away from zero": a used reading of
    /// exactly x.5 always rounds up, in both directions of the mode.
    func testPercentTextRoundsHalfAwayFromZeroInBothModes() {
        XCTAssertEqual(PercentDisplay.percentText(37.5, mode: .used), "38%")
        XCTAssertEqual(PercentDisplay.percentText(37.5, mode: .remaining), "63%") // 100 - 37.5 = 62.5 -> 63
        XCTAssertEqual(PercentDisplay.percentText(50.5, mode: .used), "51%")
        XCTAssertEqual(PercentDisplay.percentText(50.5, mode: .remaining), "50%") // 49.5 -> 50
    }

    func testSpokenRoundsHalfAwayFromZeroAndCarriesTheSuffix() {
        XCTAssertEqual(PercentDisplay.spoken(37.5, mode: .used), "38 percent used")
        XCTAssertEqual(PercentDisplay.spoken(37.5, mode: .remaining), "63 percent left")
    }

    /// Spec via the orchestrator ruling: "in used mode the CLI prints an
    /// unclamped reading past 100% ('104%'), in remaining mode it clamps ('0%
    /// left')." `percentPhrase` is the shared function behind every such site.
    func testPercentPhraseIsUnclampedPast100InUsedModeAndClampedInRemaining() {
        XCTAssertEqual(PercentDisplay.percentPhrase(104, mode: .used), "104%")
        XCTAssertEqual(PercentDisplay.percentPhrase(104, mode: .remaining), "0% left")
    }

    func testPercentPhraseCarriesNoWordInUsedModeButDoesInRemaining() {
        XCTAssertEqual(PercentDisplay.percentPhrase(42, mode: .used), "42%")
        XCTAssertEqual(PercentDisplay.percentPhrase(42, mode: .remaining), "58% left")
    }

    func testBareNumberHasNoPercentSignInEitherMode() {
        XCTAssertEqual(PercentDisplay.bareNumber(37.5, mode: .used), "38")
        XCTAssertEqual(PercentDisplay.bareNumber(37.5, mode: .remaining), "63")
    }

    func testSuffixWordsMatchTheSpec() {
        XCTAssertEqual(PercentDisplay.suffix(mode: .used), "used")
        XCTAssertEqual(PercentDisplay.suffix(mode: .remaining), "left")
    }

    // MARK: - pace mirror

    /// Design decision recorded in the plan: the pace dot mirrors in `remaining`
    /// so the "even pace" comparison still holds against an inverted fill.
    func testPaceMirrorsAtZeroHalfAndOne() {
        XCTAssertEqual(PercentDisplay.pace(0, mode: .used), 0)
        XCTAssertEqual(PercentDisplay.pace(0, mode: .remaining), 1)
        XCTAssertEqual(PercentDisplay.pace(1, mode: .used), 1)
        XCTAssertEqual(PercentDisplay.pace(0, mode: .remaining), 1)
        XCTAssertEqual(PercentDisplay.pace(0.5, mode: .used), 0.5)
        XCTAssertEqual(PercentDisplay.pace(0.5, mode: .remaining), 0.5)
    }

    func testPaceStaysNilWhenThereIsNoResetTime() {
        XCTAssertNil(PercentDisplay.pace(nil, mode: .used))
        XCTAssertNil(PercentDisplay.pace(nil, mode: .remaining))
    }

    func testPaceClampsOutOfRangeFractionsBeforeMirroring() {
        XCTAssertEqual(PercentDisplay.pace(1.4, mode: .used), 1)
        XCTAssertEqual(PercentDisplay.pace(1.4, mode: .remaining), 0)
        XCTAssertEqual(PercentDisplay.pace(-0.3, mode: .used), 0)
        XCTAssertEqual(PercentDisplay.pace(-0.3, mode: .remaining), 1)
    }

    // MARK: - OMRing.geometry — the colour never leaves the used value

    func testOMRingGeometryColourIsIdenticalInBothModesAtTheSameUsedValue() {
        let used = OMRing.geometry(used: 63, mode: .used)
        let remaining = OMRing.geometry(used: 63, mode: .remaining)
        XCTAssertEqual(used.color, remaining.color, "the ring's colour must follow used, not the drawn number")
        // Sanity: the drawn arc and label really did flip.
        XCTAssertNotEqual(used.trim, remaining.trim)
        XCTAssertEqual(used.label, "63%")
        XCTAssertEqual(remaining.label, "37%")
    }

    /// 63% used is comfortably green; a ring at 5% left must still read red — the
    /// same emergency as one at 95% used — because the colour input is used, not shown.
    func testOMRingGeometryTurnsRedByUsedEvenWhenTheNumberShownIsSmall() {
        let almostGone = OMRing.geometry(used: 95, mode: .remaining) // "5% left"
        XCTAssertEqual(almostGone.label, "5%")
        XCTAssertEqual(almostGone.color, .red, "5% left is 95% used, which is red")
    }

    /// Spec: "`OMRing.used` is optional and nil draws an empty ring."
    func testOMRingGeometryWithNilUsedIsEmptyInBothModes() {
        for mode in [PercentDisplay.Mode.used, .remaining] {
            let g = OMRing.geometry(used: nil, mode: mode)
            XCTAssertEqual(g.trim, 0, "nil must not draw any arc, mode: \(mode)")
            XCTAssertEqual(g.label, "—", "mode: \(mode)")
            XCTAssertEqual(g.accessibilityValue, "No data", "mode: \(mode)")
            XCTAssertNil(g.pace, "mode: \(mode)")
        }
    }

    /// A ring at true zero (0% used, or 0% left) still draws a visible sliver —
    /// `max(0.004, …)` — in both directions.
    func testOMRingGeometryNeverFullyEmptyAtRealZero() {
        XCTAssertEqual(OMRing.geometry(used: 0, mode: .used).trim, 0.004)
        XCTAssertEqual(OMRing.geometry(used: 100, mode: .remaining).trim, 0.004)
    }

    func testOMRingGeometryAccessibilityValueSwitchesWithMode() {
        let used = OMRing.geometry(used: 42, mode: .used)
        let remaining = OMRing.geometry(used: 42, mode: .remaining)
        XCTAssertEqual(used.accessibilityValue, "42 percent used")
        XCTAssertEqual(remaining.accessibilityValue, "58 percent left")
    }

    // MARK: - BarSegment.geometry — same split, same reason

    func testBarSegmentGeometryColourAndLabelColourFollowUsedNotShown() {
        let used = BarSegment.geometry(used: 82, mode: .used)
        let remaining = BarSegment.geometry(used: 82, mode: .remaining)
        XCTAssertEqual(used.color, remaining.color, "colour must follow used")
        XCTAssertEqual(used.labelIsColored, remaining.labelIsColored, "the >=70 threshold is on used")
        XCTAssertTrue(used.labelIsColored, "82% used should colour the label")
        XCTAssertEqual(used.label, "82%")
        XCTAssertEqual(remaining.label, "18%")
    }

    func testBarSegmentGeometryFillFractionInvertsWithMode() {
        let used = BarSegment.geometry(used: 30, mode: .used)
        let remaining = BarSegment.geometry(used: 30, mode: .remaining)
        XCTAssertEqual(used.fillFraction, 0.30, accuracy: 0.0001)
        XCTAssertEqual(remaining.fillFraction, 0.70, accuracy: 0.0001)
    }

    func testBarSegmentGeometryPaceMirrorsThroughTheSameRule() {
        let used = BarSegment.geometry(used: 50, mode: .used, pace: 0.2)
        let remaining = BarSegment.geometry(used: 50, mode: .remaining, pace: 0.2)
        XCTAssertEqual(used.pace, 0.2)
        XCTAssertEqual(remaining.pace, 0.8)
    }

    // MARK: - WindowRanking — ranking never inverts

    /// Spec § "Surfaces that do not switch" / plan row 27: "ranking by
    /// `clampedPercent` — unchanged." Neither `heroBucket` nor `tileHero` takes a
    /// mode parameter at all, which is exactly what keeps a display preference
    /// from ever touching which window is "the worst one".
    func testHeroBucketPicksTheMostUsedWindowRegardlessOfAnyDisplayPreference() {
        let quiet = Fixture.bucket(id: "quiet", label: "Quiet", percent: 12, kind: .modelSpecific)
        let busy = Fixture.bucket(id: "busy", label: "Busy", percent: 88, kind: .modelSpecific)
        let service = Fixture.snapshot(id: "gemini", buckets: [quiet, busy])

        XCTAssertEqual(WindowRanking.heroBucket(for: service)?.id, "busy")
        XCTAssertEqual(WindowRanking.tileHero(for: service)?.id, "busy")
    }

    func testSessionRowValueNumberSwitchesButResetTextDoesNot() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_GB")
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: 11, minute: 20))!
        let bucket = Fixture.bucket(
            id: "five_hour", label: "Session", percent: 42,
            resetsAt: now.addingTimeInterval(70 * 60), kind: .session
        )

        let used = WindowRanking.sessionRowValue(bucket, mode: .used, now: now, calendar: calendar, locale: locale)
        let remaining = WindowRanking.sessionRowValue(bucket, mode: .remaining, now: now, calendar: calendar, locale: locale)

        XCTAssertTrue(used.hasPrefix("42%"), used)
        XCTAssertTrue(remaining.hasPrefix("58%"), remaining)
        // Same reset text on both sides of the "·".
        let usedReset = used.split(separator: "·", maxSplits: 1).last.map(String.init)?.trimmingCharacters(in: .whitespaces)
        let remainingReset = remaining.split(separator: "·", maxSplits: 1).last.map(String.init)?.trimmingCharacters(in: .whitespaces)
        XCTAssertEqual(usedReset, remainingReset)
    }
}
