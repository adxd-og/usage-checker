import XCTest
@testable import Omelette

/// Spec 2026-11-19 keep-awake thermal guard, § Settings: "End when the Mac overheats with the lid
/// closed", default on, beside the battery switch; "Reset keep awake" turns it back on. The
/// app's preferences domain is snapshotted and handed back through `AppDomainRestore`.
final class KeepAwakeThermalGuardSettingsTests: XCTestCase {
    private var savedDomain: [String: Any]?
    private var domainName: String {
        Bundle.main.bundleIdentifier ?? "com.usagetracker.app"
    }

    override func setUp() {
        super.setUp()
        savedDomain = UserDefaults.standard.persistentDomain(forName: domainName)
    }

    override func tearDown() {
        AppDomainRestore.restore(savedDomain, domainName: domainName)
        super.tearDown()
    }

    func testTheSwitchReadsAsTheSpec() {
        XCTAssertEqual(GeneralSettingsCopy.keepAwakeThermalTitle, "End when the Mac overheats with the lid closed")
    }

    @MainActor func testTheGuardStartsOn() {
        let settings = SettingsStore.shared
        settings.resetToDefaults()
        XCTAssertTrue(SettingsStore.Defaults.keepAwakeThermalGuardEnabled)
        XCTAssertTrue(settings.keepAwakeThermalGuardEnabled)
    }

    @MainActor func testTheSwitchIsStoredUnderItsOwnKey() {
        XCTAssertEqual(SettingsStore.keepAwakeThermalGuardKey, "keepAwakeThermalGuardEnabled")
        let settings = SettingsStore.shared
        settings.keepAwakeThermalGuardEnabled = true
        settings.keepAwakeThermalGuardEnabled = false
        XCTAssertEqual(UserDefaults.standard.object(forKey: SettingsStore.keepAwakeThermalGuardKey) as? Bool, false)
    }

    @MainActor func testResetKeepAwakeTurnsTheGuardBackOn() {
        let settings = SettingsStore.shared
        settings.keepAwakeThermalGuardEnabled = false
        settings.resetKeepAwake()
        XCTAssertTrue(settings.keepAwakeThermalGuardEnabled)
    }
}
