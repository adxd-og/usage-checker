import XCTest
@testable import Omelette

/// Liquid-glass redesign spec § Components, `OMRing`: "thinner stroke, round caps,
/// pace dot on the arc (no tick)" — and § Decisions, "Widget": untouched in 3.0. The
/// widget never names a style, so the default has to be the ring it draws today.
final class OMRingSlimStyleTests: XCTestCase {
    @MainActor
    func testTheDefaultStyleIsTheClassicRingTheWidgetDraws() {
        let ring = OMRing(used: 42, mode: .used)
        XCTAssertEqual(ring.style, .classic)
        XCTAssertFalse(ring.muted)
    }

    func testTheClassicMetricsAreUnchanged() {
        let expected: [(OMRing.Size, CGFloat, CGFloat)] = [
            (.widget, 110, 10), (.hero, 84, 9), (.medium, 52, 6), (.small, 44, 5), (.mini, 26, 4),
        ]
        for (size, diameter, line) in expected {
            let m = OMRing.metrics(size: size, style: .classic)
            XCTAssertEqual(m.diameter, diameter, "\(size)")
            XCTAssertEqual(m.lineWidth, line, "\(size)")
            XCTAssertEqual(m.paceDot, 3, "\(size)")
            XCTAssertEqual(m.lineCap, .round, "\(size)")
            XCTAssertEqual(m.paceDotOpacity, 0.55, "\(size)")
            // The classic dot rides the stroke's centre line on the frame's edge, as before.
            XCTAssertEqual(OMRing.arcRadius(m), diameter / 2, "\(size)")
        }
    }

    func testTheSlimTileRingIsTheMockups54PointRing() {
        let m = OMRing.metrics(size: .medium, style: .slim)
        XCTAssertEqual(m.diameter, 54)
        XCTAssertEqual(m.lineWidth, 6)
        XCTAssertEqual(OMRing.arcRadius(m), 23)
        XCTAssertEqual(m.paceDot, 4)
        XCTAssertEqual(m.lineCap, .round)
        XCTAssertEqual(m.labelSize, 13)
        XCTAssertEqual(m.unitSize, 9)
    }

    func testTheSlimHeroRingIsTheMockups116PointRing() {
        let m = OMRing.metrics(size: .hero, style: .slim)
        XCTAssertEqual(m.diameter, 116)
        XCTAssertEqual(m.lineWidth, 10)
        XCTAssertEqual(OMRing.arcRadius(m), 52)
        XCTAssertEqual(m.paceDot, 5.6, accuracy: 0.001)
        XCTAssertEqual(m.labelSize, 28)
        XCTAssertEqual(m.unitSize, 18)
    }

    func testTheSlimStrokeIsThinnerForItsSizeThanTheClassicOne() {
        for size in [OMRing.Size.widget, .hero, .medium, .small, .mini] {
            let classic = OMRing.metrics(size: size, style: .classic)
            let slim = OMRing.metrics(size: size, style: .slim)
            XCTAssertLessThan(slim.lineWidth / slim.diameter, classic.lineWidth / classic.diameter, "\(size)")
        }
    }

    /// `Main.dc.html`: the Claude tile's pace dot is drawn at (21.28, 4.72) in a 54 pt
    /// box — on the arc's centre line, 23 pt from the centre.
    func testTheSlimPaceDotSitsOnTheArcsCentreLine() {
        let m = OMRing.metrics(size: .medium, style: .slim)
        let dx = 21.28 - 27.0
        let dy = 4.72 - 27.0
        XCTAssertEqual(Double(OMRing.arcRadius(m)), (dx * dx + dy * dy).squareRoot(), accuracy: 0.05)
    }

    func testThePaceMarkerShowsOnlyInsideTheWindow() {
        XCTAssertFalse(OMRing.paceMarkerVisible(nil))
        XCTAssertFalse(OMRing.paceMarkerVisible(0.01))
        XCTAssertTrue(OMRing.paceMarkerVisible(0.5))
        XCTAssertFalse(OMRing.paceMarkerVisible(0.99))
    }

    func testTheSlimArcTakesTheGaugeToneOnTheUsedValue() {
        XCTAssertEqual(OMRing.slimArcToken(used: 57, muted: false), .ok)
        XCTAssertEqual(OMRing.slimArcToken(used: 75, muted: false), .warning)
        XCTAssertEqual(OMRing.slimArcToken(used: 95, muted: false), .critical)
    }

    func testALastKnownArcIsMutedWhateverItsValue() {
        XCTAssertEqual(OMRing.slimArcToken(used: 95, muted: true), .muted)
        XCTAssertEqual(OMRing.slimArcToken(used: nil, muted: false), .muted)
    }
}
