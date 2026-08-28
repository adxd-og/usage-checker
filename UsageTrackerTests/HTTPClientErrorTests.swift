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
        XCTAssertEqual(HTTPClientError.badStatus(403, body: "x").errorDescription, "HTTP 403 (forbidden)")
        XCTAssertEqual(HTTPClientError.badStatus(404, body: "x").errorDescription, "HTTP 404 (not found)")
        XCTAssertEqual(HTTPClientError.badStatus(503, body: "x").errorDescription, "HTTP 503 (service unavailable)")
    }

    func testAnUnknownCodeStaysABareNumberRatherThanInventingAReason() {
        let text = HTTPClientError.badStatus(418, body: "I am a teapot and here is a token")
        XCTAssertEqual(text.errorDescription, "HTTP 418")
        XCTAssertFalse(text.errorDescription?.contains("teapot") ?? true)
    }

    func testTheBodyIsStillCarriedOnTheErrorForLogging() {
        // Dropping it from the description must not drop it from the value.
        guard case .badStatus(let code, let body) = HTTPClientError.badStatus(500, body: "boom") else {
            return XCTFail("expected a badStatus case")
        }
        XCTAssertEqual(code, 500)
        XCTAssertEqual(body, "boom")
    }

    func testTheOtherCasesStillReadAsBefore() {
        XCTAssertEqual(
            HTTPClientError.rateLimited(retryAfter: 30).errorDescription,
            "Rate limited (retry after 30s)"
        )
        XCTAssertEqual(HTTPClientError.rateLimited(retryAfter: nil).errorDescription, "Rate limited")
        XCTAssertEqual(HTTPClientError.invalidResponse.errorDescription, "Invalid response")
    }
}
