import Combine
import XCTest
@testable import Omelette

/// Verification of notch-island spec 2026-10-29 § 3.7 / D4 and plan ruling R9 at the store:
/// Show in menu bar is stored only once the user picks (false is a choice, nil is not), is
/// published to the status bar controller on every change including a reset, and a reset
/// forgets whatever the key holds. Writes the app's real defaults domain, so the domain is
/// snapshotted and handed back through `AppDomainRestore`.
final class SettingsShowInMenuBarVerificationTests: XCTestCase {
    private var savedDomain: [String: Any]?
    private var domainName: String { Bundle.main.bundleIdentifier ?? "com.usagetracker.app" }
    private var bag = Set<AnyCancellable>()

    override func setUp() {
        super.setUp()
        savedDomain = UserDefaults.standard.persistentDomain(forName: domainName)
    }

    override func tearDown() {
        bag.removeAll()
        AppDomainRestore.restore(savedDomain, domainName: domainName)
        super.tearDown()
    }

    @MainActor
    private var stored: Bool? {
        UserDefaults.standard.object(forKey: SettingsStore.showInMenuBarKey) as? Bool
    }

    @MainActor
    func testAnExplicitNoIsStoredAsNoAndNotMistakenForNoChoice() {
        let settings = SettingsStore.shared
        settings.resetToDefaults()
        settings.showInMenuBar = false
        XCTAssertNotNil(UserDefaults.standard.object(forKey: SettingsStore.showInMenuBarKey))
        XCTAssertEqual(stored, false)
    }

    @MainActor
    func testGoingBackToNoChoiceRemovesTheKey() {
        let settings = SettingsStore.shared
        settings.resetToDefaults()
        settings.showInMenuBar = true
        settings.showInMenuBar = nil
        XCTAssertNil(UserDefaults.standard.object(forKey: SettingsStore.showInMenuBarKey))
    }

    @MainActor
    func testTheStatusBarControllerHearsEveryChangeIncludingTheReset() {
        let settings = SettingsStore.shared
        settings.resetToDefaults()
        var heard: [Bool?] = []
        settings.$showInMenuBar.sink { heard.append($0) }.store(in: &bag)

        settings.showInMenuBar = true
        settings.showInMenuBar = false
        settings.resetToDefaults()

        // The first value is the current one, then each change as it lands.
        XCTAssertEqual(heard.count, 4)
        XCTAssertNil(heard[0])
        XCTAssertEqual(heard[1], .some(true))
        XCTAssertEqual(heard[2], .some(false))
        XCTAssertNil(heard[3], "a reset must tell the status item the choice is gone")
    }

    @MainActor
    func testResetForgetsAnExplicitNoTheStoreNeverSaw() {
        let settings = SettingsStore.shared
        settings.resetToDefaults()
        // Another copy of the app wrote a no behind the store's back.
        UserDefaults.standard.set(false, forKey: SettingsStore.showInMenuBarKey)

        settings.resetToDefaults()

        XCTAssertNil(settings.showInMenuBar)
        XCTAssertNil(UserDefaults.standard.object(forKey: SettingsStore.showInMenuBarKey))
    }

    @MainActor
    func testResetFromAYesPutsTheStoreBackOnItsDefaultOfNoChoice() {
        let settings = SettingsStore.shared
        settings.resetToDefaults()
        settings.showInMenuBar = true
        settings.resetToDefaults()
        XCTAssertEqual(settings.showInMenuBar, SettingsStore.Defaults.showInMenuBar)
        XCTAssertNil(SettingsStore.Defaults.showInMenuBar)
    }
}
