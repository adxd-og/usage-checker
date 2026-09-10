import XCTest
@testable import Omelette

/// The All-tab tile leads with the same window the provider tab does: the 5-hour
/// session, when the service has one. A tile that led with the weekly answered a
/// question nobody asked mid-week ("how is the week going?") while the number people
/// actually check — can I keep working right now — sat in the thin bar underneath.
final class OMProviderTileTests: XCTestCase {
    private let session = Fixture.bucket(id: "five_hour", label: "Current session", percent: 37, kind: .session)
    private let weekly  = Fixture.bucket(id: "seven_day", label: "All models", percent: 82, kind: .weekly)
    private let opus    = Fixture.bucket(id: "seven_day_opus", label: "Opus only", percent: 95, kind: .modelSpecific)

    private func claude(_ buckets: [UsageBucket], extra: ExtraUsage? = nil) -> ServiceSnapshot {
        Fixture.snapshot(id: "claude", displayName: "Claude", buckets: buckets, extraUsage: extra)
    }

    // MARK: - The ring

    func testTheTileLeadsWithTheSessionEvenWhenTheWeeklyIsHotter() {
        let service = claude([session, weekly, opus])
        XCTAssertEqual(WindowRanking.tileHero(for: service)?.id, "five_hour")
        // The old rule, kept for the surfaces that still rank by constraint.
        XCTAssertEqual(WindowRanking.heroBucket(for: service)?.id, "seven_day")
    }

    /// One rule for both, so the tile and the tab a tap later can never disagree
    /// about which window is the big ring.
    func testTheTileAndTheProviderTabAgreeOnTheHero() {
        for buckets in [[session, weekly, opus], [weekly, opus], [session], []] {
            let service = claude(buckets)
            XCTAssertEqual(
                WindowRanking.tileHero(for: service)?.id,
                WindowRanking.detailHero(for: service)?.id
            )
        }
    }

    func testWithoutASessionTheTileKeepsTheMostConstrainedWindow() {
        let service = claude([weekly, opus])
        XCTAssertEqual(WindowRanking.tileHero(for: service)?.id, "seven_day")
        XCTAssertEqual(WindowRanking.tileHero(for: service)?.id, WindowRanking.heroBucket(for: service)?.id)
    }

    func testATileWithNoWindowsHasNoRing() {
        XCTAssertNil(WindowRanking.tileHero(for: claude([])))
    }

    /// A spend-limit account has no session window at all, so the synthetic
    /// extra-usage bucket still leads — and still carries the id the caption keys on.
    func testASpendLimitAccountStillLeadsWithItsSpendLimit() {
        let extra = ExtraUsage(isEnabled: true, monthlyLimit: 1500, usedCredits: 431.26, utilization: 28.75)
        let service = claude([], extra: extra)
        XCTAssertEqual(WindowRanking.tileHero(for: service)?.id, "claude_extra_usage")
    }

    // MARK: - The bar under the ring

    /// The whole point of moving the ring: the weekly has to stay on screen. It was
    /// the hero before, so the bar under it used to be the session — which would now
    /// draw the session twice.
    func testTheWeeklyIsTheSecondaryLineWhenTheSessionLeads() {
        let service = claude([session, weekly, opus])
        XCTAssertEqual(WindowRanking.tileHero(for: service)?.id, "five_hour")
        XCTAssertEqual(WindowRanking.secondaryBucket(for: service)?.id, "seven_day")
    }

    func testTheRingAndTheBarAreNeverTheSameWindow() {
        for buckets in [[session, weekly, opus], [weekly, opus], [session, weekly]] {
            let service = claude(buckets)
            let hero = WindowRanking.tileHero(for: service)
            XCTAssertNotEqual(hero?.id, WindowRanking.secondaryBucket(for: service)?.id, "\(buckets.map(\.id))")
        }
    }

    func testAServiceWithOneWindowHasNoSecondLine() {
        XCTAssertNil(WindowRanking.secondaryBucket(for: claude([session])))
    }

    // MARK: - What VoiceOver reads

    func testVoiceOverReadsTheWindowTheRingIsShowing() {
        let service = claude([session, weekly, opus])
        XCTAssertEqual(
            OMProviderTile.accessibilityText(for: service, hero: WindowRanking.tileHero(for: service)),
            "Claude, Current session 37 percent used"
        )
    }
}
