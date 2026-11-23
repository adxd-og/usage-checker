import XCTest
@testable import Omelette

/// Spec 2026-11-19 keep-awake thermal guard, § Settings: "End when the Mac overheats with the lid
/// closed", default off (amended 2026-11-22), beside the battery switch; "Reset keep awake" turns
/// it back off. The app's preferences domain is snapshotted and handed back through
/// `AppDomainRestore`.
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

    @MainActor func testTheGuardStartsOff() {
        let settings = SettingsStore.shared
        settings.resetToDefaults()
        XCTAssertFalse(SettingsStore.Defaults.keepAwakeThermalGuardEnabled)
        XCTAssertFalse(settings.keepAwakeThermalGuardEnabled)
    }

    @MainActor func testTheSwitchIsStoredUnderItsOwnKey() {
        XCTAssertEqual(SettingsStore.keepAwakeThermalGuardKey, "keepAwakeThermalGuardEnabled")
        let settings = SettingsStore.shared
        settings.keepAwakeThermalGuardEnabled = true
        settings.keepAwakeThermalGuardEnabled = false
        XCTAssertEqual(UserDefaults.standard.object(forKey: SettingsStore.keepAwakeThermalGuardKey) as? Bool, false)
    }

    @MainActor func testResetKeepAwakeTurnsTheGuardBackOff() {
        let settings = SettingsStore.shared
        settings.keepAwakeThermalGuardEnabled = true
        settings.resetKeepAwake()
        XCTAssertFalse(settings.keepAwakeThermalGuardEnabled)
    }
}
