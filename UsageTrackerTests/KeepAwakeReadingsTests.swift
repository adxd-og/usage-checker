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

    // MARK: - Battery (IOPSGetPowerSourceDescription) and lid (IOPMrootDomain's two clamshell keys)

    /// The internal battery's description, keys as IOPSKeys.h spells them, values as
    /// `pmset -g batt` read on the owner's Mac on 2026-10-26 ("50%; discharging"). A
    /// function, not a `static let`: `[String: Any]` is not Sendable under Swift 6.
    private static func battery50() -> [String: Any] {
        [
            "Type": "InternalBattery",
            "Is Present": true,
            "Power Source State": "Battery Power",
            "Current Capacity": 50,
            "Max Capacity": 100,
        ]
    }

    func testTheInternalBatteryOnBatteryPower() {
        XCTAssertEqual(KeepAwakeReadings.power(fromDescriptions: [Self.battery50()]), KeepAwakePower(onBattery: true, percent: 50))
    }

    func testOnTheChargerTheBatteryIsNotTheSource() {
        var charging = Self.battery50()
        charging["Power Source State"] = "AC Power"
        XCTAssertEqual(KeepAwakeReadings.power(fromDescriptions: [charging]), KeepAwakePower(onBattery: false, percent: 50))
    }

    func testAMacWithoutAnInternalBatteryHasNoReading() {
        XCTAssertNil(KeepAwakeReadings.power(fromDescriptions: []))
        var ups = Self.battery50()
        ups["Type"] = "UPS"
        XCTAssertNil(KeepAwakeReadings.power(fromDescriptions: [ups]))
        var absent = Self.battery50()
        absent["Is Present"] = false
        XCTAssertNil(KeepAwakeReadings.power(fromDescriptions: [absent]))
    }

    func testCapacityIsScaledToAPercentRoundingDown() {
        var raw = Self.battery50()
        raw["Current Capacity"] = 1_499
        raw["Max Capacity"] = 6_000
        XCTAssertEqual(KeepAwakeReadings.power(fromDescriptions: [raw])?.percent, 24)
    }

    /// IOPMrootDomain's properties as `IORegistryEntryCreateCFProperties` bridges them (CF
    /// booleans arrive as NSNumber). This Mac on 2026-10-26, lid open, no external display:
    /// `"AppleClamshellState" = No`, `"AppleClamshellCausesSleep" = Yes` (ioreg).
    private static func rootDomain(closed: Bool?, causesSleep: Bool?) -> [String: Any] {
        var properties: [String: Any] = ["IOSleepSupported": NSNumber(value: true)]
        if let closed { properties["AppleClamshellState"] = NSNumber(value: closed) }
        if let causesSleep { properties["AppleClamshellCausesSleep"] = NSNumber(value: causesSleep) }
        return properties
    }

    func testThisMacsOpenLidReadsOpenAndWouldSleepWhenClosed() {
        let lid = KeepAwakeReadings.lid(fromRootDomain: Self.rootDomain(closed: false, causesSleep: true))
        XCTAssertEqual(lid, KeepAwakeLid(closed: false, causesSleep: true))
        XCTAssertFalse(lid.sleepsWhenClosed)
    }

    func testAClosedLidWithoutAnExternalDisplaySleeps() {
        let lid = KeepAwakeReadings.lid(fromRootDomain: Self.rootDomain(closed: true, causesSleep: true))
        XCTAssertEqual(lid, KeepAwakeLid(closed: true, causesSleep: true))
        XCTAssertTrue(lid.sleepsWhenClosed)
    }

    /// Session ruling on D5: a Mac in clamshell mode on an external display is never put to
    /// sleep by us.
    func testAClosedLidOnAnExternalDisplayNeverSleeps() {
        let lid = KeepAwakeReadings.lid(fromRootDomain: Self.rootDomain(closed: true, causesSleep: false))
        XCTAssertEqual(lid, KeepAwakeLid(closed: true, causesSleep: false))
        XCTAssertFalse(lid.sleepsWhenClosed)
    }

    func testAMissingKeyOrANonBooleanReadsAsNo() {
        XCTAssertEqual(KeepAwakeReadings.lid(fromRootDomain: [:]), KeepAwakeLid(closed: false, causesSleep: false))
        XCTAssertEqual(
            KeepAwakeReadings.lid(fromRootDomain: Self.rootDomain(closed: true, causesSleep: nil)),
            KeepAwakeLid(closed: true, causesSleep: false)
        )
        XCTAssertEqual(
            KeepAwakeReadings.lid(fromRootDomain: ["AppleClamshellState": "Yes", "AppleClamshellCausesSleep": "Yes"]),
            KeepAwakeLid(closed: false, causesSleep: false)
        )
    }
}
