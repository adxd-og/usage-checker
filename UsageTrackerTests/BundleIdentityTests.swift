import XCTest
@testable import Omelette

/// The rename (plan 2026-10-31-brioche-rename, R1, § What stays): the name changes, and nothing
/// an update, the keychain, launchd or a helper relies on does. Reads the test host, the built
/// app, as `KeepAwakeBundleTests` does.
final class BundleIdentityTests: XCTestCase {
    private func info(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }

    func testTheNameAPersonSeesIsBrioche() {
        XCTAssertEqual(info("CFBundleDisplayName"), "Brioche")
        XCTAssertEqual(info("CFBundleName"), "Brioche")
    }

    func testAFreshBundleIsBriocheApp() {
        XCTAssertEqual(Bundle.main.bundleURL.lastPathComponent, "Brioche.app")
    }

    /// `@testable import Omelette` in this very file already says the module; the type's full
    /// name says it at run time. The executable stays too: OWNER 2.
    func testTheExecutableAndTheModuleKeepTheirNames() {
        XCTAssertEqual(info("CFBundleExecutable"), "Omelette")
        XCTAssertEqual(Bundle.main.executableURL?.lastPathComponent, "Omelette")
        XCTAssertEqual(String(reflecting: AppVersion.self), "Omelette.AppVersion")
    }

    func testWhatAnUpdateReliesOnIsUnchanged() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.usagetracker.app")
        XCTAssertEqual(info("SUFeedURL"), "https://adxd-og.github.io/usage-checker/appcast.xml")
        XCTAssertEqual(info("SUPublicEDKey"), "MHnsTPADe6xMrC9FNW2+JGcON46j6J2JSrG/wCqpLDA=")
    }

    func testEveryHelperIsWhereThePathsAndThePlistSayItIs() {
        for helper in ["omelette", "omelette-hook", "omelette-keepawake"] {
            let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(helper)")
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path), "no helper at \(url.path)")
        }
    }

    func testTheAutomationPromptSaysBrioche() {
        XCTAssertEqual(
            info("NSAppleEventsUsageDescription"),
            "Brioche brings the terminal tab of an agent session back to the front when you click it."
        )
    }
}
