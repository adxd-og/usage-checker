import XCTest
@testable import Omelette

/// Spec 2026-10-25 (Claude switch and sign-in) § Design › Package 1, Nothing on: the
/// popover's body with no tiles to draw. With every provider off it says so and links to
/// Settings › Providers; before the first poll it is loading.
final class PopoverNothingOnTests: XCTestCase {
    private let codex = Fixture.snapshot(
        id: "codex", displayName: "Codex",
        buckets: [Fixture.bucket(id: "codex_session", label: "Session", percent: 30, kind: .session)],
        at: Date(timeIntervalSince1970: 1_793_100_000)
    )

    func testWithEveryProviderOffTheBodySaysSo() {
        XCTAssertEqual(PopoverView.emptyBody(pollsNothing: true, services: []), .nothingOn)
    }

    func testNothingOnWinsWhileThePollThatSwitchedTheLastOneOffLands() {
        XCTAssertEqual(PopoverView.emptyBody(pollsNothing: true, services: [codex]), .nothingOn)
    }

    func testBeforeTheFirstPollTheBodyIsLoading() {
        XCTAssertEqual(PopoverView.emptyBody(pollsNothing: false, services: []), .loading)
    }

    func testWithSomethingToDrawThereIsNoEmptyBody() {
        XCTAssertNil(PopoverView.emptyBody(pollsNothing: false, services: [codex]))
    }

    func testTheLinkOpensSettingsOnProviders() {
        XCTAssertEqual(NothingOnCopy.button, "Open Settings › Providers")
        XCTAssertEqual(SettingsTab.route(legacyID: SettingsTab.providers.rawValue), .providers)
    }
}
