import XCTest
@testable import Omelette

/// Spec 2026-11-20 small backlog 2 § E: `Retry-After` in its two forms, delta-seconds and an
/// HTTP-date, the date measured against the clock the caller gives. 2026-09-06 is a Sunday.
final class HTTPClientRetryAfterTests: XCTestCase {
    /// 2026-09-06 12:00:00 GMT.
    private let now = Date(timeIntervalSince1970: 1_788_696_000)

    private func response(retryAfter: String?) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.example.invalid/usage")!, statusCode: 429, httpVersion: "HTTP/1.1",
            headerFields: retryAfter.map { ["Retry-After": $0] } ?? [:]
        )!
    }

    func testASecondsValueIsTheWait() {
        XCTAssertEqual(HTTPClient.retryAfterSeconds(response(retryAfter: "120"), now: now), 120)
    }

    func testADateAheadIsTheSecondsUntilIt() {
        XCTAssertEqual(
            HTTPClient.retryAfterSeconds(response(retryAfter: "Sun, 06 Sep 2026 12:01:30 GMT"), now: now), 90
        )
    }

    func testADateBehindIsNoWait() {
        XCTAssertEqual(
            HTTPClient.retryAfterSeconds(response(retryAfter: "Sun, 06 Sep 2026 11:59:00 GMT"), now: now), 0
        )
    }

    func testAMalformedValueIsNoAnswer() {
        for value in ["soon", "2026-09-06T12:01:30Z"] {
            XCTAssertNil(HTTPClient.retryAfterSeconds(response(retryAfter: value), now: now), value)
        }
        XCTAssertNil(HTTPClient.retryAfterSeconds(response(retryAfter: nil), now: now), "no header")
    }

    func testANegativeNumberIsNoWait() {
        XCTAssertEqual(HTTPClient.retryAfterSeconds(response(retryAfter: "-5"), now: now), 0)
    }
}
