import XCTest
@testable import Omelette

/// Whole-branch review of 2.7.0 (Codex, 2026-09-24): an empty publication that failed to write.
final class WidgetPublishRetryTests: XCTestCase {
    /// The one empty list the publish rule allows is not spent by a write that failed.
    func testAnEmptyPublicationThatFailedToWriteIsTriedAgain() throws {
        let published = WidgetBridge.widgetServices(from: [Fixture.snapshot(buckets: [Fixture.bucket(id: "claude_5h")])])
        let previous: WidgetBridge.Publication? = WidgetBridge.Publication(
            services: [try XCTUnwrap(published.first)], enabledProviders: 1
        )
        let empty = WidgetBridge.Publication(services: [], enabledProviders: 1)
        let afterFailure = WidgetBridge.recordedPublication(empty, wrote: false, previous: previous)
        XCTAssertEqual(afterFailure, previous)
        XCTAssertTrue(WidgetBridge.shouldPublish(empty, lastPublished: afterFailure), "still due")
        let afterSuccess = WidgetBridge.recordedPublication(empty, wrote: true, previous: previous)
        XCTAssertEqual(afterSuccess, empty)
        XCTAssertFalse(WidgetBridge.shouldPublish(empty, lastPublished: afterSuccess), "delivered once")
    }
}
