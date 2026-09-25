import XCTest
@testable import Omelette

/// Independent verification of the hard requirement for P1 (Popover): the WidgetKit
/// target must render byte-for-byte as before `OMRing` and `BarSegment` grew a 3.0
/// `.slim` opt-in (liquid-glass spec § Decisions, "Widget": "untouched in 3.0,
/// redesigned in 3.1 ... only the deployment target moves with the bundle"; § Facts,
/// "Tokens and glass": "thinner stroke and pace dot must not change the widget's
/// look").
///
/// The widget's real call sites, read from `UsageTrackerWidget/UsageTrackerWidget.swift`
/// at `feat/3.0-p1` (unchanged from the merge base — confirmed by an empty
/// `git diff <merge-base>..feat/3.0-p1 -- UsageTrackerWidget/`):
///   - `OMRing(used: service.headlineBucket?.percent, mode: mode, size: .widget, showsLabel: false)`
///   - `BarSegment(used: bucket.percent, mode: mode, height: compact ? 5 : 6)`
/// Neither call names `style:`, so both draw through the `.classic` default. Every
/// value below is re-derived independently from the pre-P1 file
/// (`git show <merge-base>:SharedUI/OMRing.swift` / `:SharedUI/BarSegment.swift`),
/// not copied from the executor's own `OMRingSlimStyleTests` / `BarSegmentSlimStyleTests`.
final class SharedUIWidgetLookVerificationTests: XCTestCase {

    // MARK: - OMRing, widget call site

    /// Pre-P1: `size.diameter` for `.widget` was 110, `size.lineWidth` was 10, drawn
    /// with a plain `.round` cap and no inset (`Circle().stroke(...)`, no `.inset(by:)`).
    func testWidgetRingClassicMetricsMatchThePreP1Values() {
        let m = OMRing.metrics(size: .widget, style: .classic)
        XCTAssertEqual(m.diameter, 110)
        XCTAssertEqual(m.lineWidth, 10)
        XCTAssertEqual(m.arcInset, 0, "classic's stroke was centred on the frame's edge")
        XCTAssertEqual(m.lineCap, .round)
        // Pre-P1 pace dot: `.frame(width: 3, height: 3)`, opacity 0.55.
        XCTAssertEqual(m.paceDot, 3)
        XCTAssertEqual(m.paceDotOpacity, 0.55, accuracy: 0.0001)
        // Pre-P1 had no figure/unit split at all for the classic ring.
        XCTAssertNil(m.labelSize)
        XCTAssertNil(m.unitSize)
    }

    /// Pre-P1: `.offset(y: -(size.diameter / 2))` — the dot rode the frame's own edge,
    /// not an inset arc.
    func testWidgetRingPaceDotRadiusIsHalfTheDiameter() {
        let m = OMRing.metrics(size: .widget, style: .classic)
        XCTAssertEqual(OMRing.arcRadius(m), 55)
    }

    /// `OMRing(used:mode:size:.widget,showsLabel:false)` never names `style:` or
    /// `muted:`; both must default to the classic, unmuted look.
    @MainActor
    func testTheWidgetsExactCallLeavesEveryNewParameterAtItsClassicDefault() {
        let ring = OMRing(used: 61, mode: .used, size: .widget, showsLabel: false)
        XCTAssertEqual(ring.style, .classic)
        XCTAssertFalse(ring.muted)
        XCTAssertNil(ring.color)
        XCTAssertNil(ring.pace)
    }

    /// Pre-P1: `if let pace = g.pace, pace > 0.02, pace < 0.98` — inclusive band ends
    /// excluded, nothing else.
    func testWidgetRingPaceMarkerVisibilityBandIsUnchanged() {
        XCTAssertFalse(OMRing.paceMarkerVisible(nil))
        XCTAssertFalse(OMRing.paceMarkerVisible(0))
        XCTAssertFalse(OMRing.paceMarkerVisible(0.02))
        XCTAssertTrue(OMRing.paceMarkerVisible(0.021))
        XCTAssertTrue(OMRing.paceMarkerVisible(0.5))
        XCTAssertTrue(OMRing.paceMarkerVisible(0.979))
        XCTAssertFalse(OMRing.paceMarkerVisible(0.98))
        XCTAssertFalse(OMRing.paceMarkerVisible(1))
    }

    /// Pre-P1 `geometry(used:mode:pace:color:)` is untouched code; re-derive its
    /// three published bands (green/orange/red) and the "no window" fallback
    /// directly, rather than trusting the tone table added for the slim ring.
    func testWidgetRingGeometryColorMatchesUsageStatusColorAtEveryBandBoundary() {
        let cases: [Double] = [0, 1, 69, 69.9, 70, 89, 89.9, 90, 100, 150]
        for percent in cases {
            let g = OMRing.geometry(used: percent, mode: .used)
            XCTAssertEqual(g.color, usageStatusColor(max(0, min(100, percent))), "at \(percent)%")
        }
        // nil "no window" case: track only, secondary colour, "—", no VoiceOver value.
        let empty = OMRing.geometry(used: nil, mode: .used)
        XCTAssertEqual(empty.trim, 0)
        XCTAssertEqual(empty.label, "—")
        XCTAssertNil(empty.pace)
        XCTAssertEqual(empty.color, .secondary)
    }

    /// Pre-P1: `trim: max(0.004, percent / 100)` — the floor that keeps a 0% ring from
    /// disappearing entirely.
    func testWidgetRingTrimFloorIsUnchanged() {
        XCTAssertEqual(OMRing.geometry(used: 0, mode: .used).trim, 0.004, accuracy: 0.0001)
        XCTAssertEqual(OMRing.geometry(used: 42, mode: .used).trim, 0.42, accuracy: 0.0001)
    }

    // MARK: - BarSegment, widget call site

    /// Pre-P1 tick: `.frame(width: 2, height: height + 4)`, `Capsule`, opacity 0.45.
    /// The widget's own two heights (`compact ? 5 : 6`) both go through this.
    func testWidgetBarClassicTickMetricsMatchThePreP1Values() {
        XCTAssertEqual(BarSegment.tickHeight(barHeight: 5, style: .classic), 9)
        XCTAssertEqual(BarSegment.tickHeight(barHeight: 6, style: .classic), 10)
        XCTAssertEqual(BarSegment.tickWidth, 2)
        XCTAssertEqual(BarSegment.tickCorner, .capsule)
        XCTAssertEqual(BarSegment.classicTickOpacity, 0.45, accuracy: 0.0001)
    }

    /// `BarSegment(used:mode:height:)` never names `style:`, `showsLabel:` or `pace:`;
    /// they must default to the classic, label-less, tick-less look the widget drew.
    @MainActor
    func testTheWidgetsExactBarCallLeavesEveryNewParameterAtItsClassicDefault() {
        let bar = BarSegment(used: 37, mode: .used, height: 6)
        XCTAssertEqual(bar.style, .classic)
        XCTAssertFalse(bar.showsLabel)
        XCTAssertNil(bar.pace)
    }

    /// Pre-P1: `if let pace = g.pace, pace > 0.02, pace < 0.98` (identical band to the ring).
    func testWidgetBarTickVisibilityBandIsUnchanged() {
        XCTAssertFalse(BarSegment.tickVisible(nil))
        XCTAssertFalse(BarSegment.tickVisible(0.02))
        XCTAssertTrue(BarSegment.tickVisible(0.021))
        XCTAssertTrue(BarSegment.tickVisible(0.979))
        XCTAssertFalse(BarSegment.tickVisible(0.98))
    }

    /// Pre-P1 `geometry(used:mode:pace:)` is untouched code; the classic fill still
    /// reads `g.color`, i.e. `usageStatusColor`, at every band boundary — never the
    /// slim gauge-tone token.
    func testWidgetBarGeometryColorMatchesUsageStatusColorAtEveryBandBoundary() {
        let cases: [Double] = [0, 69, 70, 89, 90, 100]
        for percent in cases {
            let g = BarSegment.geometry(used: percent, mode: .used)
            XCTAssertEqual(g.color, usageStatusColor(percent), "at \(percent)%")
        }
    }

    /// Pre-P1: `labelIsColored: usedClamped >= 70` — irrelevant to the widget (it never
    /// passes `showsLabel: true`), but part of the same untouched `Geometry` the widget
    /// still builds every poll, so it is pinned alongside the rest.
    func testWidgetBarLabelColourThresholdIsUnchanged() {
        XCTAssertFalse(BarSegment.geometry(used: 69.9, mode: .used).labelIsColored)
        XCTAssertTrue(BarSegment.geometry(used: 70, mode: .used).labelIsColored)
    }
}
