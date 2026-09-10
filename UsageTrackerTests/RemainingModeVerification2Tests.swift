import XCTest
@testable import Omelette

/// Independent verification of P4, part 2: the surfaces that read `PercentDisplay`
/// through their own tested rule — menu bar, tooltip, provider tile, hero, ring row,
/// floating window, and Settings' own summary rows. Spec §§ "Surfaces that switch",
/// "Copy", Decision 5 (menu-bar tooltip wording verbatim).
final class RemainingModeVerification2Tests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_GB")
        return c
    }
    private let locale = Locale(identifier: "en_GB")
    /// Sunday 2026-09-06 11:20 UTC.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: 11, minute: 20))!
    }

    // MARK: - MenuBarLabel.text — Decision 5, verbatim

    /// Spec Decision 5: `"Claude usage 37%"` becomes `"Claude 63% left"`.
    func testMenuBarTextHealthyServiceMatchesTheSpecVerbatim() {
        let service = Fixture.snapshot(
            id: "claude", displayName: "Claude",
            buckets: [Fixture.bucket(id: "five_hour", percent: 37, kind: .session)]
        )
        XCTAssertEqual(MenuBarLabel.text(for: service, mode: .used), "Claude usage 37%")
        XCTAssertEqual(MenuBarLabel.text(for: service, mode: .remaining), "Claude 63% left")
    }

    /// Spec Decision 5: the retained form keeps its shape and takes the phrase —
    /// `"Antigravity: last known 62% (as of …) — Not running"` becomes `"… 38%
    /// left …"`. The stamp and chip text are cross-checked against their own rules
    /// rather than hardcoded, so this test is about the phrase substitution only.
    func testMenuBarTextRetainedServiceKeepsItsShapeAndSwitchesOnlyThePhrase() {
        let fetchedAt = calendar.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: 9, minute: 5))!
        let service = Fixture.snapshot(
            id: "antigravity", displayName: "Antigravity",
            buckets: [Fixture.bucket(id: "quota", percent: 62, kind: .other)],
            state: .notRunning, at: fetchedAt
        )
        let stamp = RelativeStamp.asOf(fetchedAt, now: now, calendar: calendar, locale: locale)
        let chip = RetainedCopy.chipText(for: .notRunning)

        XCTAssertEqual(
            MenuBarLabel.text(for: service, mode: .used, now: now, calendar: calendar, locale: locale),
            "Antigravity: last known 62% (as of \(stamp)) — \(chip)"
        )
        XCTAssertEqual(
            MenuBarLabel.text(for: service, mode: .remaining, now: now, calendar: calendar, locale: locale),
            "Antigravity: last known 38% left (as of \(stamp)) — \(chip)"
        )
    }

    // MARK: - StatusBarController.tooltipText

    func testTooltipTextSwitchesEveryWindowLineForAHealthyService() {
        let claude = Fixture.snapshot(
            id: "claude", displayName: "Claude", plan: "Max 5x",
            buckets: [
                Fixture.bucket(id: "five_hour", label: "Session", percent: 42, kind: .session),
                Fixture.bucket(id: "seven_day", label: "All models", percent: 18, kind: .weekly),
            ]
        )
        let snapshot = UsageSnapshot(services: [claude], fetchedAt: now, isStale: false, lastError: nil)

        let used = StatusBarController.tooltipText(snapshot: snapshot, mode: .used, now: now, calendar: calendar, locale: locale)
        let remaining = StatusBarController.tooltipText(snapshot: snapshot, mode: .remaining, now: now, calendar: calendar, locale: locale)

        XCTAssertTrue(used.contains("Session: 42%"), used)
        XCTAssertTrue(used.contains("All models: 18%"), used)
        XCTAssertTrue(remaining.contains("Session: 58% left"), remaining)
        XCTAssertTrue(remaining.contains("All models: 82% left"), remaining)
    }

    /// Plan row 9: "which windows appear … unchanged — visibility is a question
    /// about usage." An untouched window (0% used) must stay hidden in remaining
    /// mode too, even though it would show as "100% left".
    func testTooltipTextHidesAnUntouchedNonSessionWindowInBothModes() {
        let service = Fixture.snapshot(
            id: "gemini", displayName: "Gemini", plan: "Pro",
            buckets: [
                Fixture.bucket(id: "seven_day_opus", label: "Opus only", percent: 0, kind: .modelSpecific),
                Fixture.bucket(id: "seven_day", label: "All models", percent: 30, kind: .weekly),
            ]
        )
        let snapshot = UsageSnapshot(services: [service], fetchedAt: now, isStale: false, lastError: nil)

        let remaining = StatusBarController.tooltipText(snapshot: snapshot, mode: .remaining, now: now, calendar: calendar, locale: locale)

        XCTAssertFalse(remaining.contains("Opus only"), "an untouched window must not appear just because remaining mode would show it as full")
        XCTAssertTrue(remaining.contains("All models: 70% left"), remaining)
    }

    func testTooltipTextRetainedBlockUsesMenuBarLabelTextUnderTheHood() {
        let fetchedAt = calendar.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: 8, minute: 0))!
        let service = Fixture.snapshot(
            id: "codex", displayName: "Codex",
            buckets: [Fixture.bucket(id: "five_hour", percent: 80, kind: .session)],
            state: .error, at: fetchedAt
        )
        let snapshot = UsageSnapshot(services: [service], fetchedAt: now, isStale: false, lastError: nil)

        let remaining = StatusBarController.tooltipText(snapshot: snapshot, mode: .remaining, now: now, calendar: calendar, locale: locale)
        let expectedHeader = MenuBarLabel.text(for: service, mode: .remaining, now: now, calendar: calendar, locale: locale)
        XCTAssertTrue(remaining.contains(expectedHeader), remaining)
    }

    func testTooltipTextIsLoadingWhenThereIsNoServiceRegardlessOfMode() {
        let empty = UsageSnapshot(services: [], fetchedAt: now, isStale: true, lastError: nil)
        XCTAssertEqual(StatusBarController.tooltipText(snapshot: empty, mode: .used), "Omelette — loading…")
        XCTAssertEqual(StatusBarController.tooltipText(snapshot: empty, mode: .remaining), "Omelette — loading…")
    }

    // MARK: - OMProviderTile.accessibilityText

    func testProviderTileAccessibilityTextSwitchesTheNumberAndKeepsTheRetainedWord() {
        let hero = Fixture.bucket(id: "five_hour", label: "Session", percent: 62, kind: .session)
        let service = Fixture.snapshot(id: "claude", displayName: "Claude", buckets: [hero])

        XCTAssertEqual(
            OMProviderTile.accessibilityText(for: service, hero: hero, mode: .used),
            "Claude, Session 62 percent used"
        )
        XCTAssertEqual(
            OMProviderTile.accessibilityText(for: service, hero: hero, mode: .remaining),
            "Claude, Session 38 percent left"
        )
    }

    func testProviderTileAccessibilityTextWithNoHeroIgnoresModeEntirely() {
        let service = Fixture.snapshot(id: "gemini", displayName: "Gemini", buckets: [], state: .notSignedIn)
        let used = OMProviderTile.accessibilityText(for: service, hero: nil, mode: .used)
        let remaining = OMProviderTile.accessibilityText(for: service, hero: nil, mode: .remaining)
        XCTAssertEqual(used, remaining)
        XCTAssertEqual(used, "Gemini, Sign in")
    }

    // MARK: - OMHero — the wording stays on used, only the number moves

    func testHeroAccessibilityTextKeepsTheStatusPhraseAndSwitchesTheNumber() {
        let hero = Fixture.bucket(id: "five_hour", label: "Session", percent: 92, kind: .session)
        XCTAssertEqual(
            OMHero.accessibilityText(for: hero, mode: .used),
            "Session, 92 percent used, Almost at the limit"
        )
        XCTAssertEqual(
            OMHero.accessibilityText(for: hero, mode: .remaining),
            "Session, 8 percent left, Almost at the limit"
        )
    }

    // MARK: - OMRingRow — the empty-window hint survives the mode switch

    func testRingRowAccessibilityLabelSwitchesTheNumberForAUsedWindow() {
        let bucket = Fixture.bucket(id: "seven_day", label: "All models", percent: 74, kind: .weekly)
        XCTAssertEqual(
            OMRingRow.accessibilityLabel(for: bucket, mode: .used),
            "All models, 74 percent used"
        )
        XCTAssertEqual(
            OMRingRow.accessibilityLabel(for: bucket, mode: .remaining),
            "All models, 26 percent left"
        )
    }

    /// An untouched window explains itself instead of repeating "0%" — and that
    /// hint must not turn into "you have all of it left" in remaining mode.
    func testRingRowAccessibilityLabelKeepsTheEmptyHintTitleInRemainingMode() {
        let bucket = Fixture.bucket(id: "seven_day_opus", label: "Opus only", percent: 0, kind: .modelSpecific)
        let remaining = OMRingRow.accessibilityLabel(for: bucket, mode: .remaining)
        XCTAssertTrue(remaining.hasPrefix("You haven't used Opus yet"), remaining)
        XCTAssertTrue(remaining.hasSuffix("100 percent left"), remaining)
    }

    // MARK: - FloatingMiniLayout

    func testFloatingMiniRowAndHeroAccessibilitySwitchWithMode() {
        let bucket = Fixture.bucket(id: "seven_day", label: "All models", percent: 24, kind: .weekly)
        XCTAssertEqual(FloatingMiniLayout.rowPercentText(bucket, mode: .used), "24%")
        XCTAssertEqual(FloatingMiniLayout.rowPercentText(bucket, mode: .remaining), "76%")
        XCTAssertEqual(
            FloatingMiniLayout.rowAccessibilityLabel(bucket, mode: .remaining),
            "All models, 76 percent left"
        )
        XCTAssertEqual(
            FloatingMiniLayout.heroAccessibilityLabel(bucket, mode: .used),
            "All models, 24 percent used"
        )
    }

    // MARK: - SettingsView.usageSummary — independent fixtures from the executor's

    func testSettingsUsageSummarySwitchesNumbersButNotWhichWindowsAreNamed() {
        let service = Fixture.snapshot(
            id: "claude",
            buckets: [
                Fixture.bucket(id: "five_hour", label: "Current session", percent: 71, kind: .session),
                Fixture.bucket(id: "seven_day", label: "All models", percent: 9, kind: .weekly),
            ]
        )
        XCTAssertEqual(SettingsView.usageSummary(service, mode: .used), "Session 71% · Week 9%")
        XCTAssertEqual(SettingsView.usageSummary(service, mode: .remaining), "Session 29% · Week 91%")
    }
}
