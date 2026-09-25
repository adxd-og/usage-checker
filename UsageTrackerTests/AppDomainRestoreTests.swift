import XCTest
@testable import Omelette

/// The test host shares the running app's defaults domain. Classes that write settings
/// put the domain back from a snapshot after each test; the snapshot must not put back an
/// old value of a key the user owns while the suite runs: the recorded popover shortcut,
/// which KeyboardShortcuts keeps in that same domain. Pure dictionaries: nothing here
/// reads or writes real defaults.
final class AppDomainRestoreTests: XCTestCase {
    private let key = "KeyboardShortcuts_peekUsage"

    func testTheShortcutIsTheOneKeyTheRestoreLeavesToTheUser() {
        XCTAssertEqual(AppDomainRestore.liveKeys, ["KeyboardShortcuts_peekUsage"])
    }

    func testEverySettingComesBackAsItWasBeforeTheTest() {
        let merged = AppDomainRestore.merged(
            saved: ["refreshIntervalSeconds": 300, "showsRemaining": true],
            current: ["refreshIntervalSeconds": 60],
            liveKeys: [key]
        )
        XCTAssertEqual(merged["refreshIntervalSeconds"] as? Int, 300)
        XCTAssertEqual(merged["showsRemaining"] as? Bool, true)
    }

    func testAShortcutRecordedWhileTheTestRanIsKept() {
        let merged = AppDomainRestore.merged(saved: [:], current: [key: "{\"carbonKeyCode\":35}"], liveKeys: [key])
        XCTAssertEqual(merged[key] as? String, "{\"carbonKeyCode\":35}")
    }

    func testAShortcutChangedWhileTheTestRanKeepsItsNewValue() {
        let merged = AppDomainRestore.merged(saved: [key: "old"], current: [key: "new"], liveKeys: [key])
        XCTAssertEqual(merged[key] as? String, "new")
    }

    func testAShortcutClearedWhileTheTestRanStaysCleared() {
        let merged = AppDomainRestore.merged(saved: [key: "old", "a": 1], current: ["a": 2], liveKeys: [key])
        XCTAssertNil(merged[key])
        XCTAssertEqual(merged["a"] as? Int, 1)
    }

    func testWithNothingSavedOnlyTheLiveKeyRemains() {
        let merged = AppDomainRestore.merged(saved: nil, current: [key: "new", "a": 2], liveKeys: [key])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[key] as? String, "new")
    }
}
