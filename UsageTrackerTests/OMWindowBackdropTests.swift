import SwiftUI
import XCTest
@testable import Omelette

/// Liquid-glass redesign spec § Design → Tokens, "window background": `#0d0e13` with
/// the three radial gradients of `Main.dc.html` in dark, the body of
/// `Popover-All-Light.dc.html` in light. Each pool is a CSS
/// `radial-gradient(<rx> <ry> at <x> <y>, <colour>, transparent <stop>)`.
final class OMWindowBackdropTests: XCTestCase {
    func testTheDarkBackdropIsYolkBlueAndCoralPoolsOnNearBlack() {
        XCTAssertEqual(OMPalette.windowBackdrop(scheme: .dark), OMWindowBackdrop(
            base: OMRGBA(hex: 0x0D0E13),
            pools: [
                OMBackdropPool(x: 0.12, y: 0.08, radiusX: 560, radiusY: 420, color: OMRGBA(hex: 0xF2B544, opacity: 0.55), fadeStop: 0.62),
                OMBackdropPool(x: 0.92, y: 0.62, radiusX: 560, radiusY: 520, color: OMRGBA(hex: 0x5C70FF, opacity: 0.5), fadeStop: 0.64),
                OMBackdropPool(x: 0.60, y: 1.00, radiusX: 420, radiusY: 320, color: OMRGBA(hex: 0xFF6E78, opacity: 0.3), fadeStop: 0.62),
            ]
        ))
    }

    func testTheLightBackdropIsApricotPeriwinkleAndPinkPoolsOnLilacGrey() {
        XCTAssertEqual(OMPalette.windowBackdrop(scheme: .light), OMWindowBackdrop(
            base: OMRGBA(hex: 0xECE8F1),
            pools: [
                OMBackdropPool(x: 0.10, y: 0.06, radiusX: 560, radiusY: 420, color: OMRGBA(hex: 0xFFC478, opacity: 0.75), fadeStop: 0.62),
                OMBackdropPool(x: 0.94, y: 0.60, radiusX: 560, radiusY: 520, color: OMRGBA(hex: 0x8CAAFF, opacity: 0.7), fadeStop: 0.64),
                OMBackdropPool(x: 0.55, y: 1.00, radiusX: 420, radiusY: 320, color: OMRGBA(hex: 0xFFA0B4, opacity: 0.5), fadeStop: 0.62),
            ]
        ))
    }

    func testTheBaseIsTheWindowBaseToken() {
        for scheme in [ColorScheme.dark, .light] {
            XCTAssertEqual(OMPalette.windowBackdrop(scheme: scheme).base, OMPalette.rgba(.windowBase, scheme: scheme), "\(scheme)")
        }
    }

    /// CSS draws its first background layer on top. A painter draws later over earlier,
    /// so the pools are painted in reverse declaration order: the yolk pool lands on top.
    func testTheFirstCSSLayerIsPaintedLastSoItLandsOnTop() {
        for scheme in [ColorScheme.dark, .light] {
            let backdrop = OMPalette.windowBackdrop(scheme: scheme)
            XCTAssertEqual(backdrop.paintOrder, Array(backdrop.pools.reversed()), "\(scheme)")
            XCTAssertEqual(backdrop.paintOrder.last, backdrop.pools.first, "\(scheme)")
        }
        XCTAssertEqual(
            OMPalette.windowBackdrop(scheme: .dark).paintOrder.last?.color,
            OMRGBA(hex: 0xF2B544, opacity: 0.55)
        )
    }

    func testEveryPoolFadesToTransparentInsideItsEllipse() {
        for scheme in [ColorScheme.dark, .light] {
            for pool in OMPalette.windowBackdrop(scheme: scheme).pools {
                XCTAssertGreaterThan(pool.fadeStop, 0, "\(scheme)")
                XCTAssertLessThan(pool.fadeStop, 1, "\(scheme)")
            }
        }
    }
}
