import XCTest
@testable import Omelette

/// `errorDescription` reaches the UI as `lastError`, so it must never carry the
/// response body — a 401/403 from the usage API can quote token detail.
final class HTTPClientErrorTests: XCTestCase {
    func testAnUnauthorizedBodyNeverReachesTheDescription() {
        let error = HTTPClientError.badStatus(401, body: #"{"error":"secret token sk-ant-oat01-XYZ expired"}"#)
        let text = error.errorDescription ?? ""

        XCTAssertEqual(text, "HTTP 401 (unauthorized)")
        XCTAssertFalse(text.contains("secret"))
        XCTAssertFalse(text.contains("sk-ant"))
    }

    func testKnownCodesGetAReadableReason() {
        let expected: [Int: String] = [
            400: "HTTP 400 (bad request)",
            401: "HTTP 401 (unauthorized)",
            403: "HTTP 403 (forbidden)",
            404: "HTTP 404 (not found)",
            408: "HTTP 408 (request timeout)",
            500: "HTTP 500 (server error)",
            502: "HTTP 502 (bad gateway)",
            503: "HTTP 503 (service unavailable)",
            504: "HTTP 504 (gateway timeout)",
        ]
        for (code, text) in expected {
            XCTAssertEqual(HTTPClientError.badStatus(code, body: "x").errorDescription, text)
        }
    }

    func testAnUnknownCodeStaysABareNumberRatherThanInventingAReason() {
        let text = HTTPClientError.badStatus(418, body: "I am a teapot and here is a token")
        XCTAssertEqual(text.errorDescription, "HTTP 418")
        XCTAssertFalse(text.errorDescription?.contains("teapot") ?? true)
    }

    func testTheOtherCasesStillReadAsBefore() {
        XCTAssertEqual(
            HTTPClientError.rateLimited(retryAfter: 30).errorDescription,
            "Rate limited (retry after 30s)"
        )
        XCTAssertEqual(HTTPClientError.rateLimited(retryAfter: nil).errorDescription, "Rate limited")
        XCTAssertEqual(HTTPClientError.invalidResponse.errorDescription, "Invalid response")
        XCTAssertEqual(HTTPClientError.tooManyRetries.errorDescription, "Too many retries")
        XCTAssertEqual(HTTPClientError.decoding("x").errorDescription, "Decoding failed: x")
    }
}
