import SwiftUI
import XCTest
@testable import Omelette

/// Liquid-glass redesign spec § Design → Principles 1 and § Tokens: glass only on
/// chrome and controls, the raised pill a fill on its glass. These are the rules the
/// glass-surface modifiers render by: which surfaces are system glass, how a CSS
/// shadow blur maps to SwiftUI, and where the 1 px edge lights sit.
final class OMGlassRulesTests: XCTestCase {
    func testChromePaneAndTrackAreSystemGlassAndThePillIsAFill() {
        XCTAssertTrue(OMGlassRules.usesSystemGlass(.chrome))
        XCTAssertTrue(OMGlassRules.usesSystemGlass(.pane))
        XCTAssertTrue(OMGlassRules.usesSystemGlass(.controlTrack))
        XCTAssertFalse(OMGlassRules.usesSystemGlass(.raisedPill))
    }

    func testACSSBlurOfFourIsASwiftUIShadowRadiusOfTwo() {
        XCTAssertEqual(OMGlassRules.shadowRadius(cssBlur: 4), 2)
        XCTAssertEqual(OMGlassRules.shadowRadius(cssBlur: 0), 0)
    }

    func testDarkChromeLightsItsTopEdgeAndFaintlyItsBottom() {
        XCTAssertEqual(OMGlassRules.edgeHighlightStops(OMGlass.recipe(.chrome, scheme: .dark)), [
            OMEdgeStop(color: .white(0.16), location: 0),
            OMEdgeStop(color: .white(0), location: 0.5),
            OMEdgeStop(color: .white(0), location: 0.5),
            OMEdgeStop(color: .white(0.03), location: 1),
        ])
    }

    func testLightChromeLightsOnlyItsTopEdge() {
        XCTAssertEqual(OMGlassRules.edgeHighlightStops(OMGlass.recipe(.chrome, scheme: .light)), [
            OMEdgeStop(color: .white(0.95), location: 0),
            OMEdgeStop(color: .white(0), location: 0.5),
        ])
    }

    func testAPaneHasNoEdgeLight() {
        for scheme in [ColorScheme.dark, .light] {
            XCTAssertEqual(OMGlassRules.edgeHighlightStops(OMGlass.recipe(.pane, scheme: scheme)), [], "\(scheme)")
        }
    }

    func testAnEdgeLightFadesInItsOwnColourNotToGrey() {
        let recipe = OMGlassRecipe(fill: .white(0.1), border: nil,
                                   topHighlight: OMRGBA(hex: 0xF2B544, opacity: 0.4),
                                   bottomHighlight: nil, shadow: nil)
        XCTAssertEqual(OMGlassRules.edgeHighlightStops(recipe), [
            OMEdgeStop(color: OMRGBA(hex: 0xF2B544, opacity: 0.4), location: 0),
            OMEdgeStop(color: OMRGBA(hex: 0xF2B544, opacity: 0), location: 0.5),
        ])
    }
}
