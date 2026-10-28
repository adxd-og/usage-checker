import XCTest
@testable import Omelette

/// Spec 2026-10-25 § Package 1, owner ruling 2026-10-28: a provider widget pinned to a
/// switched-off provider says so.
final class WidgetProviderOffTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_790_000_000)
    private let offLine = "Claude is off. Turn it on in Omelette's Settings › Providers."

    private func service(_ id: String) -> WidgetService {
        WidgetService(
            id: id, name: id.capitalized, icon: "sparkles", plan: nil,
            buckets: [WidgetBucket(id: "\(id)_session", label: "Session", percent: 40, kind: "session")]
        )
    }

    private func file(_ ids: [String], enabledProviders: Int?, enabledProviderIDs: [String]?) -> WidgetSnapshot {
        WidgetSnapshot(
            services: ids.map(service),
            updatedAt: at,
            enabledProviders: enabledProviders,
            enabledProviderIDs: enabledProviderIDs
        )
    }

    func testAWidgetPinnedToASwitchedOffProviderSaysItIsOff() {
        let snapshot = file(["codex"], enabledProviders: 1, enabledProviderIDs: ["codex"])
        XCTAssertEqual(
            WidgetEntryRules.providerContent(snapshot, providerID: "claude", providerName: "Claude"),
            .message(offLine)
        )
    }

    func testAProviderThatIsOnButNotReportingStillSaysNoData() {
        let snapshot = file(["codex"], enabledProviders: 2, enabledProviderIDs: ["claude", "codex"])
        XCTAssertEqual(
            WidgetEntryRules.providerContent(snapshot, providerID: "claude", providerName: "Claude"),
            .message(WidgetEntryRules.noDataMessage)
        )
    }

    func testAFileWithoutTheListKeepsTodaysNoData() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let json = #"{"services": [], "updatedAt": "2026-10-27T09:00:00Z", "enabledProviders": 1}"#
        let opened = try decoder.decode(WidgetSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(opened.enabledProviderIDs)
        XCTAssertEqual(
            WidgetEntryRules.providerContent(opened, providerID: "claude", providerName: "Claude"),
            .message(WidgetEntryRules.noDataMessage)
        )
    }

    func testEveryProviderOffStillWinsOverTheProviderLine() {
        let snapshot = file([], enabledProviders: 0, enabledProviderIDs: [])
        XCTAssertEqual(
            WidgetEntryRules.providerContent(snapshot, providerID: "claude", providerName: "Claude"),
            .message(NothingOnCopy.widget)
        )
    }

    func testTheListRoundTripsThroughTheFileSorted() throws {
        let snapshot = WidgetBridge.snapshot(
            from: [], at: at, mode: .used, enabledProviders: 2, enabledProviderIDs: ["codex", "claude"].sorted()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""enabledProviderIDs":["claude","codex"]"#))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(WidgetSnapshot.self, from: data), snapshot)
    }

    func testSwappingWhichProviderIsOnReachesTheFileWhenNothingReports() {
        let codexOn = WidgetBridge.Publication(services: [], enabledProviders: 1, enabledProviderIDs: ["codex"])
        let claudeOn = WidgetBridge.Publication(services: [], enabledProviders: 1, enabledProviderIDs: ["claude"])
        XCTAssertTrue(WidgetBridge.shouldPublish(codexOn, lastPublished: claudeOn))
        XCTAssertFalse(WidgetBridge.shouldPublish(codexOn, lastPublished: codexOn))
    }

    func testAServiceStillInTheFileButSwitchedOffSaysOff() {
        // A retained Claude row is still in the file; the switch is checked before the lookup.
        let snapshot = file(["claude", "codex"], enabledProviders: 1, enabledProviderIDs: ["codex"])
        XCTAssertEqual(
            WidgetEntryRules.providerContent(snapshot, providerID: "claude", providerName: "Claude"),
            .message(offLine)
        )
    }

    func testTheFileForAPollCarriesWhichProvidersAreOnSortedWithTheirCount() {
        let on = WidgetBridge.snapshot(from: [], at: at, mode: .used, polled: ["grok", "codex", "claude"])
        XCTAssertEqual(on.enabledProviderIDs, ["claude", "codex", "grok"])
        XCTAssertEqual(on.enabledProviders, 3)
        let beforeTheFirstPoll = WidgetBridge.snapshot(from: [], at: at, mode: .used, polled: nil)
        XCTAssertNil(beforeTheFirstPoll.enabledProviderIDs)
        XCTAssertNil(beforeTheFirstPoll.enabledProviders)
    }

    func testThePublicationOfAFileCarriesWhichProvidersAreOn() {
        let claudeOn = WidgetBridge.publication(of: WidgetBridge.snapshot(from: [], at: at, mode: .used, polled: ["claude"]))
        let codexOn = WidgetBridge.publication(of: WidgetBridge.snapshot(from: [], at: at, mode: .used, polled: ["codex"]))
        XCTAssertEqual(codexOn.enabledProviderIDs, ["codex"])
        XCTAssertTrue(WidgetBridge.shouldPublish(codexOn, lastPublished: claudeOn))
        XCTAssertFalse(WidgetBridge.shouldPublish(codexOn, lastPublished: codexOn))
    }
}
