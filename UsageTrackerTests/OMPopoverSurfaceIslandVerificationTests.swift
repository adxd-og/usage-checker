import SwiftUI
import XCTest
@testable import Omelette

/// Verification of "Surfaces on the island" (notch-island spec 2026-10-29 § 3.1, owner
/// 2026-10-30), through what the style resolves to rather than how it is spelled: white 2 % fill
/// and 0.5 pt white 8 % edge on the island, in either colour scheme; the group tokens elsewhere.
final class OMPopoverSurfaceIslandVerificationTests: XCTestCase {
    private func environment(_ scheme: ColorScheme) -> EnvironmentValues {
        var env = EnvironmentValues()
        env.colorScheme = scheme
        return env
    }

    private func resolved(_ paint: OMPopoverSurface.Paint, _ scheme: ColorScheme) -> Color.Resolved {
        let env = environment(scheme)
        return paint.resolve(in: env).resolve(in: env)
    }

    func testOnTheIslandTheSurfaceIsWhiteAtFiveAndElevenPercentInBothSchemes() {
        let style = OMPopoverSurface.style(onIsland: true)
        XCTAssertEqual(style.borderWidth, 0.5)
        for scheme in [ColorScheme.light, .dark] {
            let fill = resolved(style.fill, scheme)
            let edge = resolved(style.border, scheme)
            XCTAssertEqual(fill.opacity, 0.02, accuracy: 0.001, "\(scheme) fill")
            XCTAssertEqual(edge.opacity, 0.08, accuracy: 0.001, "\(scheme) edge")
            for channel in [fill.red, fill.green, fill.blue, edge.red, edge.green, edge.blue] {
                XCTAssertEqual(channel, 1, accuracy: 0.001, "\(scheme): white")
            }
        }
    }

    func testOffTheIslandThePanelsGroupFillAndEdgeAreResolvedPerScheme() {
        let style = OMPopoverSurface.style(onIsland: false)
        XCTAssertEqual(style.borderWidth, 1)
        for scheme in [ColorScheme.light, .dark] {
            let env = environment(scheme)
            XCTAssertEqual(
                resolved(style.fill, scheme),
                OMPalette.rgba(OMPopoverSurface.fill, scheme: scheme).color.resolve(in: env),
                "\(scheme) fill is the group fill"
            )
            XCTAssertEqual(
                resolved(style.border, scheme),
                OMPalette.rgba(OMPopoverSurface.border, scheme: scheme).color.resolve(in: env),
                "\(scheme) edge is the group border"
            )
        }
    }

    func testTheIslandSurfaceIsLighterThanNothingAndDiffersFromThePanelsInDarkMode() {
        XCTAssertNotEqual(OMPopoverSurface.style(onIsland: true), OMPopoverSurface.style(onIsland: false))
        XCTAssertLessThan(OMPopoverSurface.style(onIsland: true).borderWidth, OMPopoverSurface.style(onIsland: false).borderWidth)
    }

    func testOnlyTheIslandKindSetsTheFlag() {
        XCTAssertTrue(IslandSurfaceRules.surfacesOnIsland(kind: .island))
        XCTAssertFalse(IslandSurfaceRules.surfacesOnIsland(kind: .panel))
        XCTAssertFalse(EnvironmentValues().popoverSurfaceOnIsland, "the Dashboard and Settings never set it")
    }
}
