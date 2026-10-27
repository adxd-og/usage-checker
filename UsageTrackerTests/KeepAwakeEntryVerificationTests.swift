import XCTest
import ServiceManagement
@testable import Omelette

/// Spec 2026-10-26 keep awake with the lid closed, § UI: three number fields d / h / m typed by
/// hand; a total over 7 d 23 h 59 min is applied as the ceiling, with the notice under the
/// fields while it is over (owner, 2026-10-27); hours and minutes over their range carry over. Edges around the boundary and
/// around overflow, through `KeepAwakeRules.duration`, `KeepAwakeCopy.entryNotice` / `canApply`
/// and the model's `arm`.
final class KeepAwakeEntryVerificationTests: XCTestCase {
    private let ceilingInMinutes = 11_519
    private let extremes = [Int.min, Int.min + 1, -10_081, -1, 0, 1, 59, 60, 1_439, 1_440, 10_079, 10_080, 10_081, Int.max / 1_440, Int.max / 60, Int.max - 1, Int.max]

    /// Independent reference: Double arithmetic cannot trap, and every value near the bounds is
    /// exact in it; anything astronomically large is far past the cap either way. Over the
    /// ceiling the answer is the ceiling, not nil.
    private func expectedMinutes(_ d: Int, _ h: Int, _ m: Int) -> Int? {
        guard d >= 0, h >= 0, m >= 0 else { return nil }
        let total = Double(d) * 1_440 + Double(h) * 60 + Double(m)
        guard total >= 1 else { return nil }
        return total > Double(ceilingInMinutes) ? ceilingInMinutes : Int(total)
    }

    /// The notice's reference: no negative field and a typed total over the ceiling.
    private func isOver(_ d: Int, _ h: Int, _ m: Int) -> Bool {
        d >= 0 && h >= 0 && m >= 0 && Double(d) * 1_440 + Double(h) * 60 + Double(m) > Double(ceilingInMinutes)
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
                    XCTAssertEqual(notice != nil, isOver(d, h, m), "\(d) \(h) \(m)")
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
        let ceiling: [(Int, Int, Int)] = [(7, 23, 59), (7, 22, 119), (6, 47, 59), (0, 191, 59), (0, 0, 11_519)]
        for (d, h, m) in ceiling {
            XCTAssertEqual(KeepAwakeRules.duration(days: d, hours: h, minutes: m), 691_140, "\(d) \(h) \(m)")
            XCTAssertNil(KeepAwakeCopy.entryNotice(days: d, hours: h, minutes: m), "\(d) \(h) \(m)")
        }
        let over: [(Int, Int, Int)] = [(7, 23, 60), (7, 24, 0), (6, 48, 0), (0, 192, 0), (0, 0, 11_520), (8, 0, 0), (6, 0, 10_081)]
        for (d, h, m) in over {
            XCTAssertEqual(KeepAwakeRules.duration(days: d, hours: h, minutes: m), 691_140, "\(d) \(h) \(m)")
            XCTAssertTrue(KeepAwakeCopy.canApply(days: d, hours: h, minutes: m, isWorking: false), "\(d) \(h) \(m)")
            XCTAssertEqual(KeepAwakeCopy.entryNotice(days: d, hours: h, minutes: m), KeepAwakeCopy.limitNotice, "\(d) \(h) \(m)")
        }
    }

    func testOneMinuteIsTheFloorAndSixtySecondsIsExact() {
        XCTAssertEqual(KeepAwakeRules.duration(days: 0, hours: 0, minutes: 1), 60)
        XCTAssertEqual(KeepAwakeRules.duration(days: 0, hours: 0, minutes: 60), 3_600)
        XCTAssertEqual(KeepAwakeRules.duration(days: 0, hours: 0, minutes: 90), 5_400)
        XCTAssertNil(KeepAwakeRules.duration(days: 0, hours: 0, minutes: 0))
    }

    /// A grid over the whole neighbourhood: the notice shows exactly when the typed total is over
    /// the ceiling; Apply follows the duration and a call in flight always disables it.
    func testNoticeAndApplyAgreeWithTheDurationAcrossAGrid() {
        for d in 0...8 {
            for h in 0...170 {
                for m in [0, 1, 59, 60, 61, 1_439, 10_079, 10_080, 10_081] {
                    let seconds = KeepAwakeRules.duration(days: d, hours: h, minutes: m)
                    XCTAssertEqual(seconds.map { Int($0) / 60 }, expectedMinutes(d, h, m), "\(d) \(h) \(m)")
                    XCTAssertEqual(KeepAwakeCopy.canApply(days: d, hours: h, minutes: m, isWorking: false), seconds != nil)
                    XCTAssertFalse(KeepAwakeCopy.canApply(days: d, hours: h, minutes: m, isWorking: true))
                    XCTAssertEqual(KeepAwakeCopy.entryNotice(days: d, hours: h, minutes: m) != nil, isOver(d, h, m), "\(d) \(h) \(m)")
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
        for minutes in [Int.min, -5, 0, 11_520, Int.max] {
            let p = KeepAwakeRules.parts(totalMinutes: minutes)
            XCTAssertNotNil(KeepAwakeRules.duration(days: p.days, hours: p.hours, minutes: p.minutes), "\(minutes)")
            XCTAssertNil(KeepAwakeCopy.entryNotice(days: p.days, hours: p.hours, minutes: p.minutes), "\(minutes)")
        }
    }

    // MARK: - A field's text is read as typed

    /// Edges `fieldNumber` must keep: the nine-digit window is judged on the whole text, so a
    /// non-ASCII digit after the ninth character cannot slip through, and a long run reads as
    /// its first nine digits.
    func testAFieldReadsItsFirstNineDigitsAndOnlyWhenTheWholeTextIsASCIIDigits() {
        XCTAssertEqual(KeepAwakeCopy.fieldNumber("1234567890"), 123_456_789)
        XCTAssertEqual(KeepAwakeCopy.fieldNumber("123456789"), 123_456_789)
        XCTAssertEqual(KeepAwakeCopy.fieldNumber("123456789\u{0668}"), 0)
        XCTAssertEqual(KeepAwakeCopy.fieldNumber("123456789\u{FF18}"), 0)
        XCTAssertEqual(KeepAwakeCopy.fieldNumber("123456789x"), 0)
        XCTAssertEqual(KeepAwakeCopy.fieldNumber("\u{FF15}"), 0)
        XCTAssertEqual(KeepAwakeCopy.fieldNumber("1 2"), 0)
        XCTAssertEqual(KeepAwakeCopy.fieldNumber("   "), 0)
        XCTAssertEqual(KeepAwakeCopy.fieldNumber(" \t5\t "), 5)
        XCTAssertEqual(KeepAwakeCopy.fieldNumber("  123456789  "), 123_456_789)
        XCTAssertEqual(KeepAwakeCopy.fieldNumber("0"), 0)
        XCTAssertEqual(KeepAwakeCopy.fieldNumber("00000000000007"), 0, "the window is the first nine characters, leading zeros included")
    }

    /// Whatever is typed, the three functions answer and a total over the ceiling always says so.
    func testEveryTypedRunInTheFieldsEndsInAnAnswerAndAConsistentNotice() {
        let runs = ["", "0", "7", "8", "168", "10080", "10081", "99999999999999999999", "-1", "1.5", "abc", "\u{0668}"]
        for d in runs { for h in runs { for m in runs {
            let (nd, nh, nm) = (KeepAwakeCopy.fieldNumber(d), KeepAwakeCopy.fieldNumber(h), KeepAwakeCopy.fieldNumber(m))
            let seconds = KeepAwakeRules.duration(days: nd, hours: nh, minutes: nm)
            XCTAssertEqual(KeepAwakeCopy.canApply(days: nd, hours: nh, minutes: nm, isWorking: false), seconds != nil)
            XCTAssertEqual(KeepAwakeCopy.entryNotice(days: nd, hours: nh, minutes: nm) != nil, isOver(nd, nh, nm), "\(d) \(h) \(m)")
        } } }
    }

    // MARK: - A keystroke goes through fieldText

    private let units: [KeepAwakeCopy.DurationUnit] = [.days, .hours, .minutes]

    func testAKeystrokeLeavesEmptyOrDigitsThatReadBackAsTheSameCappedNumber() {
        let typed = ["", " ", "0", "00", "000000000", "5", "7", "8", "23", "24", "25", "59", "60", "61", "100", "230",
                     "999999999", "1234567890", "99999999999999999999", "0000000000007", " 12 ", "\t9\t",
                     "-1", "1.5", "1,5", "1 2", "abc", "\u{0668}", "\u{FF15}", "5\u{0668}", "+3", "1e2"]
        for unit in units {
            for t in typed {
                for previous in ["", "0", "3"] {
                    let out = KeepAwakeCopy.fieldText(t, previous: previous, unit: unit)
                    let isDigitsOnly = !t.trimmingCharacters(in: .whitespaces).isEmpty
                        && t.trimmingCharacters(in: .whitespaces).allSatisfy { $0.isASCII && $0.isNumber }
                    if t.trimmingCharacters(in: .whitespaces).isEmpty {
                        XCTAssertEqual(out, "", "\(unit) \(t.debugDescription)")
                    } else if !isDigitsOnly {
                        XCTAssertEqual(out, previous, "\(unit) \(t.debugDescription)")
                    } else {
                        let expected = min(KeepAwakeCopy.fieldNumber(t), unit.maximum)
                        XCTAssertEqual(out, String(expected), "\(unit) \(t.debugDescription)")
                        XCTAssertEqual(KeepAwakeCopy.fieldNumber(out), expected)
                        // idempotent: typing the same thing on top of its own result changes nothing
                        XCTAssertEqual(KeepAwakeCopy.fieldText(out, previous: out, unit: unit), out)
                    }
                }
            }
        }
    }

    func testAFieldKeepsAZeroAndSnapsAnythingPastItsMaximumToTheMaximum() {
        XCTAssertEqual(KeepAwakeCopy.fieldText("0", previous: "5", unit: .minutes), "0")
        XCTAssertEqual(KeepAwakeCopy.fieldText("00", previous: "0", unit: .days), "0")
        XCTAssertEqual(KeepAwakeCopy.fieldText("   ", previous: "5", unit: .hours), "")
        XCTAssertEqual(KeepAwakeCopy.fieldText("24", previous: "2", unit: .hours), "24")
        XCTAssertEqual(KeepAwakeCopy.fieldText("245", previous: "24", unit: .hours), "24")
        XCTAssertEqual(KeepAwakeCopy.fieldText("25", previous: "2", unit: .hours), "24")
        XCTAssertEqual(KeepAwakeCopy.fieldText("23", previous: "2", unit: .hours), "23")
        XCTAssertEqual(KeepAwakeCopy.fieldText("59", previous: "5", unit: .minutes), "59")
        XCTAssertEqual(KeepAwakeCopy.fieldText("7", previous: "", unit: .days), "7")
        XCTAssertEqual(KeepAwakeCopy.fieldText("999999999", previous: "", unit: .days), "7")
        XCTAssertEqual(KeepAwakeCopy.fieldText("1234567890", previous: "", unit: .minutes), "60")
        XCTAssertEqual(KeepAwakeCopy.fieldText("99999999999999999999", previous: "", unit: .hours), "24")
        XCTAssertEqual(KeepAwakeCopy.fieldText("0000000000007", previous: "", unit: .days), "0", "only the first nine characters are read")
        XCTAssertEqual(KeepAwakeCopy.fieldText("1 2", previous: "1", unit: .minutes), "1")
        XCTAssertEqual(KeepAwakeCopy.fieldText("5\u{0668}", previous: "5", unit: .minutes), "5")
    }

    /// The caps are per field; the total rule still has the last word, at the ceiling.
    func testTheFieldCapsComposeWithTheCeilingSoOnlyTheFullStopsAreBroughtDown() {
        for d in 0...7 {
            for h in 0...24 {
                for m in [0, 1, 58, 59, 60] {
                    let nd = KeepAwakeCopy.fieldNumber(KeepAwakeCopy.fieldText(String(d), previous: "", unit: .days))
                    let nh = KeepAwakeCopy.fieldNumber(KeepAwakeCopy.fieldText(String(h), previous: "", unit: .hours))
                    let nm = KeepAwakeCopy.fieldNumber(KeepAwakeCopy.fieldText(String(m), previous: "", unit: .minutes))
                    XCTAssertEqual([nd, nh, nm], [d, h, m])
                    let total = d * 1_440 + h * 60 + m
                    let isZero = total == 0
                    let over = total > 11_519
                    XCTAssertEqual(KeepAwakeRules.duration(days: nd, hours: nh, minutes: nm), isZero ? nil : TimeInterval(min(total, 11_519) * 60), "\(d) \(h) \(m)")
                    XCTAssertEqual(KeepAwakeCopy.entryNotice(days: nd, hours: nh, minutes: nm), over ? KeepAwakeCopy.limitNotice : nil, "\(d) \(h) \(m)")
                }
            }
        }
        // typed at the stops: 7 / 24 / 60 is brought down to the ceiling with the line, 7 / 23 / 59 is the ceiling
        let stop = (KeepAwakeCopy.fieldText("9", previous: "", unit: .days), KeepAwakeCopy.fieldText("99", previous: "", unit: .hours), KeepAwakeCopy.fieldText("99", previous: "", unit: .minutes))
        XCTAssertEqual([stop.0, stop.1, stop.2], ["7", "24", "60"])
        XCTAssertEqual(KeepAwakeCopy.entryNotice(days: KeepAwakeCopy.fieldNumber(stop.0), hours: KeepAwakeCopy.fieldNumber(stop.1), minutes: KeepAwakeCopy.fieldNumber(stop.2)), KeepAwakeCopy.limitNotice)
        XCTAssertEqual(KeepAwakeRules.duration(days: 7, hours: 24, minutes: 60), 691_140)
        XCTAssertEqual(KeepAwakeRules.duration(days: 7, hours: 23, minutes: 59), 691_140)
        XCTAssertNil(KeepAwakeCopy.entryNotice(days: 7, hours: 23, minutes: 59))
        XCTAssertTrue(KeepAwakeCopy.canApply(days: 7, hours: 23, minutes: 59, isWorking: false))
        XCTAssertTrue(KeepAwakeCopy.canApply(days: 7, hours: 24, minutes: 0, isWorking: false))
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

    @MainActor func testApplyingMoreThanTheCeilingArmsTheCeilingAndRemembersIt() async {
        let helper = KeepAwakeFakeHelper(statuses: [.enabled])
        let prefs = Prefs()
        let model = makeModel(helper, prefs)
        let over = [(8, 0, 0), (0, 0, 11_520), (0, 192, 0), (Int.max, Int.max, Int.max)]
        for (d, h, m) in over {
            await model.arm(days: d, hours: h, minutes: m)
            XCTAssertNotEqual(model.failure, .invalidDuration, "\(d) \(h) \(m)")
            XCTAssertFalse(model.isWorking)
        }
        XCTAssertEqual(helper.requests, Array(repeating: .arm(seconds: 691_140, floorEnabled: true), count: over.count))
        XCTAssertEqual(prefs.remembered, Array(repeating: 11_519, count: over.count))
        // a negative field still asks nobody
        await model.arm(days: 0, hours: 0, minutes: Int.min)
        XCTAssertEqual(model.failure, .invalidDuration)
        XCTAssertEqual(helper.requests.count, over.count)
        XCTAssertEqual(prefs.remembered.count, over.count)
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
