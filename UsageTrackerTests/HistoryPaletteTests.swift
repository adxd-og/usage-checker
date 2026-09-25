import SwiftUI
import XCTest
@testable import Omelette

/// Liquid-glass spec § Design → Tokens, for the History screens: the colours
/// `Dashboard-History-*` and `Dashboard-Quota-History` draw that no other screen has.
final class HistoryPaletteTests: XCTestCase {
    private func dark(_ token: OMColorToken) -> OMRGBA { OMPalette.rgba(token, scheme: .dark) }
    private func light(_ token: OMColorToken) -> OMRGBA { OMPalette.rgba(token, scheme: .light) }

    func testTheQuotaChartsSixthLineIsCoral() {
        XCTAssertEqual(dark(.seriesQuota), OMRGBA(hex: 0xFF7A7A))
        XCTAssertEqual(light(.seriesQuota), OMRGBA(hex: 0xE85555))
    }

    func testAnEmptyCalendarSquareIsAFaintWash() {
        XCTAssertEqual(dark(.calendarEmpty), .white(0.06))
        XCTAssertEqual(light(.calendarEmpty), .black(0.06))
    }

    func testTheChartTooltipIsAnOpaqueBubbleWithAHairlineEdge() {
        XCTAssertEqual(dark(.tooltipFill), OMRGBA(hex: 0x2A2B31))
        XCTAssertEqual(light(.tooltipFill), OMRGBA(hex: 0xFFFFFF))
        XCTAssertEqual(dark(.tooltipBorder), .white(0.12))
        XCTAssertEqual(light(.tooltipBorder), .black(0.10))
    }

    func testAnOpenChatSitsOnAnInsetWash() {
        XCTAssertEqual(dark(.insetFill), .white(0.035))
        XCTAssertEqual(light(.insetFill), .black(0.025))
    }

    func testTheTooltipsCaptionsKeepTheirContrastOnTheBubble() {
        for scheme in [ColorScheme.dark, .light] {
            let bubble = OMPalette.rgba(.tooltipFill, scheme: scheme)
            let caption = OMPalette.rgba(.secondary, scheme: scheme).composited(over: bubble)
            XCTAssertGreaterThanOrEqual(OMRGBA.contrastRatio(caption, bubble), 4.5, "\(scheme)")
        }
    }

    /// Session ruling S2: History draws token types on the spec's token colours; the
    /// 2.x `TokenCategory.color` stays for the surfaces that still use it.
    func testEachTokenTypeHasItsThreePointOColourRole() {
        XCTAssertEqual(TokenCategory.allCases.map(\.token), [.tokenInput, .tokenOutput, .tokenCacheRead, .tokenCacheWrite])
        XCTAssertEqual(dark(TokenCategory.input.token), OMRGBA(hex: 0x7AA2FF))
        XCTAssertEqual(light(TokenCategory.cacheRead.token), OMRGBA(hex: 0x26A8A8))
    }
}
