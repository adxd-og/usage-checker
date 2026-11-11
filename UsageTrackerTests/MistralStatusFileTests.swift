import XCTest
@testable import Omelette

/// Spec 2026-11-10 Mistral provider § Local usage (P2), Dollars and Sessions, and the P2 row of
/// § Packages: the poll's gather reads vibe's log, so `status.json` (version 2), the cost tile,
/// `brioche status` and the status line carry Mistral's today's and week's dollars and today's
/// tokens as an API-list-price equivalent (`≈`), and the file lists its week of chats. The
/// allowance caption stays Mistral's own count and never takes them in.
final class MistralStatusFileTests: XCTestCase {
    private var root: URL!
    /// 2026-11-06 18:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_793_988_000)
    private let locale = Locale(identifier: "en_US")
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MistralStatusFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for session in [
            VibeFixture.whole(), VibeFixture.pruned(), VibeFixture.repeated(),
            VibeFixture.noTotal(), VibeFixture.glm(), VibeFixture.medium(),
        ] {
            try VibeFixture.write(session, under: root)
        }
        MistralModelPricing.update(ModelsDevPricing.parseFamily(ModelsDevMistralFixture.root, provider: ModelsDevPricing.vibeFamily))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        MistralModelPricing.update([:])
    }

    private func vibe() -> VibeUsageAggregator {
        VibeUsageAggregator(rootURL: root, ledgerURL: nil, calendar: utc)
    }

    /// The live billing answer, through P1's rule.
    private func mistral() throws -> ServiceSnapshot {
        let entries = try MistralBillingFetcher.decodeBudget(Data(MistralFixture.budgetBody.utf8))
        return MistralProvider.snapshot(
            result: .success(MistralBilling(planName: "INDIVIDUAL", budget: .entries(entries))), now: now
        )
    }

    func testGatherReadsMistralsTodayWeekAndTokensFromVibesLog() async {
        let gathered = await StatusCosts.gather(serviceIDs: ["mistral"], now: now, vibe: vibe())
        let entry = gathered.costs["mistral"]
        // 21 925.96 + 146 955.06 + 3 056.34 + 2 121.88 + 6 505.50 = 180 564.74 per million (Task 8's table)
        XCTAssertEqual(entry?.todayCost ?? 0, 0.180_564_74, accuracy: 1e-9)
        XCTAssertEqual(entry?.weekCost ?? 0, 0.180_564_74, accuracy: 1e-9)
        XCTAssertEqual(entry?.todayTokens, 885_057, "66 132 + 797 997 + 6 997 + 6 866 + 7 065")
    }

    func testGatherListsMistralsChatsOfTheLastSevenDaysAndCutsNoShare() async {
        let gathered = await StatusCosts.gather(serviceIDs: ["mistral"], now: now, vibe: vibe())
        XCTAssertEqual(
            Set(gathered.sessions["mistral"]?.map(\.id) ?? []),
            [VibeFixture.whole().id, VibeFixture.pruned().id, VibeFixture.repeated().id, VibeFixture.glm().id, VibeFixture.medium().id]
        )
        XCTAssertNil(gathered.shares["mistral"], "the Limits tab's shares stay Claude's and Codex's")
    }

    func testStatusJSONCarriesThemAsAnAPIEquivalentWithEachChatsFolder() async throws {
        let gathered = await StatusCosts.gather(serviceIDs: ["mistral"], now: now, vibe: vibe())
        let file = StatusFileWriter.build(
            services: [try mistral()], costs: gathered.costs, sessions: gathered.sessions,
            agents: .none, now: now, calendar: utc, locale: locale
        )
        XCTAssertEqual(file.version, 2)
        let service = try XCTUnwrap(file.service(id: "mistral"))
        XCTAssertEqual(service.apiEquivalent, true)
        XCTAssertEqual(service.todayTokens, 885_057)
        let chats = try XCTUnwrap(service.sessions)
        XCTAssertEqual(chats.count, 5)
        let pruned = try XCTUnwrap(chats.first { $0.id == VibeFixture.pruned().id })
        XCTAssertEqual(pruned.title, "Fixture title")
        XCTAssertEqual(pruned.project, "Vibe Fixtures / movie app")
        XCTAssertEqual(pruned.turns, 2)
        XCTAssertEqual(pruned.tokens, 797_997)
        XCTAssertEqual(pruned.cost ?? 0, 0.146_955_06, accuracy: 1e-9, "86 756.60 + 46 735.36 + 13 463.10 per million")
        XCTAssertEqual(pruned.agents, 0)
        XCTAssertNil(pruned.origin)
    }

    func testTheStatusLineMarksThemApproximateAndTheAllowanceNeverTakesThemIn() async throws {
        let gathered = await StatusCosts.gather(serviceIDs: ["mistral"], now: now, vibe: vibe())
        let snapshot = try mistral()
        let file = StatusFileWriter.build(
            services: [snapshot], costs: gathered.costs, sessions: gathered.sessions,
            agents: .none, now: now, calendar: utc, locale: locale
        )
        let service = try XCTUnwrap(file.service(id: "mistral"))
        XCTAssertEqual(StatusLineText.todayCostText(service), "≈$0.18 today")
        XCTAssertEqual(
            AllowanceCopy.caption(for: snapshot, locale: locale),
            "Vibe: $17.88 of the $300 monthly allowance\nAPI: $0.00 of the $30 monthly allowance"
        )
    }
}
