import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.3: "one shared bar-label column width per grid", so
/// every tile's bar starts at the same x (owner, 2026-10-29: Grok's "Credits" pushed its
/// bar). The view measures each tile's label in the system font; the rule takes the
/// widest, in whole points, cut back so a tile's bar keeps 56 pt beside its 36 pt figure.
final class ProviderGridBarLabelTests: XCTestCase {
    /// A tile at 640 with the habitat: a 220 pt half less the tile's 12 pt padding twice.
    private let tileAt640: CGFloat = 196

    func testEveryBarStartsAfterTheWidestLabel() {
        // "Week", "Credits", "Opus" at 11.5 pt.
        XCTAssertEqual(ProviderGridRules.barLabelWidth(labelWidths: [30.09, 39.24, 28.76], tileInterior: tileAt640), 40)
    }

    func testALabelTooWideForTheTileIsCutBackSoTheBarKeepsItsRoom() {
        // "Claude/GPT 5-hour" is 105.5: 196 − 36 − 2 × 8 − 56 = 88 at 640.
        XCTAssertEqual(ProviderGridRules.barLabelWidth(labelWidths: [30.09, 105.5], tileInterior: tileAt640), 88)
        // At 560 without the habitat a tile is 261 − 24 = 237 inside: room for 129.
        XCTAssertEqual(ProviderGridRules.barLabelWidth(labelWidths: [105.5], tileInterior: 237), 106)
    }

    func testNoBarsNoColumn() {
        XCTAssertEqual(ProviderGridRules.barLabelWidth(labelWidths: [], tileInterior: tileAt640), 0)
    }

    func testATinyTileNeverGetsANegativeColumn() {
        XCTAssertEqual(ProviderGridRules.barLabelWidth(labelWidths: [30.09], tileInterior: 50), 0)
    }

    func testATileHasABarLabelOnlyWhenItDrawsABar() {
        let session = Fixture.bucket(id: "five_hour", label: "Current session", percent: 57, kind: .session)
        let weekly = Fixture.bucket(id: "seven_day", label: "All models", percent: 41, kind: .weekly)
        XCTAssertEqual(OMProviderTile.barLabel(for: Fixture.snapshot(id: "claude", buckets: [session, weekly])), "Week")
        XCTAssertNil(OMProviderTile.barLabel(for: Fixture.snapshot(id: "claude", buckets: [session])),
                     "nothing under the hero")
        XCTAssertNil(OMProviderTile.barLabel(for: Fixture.snapshot(id: "codex", buckets: [], state: .notSignedIn)))
        let closed = Fixture.snapshot(id: "antigravity", buckets: [session, weekly], state: .notRunning)
        XCTAssertEqual(OMProviderTile.barLabel(for: closed), "Week", "a retained tile keeps its dimmed bar")
    }
}
