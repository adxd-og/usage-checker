import SwiftUI
import XCTest
@testable import Omelette

/// Independent verification of the token and quota-chart colours against liquid-glass
/// spec § Design → Tokens ("tokens" row) and § Components "Dashboard-Quota-History",
/// and of session ruling S2 (`TokenCategory.color` — the 2.x system-colour set —
/// stays untouched; only the additive `.token` carries the 3.0 palette).
final class HistoryPaletteVerificationTests: XCTestCase {
    private func dark(_ token: OMColorToken) -> OMRGBA { OMPalette.rgba(token, scheme: .dark) }
    private func light(_ token: OMColorToken) -> OMRGBA { OMPalette.rgba(token, scheme: .light) }

    // MARK: - The four token colours, every category, both schemes

    func testEveryTokenCategoryMatchesTheSpecsHexValuesInBothSchemes() {
        let expectations: [(TokenCategory, dark: UInt32, light: UInt32)] = [
            (.input, 0x7AA2FF, 0x4C7EF3),
            (.output, 0xF59E6B, 0xEE7B3A),
            (.cacheRead, 0x5CC8C8, 0x26A8A8),
            (.cacheWrite, 0xC79BFF, 0x9A66EE),
        ]
        for (category, darkHex, lightHex) in expectations {
            XCTAssertEqual(dark(category.token), OMRGBA(hex: darkHex), "\(category) dark")
            XCTAssertEqual(light(category.token), OMRGBA(hex: lightHex), "\(category) light")
        }
    }

    // MARK: - S2: `.color` (the 2.x system palette) is untouched

    func testTokenCategoryColorStaysTheTwoPointXSystemPalette() {
        XCTAssertEqual(TokenCategory.input.color, Color.accentColor)
        XCTAssertEqual(TokenCategory.output.color, Color.orange)
        XCTAssertEqual(TokenCategory.cacheRead.color, Color.teal)
        XCTAssertEqual(TokenCategory.cacheWrite.color, Color.purple)
    }

    // MARK: - Quota chart's six lines, in the provider's window order

    func testQuotaChartLinesFollowTheMockupsOrderAndColours() {
        let expected: [(dark: UInt32, light: UInt32)] = [
            (0x5CC8C8, 0x26A8A8), // tokenCacheRead
            (0x6FD99A, 0x2FB36A), // seriesSession
            (0xFF7A7A, 0xE85555), // seriesQuota
            (0x7AA2FF, 0x4C7EF3), // seriesAllModels
            (0xC79BFF, 0x9A66EE), // seriesPerModel
            (0xF59E6B, 0xEE7B3A), // tokenOutput
        ]
        XCTAssertEqual(HistoryRules.quotaSeriesTokens.count, expected.count)
        for (index, token) in HistoryRules.quotaSeriesTokens.enumerated() {
            XCTAssertEqual(dark(token), OMRGBA(hex: expected[index].dark), "index \(index) dark")
            XCTAssertEqual(light(token), OMRGBA(hex: expected[index].light), "index \(index) light")
        }
    }

    func testTheSixthQuotaLineIsTheColourNoOtherRoleUses() {
        // Coral (`seriesQuota`) exists only for the quota chart's line the token/series
        // roles don't already cover (spec: "the quota chart's one line colour no other
        // series has").
        XCTAssertNotEqual(dark(.seriesQuota), dark(.seriesSession))
        XCTAssertNotEqual(dark(.seriesQuota), dark(.seriesAllModels))
        XCTAssertNotEqual(dark(.seriesQuota), dark(.seriesPerModel))
        XCTAssertNotEqual(dark(.seriesQuota), dark(.tokenCacheRead))
        XCTAssertNotEqual(dark(.seriesQuota), dark(.tokenOutput))
    }
}
