import XCTest
@testable import Omelette

/// Spec 2026-11-19 keep-awake thermal guard, Facts (`ProcessInfo.thermalState`: nominal, fair,
/// serious, critical), § Rule and § Plan decisions accepted by the session, items 1–2: with the
/// lid closed and the guard on, `critical` ends the mode at the reading that sees it and
/// `serious` once it has held 60 s from the run's first reading; one hot reading that cools
/// within the minute ends nothing; the thresholds are constants of the pure rule.
final class KeepAwakeThermalRulesTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)

    func testTheLevelsGoFromCoolToHot() {
        XCTAssertEqual(KeepAwakeThermalLevel.allCases, [.nominal, .fair, .serious, .critical])
        XCTAssertEqual(KeepAwakeThermalLevel.allCases.reversed().sorted(), [.nominal, .fair, .serious, .critical])
        XCTAssertLessThan(KeepAwakeThermalLevel.fair, .serious)
        XCTAssertLessThan(KeepAwakeThermalLevel.serious, .critical)
    }

    func testProcessInfosFourStatesAreTheFourLevels() {
        XCTAssertEqual(KeepAwakeReadings.thermal(from: .nominal), .nominal)
        XCTAssertEqual(KeepAwakeReadings.thermal(from: .fair), .fair)
        XCTAssertEqual(KeepAwakeReadings.thermal(from: .serious), .serious)
        XCTAssertEqual(KeepAwakeReadings.thermal(from: .critical), .critical)
    }

    /// A state a later macOS adds: hotter than critical reads as critical, anything else as nominal.
    func testAStateThisBuildDoesNotKnowReadsAsCriticalOnlyWhenHotter() throws {
        XCTAssertEqual(KeepAwakeReadings.thermal(from: try XCTUnwrap(ProcessInfo.ThermalState(rawValue: 4))), .critical)
        XCTAssertEqual(KeepAwakeReadings.thermal(from: try XCTUnwrap(ProcessInfo.ThermalState(rawValue: -1))), .nominal)
    }

    /// § Spike: "constants of the pure rule".
    func testTheThresholdsAreSeriousHeldAMinuteAndCriticalAtTheReading() {
        XCTAssertEqual(KeepAwakeRules.heatEndsWhenHeld, .serious)
        XCTAssertEqual(KeepAwakeRules.heatHoldInterval, 60)
        XCTAssertEqual(KeepAwakeRules.heatEndsAtOnce, .critical)
    }

    func testCriticalEndsTheModeAtTheReadingThatSeesIt() {
        XCTAssertTrue(KeepAwakeRules.endsForHeat(level: .critical, hotSince: t0, now: t0, lidClosed: true, guardEnabled: true))
        XCTAssertTrue(KeepAwakeRules.endsForHeat(level: .critical, hotSince: nil, now: t0, lidClosed: true, guardEnabled: true))
    }

    func testSeriousEndsTheModeOnceItHeldForAMinute() {
        XCTAssertFalse(KeepAwakeRules.endsForHeat(level: .serious, hotSince: t0, now: t0, lidClosed: true, guardEnabled: true))
        XCTAssertFalse(KeepAwakeRules.endsForHeat(level: .serious, hotSince: t0, now: t0 + 59, lidClosed: true, guardEnabled: true))
        XCTAssertTrue(KeepAwakeRules.endsForHeat(level: .serious, hotSince: t0, now: t0 + 60, lidClosed: true, guardEnabled: true))
        XCTAssertFalse(KeepAwakeRules.endsForHeat(level: .serious, hotSince: nil, now: t0 + 600, lidClosed: true, guardEnabled: true))
    }

    func testAFairOrNominalMacNeverEndsTheMode() {
        for level in [KeepAwakeThermalLevel.nominal, .fair] {
            XCTAssertFalse(
                KeepAwakeRules.endsForHeat(level: level, hotSince: t0, now: t0 + 3_600, lidClosed: true, guardEnabled: true),
                "\(level)"
            )
        }
    }

    /// § Rule: "With the lid open the guard ends nothing"; with the switch off nothing either.
    func testWithTheLidOpenOrTheGuardOffHeatEndsNothing() {
        XCTAssertFalse(KeepAwakeRules.endsForHeat(level: .critical, hotSince: t0, now: t0 + 600, lidClosed: false, guardEnabled: true))
        XCTAssertFalse(KeepAwakeRules.endsForHeat(level: .critical, hotSince: t0, now: t0 + 600, lidClosed: true, guardEnabled: false))
    }

    func testAHotRunBeginsAtItsFirstReadingAndCarriesOn() {
        XCTAssertEqual(KeepAwakeRules.hotSince(level: .serious, previous: nil, now: t0, lidClosed: true, guardEnabled: true), t0)
        XCTAssertEqual(KeepAwakeRules.hotSince(level: .serious, previous: t0, now: t0 + 30, lidClosed: true, guardEnabled: true), t0)
        XCTAssertEqual(KeepAwakeRules.hotSince(level: .critical, previous: t0, now: t0 + 30, lidClosed: true, guardEnabled: true), t0)
    }

    /// "One hot reading that cools within the minute ends nothing": a cooler reading, an open lid
    /// or the switch off breaks the run.
    func testACoolerReadingAnOpenLidOrTheGuardOffBreaksTheRun() {
        XCTAssertNil(KeepAwakeRules.hotSince(level: .fair, previous: t0, now: t0 + 30, lidClosed: true, guardEnabled: true))
        XCTAssertNil(KeepAwakeRules.hotSince(level: .serious, previous: t0, now: t0 + 30, lidClosed: false, guardEnabled: true))
        XCTAssertNil(KeepAwakeRules.hotSince(level: .serious, previous: t0, now: t0 + 30, lidClosed: true, guardEnabled: false))
    }

    /// A clock set back past the run's start begins the run again rather than stretching it.
    func testARunThatBeganAfterNowBeginsAgainNow() {
        XCTAssertEqual(KeepAwakeRules.hotSince(level: .serious, previous: t0 + 600, now: t0, lidClosed: true, guardEnabled: true), t0)
    }
}
