import XCTest
@testable import Omelette

/// Liquid-glass spec § Design → Settings, "Menu bar: percentage mode, count down
/// remaining, providers shown in the menu bar, agents in the menu bar"
/// (`Settings-Menubar.dc.html`). The provider rules are 2.x General › Menu bar's.
final class MenuBarSettingsCopyTests: XCTestCase {
    private let claude = Fixture.snapshot(
        id: "claude", displayName: "Claude",
        buckets: [Fixture.bucket(id: "five_hour", label: "Current session", percent: 42, kind: .session)]
    )
    private let codex = Fixture.snapshot(
        id: "codex", displayName: "Codex",
        buckets: [Fixture.bucket(id: "primary", label: "5h", percent: 10, kind: .session)]
    )
    private let grokSpend = Fixture.snapshot(id: "grok", displayName: "Grok", buckets: [], weekCost: 3.2)
    private let silentAntigravity = Fixture.snapshot(
        id: "antigravity", displayName: "Antigravity", buckets: [], state: .notRunning
    )

    func testOnlyProvidersWithSomethingToShowCanTakeAPlace() {
        XCTAssertEqual(
            MenuBarSettingsCopy.candidates([claude, silentAntigravity, grokSpend]).map(\.id),
            ["claude", "grok"]
        )
    }

    func testTheLastVisibleProviderCannotBeHidden() {
        XCTAssertFalse(MenuBarSettingsCopy.canHide("claude", candidates: [claude, codex], hidden: ["codex"]))
    }

    func testAHiddenProviderCanAlwaysComeBack() {
        XCTAssertTrue(MenuBarSettingsCopy.canHide("codex", candidates: [claude, codex], hidden: ["codex"]))
    }

    func testWithTwoVisibleEitherCanBeHidden() {
        XCTAssertTrue(MenuBarSettingsCopy.canHide("claude", candidates: [claude, codex], hidden: []))
        XCTAssertTrue(MenuBarSettingsCopy.canHide("codex", candidates: [claude, codex], hidden: []))
    }

    func testAHiddenProviderThatNoLongerReportsDoesNotCountAsVisible() {
        XCTAssertFalse(MenuBarSettingsCopy.canHide("claude", candidates: [claude], hidden: ["gemini"]))
    }

    func testTheSwitchIsNamedForVoiceOverAsIn2x() {
        XCTAssertEqual(MenuBarSettingsCopy.switchLabel("Codex"), "Show Codex")
    }

    func testTheLogoIsTheProvidersAtTwentyPoints() {
        XCTAssertEqual(
            MenuBarSettingsCopy.logo(for: codex),
            SettingsLogo(serviceID: "codex", sfFallback: "sparkles", boxSize: 20, glyphSize: 15)
        )
    }

    func testTheRowsReadAsTheMockup() {
        XCTAssertEqual(MenuBarSettingsCopy.numbersHeader, "Numbers")
        XCTAssertEqual(MenuBarSettingsCopy.percentageTitle, "Show the percentage")
        XCTAssertEqual(MenuBarSettingsCopy.countDownTitle, "Count down remaining instead of used")
        XCTAssertEqual(
            MenuBarSettingsCopy.countDownCaption,
            "Everywhere: menu bar, popover, dashboard, widgets, CLI. Colours and alerts still follow what you used."
        )
        XCTAssertEqual(MenuBarSettingsCopy.providersHeader, "Providers in the menu bar")
        XCTAssertEqual(
            MenuBarSettingsCopy.providersFooter,
            "Hidden providers stay in the popover, widgets and notifications. The last one can't be hidden."
        )
        XCTAssertEqual(MenuBarSettingsCopy.providersEmpty, "Providers appear here once they report usage.")
        XCTAssertEqual(MenuBarSettingsCopy.agentsHeader, "Agents")
        XCTAssertEqual(MenuBarSettingsCopy.agentsTitle, "Show agents in the menu bar")
    }
}
