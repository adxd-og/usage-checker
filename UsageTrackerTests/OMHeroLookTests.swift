import XCTest
@testable import Omelette

/// Liquid-glass redesign spec § Screens, "Popover · provider": "hero ring … 'On track'
/// as text". `Popover-Claude.dc.html`: a 116 pt ring, a 16 pt title, 12.5 pt lines, the
/// phrase in the ok text colour.
final class OMHeroLookTests: XCTestCase {
    func testOnTrackIsGreenTextAndTheWarningsAreAmberAndRed() {
        XCTAssertEqual(OMHero.statusPhrase(53), "On track")
        XCTAssertEqual(OMHero.statusToken(53), .okText)
        XCTAssertEqual(OMHero.statusToken(20), .okText)
        XCTAssertEqual(OMHero.statusToken(75), .warning)
        XCTAssertEqual(OMHero.statusToken(95), .critical)
    }

    func testAVerdictThatHitsTheLimitIsAmber() {
        XCTAssertEqual(OMHero.verdictToken(BurnVerdict(willHit: true, text: "At this pace, limit in ~1h 40m")), .warning)
        XCTAssertEqual(OMHero.verdictToken(BurnVerdict(willHit: false, text: "At this pace you won't hit the limit before reset")), .secondary)
    }

    func testTheHeroIsTheMockups116PointRingWithASixteenPointTitle() {
        XCTAssertEqual(OMHero.ringStyle, .slim)
        XCTAssertEqual(OMRing.metrics(size: .hero, style: OMHero.ringStyle).diameter, 116)
        XCTAssertEqual(OMHero.ringSpacing, 18)
        XCTAssertEqual(OMHero.lineSpacing, 3)
        XCTAssertEqual(OMHero.titleSize, 16)
        XCTAssertEqual(OMHero.captionSize, 12.5)
        XCTAssertEqual(OMHero.topInset, 10)
        XCTAssertEqual(OMHero.sideInset, 6)
        XCTAssertEqual(OMHero.bottomInset, 6)
    }
}
