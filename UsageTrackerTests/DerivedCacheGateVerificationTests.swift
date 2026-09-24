import XCTest
@testable import Omelette

/// Independent verification of `DerivedCacheGate.canPublish`, from the spec, not from
/// the executor's own `DerivedCacheGateTests`. Spec:
/// docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design (session rulings),
/// UI — "Publish guards: a `DerivedCacheGate.canPublish(started:current:cancelled:)`
/// rule". Claim under test: a superseded key or a cancelled pass never publishes.
final class DerivedCacheGateVerificationTests: XCTestCase {
    private struct ProviderRangeKey: Equatable {
        let provider: String
        let range: TimeRange
    }

    func testMatchingKeyNotCancelledPublishes() {
        let key = ProviderRangeKey(provider: "claude", range: .sevenDays)
        XCTAssertTrue(DerivedCacheGate.canPublish(started: key, current: key, cancelled: false))
    }

    func testASupersededKeyNeverPublishesEvenWithoutCancellation() {
        // Cancellation is racy in real SwiftUI: a detached task can finish its work
        // before `Task.isCancelled` is observed true. The key comparison alone must
        // be enough to reject it.
        let started = ProviderRangeKey(provider: "claude", range: .sevenDays)
        let current = ProviderRangeKey(provider: "codex", range: .sevenDays)
        XCTAssertFalse(DerivedCacheGate.canPublish(started: started, current: current, cancelled: false))
    }

    func testASupersededRangeAloneIsAlsoRejected() {
        let started = ProviderRangeKey(provider: "claude", range: .thirtyDays)
        let current = ProviderRangeKey(provider: "claude", range: .ninetyDays)
        XCTAssertFalse(DerivedCacheGate.canPublish(started: started, current: current, cancelled: false))
    }

    func testACancelledPassNeverPublishesEvenWhenTheKeyStillMatches() {
        let key = ProviderRangeKey(provider: "grok", range: .oneDay)
        XCTAssertFalse(DerivedCacheGate.canPublish(started: key, current: key, cancelled: true))
    }

    func testCancelledAndSupersededTogetherIsStillRejected() {
        let started = ProviderRangeKey(provider: "grok", range: .oneDay)
        let current = ProviderRangeKey(provider: "antigravity", range: .oneDay)
        XCTAssertFalse(DerivedCacheGate.canPublish(started: started, current: current, cancelled: true))
    }

    /// The gate is generic; a caller with an `Optional` inside its key (a row id that
    /// can be nil before the first ingest) must work the same way.
    func testAnOptionalFieldInsideTheKeyStillComparesCorrectly() {
        struct KeyWithOptional: Equatable { let id: String?; let expanded: Bool }
        let a = KeyWithOptional(id: nil, expanded: true)
        let b = KeyWithOptional(id: nil, expanded: true)
        let c = KeyWithOptional(id: "row-1", expanded: true)
        XCTAssertTrue(DerivedCacheGate.canPublish(started: a, current: b, cancelled: false))
        XCTAssertFalse(DerivedCacheGate.canPublish(started: a, current: c, cancelled: false))
    }

    /// `!cancelled && started == current`, not `cancelled || started != current`
    /// negated some other way — check the truth table directly for one representative
    /// key rather than trusting the two flags are combined with AND.
    func testTheFullTruthTable() {
        let same = "chat-42"
        let other = "chat-43"
        XCTAssertTrue(DerivedCacheGate.canPublish(started: same, current: same, cancelled: false))
        XCTAssertFalse(DerivedCacheGate.canPublish(started: same, current: same, cancelled: true))
        XCTAssertFalse(DerivedCacheGate.canPublish(started: same, current: other, cancelled: false))
        XCTAssertFalse(DerivedCacheGate.canPublish(started: same, current: other, cancelled: true))
    }
}
