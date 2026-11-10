import Foundation

/// Mistral's billing API as vibe's key got it on this Mac on 2026-11-10 (spec 2026-11-10 Mistral
/// provider § Facts), verbatim, and a stand-in transport that answers by path. Tests hand the
/// fetcher this transport; no test opens a connection or reads a real key.
enum MistralFixture {
    /// `GET /v1/billing/subscription`, 200.
    static let subscriptionBody = #"{"plan_name":"INDIVIDUAL","payg_enabled":false,"vibe_payg_enabled":false,"enterprise":false}"#

    /// `GET /v1/billing/budget`, 200: two `_budget` entries, then the top level repeating
    /// `api_budget`'s fields.
    static let budgetBody = #"{"vibe_budget":{"usage_percentage":5.9597507033333335,"initial_budget":300.0,"currency":"USD","reset_at":"2026-12-01T00:00:00Z","payg_enabled":false},"api_budget":{"usage_percentage":0.0,"initial_budget":30.0,"currency":"USD","reset_at":"2026-12-01T00:00:00Z","payg_enabled":false},"usage_percentage":0.0,"initial_budget":30.0,"currency":"USD","reset_at":"2026-12-01T00:00:00Z"}"#

    /// 2026-11-10 12:00 UTC, a Tuesday.
    static let now = Date(timeIntervalSince1970: 1_794_312_000)
    /// 2026-12-01 00:00 UTC: both entries' `reset_at`.
    static let resetAt = Date(timeIntervalSince1970: 1_796_083_200)
    /// Not a key: what the tests look for in places the key must never reach.
    static let key = "test-mistral-key-0123"

    /// One HTTP answer.
    struct Answer: Sendable {
        var status: Int
        var body: String
        var headers: [String: String] = [:]
    }

    /// Every request the transport saw, in order.
    actor Requests {
        private(set) var seen: [URLRequest] = []
        func record(_ request: URLRequest) { seen.append(request) }
    }

    /// Answers `/v1/billing/subscription` and `/v1/billing/budget` by path, any other path with a
    /// 404. A nil answer fails as an unreachable network would.
    static func transport(
        subscription: Answer? = Answer(status: 200, body: subscriptionBody),
        budget: Answer? = Answer(status: 200, body: budgetBody),
        requests: Requests? = nil
    ) -> @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) {
        { request in
            await requests?.record(request)
            let url = request.url ?? URL(string: "https://api.mistral.ai/")!
            let answer: Answer?
            if url.path.hasSuffix("/billing/subscription") {
                answer = subscription
            } else if url.path.hasSuffix("/billing/budget") {
                answer = budget
            } else {
                answer = Answer(status: 404, body: "{}")
            }
            guard let answer else { throw URLError(.notConnectedToInternet) }
            let response = HTTPURLResponse(
                url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers
            )!
            return (Data(answer.body.utf8), response)
        }
    }
}
