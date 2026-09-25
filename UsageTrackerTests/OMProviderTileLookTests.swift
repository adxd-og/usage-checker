import XCTest
@testable import Omelette

/// Liquid-glass redesign spec § Screens, "Popover · All": "2×2 tiles kept, restyled;
/// plan on its own line so nothing truncates", § Principles 2: "No tinted chips under
/// text. State is coloured text". Values from `Main.dc.html`.
final class OMProviderTileLookTests: XCTestCase {
    private let session = Fixture.bucket(id: "five_hour", label: "Current session", percent: 57, kind: .session)
    private let weekly = Fixture.bucket(id: "seven_day", label: "All models", percent: 41, kind: .weekly)

    func testATileShortensItsWindowsToSessionAndWeek() {
        XCTAssertEqual(OMProviderTile.shortLabel(for: session), "Session")
        XCTAssertEqual(OMProviderTile.shortLabel(for: weekly), "Week")
        XCTAssertEqual(OMProviderTile.shortLabel(for: Fixture.bucket(id: "seven_day_opus", label: "Opus only", kind: .modelSpecific)), "Opus")
        XCTAssertEqual(OMProviderTile.shortLabel(for: Fixture.bucket(id: "grok_credits", label: "Credits")), "Credits")
    }

    func testALiveTilePutsItsPlanOnItsOwnLine() {
        let claude = Fixture.snapshot(id: "claude", displayName: "Claude", plan: "Max 20x", buckets: [session, weekly])
        let codex = Fixture.snapshot(id: "codex", displayName: "Codex", plan: "Codex Plus", buckets: [weekly])
        XCTAssertEqual(OMProviderTile.subtitle(for: claude), OMColoredText(text: "Max 20x", token: .secondary))
        XCTAssertEqual(OMProviderTile.subtitle(for: codex), OMColoredText(text: "Plus", token: .secondary))
    }

    /// Task 10's Enterprise fixture: no windows, an enabled spend limit. `WindowRanking`
    /// makes the limit its hero, so the tile draws a ring and names the plan — not
    /// "No data".
    func testASpendLimitAccountShowsItsPlanNotNoData() {
        let extra = ExtraUsage(isEnabled: true, monthlyLimit: 1500, usedCredits: 431.26, utilization: 28.75)
        let service = Fixture.snapshot(id: "claude", displayName: "Claude", plan: "Enterprise", extraUsage: extra)
        XCTAssertNotNil(WindowRanking.detailHero(for: service))
        XCTAssertEqual(OMProviderTile.subtitle(for: service), OMColoredText(text: "Enterprise", token: .secondary))
    }

    func testATileThatIsNotLiveSaysItsStateInColourInsteadOfAChip() {
        let closed = Fixture.snapshot(id: "antigravity", displayName: "Antigravity", plan: "Antigravity Pro",
                                      buckets: [session], state: .notRunning)
        let signedOut = Fixture.snapshot(id: "codex", displayName: "Codex", buckets: [], state: .notSignedIn)
        let failed = Fixture.snapshot(id: "grok", displayName: "Grok", buckets: [], state: .error)
        let empty = Fixture.snapshot(id: "claude", displayName: "Claude", buckets: [])
        XCTAssertEqual(OMProviderTile.subtitle(for: closed), OMColoredText(text: "Not running", token: .secondary))
        XCTAssertEqual(OMProviderTile.subtitle(for: signedOut), OMColoredText(text: "Sign in", token: .warning))
        XCTAssertEqual(OMProviderTile.subtitle(for: failed), OMColoredText(text: "Error", token: .critical))
        XCTAssertEqual(OMProviderTile.subtitle(for: empty), OMColoredText(text: "No data", token: .secondary))
    }

    func testTheBarUnderTheRingIsLabelledWeekWithItsFigure() {
        XCTAssertEqual(OMProviderTile.secondaryLine(weekly, mode: .used), OMTileCaption(title: "Week", value: "41%"))
        XCTAssertEqual(OMProviderTile.secondaryLine(weekly, mode: .remaining), OMTileCaption(title: "Week", value: "59%"))
    }

    func testTheRingsLabelIsSessionOnALiveTile() throws {
        let claude = Fixture.snapshot(id: "claude", displayName: "Claude", buckets: [session, weekly])
        let hero = try XCTUnwrap(WindowRanking.tileHero(for: claude))
        XCTAssertEqual(OMProviderTile.heroCaption(for: claude, hero: hero).title, "Session")
    }

    func testARetainedPayAsYouGoTileDatesItsDollars() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let at = calendar.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 12, minute: 50))!
        let live = Fixture.snapshot(id: "grok", displayName: "Grok", weekCost: 6.41, at: at)
        var retained = Fixture.snapshot(id: "grok", displayName: "Grok", weekCost: 6.41, state: .error, at: at)
        retained.isCarriedOver = true
        XCTAssertEqual(OMProviderTile.spendTitle(for: live), "Last 7 days")
        XCTAssertEqual(
            OMProviderTile.spendTitle(for: retained, now: at.addingTimeInterval(3600), calendar: calendar,
                                      locale: Locale(identifier: "en_GB")),
            "Last 7 days · as of 12:50"
        )
    }

    func testTheTileIsTheMockupsTile() {
        XCTAssertEqual(OMProviderTile.surface, .tile)
        XCTAssertEqual(OMProviderTile.padding, 12)
        XCTAssertEqual(OMProviderTile.sectionSpacing, 11)
        XCTAssertEqual(OMProviderTile.logoSize, 22)
        XCTAssertEqual(OMProviderTile.nameSize, 13)
        XCTAssertEqual(OMProviderTile.subtitleSize, 11)
        XCTAssertEqual(OMProviderTile.barHeight, 4)
        XCTAssertEqual(OMProviderTile.retainedOpacity, 0.55)
    }

    func testTheAllTabLaysTilesTwoARow() {
        let services = ["claude", "codex", "antigravity", "grok", "gemini"].map { Fixture.snapshot(id: $0) }
        XCTAssertEqual(PopoverView.tileRows(Array(services.prefix(4))).map { $0.map(\.id) },
                       [["claude", "codex"], ["antigravity", "grok"]])
        XCTAssertEqual(PopoverView.tileRows(services).map { $0.map(\.id) },
                       [["claude", "codex"], ["antigravity", "grok"], ["gemini"]])
        XCTAssertTrue(PopoverView.tileRows([]).isEmpty)
        XCTAssertEqual(PopoverView.tileSpacing, 10)
    }
}
