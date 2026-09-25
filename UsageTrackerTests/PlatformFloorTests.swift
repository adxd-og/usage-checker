import XCTest
@testable import Omelette

/// Liquid-glass redesign spec § Design → Platform floor and § Decisions, "Helper
/// deployment targets": 3.0 needs macOS 26 for the whole bundle. Xcode writes each
/// target's deployment target into its Info.plist as `LSMinimumSystemVersion`, which
/// is what Launch Services checks, so these tests read the built bundles rather than
/// project.yml.
final class PlatformFloorTests: XCTestCase {
    func testTheAppDeclaresMacOS26AsItsFloor() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String, "26.0")
    }

    func testTheWidgetMovesToMacOS26WithTheBundle() throws {
        let plugIns = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let widget = try XCTUnwrap(Bundle(url: plugIns.appendingPathComponent("UsageTrackerWidget.appex")))
        XCTAssertEqual(widget.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String, "26.0")
    }
}
