import XCTest
import ServiceManagement
@testable import Omelette

/// Spec 2026-10-26 keep awake with the lid closed, § UI: three number fields d / h / m typed by
/// hand; a total over 7 days is refused, not clamped, with the notice under the fields and Apply
/// disabled; hours and minutes over their range carry over. Edges around the boundary and
/// around overflow, through `KeepAwakeRules.duration`, `KeepAwakeCopy.entryNotice` / `canApply`
/// and the model's `arm`.
final class KeepAwakeEntryVerificationTests: XCTestCase {
    private let sevenDaysInMinutes = 10_080
    private let extremes = [Int.min, Int.min + 1, -10_081, -1, 0, 1, 59, 60, 1_439, 1_440, 10_079, 10_080, 10_081, Int.max / 1_440, Int.max / 60, Int.max - 1, Int.max]

    /// Independent reference: Double arithmetic cannot trap, and every value near the bounds is
    /// exact in it; anything astronomically large is far past the cap either way.
    private func expectedMinutes(_ d: Int, _ h: Int, _ m: Int) -> Int? {
        guard d >= 0, h >= 0, m >= 0 else { return nil }
        let total = Double(d) * 1_440 + Double(h) * 60 + Double(m)
        guard total >= 1, total <= Double(sevenDaysInMinutes) else { return nil }
        return Int(total)
    }

    // MARK: - Overflow-shaped input never traps

    func testEveryCombinationOfExtremeValuesIsAnsweredWithoutTrappingByAllThreeFunctions() {
        for d in extremes {
            for h in extremes {
                for m in extremes {
                    let seconds = KeepAwakeRules.duration(days: d, hours: h, minutes: m)
                    let notice = KeepAwakeCopy.entryNotice(days: d, hours: h, minutes: m)
                    let can = KeepAwakeCopy.canApply(days: d, hours: h, minutes: m, isWorking: false)
                    XCTAssertEqual(seconds.map { Int($0) / 60 }, expectedMinutes(d, h, m), "\(d) \(h) \(m)")
                    XCTAssertEqual(can, seconds != nil, "\(d) \(h) \(m)")
                    let shouldNotice = d >= 0 && h >= 0 && m >= 0 && (d > 0 || h > 0 || m > 0) && seconds == nil
                    XCTAssertEqual(notice != nil, shouldNotice, "\(d) \(h) \(m)")
                }
            }
        }
    }

    // MARK: - The boundary

    func testTheSevenDayBoundaryIsTheSameFromEveryDirectionOfTyping() {
        let accepted: [(Int, Int, Int)] = [(7, 0, 0), (6, 24, 0), (6, 23, 60), (0, 168, 0), (0, 0, 10_080), (1, 143, 60), (0, 167, 60)]
        for (d, h, m) in accepted {
            XCTAssertEqual(KeepAwakeRules.duration(days: d, hours: h, minutes: m), 604_800, "\(d) \(h) \(m)")
            XCTAssertTrue(KeepAwakeCopy.canApply(days: d, hours: h, minutes: m, isWorking: false), "\(d) \(h) \(m)")
            XCTAssertNil(KeepAwakeCopy.entryNotice(days: d, hours: h, minutes: m), "\(d) \(h) \(m)")
        }
        let refused: [(Int, Int, Int)] = [(7, 0, 1), (6, 24, 1), (6, 23, 61), (0, 168, 1), (0, 169, 0), (0, 0, 10_081), (8, 0, 0), (6, 0, 10_081)]
        for (d, h, m) in refused {
            XCTAssertNil(KeepAwakeRules.duration(days: d, hours: h, minutes: m), "\(d) \(h) \(m)")
            XCTAssertFalse(KeepAwakeCopy.canApply(days: d, hours: h, minutes: m, isWorking: false), "\(d) \(h) \(m)")
            XCTAssertEqual(KeepAwakeCopy.entryNotice(days: d, hours: h, minutes: m), KeepAwakeCopy.limitNotice, "\(d) \(h) \(m)")
        }
    }

    func testOneMinuteIsTheFloorAndSixtySecondsIsExact() {
        XCTAssertEqual(KeepAwakeRules.duration(days: 0, hours: 0, minutes: 1), 60)
        XCTAssertEqual(KeepAwakeRules.duration(days: 0, hours: 0, minutes: 60), 3_600)
        XCTAssertEqual(KeepAwakeRules.duration(days: 0, hours: 0, minutes: 90), 5_400)
        XCTAssertNil(KeepAwakeRules.duration(days: 0, hours: 0, minutes: 0))
    }

    /// A grid over the whole neighbourhood: every refusal over seven days has its line and no
    /// accepted total does; Apply follows the duration and a call in flight always disables it.
    func testNoticeAndApplyAgreeWithTheDurationAcrossAGrid() {
        for d in 0...8 {
            for h in 0...170 {
                for m in [0, 1, 59, 60, 61, 1_439, 10_079, 10_080, 10_081] {
                    let seconds = KeepAwakeRules.duration(days: d, hours: h, minutes: m)
                    XCTAssertEqual(seconds.map { Int($0) / 60 }, expectedMinutes(d, h, m), "\(d) \(h) \(m)")
                    XCTAssertEqual(KeepAwakeCopy.canApply(days: d, hours: h, minutes: m, isWorking: false), seconds != nil)
                    XCTAssertFalse(KeepAwakeCopy.canApply(days: d, hours: h, minutes: m, isWorking: true))
                    let isZero = d == 0 && h == 0 && m == 0
                    XCTAssertEqual(KeepAwakeCopy.entryNotice(days: d, hours: h, minutes: m) != nil, seconds == nil && !isZero, "\(d) \(h) \(m)")
                }
            }
        }
    }

    func testANegativeFieldGetsNoNoticeEvenWhenTheRestIsHuge() {
        XCTAssertNil(KeepAwakeCopy.entryNotice(days: -1, hours: 0, minutes: 0))
        XCTAssertNil(KeepAwakeCopy.entryNotice(days: 9, hours: -1, minutes: 0))
        XCTAssertNil(KeepAwakeCopy.entryNotice(days: 0, hours: 0, minutes: Int.min))
        XCTAssertNil(KeepAwakeCopy.entryNotice(days: Int.max, hours: Int.max, minutes: -1))
        XCTAssertNil(KeepAwakeRules.duration(days: 7, hours: -1, minutes: 0))
    }

    // MARK: - The fields are seeded by parts(totalMinutes:)

    func testSeedingTheFieldsAndReadingThemBackKeepsTheMinutes() {
        for minutes in [1, 59, 60, 61, 90, 1_439, 1_440, 1_441, 5_000, 10_079, 10_080] {
            let p = KeepAwakeRules.parts(totalMinutes: minutes)
            XCTAssertEqual(KeepAwakeRules.duration(days: p.days, hours: p.hours, minutes: p.minutes), TimeInterval(minutes * 60), "\(minutes)")
            XCTAssertNil(KeepAwakeCopy.entryNotice(days: p.days, hours: p.hours, minutes: p.minutes), "\(minutes)")
        }
        // out-of-range remembered values are brought inside, so the seeded fields never carry a notice
        for minutes in [Int.min, -5, 0, 10_081, Int.max] {
            let p = KeepAwakeRules.parts(totalMinutes: minutes)
            XCTAssertNotNil(KeepAwakeRules.duration(days: p.days, hours: p.hours, minutes: p.minutes), "\(minutes)")
            XCTAssertNil(KeepAwakeCopy.entryNotice(days: p.days, hours: p.hours, minutes: p.minutes), "\(minutes)")
        }
    }

    // MARK: - The model's Apply goes through the same rule

    @MainActor private final class Prefs { var remembered: [Int] = [] }

    @MainActor private func makeModel(_ helper: KeepAwakeFakeHelper, _ prefs: Prefs) -> KeepAwakeModel {
        KeepAwakeModel(
            client: KeepAwakeClient(dependencies: helper.dependencies()),
            floorEnabled: { true },
            rememberDuration: { prefs.remembered.append($0) },
            resetSettings: {}
        )
    }

    @MainActor func testApplyingMoreThanSevenDaysAsksNobodyAndRemembersNothing() async {
        let helper = KeepAwakeFakeHelper(statuses: [.enabled])
        let prefs = Prefs()
        let model = makeModel(helper, prefs)
        for (d, h, m) in [(7, 0, 1), (0, 0, 10_081), (0, 169, 0), (Int.max, Int.max, Int.max), (0, 0, Int.min)] {
            await model.arm(days: d, hours: h, minutes: m)
            XCTAssertEqual(model.failure, .invalidDuration, "\(d) \(h) \(m)")
            XCTAssertFalse(model.isWorking)
        }
        XCTAssertEqual(helper.requests, [])
        XCTAssertEqual(prefs.remembered, [])
    }

    @MainActor func testApplyingHoursAndMinutesOverTheirRangeArmsTheCarriedOverTotal() async {
        let t0 = Date(timeIntervalSince1970: 1_793_000_000)
        let helper = KeepAwakeFakeHelper(statuses: [.enabled]) { request in
            if case .arm(let seconds, let floor) = request {
                return .success(KeepAwakeReply(state: .armed(deadline: t0 + seconds, floorEnabled: floor), failure: nil))
            }
            return .success(KeepAwakeReply(state: .idle, failure: nil))
        }
        let prefs = Prefs()
        let model = makeModel(helper, prefs)
        await model.arm(days: 0, hours: 0, minutes: 90, now: t0)
        await model.arm(days: 6, hours: 24, minutes: 0, now: t0)
        XCTAssertEqual(helper.requests, [.arm(seconds: 5_400, floorEnabled: true), .arm(seconds: 604_800, floorEnabled: true)])
        XCTAssertEqual(prefs.remembered, [90, 10_080])
        XCTAssertNil(model.failure)
    }
}
