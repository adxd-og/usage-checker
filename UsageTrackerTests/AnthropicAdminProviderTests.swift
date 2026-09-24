import XCTest
@testable import Omelette

/// The Enterprise row: what `AnthropicAdminProvider` makes of the Admin API's cost
/// report. The request is injected, so no test opens a connection or needs a key.
/// Spec: docs/superpowers/specs/2026-09-24-2.6.5-review-fixes.md § Design (#11).
final class AnthropicAdminProviderTests: XCTestCase {
    private let adminKey = "sk-ant-admin-test"

    /// What the provider asked for. The @Sendable fetch closure writes it and the
    /// test reads it after `fetch()` has returned; the test target checks
    /// concurrency minimally and nothing here runs in parallel.
    private final class Request: @unchecked Sendable {
        var url: URL?
        var headers: [String: String] = [:]
    }

    /// A provider whose cost report is `payload`, verbatim. The bytes are built out
    /// here so the @Sendable closure captures a value, not the test case.
    private func provider(answering payload: String) -> AnthropicAdminProvider {
        let data = Data(payload.utf8)
        return AnthropicAdminProvider(adminKey: adminKey, fetchCostReport: { _, _ in data })
    }

    // MARK: - The request and the error paths

    func testTheCostReportIsAskedForWithTheAdminKey() async throws {
        let request = Request()
        let provider = AnthropicAdminProvider(adminKey: adminKey, fetchCostReport: { url, headers in
            request.url = url
            request.headers = headers
            return Data(#"{"data": []}"#.utf8)
        })

        let snapshot = await provider.fetch()

        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.host, "api.anthropic.com")
        XCTAssertEqual(url.path, "/v1/organizations/cost_report")
        XCTAssertEqual(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name),
            ["starting_at"]
        )
        XCTAssertEqual(request.headers["x-api-key"], "sk-ant-admin-test")
        XCTAssertEqual(request.headers["anthropic-version"], "2023-06-01")
        XCTAssertEqual(snapshot.state, .ok)
        XCTAssertEqual(snapshot.weekCost, 0, "an empty week is $0, not an error")
    }

    func testAReportThatDoesNotDecodeIsAnErrorWithNoSpend() async {
        let snapshot = await provider(answering: #"{"has_more": false}"#).fetch()

        XCTAssertEqual(snapshot.state, .error)
        XCTAssertNil(snapshot.weekCost)
        XCTAssertNil(snapshot.plan)
        XCTAssertEqual(snapshot.displayName, "Anthropic Enterprise")
        XCTAssertTrue(
            snapshot.stateMessage?.hasPrefix("Decoding failed: ") == true,
            snapshot.stateMessage ?? "nil"
        )
    }

    func testATransportFailureIsAnErrorWithNoSpend() async {
        let provider = AnthropicAdminProvider(adminKey: adminKey, fetchCostReport: { _, _ in
            throw HTTPClientError.badStatus(401, body: "")
        })

        let snapshot = await provider.fetch()

        XCTAssertEqual(snapshot.state, .error)
        XCTAssertNil(snapshot.weekCost)
        XCTAssertEqual(snapshot.stateMessage, "HTTP 401 (unauthorized)")
    }

    // MARK: - Amounts are cents

    /// The Admin API's own shape (API reference; the same payload CodexBar's
    /// ClaudeAdminAPIUsageTests carries, first day bucket): `amount` is a decimal
    /// string in cents, so "12345.00" is $123.45.
    private let costReport = """
    {
      "data": [
        {
          "starting_at": "2023-11-14T00:00:00Z",
          "ending_at": "2023-11-15T00:00:00Z",
          "results": [
            {
              "currency": "USD",
              "amount": "12345.00",
              "description": "Claude Sonnet 4 Usage - Input Tokens",
              "cost_type": "tokens"
            },
            {
              "currency": "USD",
              "amount": "2500.00",
              "description": "Web Search Usage",
              "cost_type": "web_search"
            }
          ]
        }
      ],
      "has_more": false,
      "next_page": null
    }
    """

    func testTheWeekIsTheReportsCentsInDollars() async throws {
        let snapshot = await provider(answering: costReport).fetch()

        XCTAssertEqual(snapshot.state, .ok, snapshot.stateMessage ?? "no message")
        XCTAssertEqual(snapshot.plan, "Enterprise")
        XCTAssertNil(snapshot.stateMessage)
        let week = try XCTUnwrap(snapshot.weekCost, snapshot.stateMessage ?? "no message")
        XCTAssertEqual(week, 148.45, accuracy: 0.000_001, "$123.45 + $25.00")
    }

    func testANumericAmountIsCentsToo() async throws {
        let payload = """
        {
          "data": [
            { "results": [ { "currency": "USD", "amount": 12345.00 } ] },
            { "results": [ { "currency": "USD", "amount": 2500 } ] }
          ],
          "has_more": false
        }
        """

        let snapshot = await provider(answering: payload).fetch()

        XCTAssertEqual(snapshot.state, .ok, snapshot.stateMessage ?? "no message")
        let week = try XCTUnwrap(snapshot.weekCost, snapshot.stateMessage ?? "no message")
        XCTAssertEqual(week, 148.45, accuracy: 0.000_001, "summed across day buckets, then divided once")
    }

    func testTheOlderValueObjectStillDecodesAsCents() async throws {
        let payload = """
        {
          "data": [
            {
              "results": [
                { "currency": "USD", "amount": { "value": "12345.00" } },
                { "currency": "USD", "amount": { "value": "2500.00" } }
              ]
            }
          ]
        }
        """

        let snapshot = await provider(answering: payload).fetch()

        XCTAssertEqual(snapshot.state, .ok, snapshot.stateMessage ?? "no message")
        let week = try XCTUnwrap(snapshot.weekCost, snapshot.stateMessage ?? "no message")
        XCTAssertEqual(week, 148.45, accuracy: 0.000_001, "the same cents, not dollars")
    }

    func testAResultWithNoAmountAddsNothing() async throws {
        let payload = """
        {
          "data": [
            {
              "results": [
                { "currency": "USD", "amount": "12345.00" },
                { "currency": "USD", "amount": null },
                { "currency": "USD" },
                { "currency": "USD", "amount": { "value": null } }
              ]
            }
          ]
        }
        """

        let snapshot = await provider(answering: payload).fetch()

        XCTAssertEqual(snapshot.state, .ok, snapshot.stateMessage ?? "no message")
        let week = try XCTUnwrap(snapshot.weekCost, snapshot.stateMessage ?? "no message")
        XCTAssertEqual(week, 123.45, accuracy: 0.000_001)
    }

    func testAnAmountOfNoKnownShapeFailsTheReportVisibly() async {
        let payload = #"{"data": [{"results": [{"amount": "12345.00"}, {"amount": true}]}]}"#

        let snapshot = await provider(answering: payload).fetch()

        XCTAssertEqual(snapshot.state, .error)
        XCTAssertNil(snapshot.weekCost, "a changed API reads as an error, not as a quiet $0.00")
        XCTAssertTrue(
            snapshot.stateMessage?.hasPrefix("Decoding failed: ") == true,
            snapshot.stateMessage ?? "nil"
        )
    }
}
