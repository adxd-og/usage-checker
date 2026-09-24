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
}
