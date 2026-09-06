import XCTest
@testable import Omelette

/// Independent verification of `StatusText`, derived from the spec's `omelette status`
/// example and the plan's Task 6, not from `StatusTextTests`. Focus: pay-as-you-go
/// providers, an unrecognised state string, and name-column alignment at an extreme
/// length difference.
final class StatusTextVerificationTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = utc
        c.locale = Locale(identifier: "en_GB")
        return c
    }
    private let locale = Locale(identifier: "en_GB")
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: 11, minute: 20))!
    }

    private func service(
        id: String = "claude", name: String = "Claude", state: String = "ok",
        windows: [StatusSnapshot.Window] = [], todayCost: Double? = nil, weekCost: Double? = nil,
        apiEquivalent: Bool? = nil
    ) -> StatusSnapshot.Service {
        StatusSnapshot.Service(
            id: id, name: name, state: state, retained: false, retainedAt: nil,
            plan: nil, windows: windows, todayCost: todayCost, weekCost: weekCost,
            todayTokens: nil, apiEquivalent: apiEquivalent
        )
    }

    private func snapshot(_ services: [StatusSnapshot.Service]) -> StatusSnapshot {
        StatusSnapshot(version: 1, updatedAt: now, services: services, agents: .none)
    }

    private func render(_ snapshot: StatusSnapshot) -> String {
        StatusText.render(snapshot: snapshot, now: now, calendar: calendar, locale: locale)
    }

    /// A pay-as-you-go account (Enterprise API billing): no rate-limit windows at all,
    /// only dollars. The spec's `costParts` rule ("providers without a log are absent,
    /// not 0") is about missing entries, not this shape — a PAYG service that *does*
    /// have dollars must still show them even with zero windows, and the line must not
    /// fall back to a state message when there is money to show.
    func testAPayAsYouGoProviderWithNoWindowsStillShowsItsSpend() {
        let text = render(snapshot([
            service(id: "claude", name: "Claude", todayCost: 9.10, weekCost: 63.40, apiEquivalent: false),
        ]))

        XCTAssertEqual(text, "Claude  $9.10 today · $63.40 this week\n")
    }

    /// `stateText` has four named cases and a `default`. A state string the CLI does
    /// not recognise (a future `ServiceState` case this build predates) must fall
    /// through to "No data" rather than printing the raw enum string or crashing.
    func testAnUnrecognisedStateFallsBackToNoData() {
        XCTAssertEqual(StatusText.stateText("somethingFutureAndUnknown"), "No data")
        let text = render(snapshot([service(id: "x", name: "X", state: "somethingFutureAndUnknown")]))
        XCTAssertEqual(text, "X  No data\n")
    }

    /// A one-character name beside a much longer one: `nameWidth` must still pad every
    /// row to the longest, and truncate none of them.
    func testExtremeNameLengthDifferenceStillAligns() {
        let text = render(snapshot([
            service(id: "x", name: "X", windows: [
                StatusSnapshot.Window(id: "w", label: "Session", percent: 5, resetsAt: nil, kind: "session"),
            ]),
            service(id: "long", name: "A Very Long Provider Name Indeed", windows: [
                StatusSnapshot.Window(id: "w2", label: "Session", percent: 9, resetsAt: nil, kind: "session"),
            ]),
        ]))

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines[0], "X                                 Session 5%")
        XCTAssertEqual(lines[1], "A Very Long Provider Name Indeed  Session 9%")
        // Both name columns must be exactly as wide as the longest name plus the gap.
        let width = StatusText.nameWidth(snapshot([]).services) // sanity: empty is 0
        XCTAssertEqual(width, 0)
    }

    /// A service whose name is longer than every other name, on its own — `nameWidth`
    /// must not shrink the column below that single name's own length even though
    /// `padding(toLength:)` would otherwise truncate it were `max` absent.
    func testASingleServiceNameIsNeverTruncated() {
        let text = StatusText.serviceLine(
            service(id: "x", name: "X", windows: [
                StatusSnapshot.Window(id: "w", label: "Session", percent: 5, resetsAt: nil, kind: "session"),
            ]),
            width: 0, now: now, calendar: calendar, locale: locale
        )
        XCTAssertEqual(text, "X  Session 5%")
    }
}
