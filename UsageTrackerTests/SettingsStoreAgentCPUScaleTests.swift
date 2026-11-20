import Combine
import XCTest
@testable import Omelette

/// Spec 2026-11-19 agent resources, Decision 2: the CPU scale is per core until the user picks
/// Whole Mac, stored under its own key, published at once so the island and the Agents tab
/// repaint, and forgotten by a reset. Writes the app's real defaults domain, so the domain is
/// snapshotted and handed back through `AppDomainRestore`.
final class SettingsStoreAgentCPUScaleTests: XCTestCase {
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
    func testPerCoreIsTheDefault() {
        let settings = SettingsStore.shared
        settings.resetToDefaults()
        XCTAssertEqual(settings.agentsCPUScale, .perCore)
        XCTAssertNil(UserDefaults.standard.object(forKey: SettingsStore.agentsCPUScaleKey))
    }

    @MainActor
    func testTheChoiceIsStoredUnderItsOwnKey() {
        let settings = SettingsStore.shared
        settings.resetToDefaults()
        settings.agentsCPUScale = .wholeMac
        XCTAssertEqual(UserDefaults.standard.string(forKey: SettingsStore.agentsCPUScaleKey), "wholeMac")
        settings.agentsCPUScale = .perCore
        XCTAssertEqual(UserDefaults.standard.string(forKey: SettingsStore.agentsCPUScaleKey), "perCore")
    }

    @MainActor
    func testAFlipIsPublishedAtOnce() {
        let settings = SettingsStore.shared
        settings.resetToDefaults()
        var sent: [AgentCPUScale] = []
        let watch = settings.$agentsCPUScale.dropFirst().sink { sent.append($0) }
        settings.agentsCPUScale = .wholeMac
        watch.cancel()
        XCTAssertEqual(sent, [.wholeMac])
    }

    @MainActor
    func testResetForgetsTheChoice() {
        let settings = SettingsStore.shared
        settings.resetToDefaults()
        settings.agentsCPUScale = .wholeMac
        settings.resetToDefaults()
        XCTAssertEqual(settings.agentsCPUScale, .perCore)
        XCTAssertNil(UserDefaults.standard.object(forKey: SettingsStore.agentsCPUScaleKey))
    }

    func testAStoredValueReadsBackAndAnythingElseIsPerCore() {
        XCTAssertEqual(SettingsStore.storedCPUScale("wholeMac"), .wholeMac)
        XCTAssertEqual(SettingsStore.storedCPUScale("perCore"), .perCore)
        XCTAssertEqual(SettingsStore.storedCPUScale(nil), .perCore)
        XCTAssertEqual(SettingsStore.storedCPUScale("ludicrous"), .perCore)
    }
}
