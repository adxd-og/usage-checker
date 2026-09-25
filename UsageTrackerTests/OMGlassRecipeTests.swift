import SwiftUI
import XCTest
@testable import Omelette

/// Liquid-glass redesign spec § Design → Tokens: chrome glass, pane glass and the
/// raised pill, plus the segmented-control track the spec lists under chrome glass.
/// Values are the mockups' (`Main`, `Popover-All-Light`, `Dashboard-Overview(-Light)`).
final class OMGlassRecipeTests: XCTestCase {
    func testDarkChromeIsSmokedGlassWithATopLightAndAFaintBottomLight() {
        XCTAssertEqual(OMGlass.recipe(.chrome, scheme: .dark), OMGlassRecipe(
            fill: OMRGBA(hex: 0x1A1A1F, opacity: 0.6), border: .white(0.11),
            topHighlight: .white(0.16), bottomHighlight: .white(0.03), shadow: nil))
    }

    func testLightChromeIsMilkGlassAt56PercentAsBothLightMockupsDrawIt() {
        // The spec's table says white @ 72 %; Popover-All-Light's body and
        // Dashboard-Overview-Light's sidebar both draw rgba(255,255,255,0.56), and the
        // spec takes its values from the mockups (plan decision 4).
        XCTAssertEqual(OMGlass.recipe(.chrome, scheme: .light), OMGlassRecipe(
            fill: .white(0.56), border: .white(0.75),
            topHighlight: .white(0.95), bottomHighlight: nil, shadow: nil))
    }

    func testPaneGlassIsTheContentFillOverGlassInBothAppearances() {
        for scheme in [ColorScheme.dark, .light] {
            XCTAssertEqual(OMGlass.recipe(.pane, scheme: scheme), OMGlassRecipe(
                fill: OMPalette.rgba(.contentFill, scheme: scheme),
                border: OMPalette.rgba(.contentBorder, scheme: scheme),
                topHighlight: nil, bottomHighlight: nil, shadow: nil), "\(scheme)")
        }
    }

    func testTheControlTrackIsAFaintCapsuleWithAHairlineEdge() {
        XCTAssertEqual(OMGlass.recipe(.controlTrack, scheme: .dark), OMGlassRecipe(
            fill: .white(0.07), border: .white(0.08),
            topHighlight: .white(0.08), bottomHighlight: nil, shadow: nil))
        XCTAssertEqual(OMGlass.recipe(.controlTrack, scheme: .light), OMGlassRecipe(
            fill: .black(0.05), border: .white(0.6),
            topHighlight: .white(0.6), bottomHighlight: nil, shadow: nil))
    }

    func testTheRaisedPillIsABrightFillWithATopLightAndASoftShadow() {
        XCTAssertEqual(OMGlass.recipe(.raisedPill, scheme: .dark), OMGlassRecipe(
            fill: .white(0.17), border: nil, topHighlight: .white(0.28), bottomHighlight: nil,
            shadow: OMShadow(color: .black(0.35), y: 1, blur: 4)))
        XCTAssertEqual(OMGlass.recipe(.raisedPill, scheme: .light), OMGlassRecipe(
            fill: .white(0.95), border: nil, topHighlight: .white(1), bottomHighlight: nil,
            shadow: OMShadow(color: OMRGBA(hex: 0x281E50, opacity: 0.16), y: 1, blur: 4)))
    }
}
