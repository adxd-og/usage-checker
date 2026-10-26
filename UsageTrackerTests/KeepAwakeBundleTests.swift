import XCTest
@testable import Omelette

/// Spec 2026-10-26 § Helper: "`Contents/Helpers/omelette-keepawake` … plus
/// `Contents/Library/LaunchDaemons/com.usagetracker.app.keepawake.plist` (`BundleProgram`,
/// `AssociatedBundleIdentifiers` = `com.usagetracker.app`, `MachServices` =
/// `com.usagetracker.app.keepawake`, `RunAtLoad`)", plus `KeepAlive = {SuccessfulExit: false}`
/// (plan D7: an idle exit with status 0 is final until the next call or boot; a crash is
/// restarted). Reads the test host, the built Omelette.app, the way TmuxHookWireTests finds
/// omelette-hook.
final class KeepAwakeBundleTests: XCTestCase {
    private var plistURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/\(KeepAwakeIdentity.plistName)")
    }

    private func readPlist() throws -> [String: Any] {
        let data = try Data(contentsOf: plistURL)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func testTheLaunchdPlistSitsWhereSMAppServiceLooksForIt() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: plistURL.path), "no plist at \(plistURL.path)")
    }

    func testThePlistNamesTheDaemonItsAppAndItsMachService() throws {
        let plist = try readPlist()
        XCTAssertEqual(plist["Label"] as? String, KeepAwakeIdentity.label)
        XCTAssertEqual(plist["BundleProgram"] as? String, "Contents/Helpers/omelette-keepawake")
        XCTAssertEqual(plist["AssociatedBundleIdentifiers"] as? [String], ["com.usagetracker.app"])
        XCTAssertEqual(plist["MachServices"] as? [String: Bool], [KeepAwakeIdentity.machServiceName: true])
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["KeepAlive"] as? [String: Bool], ["SuccessfulExit": false])
    }

    func testTheProgramThePlistNamesIsInTheBundleAndExecutable() throws {
        let program = try XCTUnwrap(try readPlist()["BundleProgram"] as? String)
        let url = Bundle.main.bundleURL.appendingPathComponent(program)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path), "no daemon at \(url.path)")
    }
}
