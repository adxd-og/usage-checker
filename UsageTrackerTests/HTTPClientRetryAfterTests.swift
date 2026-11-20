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

    func testTheLongestWaitIsADay() {
        XCTAssertEqual(HTTPClient.maximumRetryAfter, 86_400)
    }

    /// `Double` reads "inf" and "1e19", and a date a year ahead is a wait too: each is clamped
    /// to a day, finite and far under what an `Int` holds. "-inf" is no wait; "nan" no number.
    /// 2027-09-06 is a Monday.
    func testAWaitNoClockCanHoldIsClampedToADay() {
        for value in ["inf", "infinity", "1e19", "Mon, 06 Sep 2027 12:00:00 GMT"] {
            XCTAssertEqual(HTTPClient.retryAfterSeconds(response(retryAfter: value), now: now), 86_400, value)
        }
        XCTAssertEqual(HTTPClient.retryAfterSeconds(response(retryAfter: "-inf"), now: now), 0)
        XCTAssertNil(HTTPClient.retryAfterSeconds(response(retryAfter: "nan"), now: now))
    }
}
