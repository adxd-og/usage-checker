import XCTest
@testable import Omelette

/// Verifier round for the owner ruling of 2026-10-28 on spec 2026-10-25 § Package 1: a
/// provider widget pinned to a switched-off provider says "<Provider> is off". Covers what
/// `WidgetProviderOffTests` leaves: the ids the app really publishes (admin key included),
/// the file as an older build reads it, the All providers widget, the exact line per name.
final class WidgetProviderOffVerificationTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_793_100_000)

    private func service(_ id: String) -> WidgetService {
        WidgetService(
            id: id, name: id.capitalized, icon: "sparkles", plan: nil,
            buckets: [WidgetBucket(id: "\(id)_session", label: "Session", percent: 40, kind: "session")]
        )
    }

    private func file(_ ids: [String], count: Int?, polled: [String]?) -> WidgetSnapshot {
        WidgetSnapshot(services: ids.map(service), updatedAt: at, enabledProviders: count, enabledProviderIDs: polled)
    }

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: - The ids the app really publishes

    func testOnlyTheAdminKeyOnLeavesEveryPerProviderWidgetOff() {
        // The admin organisation is polled but no widget can be pinned to it: Claude, Codex,
        // Antigravity and Grok are all off, and the count (1) is not the "nothing on" 0.
        let polled = AppState.polledServiceIDs(
            claudeEnabled: false, codexEnabled: false, antigravityEnabled: false, grokEnabled: false, hasAdminKey: true
        )
        let snapshot = WidgetBridge.snapshot(
            from: [], at: at, mode: .used, enabledProviders: polled.count, enabledProviderIDs: polled.sorted()
        )
        XCTAssertFalse(snapshot.isNothingOn)
        for (id, name) in [("claude", "Claude"), ("codex", "Codex"), ("antigravity", "Antigravity"), ("grok", "Grok")] {
            XCTAssertEqual(
                WidgetEntryRules.providerContent(snapshot, providerID: id, providerName: name),
                .message("\(name) is off. Turn it on in Omelette's Settings › Providers."),
                id
            )
        }
    }

    func testTheSetThePollRunsWithIsTheSetTheWidgetFileSaysIsOn() {
        let polled = AppState.polledServiceIDs(
            claudeEnabled: false, codexEnabled: true, antigravityEnabled: true, grokEnabled: false, hasAdminKey: true
        )
        let snapshot = WidgetBridge.snapshot(
            from: [], at: at, mode: .used, enabledProviders: polled.count, enabledProviderIDs: polled.sorted()
        )
        XCTAssertEqual(snapshot.enabledProviderIDs, ["anthropic-admin", "antigravity", "codex"])
        XCTAssertEqual(snapshot.enabledProviders, snapshot.enabledProviderIDs?.count)
        XCTAssertEqual(
            WidgetEntryRules.providerContent(snapshot, providerID: "grok", providerName: "Grok"),
            .message(NothingOnCopy.providerOff("Grok"))
        )
        // On, listening, nothing in the file: still "No data".
        XCTAssertEqual(
            WidgetEntryRules.providerContent(snapshot, providerID: "codex", providerName: "Codex"),
            .message(WidgetEntryRules.noDataMessage)
        )
    }

    func testAProviderThatIsOnAndReportingIsDrawnNotCalledOff() {
        let snapshot = file(["codex"], count: 2, polled: ["claude", "codex"])
        XCTAssertEqual(
            WidgetEntryRules.providerContent(snapshot, providerID: "codex", providerName: "Codex"),
            .service(service("codex"))
        )
    }

    // MARK: - The line

    func testTheLineNamesTheProviderAndPointsToSettingsInEachCase() {
        XCTAssertEqual(NothingOnCopy.providerOff("Claude"), "Claude is off. Turn it on in Omelette's Settings › Providers.")
        XCTAssertEqual(NothingOnCopy.providerOff("Antigravity"), "Antigravity is off. Turn it on in Omelette's Settings › Providers.")
    }

    // MARK: - The file an older build wrote, and the file a newer one writes

    func testAFileAnOlderBuildWroteStillReadsNoDataForEveryProvider() throws {
        let json = #"{"services": [], "updatedAt": "2026-10-27T09:00:00Z", "showsRemaining": true, "enabledProviders": 2}"#
        let opened = try decoder.decode(WidgetSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(opened.enabledProviderIDs)
        for id in ["claude", "codex", "antigravity", "grok"] {
            XCTAssertFalse(opened.isSwitchedOff(id), id)
            XCTAssertEqual(
                WidgetEntryRules.providerContent(opened, providerID: id, providerName: id),
                .message(WidgetEntryRules.noDataMessage), id
            )
        }
    }

    func testAnExplicitNullOrAnEmptyListDecodesAsWritten() throws {
        let null = #"{"services": [], "updatedAt": "2026-10-27T09:00:00Z", "enabledProviderIDs": null}"#
        XCTAssertNil(try decoder.decode(WidgetSnapshot.self, from: Data(null.utf8)).enabledProviderIDs)
        // The empty list is a statement ("nothing is on"), not an absence: with the count
        // 0 beside it the nothing-on line wins over any per-provider line.
        let empty = #"{"services": [], "updatedAt": "2026-10-27T09:00:00Z", "enabledProviders": 0, "enabledProviderIDs": []}"#
        let opened = try decoder.decode(WidgetSnapshot.self, from: Data(empty.utf8))
        XCTAssertEqual(opened.enabledProviderIDs, [])
        XCTAssertEqual(
            WidgetEntryRules.providerContent(opened, providerID: "claude", providerName: "Claude"),
            .message(NothingOnCopy.widget)
        )
    }

    func testTheNewFileKeepsEveryKeyAnOlderExtensionReadsAndAddsOne() throws {
        let snapshot = file(["codex"], count: 1, polled: ["codex"])
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(snapshot)) as? [String: Any]
        )
        // An older extension decodes services, updatedAt, showsRemaining, enabledProviders
        // and ignores the rest; none of them may move or change type.
        XCTAssertNotNil(object["services"] as? [[String: Any]])
        XCTAssertNotNil(object["updatedAt"] as? String)
        XCTAssertEqual(object["showsRemaining"] as? Bool, false)
        XCTAssertEqual(object["enabledProviders"] as? Int, 1)
        XCTAssertEqual(object["enabledProviderIDs"] as? [String], ["codex"])
        XCTAssertEqual(try decoder.decode(WidgetSnapshot.self, from: encoder.encode(snapshot)), snapshot)
    }

    // MARK: - Order of the checks, and the other widget

    func testNothingOnWinsOverSwitchedOffAndSwitchedOffWinsOverAServiceInTheFile() {
        // 0 providers on, yet a stale row and a list that lacks the id: the all-off line.
        let allOff = file(["claude"], count: 0, polled: [])
        XCTAssertEqual(
            WidgetEntryRules.providerContent(allOff, providerID: "claude", providerName: "Claude"),
            .message(NothingOnCopy.widget)
        )
        // A retained row of a provider that is off does not draw numbers.
        let retained = file(["claude", "codex"], count: 1, polled: ["codex"])
        XCTAssertEqual(
            WidgetEntryRules.providerContent(retained, providerID: "claude", providerName: "Claude"),
            .message(NothingOnCopy.providerOff("Claude"))
        )
    }

    func testNoFileStillSaysOpenOmeletteWhateverTheProviderIs() {
        XCTAssertEqual(
            WidgetEntryRules.providerContent(nil, providerID: "claude", providerName: "Claude"),
            .message(WidgetEntryRules.openAppMessage)
        )
    }

    func testTheAllProvidersWidgetIgnoresWhichProvidersAreOff() {
        let rows = file(["codex"], count: 1, polled: ["codex"])
        XCTAssertEqual(WidgetEntryRules.allProvidersContent(rows), .snapshot(rows))
        // Nothing reporting while some are on: the same line as before, not a provider-off one.
        let none = file([], count: 1, polled: ["codex"])
        XCTAssertEqual(WidgetEntryRules.allProvidersContent(none), .message(WidgetEntryRules.nothingReportingMessage))
    }

    func testThePreviewSampleNeverSaysAProviderIsOff() {
        XCTAssertNil(WidgetSnapshot.placeholder.enabledProviderIDs)
        let sample = WidgetEntryRules.snapshot(read: nil, isPreview: true)
        for id in ["claude", "codex", "antigravity", "grok"] {
            XCTAssertFalse(sample?.isSwitchedOff(id) ?? true, id)
        }
    }

    // MARK: - The change comparison

    func testTheSameNothingToDrawIsNotRewrittenButAMovedListIs() {
        let a = WidgetBridge.Publication(services: [], enabledProviders: 2, enabledProviderIDs: ["claude", "codex"])
        XCTAssertFalse(WidgetBridge.shouldPublish(a, lastPublished: a))
        // Same count, a different pair: a provider widget has to hear it.
        let b = WidgetBridge.Publication(services: [], enabledProviders: 2, enabledProviderIDs: ["claude", "grok"])
        XCTAssertTrue(WidgetBridge.shouldPublish(b, lastPublished: a))
        // Before the first poll (nil) against the first poll's list.
        let before = WidgetBridge.Publication(services: [], enabledProviders: nil, enabledProviderIDs: nil)
        XCTAssertTrue(WidgetBridge.shouldPublish(a, lastPublished: before))
        XCTAssertTrue(WidgetBridge.shouldPublish(a, lastPublished: nil))
    }

    func testAFailedWriteOfAMovedListIsTriedAgain() {
        let a = WidgetBridge.Publication(services: [], enabledProviders: 1, enabledProviderIDs: ["claude"])
        let b = WidgetBridge.Publication(services: [], enabledProviders: 1, enabledProviderIDs: ["codex"])
        let recorded = WidgetBridge.recordedPublication(b, wrote: false, previous: a)
        XCTAssertEqual(recorded, a)
        XCTAssertTrue(WidgetBridge.shouldPublish(b, lastPublished: recorded))
    }
}
