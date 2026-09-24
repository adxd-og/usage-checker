import XCTest
@testable import Omelette

/// A build that is not the shipped one never updates itself (`Updater.updatesItself`):
/// a Debug build, or any bundle running out of a DerivedData tree, must not take the
/// public update and have Sparkle replace its bundle with the release app.
final class UpdaterDebugBuildTests: XCTestCase {
    func testAReleaseBuildInApplicationsUpdatesItself() {
        XCTAssertTrue(Updater.updatesItself(isDebugBuild: false, bundlePath: "/Applications/Omelette.app"))
    }

    func testADebugBuildNeverUpdatesItself() {
        XCTAssertFalse(Updater.updatesItself(isDebugBuild: true, bundlePath: "/Applications/Omelette.app"))
    }

    func testAReleaseBuildRunningOutOfDerivedDataNeverUpdatesItself() {
        let path = "/tmp/checkout/build/DerivedData/Build/Products/Release/Omelette.app"
        XCTAssertFalse(Updater.updatesItself(isDebugBuild: false, bundlePath: path))
    }
}
