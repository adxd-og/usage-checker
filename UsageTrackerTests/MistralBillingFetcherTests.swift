import XCTest
@testable import Omelette

/// Spec 2026-11-10 Mistral provider § Fetch, § Windows and § States: the two billing GETs go
/// out at once, 10 s each, with the key in the `Authorization` header only. A failed
/// `/subscription` leaves the plan empty and never fails the answer. `/budget` decides:
/// its `_budget` entries (each with a numeric `usage_percentage`), no usage access on 403,
/// no billing on 404, signed out on 401, its Retry-After on 429, an error otherwise.
final class MistralBillingFetcherTests: XCTestCase {
    private typealias Answer = MistralFixture.Answer

    private func fetch(
        subscription: Answer? = Answer(status: 200, body: MistralFixture.subscriptionBody),
        budget: Answer? = Answer(status: 200, body: MistralFixture.budgetBody),
        requests: MistralFixture.Requests? = nil
    ) async -> Result<MistralBilling, MistralBillingError> {
        let transport = MistralFixture.transport(subscription: subscription, budget: budget, requests: requests)
        return await MistralBillingFetcher(transport: transport).fetch(apiKey: MistralFixture.key)
    }

    private func entries(_ result: Result<MistralBilling, MistralBillingError>) -> [MistralBudgetEntry]? {
        guard case .success(let billing) = result, case .entries(let entries) = billing.budget else { return nil }
        return MistralBudgetRules.ordered(entries)
    }

    func testTheLiveAnswersAreThePlanAndTheTwoBudgets() async {
        let result = await fetch()
        guard case .success(let billing) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(billing.planName, "INDIVIDUAL")
        XCTAssertEqual(entries(result), [
            MistralBudgetEntry(
                key: "vibe_budget", usagePercentage: 5.9597507033333335, initialBudget: 300, currency: "USD",
                resetAt: MistralFixture.resetAt
            ),
            MistralBudgetEntry(
                key: "api_budget", usagePercentage: 0, initialBudget: 30, currency: "USD", resetAt: MistralFixture.resetAt
            ),
        ], "the top-level fields repeat api_budget and are no window of their own")
    }

    func testBothCallsCarryTheKeyInTheAuthorizationHeaderAndNowhereElse() async {
        let requests = MistralFixture.Requests()
        _ = await fetch(requests: requests)
        let seen = await requests.seen
        XCTAssertEqual(Set(seen.compactMap(\.url?.absoluteString)), [
            "https://api.mistral.ai/v1/billing/subscription", "https://api.mistral.ai/v1/billing/budget",
        ])
        for request in seen {
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(MistralFixture.key)")
            XCTAssertEqual(request.timeoutInterval, 10)
            XCTAssertFalse(request.url?.absoluteString.contains(MistralFixture.key) ?? true)
        }
    }

    private actor Arrivals {
        private(set) var count = 0
        private(set) var sawBoth: [Bool] = []
        func arrive() { count += 1 }
        func record(_ both: Bool) { sawBoth.append(both) }
    }

    /// Plan review finding 1: `URLSession.shared` stores a cacheable answer on disk with its
    /// request, the `Authorization` header included. The live session has nowhere to store one.
    func testTheLiveSessionHasNoURLCacheCookieOrCredentialStore() {
        let configuration = MistralBillingFetcher.session.configuration
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testTheTwoCallsRunAtOnce() async {
        let arrivals = Arrivals()
        let answers = MistralFixture.transport()
        let fetcher = MistralBillingFetcher(transport: { request in
            await arrivals.arrive()
            // Up to two seconds for the other call to arrive. Run one after the other, the first
            // waits alone, and the test fails instead of hanging.
            var waited = 0
            while await arrivals.count < 2, waited < 200 {
                try await Task.sleep(nanoseconds: 10_000_000)
                waited += 1
            }
            let both = await arrivals.count >= 2
            await arrivals.record(both)
            return try await answers(request)
        })
        _ = await fetcher.fetch(apiKey: MistralFixture.key)
        let sawBoth = await arrivals.sawBoth
        XCTAssertEqual(sawBoth, [true, true])
    }

    func testAFailedSubscriptionLeavesThePlanEmptyAndTheBudgetStands() async {
        let failures: [Answer?] = [Answer(status: 500, body: ""), Answer(status: 200, body: "not json"), nil]
        for subscription in failures {
            let result = await fetch(subscription: subscription)
            guard case .success(let billing) = result else { return XCTFail("\(String(describing: subscription))") }
            XCTAssertNil(billing.planName)
            XCTAssertEqual(entries(result)?.map(\.key), ["vibe_budget", "api_budget"])
        }
    }

    func testA403IsNoUsageAccessAndA404IsNoBillingWithThePlanKept() async {
        let cases: [(Int, MistralBilling.Budget)] = [(403, .noUsageAccess), (404, .noBilling)]
        for (status, budget) in cases {
            let result = await fetch(budget: Answer(status: status, body: #"{"detail":"x"}"#))
            XCTAssertEqual(result, .success(MistralBilling(planName: "INDIVIDUAL", budget: budget)), "\(status)")
        }
    }

    func testA401IsSignedOut() async {
        let result = await fetch(budget: Answer(status: 401, body: "{}"))
        XCTAssertEqual(result, .failure(.unauthorized))
    }

    func testA429CarriesItsRetryAfter() async {
        let stated = await fetch(budget: Answer(status: 429, body: "{}", headers: ["Retry-After": "30"]))
        XCTAssertEqual(stated, .failure(.rateLimited(retryAfter: 30)))
        let unstated = await fetch(budget: Answer(status: 429, body: "{}"))
        XCTAssertEqual(unstated, .failure(.rateLimited(retryAfter: nil)))
    }

    func testAServerErrorIsABadStatusAndANetworkFailureATransportError() async {
        let server = await fetch(budget: Answer(status: 503, body: "busy"))
        XCTAssertEqual(server, .failure(.badStatus(503)))
        let offline = await fetch(budget: nil)
        guard case .failure(.transport(let words)) = offline else { return XCTFail("\(offline)") }
        XCTAssertFalse(words.isEmpty)
        XCTAssertFalse(words.contains(MistralFixture.key))
    }

    func testABodyWithNoBudgetKeyIsNoWindowsAndOneThatIsNotAnObjectFailsToDecode() async {
        let none = await fetch(budget: Answer(status: 200, body: #"{"usage_percentage":0.0,"initial_budget":30.0}"#))
        XCTAssertEqual(none, .success(MistralBilling(planName: "INDIVIDUAL", budget: .entries([]))))
        let array = await fetch(budget: Answer(status: 200, body: "[]"))
        guard case .failure(.decoding(_)) = array else { return XCTFail("\(array)") }
    }

    func testAnEntryWithoutANumericPercentIsSkippedAndLooseFiguresAreDropped() async {
        let loose = #"{"vibe_budget":{"usage_percentage":"5"},"api_budget":{"usage_percentage":1.5,"initial_budget":"30","reset_at":"soon"},"extra_budget":3}"#
        let result = await fetch(budget: Answer(status: 200, body: loose))
        XCTAssertEqual(entries(result), [MistralBudgetEntry(key: "api_budget", usagePercentage: 1.5)])
    }
}
