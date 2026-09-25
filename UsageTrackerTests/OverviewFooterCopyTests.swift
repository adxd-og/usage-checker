import XCTest
@testable import Omelette

/// Liquid-glass spec § Screens, "Overview" (`Dashboard-Overview.dc.html`): the legend's
/// title, and its last line — the burn verdict in its colour when there is one, else the
/// mockup's "Burn rate: idle".
final class OverviewFooterCopyTests: XCTestCase {
    func testTheLegendIsTitledUsageWindows() {
        XCTAssertEqual(OverviewCopy.legendTitle, "Usage windows")
    }

    func testTheBurnLineIsTheMockupsWording() {
        XCTAssertEqual(OverviewCopy.burnLine(burn: Fixture.prediction(secondsToLimit: nil, percentPerMinute: 0),
                                             retained: false), "Burn rate: idle")
        XCTAssertEqual(OverviewCopy.burnLine(burn: Fixture.prediction(secondsToLimit: nil, percentPerMinute: 1),
                                             retained: false), "Burn rate: stable")
        XCTAssertEqual(OverviewCopy.burnLine(burn: nil, retained: false), "Burn rate: not enough data")
        XCTAssertEqual(OverviewCopy.burnLine(burn: Fixture.prediction(secondsToLimit: 2 * 3600 + 15 * 60),
                                             retained: false), "Burn rate: hit limit in 2h 15m")
    }

    func testLastKnownNumbersArePaused() {
        XCTAssertEqual(OverviewCopy.burnLine(burn: Fixture.prediction(secondsToLimit: 3600), retained: true),
                       "Burn rate: paused")
    }

    func testAVerdictThatHitsTheLimitIsAmber() {
        let verdict = BurnVerdict(willHit: true, text: "At this pace, limit in ~1h 40m")
        XCTAssertEqual(OverviewCopy.footer(verdict: verdict, burn: nil, retained: false),
                       OverviewLine(text: "At this pace, limit in ~1h 40m", token: .warning))
    }

    func testAVerdictThatDoesNotIsQuiet() {
        let verdict = BurnVerdict(willHit: false, text: "At this pace you won't hit the limit before reset")
        XCTAssertEqual(OverviewCopy.footer(verdict: verdict, burn: nil, retained: false).token, .secondary)
    }

    func testWithNoVerdictTheFooterIsTheBurnLine() {
        XCTAssertEqual(
            OverviewCopy.footer(verdict: nil, burn: Fixture.prediction(secondsToLimit: nil, percentPerMinute: 0),
                                retained: false),
            OverviewLine(text: "Burn rate: idle", token: .secondary)
        )
    }
}
