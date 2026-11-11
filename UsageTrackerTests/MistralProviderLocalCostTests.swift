import XCTest
@testable import Omelette

/// Spec 2026-11-10 Mistral provider § Local usage (P2), Dollars: the week's API-list-price
/// dollars from vibe's log ride Mistral's snapshot, as Grok's do, on every answer billing gives,
/// a failed one too, and the provider page captions them API-equivalent. A provider a test builds
/// reads no log (plan R13).
final class MistralProviderLocalCostTests: XCTestCase {
    private typealias Answer = MistralFixture.Answer
    private let now = MistralFixture.now

    /// The moments the provider asked the log for, in order.
    private actor Asked {
        var moments: [Date] = []
        func add(_ moment: Date) { moments.append(moment) }
    }

    private func envFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MistralProviderLocalCostTests-\(UUID().uuidString)/.env")
    }

    private func provider(
        key: String? = MistralFixture.key,
        budget: Answer? = Answer(status: 200, body: MistralFixture.budgetBody),
        weekCost: Double,
        asked: Asked? = nil
    ) -> MistralProvider {
        MistralProvider(
            credentials: MistralCredentialReader(keychain: { key }, envFileURL: envFile()),
            fetcher: MistralBillingFetcher(transport: MistralFixture.transport(budget: budget)),
            weekCost: { moment in
                await asked?.add(moment)
                return weekCost
            }
        )
    }

    func testTheWeeksLocalDollarsRideAHealthyAnswerAsOfThePoll() async {
        let asked = Asked()
        // The fixture day's dollars (Task 8): 21 925.96 + 146 955.06 + 3 056.34 + 2 121.88 + 6 505.50 per million.
        let snapshot = await provider(weekCost: 0.180_564_74, asked: asked).fetch(now: now)
        XCTAssertEqual(snapshot.state, .ok)
        XCTAssertEqual(snapshot.buckets.map(\.id), ["mistral_vibe", "mistral_api"])
        XCTAssertEqual(snapshot.weekCost ?? 0, 0.180_564_74, accuracy: 1e-12)
        let moments = await asked.moments
        XCTAssertEqual(moments, [now])
        XCTAssertEqual(ProviderGridRules.spendCaption(for: snapshot), CostCopy.apiEquivalent)
    }

    func testTheyRideEveryFailedAnswerToo() async {
        let failures: [(String, MistralProvider)] = [
            ("no key", provider(key: nil, weekCost: 3.9)),
            ("401", provider(budget: Answer(status: 401, body: "{}"), weekCost: 3.9)),
            ("403", provider(budget: Answer(status: 403, body: "{}"), weekCost: 3.9)),
            ("503", provider(budget: Answer(status: 503, body: ""), weekCost: 3.9)),
            ("offline", provider(budget: nil, weekCost: 3.9)),
        ]
        for (name, mistral) in failures {
            let snapshot = await mistral.fetch(now: now)
            XCTAssertNotEqual(snapshot.state, .ok, name)
            XCTAssertEqual(snapshot.weekCost, 3.9, name)
        }
    }

    func testNothingSpentIsNoFigureAndATestBuiltProviderReadsNoLog() async {
        let spentNothing = await provider(weekCost: 0).fetch(now: now)
        XCTAssertNil(spentNothing.weekCost)
        let bare = MistralProvider(
            credentials: MistralCredentialReader(keychain: { nil }, envFileURL: envFile()),
            fetcher: MistralBillingFetcher(transport: MistralFixture.transport())
        )
        let unread = await bare.fetch(now: now)
        XCTAssertNil(unread.weekCost)
    }
}
