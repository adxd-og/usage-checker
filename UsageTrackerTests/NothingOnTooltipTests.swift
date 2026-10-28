import XCTest
@testable import Omelette

/// Spec 2026-10-25 (Claude switch and sign-in) § Design › Package 1, Nothing on: with every
/// switch off and no admin key the menu bar tooltip says so and points to Settings ›
/// Providers; before the first poll it still says "loading…". The words are
/// `NothingOnCopy`'s, which every surface shares.
final class NothingOnTooltipTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_GB")
        return c
    }()
    private let locale = Locale(identifier: "en_GB")
    /// Monday 2026-10-26 13:48 UTC.
    private let now = Date(timeIntervalSince1970: 1_793_022_480)

    /// What a poll with nothing on leaves: no services, fetched just now.
    private var empty: UsageSnapshot {
        UsageSnapshot(services: [], fetchedAt: now, isStale: false, lastError: nil)
    }

    func testWithEveryProviderOffTheTooltipSaysSoAndWhereToTurnOneOn() {
        XCTAssertEqual(
            StatusBarController.tooltipText(
                snapshot: empty, mode: .used, pollsNothing: true, now: now, calendar: calendar, locale: locale
            ),
            "Omelette — all providers are off. Turn one on in Settings › Providers."
        )
    }

    func testBeforeTheFirstPollTheTooltipStillSaysLoading() {
        let unpolled = UsageSnapshot(services: [], fetchedAt: Date(timeIntervalSince1970: 0), isStale: false, lastError: nil)
        XCTAssertEqual(
            StatusBarController.tooltipText(
                snapshot: unpolled, mode: .used, pollsNothing: false, now: now, calendar: calendar, locale: locale
            ),
            "Omelette — loading…"
        )
    }

    func testKeepAwakeStillLeadsTheTooltipWithNothingOn() {
        let armed = KeepAwakeState.armed(deadline: now.addingTimeInterval(4 * 3_600 + 52 * 60), floorEnabled: true)
        XCTAssertEqual(
            StatusBarController.tooltipText(
                snapshot: empty, mode: .used, keepAwake: armed, pollsNothing: true,
                now: now, calendar: calendar, locale: locale
            ),
            "Keep awake until 18:40\n\nOmelette — all providers are off. Turn one on in Settings › Providers."
        )
    }

    func testNothingOnIsAnEmptyPolledSetNotAPollThatHasNotStarted() {
        XCTAssertTrue(AppState.isNothingOn(polledIDs: []))
        XCTAssertFalse(AppState.isNothingOn(polledIDs: nil), "before the first poll it is still loading")
        XCTAssertFalse(AppState.isNothingOn(polledIDs: ["codex"]))
        XCTAssertFalse(AppState.isNothingOn(polledIDs: ["anthropic-admin"]), "an admin key alone is something on")
    }

    func testTheWordsNameTheSettingsTabByItsOwnName() {
        XCTAssertEqual(NothingOnCopy.title, "All providers are off")
        XCTAssertEqual(NothingOnCopy.hint, "Turn one on in Settings › Providers.")
        XCTAssertEqual(NothingOnCopy.tooltip, "Omelette — all providers are off. Turn one on in Settings › Providers.")
        XCTAssertTrue(NothingOnCopy.hint.contains("Settings › \(SettingsTab.providers.rawValue)"))
    }
}
