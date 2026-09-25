import Combine
import XCTest
@testable import Omelette

/// The switch itself: where it is stored, that it is off to begin with, that it
/// announces itself so every observing surface repaints, and that Settings' own
/// provider rows follow it. Spec § "Setting" and § "Propagation".
///
/// `SettingsStore` writes to the host app's real preferences domain, so the whole
/// domain is captured before each test and put back afterwards — the same guard
/// `SettingsStoreTests` uses. A test must not leave the user's settings changed.
final class RemainingModeSettingsTests: XCTestCase {
    private var savedDomain: [String: Any]?
    private var domainName: String { Bundle.main.bundleIdentifier ?? "com.usagetracker.app" }
    private var bag: Set<AnyCancellable> = []

    override func setUp() {
        super.setUp()
        savedDomain = UserDefaults.standard.persistentDomain(forName: domainName)
        // Keeps `resetToDefaults()` off the shortcut the user recorded, which lives in
        // this same domain.
        MainActor.assumeIsolated { SettingsStore.shared.resetShortcuts = {} }
    }

    override func tearDown() {
        MainActor.assumeIsolated { SettingsStore.shared.resetShortcuts = SettingsStore.resetRecordedShortcuts }
        bag.removeAll()
        UserDefaults.standard.setPersistentDomain(savedDomain ?? [:], forName: domainName)
        super.tearDown()
    }

    @MainActor
    func testTheSwitchIsOffAndTheAppCountsUpByDefault() {
        let settings = SettingsStore.shared
        settings.resetToDefaults()
        XCTAssertFalse(settings.showsRemaining)
        XCTAssertEqual(settings.percentMode, .used)
    }

    @MainActor
    func testTurningItOnPutsEverySurfaceIntoRemaining() {
        let settings = SettingsStore.shared
        settings.showsRemaining = true
        XCTAssertEqual(settings.percentMode, .remaining)
    }

    @MainActor
    func testTheSwitchSurvivesARelaunchThroughItsOwnDefaultsKey() {
        let settings = SettingsStore.shared
        settings.showsRemaining = true
        // What a fresh process reads at launch.
        XCTAssertTrue(UserDefaults.standard.bool(forKey: SettingsStore.showsRemainingKey))
        settings.showsRemaining = false
        XCTAssertFalse(UserDefaults.standard.bool(forKey: SettingsStore.showsRemainingKey))
    }

    /// The spec asks for an immediate re-render. That only happens if the store
    /// tells its observers, which an `@AppStorage` property inside an
    /// `ObservableObject` never does.
    @MainActor
    func testTurningTheSwitchAnnouncesItselfSoEverySurfaceRedraws() {
        let settings = SettingsStore.shared
        settings.showsRemaining = false
        let announced = expectation(description: "objectWillChange fired")
        settings.objectWillChange
            .sink { _ in announced.fulfill() }
            .store(in: &bag)
        settings.showsRemaining = true
        wait(for: [announced], timeout: 1)
    }

    @MainActor
    func testResettingSettingsPutsTheAppBackToCountingUp() {
        let settings = SettingsStore.shared
        settings.showsRemaining = true
        settings.resetToDefaults()
        XCTAssertFalse(settings.showsRemaining)
    }

    // MARK: - Settings → Account, the provider summary rows

    func testTheProviderSummaryReadsAsItAlwaysDidByDefault() {
        let service = Fixture.snapshot(
            id: "claude",
            buckets: [
                Fixture.bucket(id: "five_hour", label: "Current session", percent: 42, kind: .session),
                Fixture.bucket(id: "seven_day", label: "All models", percent: 18, kind: .weekly),
            ]
        )
        XCTAssertEqual(SettingsView.usageSummary(service, mode: .used), "Session 42% · Week 18%")
    }

    func testTheProviderSummaryCountsDownToo() {
        let service = Fixture.snapshot(
            id: "claude",
            buckets: [
                Fixture.bucket(id: "five_hour", label: "Current session", percent: 42, kind: .session),
                Fixture.bucket(id: "seven_day", label: "All models", percent: 18, kind: .weekly),
            ]
        )
        XCTAssertEqual(SettingsView.usageSummary(service, mode: .remaining), "Session 58% · Week 82%")
    }

    func testTheWorstTwoWindowsAreStillPickedByHowMuchIsUsed() {
        // Ranking is a question about usage. In remaining mode the row still leads
        // with the fullest window, it just prints what is left of it.
        let service = Fixture.snapshot(
            id: "gemini",
            buckets: [
                // .modelSpecific keeps each window's own label: a `.weekly` pair
                // would both print as "Week" and say nothing about the ranking.
                Fixture.bucket(id: "a", label: "Quiet", percent: 5, kind: .modelSpecific),
                Fixture.bucket(id: "b", label: "Busy", percent: 91, kind: .modelSpecific),
            ]
        )
        XCTAssertEqual(SettingsView.usageSummary(service, mode: .remaining), "Busy 9% · Quiet 95%")
    }

    func testAProviderWithNoWindowsStillShowsItsDollarsNotAPercentage() {
        let service = Fixture.snapshot(id: "claude", buckets: [], weekCost: 41.37)
        XCTAssertEqual(SettingsView.usageSummary(service, mode: .remaining), "$41.37 this week")
    }

    func testAProviderWithNothingAtAllIsADash() {
        let service = Fixture.snapshot(id: "codex", buckets: [], state: .notSignedIn)
        XCTAssertEqual(SettingsView.usageSummary(service, mode: .remaining), "—")
    }
}
