import XCTest
@testable import Omelette

/// Liquid-glass spec § Removals and § Packages P2: the dashboard sidebar's footnote is
/// "Updated 7s ago" with a status dot, in the popover header's words. The stale dot is
/// the popover's orange (session ruling R3).
final class UpdatedCopyTests: XCTestCase {
    private let fetched = Date(timeIntervalSince1970: 1_790_000_000)

    private func snapshot(isStale: Bool) -> UsageSnapshot {
        UsageSnapshot(services: [Fixture.snapshot(id: "claude", at: fetched)],
                      fetchedAt: fetched, isStale: isStale, lastError: nil)
    }

    func testAReadingUnderFiveSecondsOldIsJustUpdated() {
        XCTAssertEqual(UpdatedCopy.text(fetchedAt: fetched, now: fetched.addingTimeInterval(4.9)), "Just updated")
    }

    func testTheAgeReadsInSecondsThenMinutesThenHours() {
        XCTAssertEqual(UpdatedCopy.text(fetchedAt: fetched, now: fetched.addingTimeInterval(7)), "Updated 7s ago")
        XCTAssertEqual(UpdatedCopy.text(fetchedAt: fetched, now: fetched.addingTimeInterval(59)), "Updated 59s ago")
        XCTAssertEqual(UpdatedCopy.text(fetchedAt: fetched, now: fetched.addingTimeInterval(60)), "Updated 1m ago")
        XCTAssertEqual(UpdatedCopy.text(fetchedAt: fetched, now: fetched.addingTimeInterval(3599)), "Updated 59m ago")
        XCTAssertEqual(UpdatedCopy.text(fetchedAt: fetched, now: fetched.addingTimeInterval(3600)), "Updated 1h ago")
        XCTAssertEqual(UpdatedCopy.text(fetchedAt: fetched, now: fetched.addingTimeInterval(26 * 3600)), "Updated 26h ago")
    }

    func testAClockThatRunsBehindTheReadingSaysJustUpdated() {
        XCTAssertEqual(UpdatedCopy.text(fetchedAt: fetched, now: fetched.addingTimeInterval(-30)), "Just updated")
    }

    func testNothingReadYetIsNeverUpdated() {
        XCTAssertEqual(UpdatedCopy.text(fetchedAt: UsageSnapshot.empty.fetchedAt, now: fetched), "Never updated")
        XCTAssertEqual(UpdatedCopy.text(fetchedAt: .distantPast, now: fetched), "Never updated")
    }

    func testWhileAnyProviderAnswersTheDotIsTheOkGreen() {
        let status = UpdatedCopy.status(of: snapshot(isStale: false))
        XCTAssertEqual(status, .live)
        XCTAssertEqual(UpdatedCopy.dot(for: status), .token(.ok))
    }

    func testWhenEveryProviderFailedTheDotIsThePopoversStaleOrange() {
        let status = UpdatedCopy.status(of: snapshot(isStale: true))
        XCTAssertEqual(status, .stale)
        XCTAssertEqual(UpdatedCopy.dot(for: status), .systemOrange)
    }

    func testBeforeTheFirstReadingTheDotIsSecondary() {
        let status = UpdatedCopy.status(of: .empty)
        XCTAssertEqual(status, .never)
        XCTAssertEqual(UpdatedCopy.dot(for: status), .token(.secondary))
    }

    func testTheLiveDotIsTheMockupsGreenInBothThemes() {
        guard case .token(let token) = UpdatedCopy.dot(for: .live) else {
            return XCTFail("the live dot is a 3.0 colour role")
        }
        XCTAssertEqual(OMPalette.rgba(token, scheme: .dark), OMRGBA(hex: 0x6FD99A))
        XCTAssertEqual(OMPalette.rgba(token, scheme: .light), OMRGBA(hex: 0x2FB36A))
    }

    func testVoiceOverHearsWhatTheStaleDotShows() {
        XCTAssertEqual(UpdatedCopy.accessibilityLabel(text: "Updated 12m ago", status: .stale),
                       "Updated 12m ago, can't refresh")
        XCTAssertEqual(UpdatedCopy.accessibilityLabel(text: "Updated 7s ago", status: .live), "Updated 7s ago")
        XCTAssertEqual(UpdatedCopy.accessibilityLabel(text: "Never updated", status: .never), "Never updated")
    }
}

/// `Dashboard-Overview(-Light).dc.html`: a 7 pt dot, 8 pt from an 11.5 pt line, 12 pt in
/// from the sidebar's content edge.
final class UpdatedFootnoteRulesTests: XCTestCase {
    func testTheFootnoteMetricsAreTheMockups() {
        XCTAssertEqual(UpdatedFootnoteRules.dotSize, 7)
        XCTAssertEqual(UpdatedFootnoteRules.spacing, 8)
        XCTAssertEqual(UpdatedFootnoteRules.fontSize, 11.5)
        XCTAssertEqual(UpdatedFootnoteRules.horizontalPadding, 12)
    }
}
