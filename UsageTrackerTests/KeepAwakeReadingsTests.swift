import XCTest
@testable import Omelette

/// Spec 2026-10-26 § Facts: "`pmset -g` prints `SleepDisabled 1` while set,
/// `SleepDisabled 0` once it has been cleared explicitly, and no line before it was ever
/// set — a read-back checks the value, not the line's presence."
final class KeepAwakeReadingsTests: XCTestCase {
    /// `pmset -g` on the owner's Mac (macOS 27.0, 26A428), 2026-10-26, after spike step 5
    /// cleared the flag. Verbatim; the two tabs after SleepDisabled are pmset's own.
    static let pmsetCleared = [
        "System-wide power settings:",
        " SleepDisabled\t\t0",
        "Currently in use:",
        " standby              1",
        " Sleep On Power Button 1",
        " hibernatefile        /var/vm/sleepimage",
        " powernap             0",
        " networkoversleep     0",
        " disksleep            10",
        " sleep                1 (sleep prevented by useractivityd, powerd, sharingd, caffeinate)",
        " hibernatemode        3",
        " ttyskeepawake        1",
        " displaysleep         10",
        " tcpkeepalive         1",
        " lowpowermode         0",
        " womp                 0",
    ].joined(separator: "\n") + "\n"

    /// The same output with the flag set (spike step 1 read `SleepDisabled 1`).
    static let pmsetSet = pmsetCleared.replacingOccurrences(of: "SleepDisabled\t\t0", with: "SleepDisabled\t\t1")

    /// Before the flag was ever set there is no system-wide section (derived: the first two
    /// lines of the capture dropped).
    static let pmsetNeverSet = pmsetCleared
        .split(separator: "\n", omittingEmptySubsequences: false)
        .dropFirst(2)
        .joined(separator: "\n")

    func testAFlagSetReadsAsSet() {
        XCTAssertEqual(KeepAwakeReadings.flag(fromPmset: Self.pmsetSet), .set)
    }

    func testAnExplicitlyClearedFlagReadsAsCleared() {
        XCTAssertEqual(KeepAwakeReadings.flag(fromPmset: Self.pmsetCleared), .cleared)
    }

    func testAMacThatNeverSetTheFlagHasNoLine() {
        XCTAssertEqual(KeepAwakeReadings.flag(fromPmset: Self.pmsetNeverSet), .neverSet)
    }

    func testTheSleepSettingIsNotTheFlag() {
        XCTAssertEqual(KeepAwakeReadings.flag(fromPmset: " sleep                1 (sleep prevented by caffeinate)\n"), .neverSet)
        XCTAssertEqual(KeepAwakeReadings.flag(fromPmset: " Sleep On Power Button 1\n"), .neverSet)
    }

    func testAValueThatIsNotZeroOrOneIsUnreadable() {
        XCTAssertEqual(KeepAwakeReadings.flag(fromPmset: " SleepDisabled\t\tyes\n"), .unreadable)
        XCTAssertEqual(KeepAwakeReadings.flag(fromPmset: " SleepDisabled\n"), .unreadable)
    }

    func testClearMeansClearedOrNeverSet() {
        XCTAssertTrue(KeepAwakeFlagReading.cleared.isClear)
        XCTAssertTrue(KeepAwakeFlagReading.neverSet.isClear)
        XCTAssertFalse(KeepAwakeFlagReading.set.isClear)
        XCTAssertFalse(KeepAwakeFlagReading.unreadable.isClear)
    }
}
