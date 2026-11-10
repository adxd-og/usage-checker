import XCTest
@testable import Omelette

/// Spec 2026-11-10 Mistral provider § Surfaces, the widget with a fifth provider. The All
/// providers widget lists up to five providers. Up to four listed, each shows its session and
/// its fullest other window; at five, each shows its one most telling window, so the large
/// widget's height holds them.
final class WidgetAllProvidersRulesTests: XCTestCase {
    private func service(_ id: String, buckets: [WidgetBucket] = []) -> WidgetService {
        WidgetService(id: id, name: id.capitalized, icon: "circle", plan: nil, buckets: buckets)
    }

    func testFiveProvidersAllFitTheLargeWidgetAndASixthDoesNot() {
        let ids = ["claude", "anthropic-admin", "codex", "antigravity", "grok", "mistral"]
        let six = WidgetSnapshot(services: ids.map { service($0) }, updatedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(WidgetEntryRules.allProvidersShown(six).map(\.id), Array(ids.prefix(5)))
        XCTAssertEqual(WidgetEntryRules.allProvidersLimit, 5)
    }

    func testFourOrFewerKeepTwoWindowsAndFiveGetOne() {
        XCTAssertEqual(WidgetEntryRules.windowRowsPerProvider(shown: 1), 2)
        XCTAssertEqual(WidgetEntryRules.windowRowsPerProvider(shown: 4), 2)
        XCTAssertEqual(WidgetEntryRules.windowRowsPerProvider(shown: 5), 1)
    }

    func testTwoRowsAreTheSessionAndTheFullestOtherWindow() {
        let claude = service("claude", buckets: [
            WidgetBucket(id: "seven_day", label: "All models", percent: 18, kind: "weekly"),
            WidgetBucket(id: "five_hour", label: "Session", percent: 42, kind: "session"),
            WidgetBucket(id: "seven_day_fable", label: "Fable only", percent: 24, kind: "modelSpecific"),
        ])
        XCTAssertEqual(WidgetEntryRules.windowRows(of: claude, limit: 2).map(\.id), ["five_hour", "seven_day_fable"])
        XCTAssertEqual(WidgetEntryRules.windowRows(of: claude, limit: 1).map(\.id), ["five_hour"])
    }

    func testOneRowWithoutASessionIsTheFullestWindow() {
        let mistral = service("mistral", buckets: [
            WidgetBucket(id: "mistral_vibe", label: "Vibe", percent: 6, kind: "weekly"),
            WidgetBucket(id: "mistral_api", label: "API", percent: 0, kind: "modelSpecific"),
        ])
        XCTAssertEqual(WidgetEntryRules.windowRows(of: mistral, limit: 1).map(\.id), ["mistral_vibe"])
        XCTAssertEqual(WidgetEntryRules.windowRows(of: mistral, limit: 2).map(\.id), ["mistral_vibe", "mistral_api"])
    }
}
