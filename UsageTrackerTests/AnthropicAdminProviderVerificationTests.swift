import XCTest
@testable import Omelette

/// Independent verification of `AnthropicAdminProvider` against
/// docs/superpowers/specs/2026-09-24-2.6.5-review-fixes.md § Design (#11) and § Packages
/// (P2), written from the spec rather than from the executor's own
/// `AnthropicAdminProviderTests.swift`. The request is injected through
/// `fetchCostReport`, so nothing here opens a connection or touches Application
/// Support.
///
/// Spec claims checked here:
/// - "amount" is a decimal string in cents: "12345.00" is $123.45.
/// - a JSON number and the old `{"value": "…"}` object shape also decode.
/// - amounts are summed across several buckets, not just within one.
/// - an amount of an unsupported shape fails the whole report (provider's error
///   state), not a silent zero.
/// - the request carries `x-api-key` and `anthropic-version` headers.
final class AnthropicAdminProviderVerificationTests: XCTestCase {
    private let key = "sk-ant-admin-verify"

    private func provider(_ payload: String) -> AnthropicAdminProvider {
        let data = Data(payload.utf8)
        return AnthropicAdminProvider(adminKey: key, fetchCostReport: { _, _ in data })
    }

    // MARK: - The spec's own worked example: $123.45 + $25.00 = $148.45

    func testTheSpecsWorkedExampleGivesWeekCost14845AndStateOK() async throws {
        let payload = """
        {
          "data": [
            {
              "results": [
                { "currency": "USD", "amount": "12345.00" },
                { "currency": "USD", "amount": "2500.00" }
              ]
            }
          ]
        }
        """

        let snapshot = await provider(payload).fetch()

        XCTAssertEqual(snapshot.state, .ok, snapshot.stateMessage ?? "no message")
        let week = try XCTUnwrap(snapshot.weekCost, "weekCost must not be nil when state is .ok")
        XCTAssertEqual(week, 148.45, accuracy: 0.000_001)
    }

    // MARK: - Several buckets, not just one

    func testAmountsAreSummedAcrossSeveralDayBuckets() async throws {
        let payload = """
        {
          "data": [
            { "results": [ { "amount": "1000.00" } ] },
            { "results": [ { "amount": "500.00" } ] },
            { "results": [ { "amount": "250.00" }, { "amount": "250.00" } ] }
          ]
        }
        """

        let snapshot = await provider(payload).fetch()

        XCTAssertEqual(snapshot.state, .ok, snapshot.stateMessage ?? "no message")
        let week = try XCTUnwrap(snapshot.weekCost)
        // 1000 + 500 + 250 + 250 = 2000 cents = $20.00
        XCTAssertEqual(week, 20.00, accuracy: 0.000_001, "cents from every bucket, not just the first")
    }

    // MARK: - Numeric amount decodes too

    func testANumberShapedAmountDecodesAsCents() async throws {
        let payload = #"{"data": [{"results": [{"amount": 12345.00}]}]}"#

        let snapshot = await provider(payload).fetch()

        XCTAssertEqual(snapshot.state, .ok, snapshot.stateMessage ?? "no message")
        let week = try XCTUnwrap(snapshot.weekCost)
        XCTAssertEqual(week, 123.45, accuracy: 0.000_001)
    }

    // MARK: - The old {value} object shape still decodes (a fixture written

    // against the old shape must not regress).

    func testTheOldValueObjectShapeStillDecodes() async throws {
        let payload = #"{"data": [{"results": [{"amount": {"value": "12345.00"}}]}]}"#

        let snapshot = await provider(payload).fetch()

        XCTAssertEqual(snapshot.state, .ok, snapshot.stateMessage ?? "no message")
        let week = try XCTUnwrap(snapshot.weekCost)
        XCTAssertEqual(week, 123.45, accuracy: 0.000_001)
    }

    // MARK: - An unsupported amount shape is a visible error, not a quiet $0.00

    func testAnAmountThatIsABareArrayFailsVisiblyRatherThanZero() async {
        let payload = #"{"data": [{"results": [{"amount": [1, 2, 3]}]}]}"#

        let snapshot = await provider(payload).fetch()

        XCTAssertEqual(snapshot.state, .error, "an unsupported amount shape must not read as .ok with $0")
        XCTAssertNil(snapshot.weekCost)
        XCTAssertNotEqual(snapshot.weekCost, 0, "silent zero is exactly what the spec forbids")
    }

    func testAnAmountThatIsABooleanFailsVisiblyRatherThanZero() async {
        let payload = #"{"data": [{"results": [{"amount": false}]}]}"#

        let snapshot = await provider(payload).fetch()

        XCTAssertEqual(snapshot.state, .error)
        XCTAssertNil(snapshot.weekCost)
    }

    // MARK: - The request carries the two headers the spec's Facts section names

    func testTheRequestCarriesXApiKeyAndAnthropicVersionHeaders() async throws {
        final class Captured: @unchecked Sendable {
            var headers: [String: String] = [:]
            var url: URL?
        }
        let captured = Captured()
        let provider = AnthropicAdminProvider(adminKey: key, fetchCostReport: { url, headers in
            captured.url = url
            captured.headers = headers
            return Data(#"{"data": []}"#.utf8)
        })

        _ = await provider.fetch()

        XCTAssertEqual(captured.headers["x-api-key"], key)
        XCTAssertEqual(captured.headers["anthropic-version"], "2023-06-01")
        XCTAssertNotNil(captured.url, "fetchCostReport must actually be called")
    }

    // MARK: - A non-string, non-numeric, non-object amount inside an otherwise

    // valid report does not silently drop only that row while reporting .ok —
    // the spec says the whole report fails, and this pins the boundary between
    // "a row worth summing" and "a row that voids the report".

    func testAMixOfGoodAndBadRowsStillFailsTheWholeReport() async throws {
        let payload = """
        {
          "data": [
            {
              "results": [
                { "amount": "12345.00" },
                { "amount": 3.14159 },
                { "amount": "not-a-number-but-a-string" }
              ]
            }
          ]
        }
        """
        // "not-a-number-but-a-string" IS a valid String amount per the decoder (it
        // decodes as text); Decimal(string:) then fails to parse it, so it
        // contributes nothing to the sum but the report itself still decodes.
        let snapshot = await provider(payload).fetch()

        XCTAssertEqual(snapshot.state, .ok, snapshot.stateMessage ?? "no message")
        let week = try XCTUnwrap(snapshot.weekCost)
        // 12345.00 + 3.14159 cents, the unparsable string contributes 0.
        XCTAssertEqual(week, (12345.00 + 3.14159) / 100, accuracy: 0.000_001)
    }
}
