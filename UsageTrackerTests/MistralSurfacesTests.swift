import XCTest
@testable import Omelette

/// Spec 2026-11-10 Mistral provider § Surfaces. Mistral is polled while its switch is on, and
/// listed in Settings › Providers after Grok with a switch. The Dashboard's picker offers it, and
/// its windows reach the island grid, the widget, `status.json` (version 2), `brioche status`,
/// the status line and MCP `get_usage` by the path every provider takes.
final class MistralSurfacesTests: XCTestCase {
    private let now = MistralFixture.now
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private let locale = Locale(identifier: "en_US")

    /// The live answer, through the provider's own rule.
    private func mistral() throws -> ServiceSnapshot {
        let entries = try MistralBillingFetcher.decodeBudget(Data(MistralFixture.budgetBody.utf8))
        return MistralProvider.snapshot(
            result: .success(MistralBilling(planName: "INDIVIDUAL", budget: .entries(entries))), now: now
        )
    }

    // MARK: - Polled and listed

    func testTheCoordinatorPollsMistralAndSettingsListsItLastWithASwitch() {
        XCTAssertTrue(ProviderCoordinator.serviceIDs.contains(MistralProvider.serviceID))
        XCTAssertEqual(ProvidersSettingsCopy.mistralID, MistralProvider.serviceID)
        XCTAssertEqual(ProvidersSettingsCopy.listed.last, ProvidersSettingsCopy.Provider(
            id: "mistral", name: "Mistral", source: "API key from the vibe CLI", sfFallback: "cat", hasSwitch: true
        ))
    }

    func testMistralIsListedAfterGrok() {
        let services = ProviderCoordinator.ordered(
            claude: Fixture.snapshot(id: "claude"), admin: nil, codex: Fixture.snapshot(id: "codex"),
            antigravity: Fixture.snapshot(id: "antigravity"), grok: Fixture.snapshot(id: "grok"),
            mistral: Fixture.snapshot(id: "mistral"), preferAdmin: false
        )
        XCTAssertEqual(services.map(\.id), ["claude", "codex", "antigravity", "grok", "mistral"])
    }

    func testItsSwitchDecidesWhetherItIsPolled() {
        XCTAssertEqual(
            AppState.polledServiceIDs(
                claudeEnabled: false, codexEnabled: false, antigravityEnabled: false, grokEnabled: false,
                mistralEnabled: true, hasAdminKey: false
            ),
            ["mistral"]
        )
        XCTAssertEqual(
            AppState.polledServiceIDs(
                claudeEnabled: true, codexEnabled: false, antigravityEnabled: false, grokEnabled: false,
                mistralEnabled: false, hasAdminKey: false
            ),
            ["claude"]
        )
        XCTAssertEqual(
            AppState.switchedOnIDs(
                polledIDs: [], claudeEnabled: false, codexEnabled: false, antigravityEnabled: false,
                grokEnabled: false, mistralEnabled: true
            ),
            ["mistral"]
        )
    }

    func testACoordinatorWithMistralOffAsksItNothing() async {
        let poll = await ProviderCoordinator().snapshot(
            adminKey: nil, betaHeader: "", preferAdmin: false,
            claudeEnabled: false, codexEnabled: false, antigravityEnabled: false, grokEnabled: false,
            mistralEnabled: false
        )
        XCTAssertTrue(poll.services.isEmpty, "\(poll.services.map(\.id))")
    }

    // MARK: - The Dashboard and the island

    func testTheDashboardOffersMistralsHistoryWhileItsSwitchIsOn() {
        XCTAssertEqual(DashboardState.availableServices(recorded: ["mistral"], snapshot: .empty, disabled: []), ["mistral"])
        XCTAssertEqual(
            DashboardState.availableServices(
                recorded: ["mistral"], snapshot: .empty, disabled: DashboardState.switchedOff(polled: ["claude"])
            ),
            []
        )
    }

    func testFiveProvidersMakeThreeRowsWithTheCostTileBesideMistral() {
        XCTAssertEqual(
            ProviderGridRules.grid(serviceIDs: ["claude", "codex", "antigravity", "grok", "mistral"], showsCostTile: true),
            ProviderGridRules.Grid(
                tileRows: [
                    [.provider("claude"), .provider("codex")],
                    [.provider("antigravity"), .provider("grok")],
                    [.provider("mistral"), .cost],
                ],
                costInLowerRow: false
            )
        )
    }

    // MARK: - The widget, the file and the terminal

    func testMistralsWindowsReachTheWidgetAsLimits() throws {
        let widget = try XCTUnwrap(WidgetBridge.widgetServices(from: [mistral()]).first)
        XCTAssertEqual(widget.name, "Mistral")
        XCTAssertEqual(widget.plan, "Pro")
        XCTAssertEqual(widget.buckets.map(\.id), ["mistral_vibe", "mistral_api"])
        XCTAssertEqual(widget.buckets.map(\.kind), ["weekly", "modelSpecific"])
        XCTAssertEqual(widget.headlineBucket?.id, "mistral_vibe")
    }

    func testBriocheStatusTheStatusLineAndGetUsageReadMistralsWindows() throws {
        let status = StatusFileWriter.build(services: [try mistral()], costs: [:], agents: .none, now: now)
        XCTAssertEqual(status.version, 2)
        let service = try XCTUnwrap(status.service(id: "mistral"))
        XCTAssertEqual(service.windows.map(\.id), ["mistral_vibe", "mistral_api"])
        let lines = StatusText.render(snapshot: status, now: now, calendar: utc, locale: locale)
        XCTAssertTrue(lines.contains("Vibe 6%"), lines)
        XCTAssertTrue(lines.contains("API 0%"), lines)
        let bar = StatusLineText.render(snapshot: status, provider: "mistral", now: now, colour: false)
        XCTAssertTrue(bar.hasPrefix("◐ 6%"), bar)
        let sentence = MCPSummary.serviceSentence(service, now: now, calendar: utc, locale: locale)
        XCTAssertTrue(sentence.hasPrefix("Mistral (Pro): vibe 6%"), sentence)
    }
}
