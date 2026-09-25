import SwiftUI
import XCTest
@testable import Omelette

/// Liquid-glass redesign spec § Design → Tokens (colour rows). Every role has one dark
/// and one light value, taken from `Main.dc.html`, `Popover-All-Light.dc.html` and
/// `Dashboard-Overview(-Light).dc.html`; a view gets the one for its environment's
/// colour scheme; captions keep 4.5:1.
final class OMPaletteTests: XCTestCase {
    private func dark(_ token: OMColorToken) -> OMRGBA { OMPalette.rgba(token, scheme: .dark) }
    private func light(_ token: OMColorToken) -> OMRGBA { OMPalette.rgba(token, scheme: .light) }

    func testTheAccentIsYolkAsAFillInBothAppearances() {
        XCTAssertEqual(dark(.accent), OMRGBA(hex: 0xF2B544))
        XCTAssertEqual(light(.accent), OMRGBA(hex: 0xF2B544))
    }

    func testAccentAsTextIsYolkInDarkAndMixedWithTheTextColourInLight() {
        XCTAssertEqual(dark(.accentText), OMRGBA(hex: 0xF2B544))
        // color-mix(in oklab, #F2B544 52%, #1D1D1F), as Dashboard-Overview-Light draws links.
        XCTAssertEqual(light(.accentText), OMRGBA(hex: 0x846739))
    }

    func testTextIsNearWhiteInDarkAndNearBlackInLightWithSecondaryAt64Percent() {
        XCTAssertEqual(dark(.text), OMRGBA(hex: 0xF5F5F7))
        XCTAssertEqual(light(.text), OMRGBA(hex: 0x1D1D1F))
        XCTAssertEqual(dark(.secondary), OMRGBA(hex: 0xF5F5F7, opacity: 0.64))
        XCTAssertEqual(light(.secondary), OMRGBA(hex: 0x1D1D1F, opacity: 0.64))
    }

    func testCardsTracksAndHairlinesAreTranslucentWhiteInDarkAndQuietInLight() {
        XCTAssertEqual(dark(.contentFill), .white(0.055))
        XCTAssertEqual(dark(.contentBorder), .white(0.05))
        XCTAssertEqual(light(.contentFill), .white(0.72))
        XCTAssertEqual(light(.contentBorder), .black(0.05))
        XCTAssertEqual(dark(.track), .white(0.10))
        XCTAssertEqual(light(.track), .black(0.08))
        XCTAssertEqual(dark(.hairline), .white(0.07))
        XCTAssertEqual(light(.hairline), .black(0.08))
    }

    func testOkAndWorkingHaveAFillAndATextOrHaloValue() {
        XCTAssertEqual(dark(.ok), OMRGBA(hex: 0x6FD99A))
        XCTAssertEqual(light(.ok), OMRGBA(hex: 0x2FB36A))
        XCTAssertEqual(dark(.okText), OMRGBA(hex: 0x7FE3A8))
        XCTAssertEqual(light(.okText), OMRGBA(hex: 0x1E8A4F))
        XCTAssertEqual(dark(.working), OMRGBA(hex: 0x6EA8FF))
        XCTAssertEqual(light(.working), OMRGBA(hex: 0x2F7BF5))
        XCTAssertEqual(dark(.workingHalo), OMRGBA(hex: 0x6EA8FF, opacity: 0.25))
        XCTAssertEqual(light(.workingHalo), OMRGBA(hex: 0x2F7BF5, opacity: 0.25))
    }

    func testTheFocusRingIsYolkAt28PercentThreePointsWide() {
        XCTAssertEqual(dark(.focusRing), OMRGBA(hex: 0xF2B544, opacity: 0.28))
        XCTAssertEqual(light(.focusRing), OMRGBA(hex: 0xF2B544, opacity: 0.28))
        XCTAssertEqual(OMFocusRing.width, 3)
    }

    func testOverviewSeriesAreGreenBlueAndViolet() {
        XCTAssertEqual(dark(.seriesSession), OMRGBA(hex: 0x6FD99A))
        XCTAssertEqual(dark(.seriesAllModels), OMRGBA(hex: 0x7AA2FF))
        XCTAssertEqual(dark(.seriesPerModel), OMRGBA(hex: 0xC79BFF))
        XCTAssertEqual(light(.seriesSession), OMRGBA(hex: 0x2FB36A))
        XCTAssertEqual(light(.seriesAllModels), OMRGBA(hex: 0x4C7EF3))
        XCTAssertEqual(light(.seriesPerModel), OMRGBA(hex: 0x9A66EE))
    }

    func testTokenCategoriesAreBlueOrangeTealAndViolet() {
        XCTAssertEqual(dark(.tokenInput), OMRGBA(hex: 0x7AA2FF))
        XCTAssertEqual(dark(.tokenOutput), OMRGBA(hex: 0xF59E6B))
        XCTAssertEqual(dark(.tokenCacheRead), OMRGBA(hex: 0x5CC8C8))
        XCTAssertEqual(dark(.tokenCacheWrite), OMRGBA(hex: 0xC79BFF))
        XCTAssertEqual(light(.tokenInput), OMRGBA(hex: 0x4C7EF3))
        XCTAssertEqual(light(.tokenOutput), OMRGBA(hex: 0xEE7B3A))
        XCTAssertEqual(light(.tokenCacheRead), OMRGBA(hex: 0x26A8A8))
        XCTAssertEqual(light(.tokenCacheWrite), OMRGBA(hex: 0x9A66EE))
    }

    func testTheWindowBaseIsTheMockupsBackdropColour() {
        XCTAssertEqual(dark(.windowBase), OMRGBA(hex: 0x0D0E13))
        XCTAssertEqual(light(.windowBase), OMRGBA(hex: 0xECE8F1))
    }

    func testSecondaryTextKeepsFourAndAHalfToOneOnTheWindowAndOnACard() {
        for scheme in [ColorScheme.dark, .light] {
            let base = OMPalette.rgba(.windowBase, scheme: scheme)
            let card = OMPalette.rgba(.contentFill, scheme: scheme).composited(over: base)
            let secondary = OMPalette.rgba(.secondary, scheme: scheme)
            XCTAssertGreaterThanOrEqual(
                OMRGBA.contrastRatio(secondary.composited(over: base), base), 4.5, "\(scheme) window")
            XCTAssertGreaterThanOrEqual(
                OMRGBA.contrastRatio(secondary.composited(over: card), card), 4.5, "\(scheme) card")
        }
    }

    func testTheContrastRatioIsWCAGs() {
        XCTAssertEqual(OMRGBA.contrastRatio(OMRGBA(hex: 0x000000), OMRGBA(hex: 0xFFFFFF)), 21, accuracy: 0.0001)
        XCTAssertEqual(OMRGBA.contrastRatio(OMRGBA(hex: 0xFFFFFF), OMRGBA(hex: 0x000000)), 21, accuracy: 0.0001)
        XCTAssertEqual(OMRGBA.contrastRatio(OMRGBA(hex: 0x777777), OMRGBA(hex: 0x777777)), 1, accuracy: 0.0001)
        // #767676 on white is the textbook 4.54:1 grey.
        XCTAssertEqual(OMRGBA.contrastRatio(OMRGBA(hex: 0x767676), OMRGBA(hex: 0xFFFFFF)), 4.54, accuracy: 0.01)
    }

    func testATranslucentColourCompositesStraightAlphaOverItsBackground() {
        XCTAssertEqual(OMRGBA.white(0.5).composited(over: OMRGBA(hex: 0x000000)), OMRGBA(red: 0.5, green: 0.5, blue: 0.5))
        XCTAssertEqual(OMRGBA.black(0).composited(over: OMRGBA(hex: 0xECE8F1)), OMRGBA(hex: 0xECE8F1))
    }

    @MainActor
    func testATokenTakesItsValueFromTheEnvironmentsColourScheme() {
        var environment = EnvironmentValues()
        environment.colorScheme = .dark
        XCTAssertEqual(OMColor(.text).resolve(in: environment), OMRGBA(hex: 0xF5F5F7).color)
        environment.colorScheme = .light
        XCTAssertEqual(OMColor(.text).resolve(in: environment), OMRGBA(hex: 0x1D1D1F).color)
    }
}
