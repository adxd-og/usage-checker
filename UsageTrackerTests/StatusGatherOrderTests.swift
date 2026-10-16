import XCTest
@testable import Omelette

/// The order gathers land in. Each poll starts a gather of its own, off the main actor.
/// Gathers can finish out of order, and only the newest poll's result may set the caches
/// the writes between polls reuse and write `status.json`. The decision is
/// `AppState.appliesGather(started:latest:)`; the counter around it is glue.
final class StatusGatherOrderTests: XCTestCase {
    func testAGatherThatFinishesAfterALaterPollsIsDropped() {
        // Polls 1 and 2 each start a gather. Poll 2's finishes first, poll 1's last.
        XCTAssertTrue(AppState.appliesGather(started: 2, latest: 2))
        XCTAssertFalse(
            AppState.appliesGather(started: 1, latest: 2),
            "poll 1's costs, chats and shares would overwrite poll 2's"
        )
    }
}
