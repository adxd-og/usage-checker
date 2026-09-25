import XCTest
@testable import Omelette

/// Liquid-glass spec § Screens, "Overview" (`Dashboard-Overview.dc.html`): under the
/// provider's name, its plan and how fresh the numbers are, "Max 20x · updated 7s ago", in
/// `UpdatedCopy`'s words. A live provider's age is the poll's, the same source as the
/// sidebar footnote; the two tick on separate 5 s timelines and may lag by one tick.
final class OverviewHeaderCopyTests: XCTestCase {
    private let polled = Date(timeIntervalSince1970: 1_790_000_000)

    private func claude(plan: String? = "Claude Max 20x", state: ServiceState = .ok, fetchedAt: Date? = nil) -> ServiceSnapshot {
        Fixture.snapshot(
            id: "claude", plan: plan,
            buckets: [Fixture.bucket(id: "five_hour", label: "Current session", percent: 53, kind: .session)],
            state: state, at: fetchedAt ?? polled
        )
    }

    func testTheSubtitleIsThePlanAndTheAgeOfThePoll() {
        XCTAssertEqual(OverviewCopy.subtitle(service: claude(), snapshotFetchedAt: polled, now: polled.addingTimeInterval(7)),
                       "Max 20x · updated 7s ago")
    }

    func testAFreshPollIsJustUpdated() {
        XCTAssertEqual(OverviewCopy.subtitle(service: claude(), snapshotFetchedAt: polled, now: polled.addingTimeInterval(2)),
                       "Max 20x · just updated")
    }

    func testWithNoPlanTheAgeStandsAlone() {
        XCTAssertEqual(OverviewCopy.subtitle(service: claude(plan: nil), snapshotFetchedAt: polled,
                                             now: polled.addingTimeInterval(90)),
                       "Updated 1m ago")
        // "Antigravity" under "Antigravity" says nothing.
        let antigravity = Fixture.snapshot(id: "antigravity", plan: "Antigravity", buckets: [], at: polled)
        XCTAssertEqual(OverviewCopy.subtitle(service: antigravity, snapshotFetchedAt: polled,
                                             now: polled.addingTimeInterval(7)),
                       "Updated 7s ago")
    }

    func testLiveNumbersAreAsOldAsThePollNotTheProvidersOwnStamp() {
        let service = claude(fetchedAt: polled.addingTimeInterval(-3))
        XCTAssertEqual(OverviewCopy.subtitle(service: service, snapshotFetchedAt: polled, now: polled.addingTimeInterval(7)),
                       "Max 20x · updated 7s ago")
    }

    func testLastKnownNumbersAreAsOldAsTheirOwnReading() {
        let service = claude(state: .notRunning, fetchedAt: polled.addingTimeInterval(-2 * 3600))
        XCTAssertEqual(OverviewCopy.subtitle(service: service, snapshotFetchedAt: polled, now: polled.addingTimeInterval(7)),
                       "Max 20x · updated 2h ago")
    }

    func testAProviderMissingFromTheSnapshotHasNoSubtitle() {
        XCTAssertNil(OverviewCopy.subtitle(service: nil, snapshotFetchedAt: polled, now: polled))
    }
}
