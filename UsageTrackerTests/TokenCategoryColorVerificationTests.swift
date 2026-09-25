import SwiftUI
import XCTest
@testable import Omelette

/// Independent verification of `fix/3.0-followups` package contract item 2:
/// `TokensTodayCard`'s colours come from `TokenCategory.token` — the four categories map
/// to `.tokenInput` / `.tokenOutput` / `.tokenCacheRead` / `.tokenCacheWrite` — and
/// `TokensTodayCard.colorToken`, the private mirror of the same switch, is gone.
/// `TokensTodayCardVerificationTests.swift` already pins the four colour roles' hex
/// values (`OMPalette.rgba`); this file pins the mapping the diff actually changed —
/// which `TokenCategory` case reads which role — and that the deleted symbol stays
/// deleted.
final class TokenCategoryColorVerificationTests: XCTestCase {
    private static func repoRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()
        url.deleteLastPathComponent()
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("UsageTracker.xcodeproj").path) else {
            throw XCTSkip("could not locate the repo root from #filePath")
        }
        return url
    }

    func testEveryTokenCategoryMapsToItsOwnThreeDotOhColourRole() {
        XCTAssertEqual(TokenCategory.input.token, .tokenInput)
        XCTAssertEqual(TokenCategory.output.token, .tokenOutput)
        XCTAssertEqual(TokenCategory.cacheRead.token, .tokenCacheRead)
        XCTAssertEqual(TokenCategory.cacheWrite.token, .tokenCacheWrite)
    }

    /// A copy-paste that pointed two categories at the same role would still compile
    /// and would still pass a test that only checks each mapping in isolation.
    func testNoTwoCategoriesShareAColourRole() {
        let roles = TokenCategory.allCases.map(\.token)
        XCTAssertEqual(Set(roles).count, TokenCategory.allCases.count, "\(roles)")
    }

    /// The pre-3.0 `color` property is untouched — it stays the 2.x system set per its
    /// own doc comment — so it must still exist and must still disagree with `token`'s
    /// palette-driven roles (they are different colour systems, not two names for one).
    func testTheTwoDotXColorPropertyIsUntouchedAndSeparateFromToken() {
        XCTAssertEqual(TokenCategory.input.color, .accentColor)
        XCTAssertEqual(TokenCategory.output.color, .orange)
        XCTAssertEqual(TokenCategory.cacheRead.color, .teal)
        XCTAssertEqual(TokenCategory.cacheWrite.color, .purple)
    }

    func testTokensTodayCardNoLongerDeclaresItsOwnColorTokenMirror() throws {
        let url = try Self.repoRoot().appendingPathComponent("UsageTracker/UI/Dashboard/TokensTodayCard.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(
            source.contains("colorToken"),
            "TokensTodayCard.colorToken must be gone; colours must come from TokenCategory.token"
        )
        XCTAssertTrue(
            source.contains(".fill(OMColor(item.category.token))") || source.contains(".fill(OMColor(segment.category.token))"),
            "the legend and bar fills should read `.token` straight off the category"
        )
    }

    /// A tree-wide check, not just the one file the diff touched: nothing else in the
    /// scanned sources should have grown a second `colorToken` symbol either.
    func testNoSourceUnderTheAppOrCLICoreDeclaresAColorTokenSymbol() throws {
        let repo = try Self.repoRoot()
        for relative in ["UsageTracker", "CLICore"] {
            let root = repo.appendingPathComponent(relative)
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
                let contents = try String(contentsOf: fileURL, encoding: .utf8)
                XCTAssertFalse(
                    contents.contains("colorToken"),
                    "\(fileURL.lastPathComponent) still mentions colorToken"
                )
            }
        }
    }
}
