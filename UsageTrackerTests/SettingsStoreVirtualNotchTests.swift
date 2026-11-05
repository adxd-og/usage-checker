import Combine
import XCTest
@testable import Omelette

/// Spec 2026-11-03 § P4: Island on displays without a notch is on until the user says otherwise
/// (4.1's behaviour, nothing changes for an existing user), stored under its own key, published at
/// once, and forgotten by a reset. Writes the app's real defaults domain, so the domain is
/// snapshotted and handed back through `AppDomainRestore`.
final class SettingsStoreVirtualNotchTests: XCTestCase {
    private var savedDomain: [String: Any]?
    private var domainName: String { Bundle.main.bundleIdentifier ?? "com.usagetracker.app" }

    override func setUp() {
        super.setUp()
        savedDomain = UserDefaults.standard.persistentDomain(forName: domainName)
    }

    override func tearDown() {
        AppDomainRestore.restore(savedDomain, domainName: domainName)
        super.tearDown()
    }

    @MainActor
    func testTheVirtualNotchIsOnByDefault() {
        let settings = SettingsStore.shared
        settings.resetToDefaults()
        XCTAssertTrue(SettingsStore.Defaults.virtualNotchEnabled)
        XCTAssertTrue(settings.virtualNotchEnabled)
        XCTAssertNil(UserDefaults.standard.object(forKey: SettingsStore.virtualNotchEnabledKey))
    }

    @MainActor
    func testTheSwitchIsStoredUnderItsOwnKey() {
        let settings = SettingsStore.shared
        settings.resetToDefaults()
        settings.virtualNotchEnabled = false
        XCTAssertEqual(UserDefaults.standard.object(forKey: SettingsStore.virtualNotchEnabledKey) as? Bool, false)
        XCTAssertNil(UserDefaults.standard.object(forKey: SettingsStore.showInMenuBarKey))
        settings.virtualNotchEnabled = true
        XCTAssertEqual(UserDefaults.standard.object(forKey: SettingsStore.virtualNotchEnabledKey) as? Bool, true)
    }

    @MainActor
    func testAFlipIsPublishedAtOnce() {
        let settings = SettingsStore.shared
        settings.resetToDefaults()
        var sent: [Bool] = []
        let watch = settings.$virtualNotchEnabled.dropFirst().sink { sent.append($0) }
        settings.virtualNotchEnabled = false
        watch.cancel()
        XCTAssertEqual(sent, [false])
    }

    @MainActor
    func testResetTurnsItBackOn() {
        let settings = SettingsStore.shared
        settings.resetToDefaults()
        settings.virtualNotchEnabled = false

        settings.resetToDefaults()

        XCTAssertTrue(settings.virtualNotchEnabled)
        XCTAssertNil(UserDefaults.standard.object(forKey: SettingsStore.virtualNotchEnabledKey))
    }

    /// The key can hold what the store never saw: a domain put back by `AppDomainRestore`, or another
    /// copy of the app sharing it.
    @MainActor
    func testResetForgetsTheSwitchEvenIfTheStoreNeverSawTheValue() {
        let settings = SettingsStore.shared
        settings.resetToDefaults()
        UserDefaults.standard.set(false, forKey: SettingsStore.virtualNotchEnabledKey)

        settings.resetToDefaults()

        XCTAssertTrue(settings.virtualNotchEnabled)
        XCTAssertNil(UserDefaults.standard.object(forKey: SettingsStore.virtualNotchEnabledKey))
    }
}
