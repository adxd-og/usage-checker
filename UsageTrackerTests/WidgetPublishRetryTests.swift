import XCTest
@testable import Omelette

/// Whole-branch review of 2.7.0 (Codex, 2026-09-24): an empty publication that failed to write.
final class WidgetPublishRetryTests: XCTestCase {
    /// The one empty list the publish rule allows is not spent by a write that failed.
    func testAnEmptyPublicationThatFailedToWriteIsTriedAgain() throws {
        let published = WidgetBridge.widgetServices(from: [Fixture.snapshot(buckets: [Fixture.bucket(id: "claude_5h")])])
        let previous: [WidgetService]? = [try XCTUnwrap(published.first)]
        let afterFailure = WidgetBridge.recordedPublication([], wrote: false, previous: previous)
        XCTAssertEqual(afterFailure, previous)
        XCTAssertTrue(WidgetBridge.shouldPublish([], lastPublished: afterFailure), "still due")
        let afterSuccess = WidgetBridge.recordedPublication([], wrote: true, previous: previous)
        XCTAssertEqual(afterSuccess, [])
        XCTAssertFalse(WidgetBridge.shouldPublish([], lastPublished: afterSuccess), "delivered once")
    }
}
