import XCTest
@testable import Omelette

/// What a widget entry draws when there is a file, an empty file or no file. Spec
/// docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design, Retention — "Widget:
/// `.placeholder` only for `placeholder(in:)` and previews; a failed read is an explicit
/// 'Open Omelette' state decided by a widget-side rule". The extension is its own
/// module; these rules live in SharedWidgetData.swift, which the app compiles too.
final class WidgetEntryRulesTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_788_000_000)

    private func service(_ id: String) -> WidgetService {
        WidgetService(
            id: id, name: id.capitalized, icon: "sparkles", plan: nil,
            buckets: [WidgetBucket(id: "\(id)_session", label: "Session", percent: 40, kind: "session")]
        )
    }

    private func file(_ ids: [String]) -> WidgetSnapshot {
        WidgetSnapshot(services: ids.map(service), updatedAt: at)
    }

    func testNoFileIsNotReplacedBySampleNumbersOnTheDesktop() {
        // Before: `SharedWidgetStore.read() ?? .placeholder` drew Claude "Max 5x" at 42%
        // on a Mac that had never run Omelette.
        XCTAssertNil(WidgetEntryRules.snapshot(read: nil, isPreview: false))
    }

    func testTheWidgetGalleryStillGetsSampleNumbers() {
        XCTAssertEqual(
            WidgetEntryRules.snapshot(read: nil, isPreview: true)?.services.map(\.id),
            ["claude", "antigravity"]
        )
    }

    func testARealFileWinsEverywhere() {
        let real = file(["codex"])
        XCTAssertEqual(WidgetEntryRules.snapshot(read: real, isPreview: false), real)
        XCTAssertEqual(WidgetEntryRules.snapshot(read: real, isPreview: true), real)
    }

    func testNoFileSaysOpenOmelette() {
        XCTAssertEqual(WidgetEntryRules.providerContent(nil, providerID: "claude"), .message("Open Omelette"))
        XCTAssertEqual(WidgetEntryRules.allProvidersContent(nil), .message("Open Omelette"))
    }

    func testAProviderMissingFromTheFileSaysNoData() {
        XCTAssertEqual(
            WidgetEntryRules.providerContent(file(["codex"]), providerID: "claude"), .message("No data")
        )
    }

    func testAProviderInTheFileIsDrawn() {
        XCTAssertEqual(
            WidgetEntryRules.providerContent(file(["claude", "codex"]), providerID: "claude"),
            .service(service("claude"))
        )
    }

    func testAnEmptyFileSaysNothingIsReporting() {
        XCTAssertEqual(WidgetEntryRules.allProvidersContent(file([])), .message("No provider is reporting"))
    }

    func testAFileWithProvidersIsDrawn() {
        let real = file(["claude"])
        XCTAssertEqual(WidgetEntryRules.allProvidersContent(real), .snapshot(real))
    }
}
