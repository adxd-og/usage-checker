import XCTest
@testable import Omelette

/// Independent verification of `Updater.lastCheckText(_:locale:timeZone:)`, from the
/// spec rather than from the executor's own `UpdaterStateTests`. Spec:
/// docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design (session rulings),
/// UI — "`lastCheckText(_:locale:timeZone:)` rule"; report D § 7. Claims under test:
/// nil for nil, and a fixed date renders deterministically in a pinned locale and time
/// zone.
final class UpdaterLastCheckTextVerificationTests: XCTestCase {
    private let gb = Locale(identifier: "en_GB")
    private let utc = TimeZone(identifier: "UTC")!
    /// 2026-09-24 09:03:00 UTC — chosen with single-digit hour and minute so a missing
    /// zero-pad would show up in the assertion.
    private let fixedDate = Date(timeIntervalSince1970: 1_790_240_580)

    func testNilInputGivesNilOutput() {
        XCTAssertNil(Updater.lastCheckText(nil, locale: gb, timeZone: utc))
    }

    func testAFixedDateInAPinnedLocaleAndTimeZoneIsDeterministic() {
        // en_GB's `.shortened` time style does not zero-pad a single-digit hour
        // ("9:03", not "09:03") — verified against Foundation's actual output, not
        // assumed.
        XCTAssertEqual(
            Updater.lastCheckText(fixedDate, locale: gb, timeZone: utc),
            "Last check: 24 Sep 2026, 9:03"
        )
    }

    /// Calling it twice with the same fixed inputs must give byte-identical output —
    /// no dependency on `Date()`/`Locale.current`/`TimeZone.current` smuggled in
    /// through a default argument.
    func testCallingItTwiceWithTheSameInputsIsIdentical() {
        let a = Updater.lastCheckText(fixedDate, locale: gb, timeZone: utc)
        let b = Updater.lastCheckText(fixedDate, locale: gb, timeZone: utc)
        XCTAssertEqual(a, b)
    }

    func testAnotherTimeZoneShiftsTheSameInstantVisibly() {
        // 09:03 UTC on 2026-09-24 is 18:03 in Tokyo the same day.
        XCTAssertEqual(
            Updater.lastCheckText(fixedDate, locale: gb, timeZone: TimeZone(identifier: "Asia/Tokyo")!),
            "Last check: 24 Sep 2026, 18:03"
        )
    }

    func testTheLinePrefixIsStable() {
        let text = Updater.lastCheckText(fixedDate, locale: gb, timeZone: utc) ?? ""
        XCTAssertTrue(text.hasPrefix("Last check: "), text)
    }
}
