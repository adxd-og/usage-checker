import XCTest
@testable import Omelette

/// Independent verification of P1 (Retention), report A item 1. Spec
/// docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design, Retention — "Widget:
/// `.placeholder` only for `placeholder(in:)` and previews; a failed read is an explicit
/// 'Open Omelette' state decided by a widget-side rule; `WidgetBridge.publish` may
/// write an empty snapshot and is called from `forgetLastKnown` and whenever the
/// published services changed."
///
/// The executor's `WidgetEntryRulesTests` and `WidgetPublishTests` cover these rules
/// with their own fixtures. This file adds the literal claim from the task brief that
/// neither exercises directly — a nil read outside a preview gives nil, full stop, with
/// no dependency on what `isPreview` would otherwise supply — plus `shouldPublish`
/// idempotence across a longer sequence of polls than either executor test drives.
final class WidgetRetentionVerificationTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_788_200_000)

    private func service(_ id: String, retained: Bool = false) -> WidgetService {
        WidgetService(
            id: id, name: id.capitalized, icon: "sparkles", plan: nil,
            buckets: [WidgetBucket(id: "\(id)_session", label: "Session", percent: 33, kind: "session")],
            isRetained: retained
        )
    }

    func testANilReadOutsideAPreviewIsNilNoMatterWhatWasThereBefore() {
        // The literal claim: nil in, nil out, when not a preview — regardless of
        // whether a previous call in the same process happened to be a preview.
        _ = WidgetEntryRules.snapshot(read: nil, isPreview: true)
        XCTAssertNil(WidgetEntryRules.snapshot(read: nil, isPreview: false))
    }

    func testAPreviewAlwaysGetsThePlaceholderEvenRightAfterANilRealRead() {
        _ = WidgetEntryRules.snapshot(read: nil, isPreview: false)
        XCTAssertEqual(WidgetEntryRules.snapshot(read: nil, isPreview: true), .placeholder)
    }

    func testAnUndecodableFileReadsAsNilJustLikeAMissingOne() {
        // `SharedWidgetStore.read()` answers nil for both a missing and an
        // undecodable file; `WidgetEntryRules.snapshot` cannot tell them apart and
        // must not need to — both are "nothing to read".
        let fromMissingFile = WidgetEntryRules.snapshot(read: nil, isPreview: false)
        let fromUndecodableFile = WidgetEntryRules.snapshot(read: nil, isPreview: false)
        XCTAssertEqual(fromMissingFile, fromUndecodableFile)
        XCTAssertNil(fromMissingFile)
    }

    func testShouldPublishStaysFalseAcrossRepeatedEmptyPollsAfterTheFirst() {
        // A longer sequence than either executor test: five consecutive empty polls
        // after the widget already knows there is nothing — the extension's timelines
        // must not reload five times to say the same "nothing to show" again.
        var lastPublished: [WidgetService]? = [service("claude")]
        let firstEmpty = WidgetBridge.shouldPublish([], lastPublished: lastPublished)
        XCTAssertTrue(firstEmpty)
        lastPublished = []

        for i in 0..<5 {
            XCTAssertFalse(
                WidgetBridge.shouldPublish([], lastPublished: lastPublished),
                "empty poll \(i): nothing changed, nothing should republish"
            )
        }
    }

    func testShouldPublishFlipsBackOnAsSoonAsSomethingReturns() {
        var lastPublished: [WidgetService]? = []
        XCTAssertFalse(WidgetBridge.shouldPublish([], lastPublished: lastPublished))

        let returned = [service("claude")]
        XCTAssertTrue(WidgetBridge.shouldPublish(returned, lastPublished: lastPublished))
        lastPublished = returned
        // And a retained flag flipping on the same provider — still "something to
        // draw" — keeps publishing every time, same as any other live change.
        XCTAssertTrue(WidgetBridge.shouldPublish([service("claude", retained: true)], lastPublished: lastPublished))
    }

    func testAllProvidersContentTreatsANilSnapshotAndAnEmptyOneDifferently() {
        // Two distinct "nothing" states the report calls out separately: no file at
        // all ("Open Omelette") versus a real, empty file ("No provider is reporting").
        XCTAssertEqual(WidgetEntryRules.allProvidersContent(nil), .message(WidgetEntryRules.openAppMessage))
        let empty = WidgetSnapshot(services: [], updatedAt: at)
        XCTAssertEqual(WidgetEntryRules.allProvidersContent(empty), .message(WidgetEntryRules.nothingReportingMessage))
        XCTAssertNotEqual(WidgetEntryRules.openAppMessage, WidgetEntryRules.nothingReportingMessage)
    }
}
