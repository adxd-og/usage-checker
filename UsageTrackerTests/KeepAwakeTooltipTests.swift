import XCTest
@testable import Omelette

/// Keep-awake spec 2026-10-26, § UI, Menu bar: "The tooltip's first line says 'Keep awake
/// until 18:40'"; nothing else in the tooltip changes.
final class KeepAwakeTooltipTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_GB")
        return c
    }()
    private let locale = Locale(identifier: "en_GB")
    /// Monday 2026-10-26 13:48 UTC.
    private let now = Date(timeIntervalSince1970: 1_793_022_480)
    private var armed: KeepAwakeState {
        .armed(deadline: now.addingTimeInterval(4 * 3_600 + 52 * 60), floorEnabled: true)
    }

    private func claude() -> UsageSnapshot {
        let service = Fixture.snapshot(
            id: "claude", displayName: "Claude", plan: "Max 20x",
            buckets: [Fixture.bucket(id: "five_hour", label: "Current session", percent: 42, kind: .session)],
            at: now
        )
        return UsageSnapshot(services: [service], fetchedAt: now, isStale: false, lastError: nil)
    }

    func testTheTooltipOpensWithTheKeepAwakeLine() {
        let text = StatusBarController.tooltipText(
            snapshot: claude(), mode: .used, keepAwake: armed,
            now: now, calendar: calendar, locale: locale
        )
        XCTAssertEqual(text, """
        Keep awake until 18:40

        Max 20x
          Current session: 42%

        Updated just now
        """)
    }

    func testNothingArmedLeavesTheTooltipAsItWas() {
        let before = StatusBarController.tooltipText(snapshot: claude(), mode: .used, now: now, calendar: calendar, locale: locale)
        for state in [KeepAwakeState.idle, .ended(at: now, reason: .deadline), .armed(deadline: now, floorEnabled: true)] {
            XCTAssertEqual(
                StatusBarController.tooltipText(snapshot: claude(), mode: .used, keepAwake: state, now: now, calendar: calendar, locale: locale),
                before,
                "\(state)"
            )
        }
    }

    func testWhileLoadingTheTooltipStillSaysKeepAwake() {
        let empty = UsageSnapshot(services: [], fetchedAt: Date(timeIntervalSince1970: 0), isStale: false, lastError: nil)
        XCTAssertEqual(
            StatusBarController.tooltipText(snapshot: empty, mode: .used, keepAwake: armed, now: now, calendar: calendar, locale: locale),
            "Keep awake until 18:40\n\nOmelette — loading…"
        )
    }
}
