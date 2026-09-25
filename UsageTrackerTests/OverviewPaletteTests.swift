import SwiftUI
import XCTest
@testable import Omelette

/// Liquid-glass spec § Tokens ("track") and `Dashboard-Overview(-Light).dc.html`: the CLI
/// card's 30 bars draw the week that "Last 7 days" counts at twice the track's strength,
/// white 20 % in dark and black 16 % in light; older days are the track itself.
final class OverviewPaletteTests: XCTestCase {
    func testTheLastWeeksBarsAreTheTrackAtTwiceItsStrength() {
        XCTAssertEqual(OMPalette.rgba(.barRecent, scheme: .dark), .white(0.20))
        XCTAssertEqual(OMPalette.rgba(.barRecent, scheme: .light), .black(0.16))
        XCTAssertEqual(OMPalette.rgba(.track, scheme: .dark), .white(0.10))
        XCTAssertEqual(OMPalette.rgba(.track, scheme: .light), .black(0.08))
    }
}
