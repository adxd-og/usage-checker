import XCTest
@testable import Omelette

/// A calculation the dashboard ran off the main actor publishes only while it is still
/// the one the view wants. Activity, Insights, History's quota chart and an open chat's
/// breakdown all build in a `Task.detached` from a `.task(id:)`; awaiting the detached
/// task's value does not stop when SwiftUI cancels the pass, so each asks this before
/// assigning. Spec: docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design
/// (session rulings), UI — publish guards; report D § 2.
final class DerivedCacheGateTests: XCTestCase {
    /// The shape of the views' keys: the provider and whatever else the pass read.
    private struct Key: Equatable {
        let service: String
        let weeks: Int
    }

    private let claude52 = Key(service: "claude", weeks: 52)
    private let grok52 = Key(service: "grok", weeks: 52)
    private let claude13 = Key(service: "claude", weeks: 13)

    func testAPassThatIsStillWantedPublishes() {
        XCTAssertTrue(DerivedCacheGate.canPublish(started: claude52, current: claude52, cancelled: false))
    }

    func testAPassForTheProviderYouLeftDoesNotPaintOverTheNewOne() {
        // Activity at 52w, Claude (slow) → Grok (fast): Grok publishes, then Claude's
        // pass finishes — and must not overwrite the Grok grid.
        XCTAssertFalse(DerivedCacheGate.canPublish(started: claude52, current: grok52, cancelled: false))
    }

    func testAPassForTheRangeYouLeftDoesNotPublish() {
        XCTAssertFalse(DerivedCacheGate.canPublish(started: claude52, current: claude13, cancelled: false))
    }

    func testACancelledPassStaysOutEvenWhenTheKeyCameBack() {
        // Claude → Grok → Claude: the first Claude pass was cancelled, the key matches
        // again, but the third pass owns the screen now.
        XCTAssertFalse(DerivedCacheGate.canPublish(started: claude52, current: claude52, cancelled: true))
    }

    func testCancelledAndSupersededIsStillNo() {
        XCTAssertFalse(DerivedCacheGate.canPublish(started: claude52, current: grok52, cancelled: true))
    }

    func testAnyEquatableKeyWillDo() {
        XCTAssertTrue(DerivedCacheGate.canPublish(started: "chat-1", current: "chat-1", cancelled: false))
        XCTAssertFalse(DerivedCacheGate.canPublish(started: "chat-1", current: "chat-2", cancelled: false))
    }
}
