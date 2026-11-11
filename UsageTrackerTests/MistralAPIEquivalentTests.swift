import XCTest
@testable import Omelette

/// Spec 2026-11-10 Mistral provider § Local usage (P2), Dollars; plan R17 (review finding 2): the
/// dollars from vibe's log are an API-list-price equivalent always, whatever windows Mistral
/// reports. With no key, a 403, a 404, no `_budget` or a Free plan Mistral shows no window, which
/// the pay-as-you-go rules read as a bill; for `mistral` they never do, at every surface. No
/// other provider's answer moves.
final class MistralAPIEquivalentTests: XCTestCase {
    /// 2026-11-06 18:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_793_988_000)
    private let locale = Locale(identifier: "en_US")
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// Mistral with a week of vibe dollars and no window, in each way that happens.
    private var windowless: [(String, ServiceSnapshot)] {
        [
            ("no key", Fixture.snapshot(id: "mistral", displayName: "Mistral", icon: "cat", plan: nil, weekCost: 3.9, state: .notSignedIn, at: now)),
            ("403", Fixture.snapshot(id: "mistral", displayName: "Mistral", icon: "cat", plan: "Pro", weekCost: 3.9, state: .error, at: now)),
            ("404 or no _budget", Fixture.snapshot(id: "mistral", displayName: "Mistral", icon: "cat", plan: "Pro", weekCost: 3.9, state: .ok, at: now)),
            ("Free plan with no window", Fixture.snapshot(id: "mistral", displayName: "Mistral", icon: "cat", plan: "Free", weekCost: 3.9, state: .ok, at: now)),
        ]
    }

    private func fileEntry(_ service: ServiceSnapshot) -> StatusSnapshot.Service? {
        StatusFileWriter.build(
            services: [service],
            costs: [service.id: StatusFileWriter.CostEntry(todayCost: 0.18, weekCost: 3.9, todayTokens: 885_057)],
            agents: .none, now: now, calendar: utc, locale: locale
        ).service(id: service.id)
    }

    func testMistralsLocalDollarsAreNeverTheBillWhateverWindowsItShows() {
        XCTAssertEqual(CostCopy.alwaysAPIEquivalent, ["mistral"])
        for (name, service) in windowless {
            XCTAssertFalse(CostCopy.isPayAsYouGo(service), name)
            XCTAssertFalse(StatusFileWriter.isPayAsYouGo(service), name)
            XCTAssertEqual(fileEntry(service)?.apiEquivalent, true, "status.json, \(name)")
        }
    }

    func testBriocheStatusTheStatusLineAndMCPSayAPIEquivalent() throws {
        let chat = StatusSnapshot.SessionEntry(
            id: "vibe-chat", title: "Fixture title", project: "Vibe Fixtures / probe",
            lastAt: now, turns: 6, tokens: 66_132, cost: 0.02, agents: 0
        )
        for (name, service) in windowless {
            let entry = try XCTUnwrap(fileEntry(service), name)
            XCTAssertEqual(StatusText.costParts(entry), ["$0.18 today", "$3.90 this week (API-equivalent)"], name)
            XCTAssertEqual(StatusLineText.todayCostText(entry), "≈$0.18 today", name)
            XCTAssertTrue(
                MCPSummary.serviceSentence(entry, now: now, calendar: utc, locale: locale)
                    .contains("(API-equivalent, not a subscription bill)"),
                name
            )
            XCTAssertEqual(MCPSummary.sessionsQualifier([(service: entry, session: chat)]), MCPSummary.sessionsCostQualifier, name)
        }
    }

    func testTheIslandTheDashboardAndTheWidgetSayItToo() {
        for (name, service) in windowless {
            XCTAssertEqual(ProviderGridRules.spendCaption(for: service), CostCopy.apiEquivalent, "island page, \(name)")
            XCTAssertEqual(
                OMCostTile.caption(services: [service], today: ["mistral": 0.18], week: ["mistral": 3.9]),
                CostCopy.apiEquivalent, "cost tile, \(name)"
            )
            XCTAssertEqual(CostCopy.apiEquivalentCaption(for: service), CostCopy.apiEquivalent, "Overview, \(name)")
            XCTAssertEqual(
                HistoryCopy.subtitle(
                    showsQuota: false, providerName: "Mistral", sourceName: "the vibe CLI's session logs",
                    isPayAsYouGo: CostCopy.isPayAsYouGo(service)
                ),
                "API-equivalent cost from the vibe CLI's session logs, not your subscription bill", "History, \(name)"
            )
            XCTAssertEqual(
                InsightsRules.footnote(
                    costSource: .log(shortName: "Vibe CLI", longName: "the vibe CLI's session logs"), service: service
                ),
                CostCopy.apiEquivalent, "Insights, \(name)"
            )
            XCTAssertEqual(WidgetBridge.widgetServices(from: [service]).first?.spendLabel, "≈$3.90 last 7 days", "widget, \(name)")
        }
    }

    func testNoOtherProvidersAnswerChanges() {
        let claude = Fixture.snapshot(id: "claude", plan: nil, weekCost: 3.9, state: .ok, at: now)
        let codex = Fixture.snapshot(id: "codex", plan: nil, weekCost: 3.9, state: .ok, at: now)
        let grokSignedOut = Fixture.snapshot(id: "grok", plan: nil, weekCost: 3.9, state: .notSignedIn, at: now)
        for service in [claude, codex] {
            XCTAssertTrue(CostCopy.isPayAsYouGo(service), service.id)
            XCTAssertTrue(StatusFileWriter.isPayAsYouGo(service), service.id)
            XCTAssertNil(ProviderGridRules.spendCaption(for: service), service.id)
            XCTAssertEqual(WidgetBridge.widgetServices(from: [service]).first?.spendLabel, "$3.90 last 7 days", service.id)
        }
        XCTAssertFalse(CostCopy.isPayAsYouGo(grokSignedOut))
        XCTAssertTrue(StatusFileWriter.isPayAsYouGo(grokSignedOut), "the file's rule for a signed-out Grok is as it was")
        XCTAssertEqual(WidgetBridge.widgetServices(from: [grokSignedOut]).first?.spendLabel, "$3.90 last 7 days")
    }
}
