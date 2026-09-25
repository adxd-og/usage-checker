import XCTest
@testable import Omelette

/// "Reset all settings" also forgets the recorded popover shortcut, and it does so through
/// `SettingsStore.resetShortcuts`, so a test can reset the settings without reaching the
/// user's real shortcut, which KeyboardShortcuts keeps in the app's own defaults domain.
///
/// `resetToDefaults()` writes the host app's real preferences, so the domain is captured
/// before the test and put back afterwards, as `SettingsStoreTests` does.
final class SettingsStoreShortcutResetTests: XCTestCase {
    private var savedDomain: [String: Any]?
    private var domainName: String { Bundle.main.bundleIdentifier ?? "com.usagetracker.app" }

    override func setUp() {
        super.setUp()
        savedDomain = UserDefaults.standard.persistentDomain(forName: domainName)
    }

    override func tearDown() {
        MainActor.assumeIsolated { SettingsStore.shared.resetShortcuts = SettingsStore.resetRecordedShortcuts }
        AppDomainRestore.restore(savedDomain, domainName: domainName)
        super.tearDown()
    }

    @MainActor
    func testResettingSettingsResetsTheShortcutExactlyOnceThroughItsHook() {
        let settings = SettingsStore.shared
        var calls = 0
        settings.resetShortcuts = { calls += 1 }

        settings.resetToDefaults()

        XCTAssertEqual(calls, 1)
    }
}
