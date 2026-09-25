import SwiftUI
import XCTest
@testable import Omelette

/// Liquid-glass redesign spec § Design → Tokens, the popover values the P0 table left
/// to P1 (P0 plan, Decision 9): `Main.dc.html` (dark) and `Popover-All-Light.dc.html`
/// (light).
final class OMPalettePopoverTokensTests: XCTestCase {
    private func dark(_ token: OMColorToken) -> OMRGBA { OMPalette.rgba(token, scheme: .dark) }
    private func light(_ token: OMColorToken) -> OMRGBA { OMPalette.rgba(token, scheme: .light) }

    func testPopoverGroupsMatchTheCardsInDarkAndAreLighterEdgedInLight() {
        XCTAssertEqual(dark(.groupFill), dark(.contentFill))
        XCTAssertEqual(dark(.groupBorder), dark(.contentBorder))
        XCTAssertEqual(light(.groupFill), .white(0.55))
        XCTAssertEqual(light(.groupBorder), .white(0.70))
    }

    func testLastKnownArcsAndIdleDotsAreMuted() {
        XCTAssertEqual(dark(.muted), OMRGBA(hex: 0xF5F5F7, opacity: 0.40))
        XCTAssertEqual(light(.muted), OMRGBA(hex: 0x1D1D1F, opacity: 0.35))
    }

    func testThePaceMarkerIsWhiteInDarkAndNearBlackInLight() {
        XCTAssertEqual(dark(.paceMarker), .white(0.75))
        XCTAssertEqual(light(.paceMarker), OMRGBA(hex: 0x1D1D1F, opacity: 0.60))
    }

    func testTheAllowLabelIsDarkYolkAndReadsOnTheAccent() {
        XCTAssertEqual(dark(.onAccent), OMRGBA(hex: 0x231704))
        XCTAssertEqual(light(.onAccent), OMRGBA(hex: 0x231704))
        XCTAssertGreaterThanOrEqual(OMRGBA.contrastRatio(dark(.onAccent), dark(.accent)), 4.5)
    }

    /// The spec's table has no amber or red: these are the system orange and red the
    /// 2.x gauges already draw, so the 70–89 % and 90 % bands keep their colours.
    func testWarningAndCriticalAreTheSystemOrangeAndRed() {
        XCTAssertEqual(dark(.warning), OMRGBA(hex: 0xFF9F0A))
        XCTAssertEqual(light(.warning), OMRGBA(hex: 0xFF9500))
        XCTAssertEqual(dark(.critical), OMRGBA(hex: 0xFF453A))
        XCTAssertEqual(light(.critical), OMRGBA(hex: 0xFF3B30))
    }
}
