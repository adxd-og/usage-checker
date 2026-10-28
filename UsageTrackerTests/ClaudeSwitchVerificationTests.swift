import XCTest
@testable import Omelette

/// Verifier round for spec 2026-10-25 (Claude switch and sign-in) § Design › Package 1.
/// What the coders' tests leave open: the coordinator asked for nothing returns nothing
/// (no fetch), Claude on but signed out keeps its last-known numbers while Claude off drops
/// them, the picker's heal across the switches and the admin key (before and after the first
/// poll), the admin key counting as "something on" all the way to the widget's file, and the
/// "nothing on" words agreeing across surfaces and with the Settings tab's own name.
final class ClaudeSwitchVerificationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_100_000)
    private var t1: Date { t0.addingTimeInterval(60) }
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeSwitchVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func claudeReading() -> ServiceSnapshot {
        Fixture.snapshot(
            id: "claude", plan: "Claude Max 20x",
            buckets: [Fixture.bucket(id: "five_hour", label: "Current session", percent: 12, kind: .session)],
            at: t0
        )
    }

    private func codexReading() -> ServiceSnapshot {
        Fixture.snapshot(
            id: "codex", displayName: "Codex", plan: "Codex Plus",
            buckets: [Fixture.bucket(id: "codex_session", label: "Session", percent: 30, kind: .session)],
            at: t0
        )
    }

    private func signedOutClaude() -> ServiceSnapshot {
        Fixture.snapshot(id: "claude", plan: nil, buckets: [], state: .notSignedIn, stateMessage: "Sign in", at: t1)
    }

    // MARK: - The coordinator

    /// "Not fetched": with every switch off and no key the coordinator has nothing to call,
    /// so the poll is empty and carries no error. (A fetch of Claude would answer with a
    /// snapshot, signed in or not; so would the others.)
    func testACoordinatorAskedForNothingFetchesNothing() async {
        let poll = await ProviderCoordinator().snapshot(
            adminKey: nil, betaHeader: "", preferAdmin: true,
            claudeEnabled: false, codexEnabled: false, antigravityEnabled: false, grokEnabled: false
        )
        XCTAssertTrue(poll.services.isEmpty, "\(poll.services.map(\.id))")
        XCTAssertNil(poll.lastError)
        XCTAssertFalse(poll.hasAnyData)
    }

    func testAnEmptyAdminKeyIsNoKeyAtAll() async {
        let poll = await ProviderCoordinator().snapshot(
            adminKey: "", betaHeader: "", preferAdmin: false,
            claudeEnabled: false, codexEnabled: false, antigravityEnabled: false, grokEnabled: false
        )
        XCTAssertTrue(poll.services.isEmpty, "\(poll.services.map(\.id))")
    }

    // MARK: - Retention: signed out is not off

    func testClaudeOnButSignedOutKeepsItsLastKnownNumbersAndClaudeOffDropsThem() throws {
        let stored = ["claude": LastKnownService(from: claudeReading(), order: 0)]
        let previous = UsageSnapshot(services: [], fetchedAt: t0, isStale: false, lastError: nil)

        // On, signed out: the poll returns Claude as a failure; its numbers stay, dimmed.
        let on = AppState.mergingPoll(
            previous: previous,
            next: UsageSnapshot(
                services: [signedOutClaude(), codexReading()], fetchedAt: t1, isStale: false, lastError: "Sign in"
            ),
            stored: stored
        )
        let claude = try XCTUnwrap(on.services.first { $0.id == "claude" })
        XCTAssertEqual(claude.state, .notSignedIn)
        XCTAssertEqual(claude.buckets.map(\.id), ["five_hour"], "the last-known windows stay")
        XCTAssertTrue(claude.isRetained)

        // Off: the coordinator returns no Claude at all; the stored reading brings nothing back.
        let off = AppState.mergingPoll(
            previous: previous,
            next: UsageSnapshot(services: [codexReading()], fetchedAt: t1, isStale: false, lastError: nil),
            stored: stored
        )
        XCTAssertEqual(off.services.map(\.id), ["codex"])
    }

    func testEveryProviderOffLeavesAnEmptyScreenWhateverIsStored() {
        let stored = [
            "claude": LastKnownService(from: claudeReading(), order: 0),
            "codex": LastKnownService(from: codexReading(), order: 1),
        ]
        let previous = UsageSnapshot(
            services: [claudeReading(), codexReading()], fetchedAt: t0, isStale: false, lastError: nil
        )
        let merged = AppState.mergingPoll(
            previous: previous,
            next: UsageSnapshot(services: [], fetchedAt: t1, isStale: false, lastError: nil),
            stored: stored
        )
        XCTAssertTrue(merged.services.isEmpty)
        XCTAssertFalse(merged.isStale, "an empty poll is not 'every service failed'")
        XCTAssertFalse(merged.hasAnyData)
    }

    // MARK: - The picker, from the switches to the selection

    /// The chain the app runs: switches and key → polled set → what is switched off → what is
    /// on offer → where a stored selection goes. `recorded` is the history on disk, `live`
    /// what the screen holds now (a retained Claude included).
    private func picker(
        stored: String, claude: Bool, codex: Bool, adminKey: Bool,
        recorded: [String], live: [ServiceSnapshot]
    ) -> (available: [String], selection: String) {
        let polled = AppState.polledServiceIDs(
            claudeEnabled: claude, codexEnabled: codex, antigravityEnabled: false, grokEnabled: false,
            hasAdminKey: adminKey
        )
        let available = DashboardState.availableServices(
            recorded: recorded,
            snapshot: UsageSnapshot(services: live, fetchedAt: t0, isStale: false, lastError: nil),
            disabled: DashboardState.switchedOff(polled: polled)
        )
        return (available, DashboardState.healedSelection(stored: stored, available: available, polled: polled))
    }

    func testAStoredClaudeSelectionLeavesClaudeEvenWhileAKeptClaudeReadingIsStillOnScreen() {
        // Before the first poll after the switch: the retained Claude tile is still in the
        // snapshot and Claude has history, yet it is off.
        let result = picker(
            stored: "claude", claude: false, codex: true, adminKey: false,
            recorded: ["claude", "codex"], live: [claudeReading(), codexReading()]
        )
        XCTAssertEqual(result.available, ["codex"])
        XCTAssertEqual(result.selection, "codex")
    }

    func testWithEverythingOffAStoredClaudeSelectionLandsOnNoProvider() {
        let result = picker(
            stored: "claude", claude: false, codex: false, adminKey: false,
            recorded: ["claude", "codex"], live: [claudeReading()]
        )
        XCTAssertEqual(result.available, [])
        XCTAssertEqual(result.selection, DashboardState.noSelection)
    }

    func testAnAdminKeyAloneIsWhereAClaudeSelectionGoesWhenNothingIsOnOffer() {
        let result = picker(
            stored: "claude", claude: false, codex: false, adminKey: true,
            recorded: ["claude"], live: []
        )
        XCTAssertEqual(result.available, [])
        XCTAssertEqual(result.selection, "anthropic-admin")
    }

    func testAProviderThatIsOffGoesToClaudeNotToTheAdminOrganisationWhenBothArePolled() {
        // "anthropic-admin" sorts before "claude": the preference for Claude must be explicit.
        let polled: Set<String> = ["anthropic-admin", "claude"]
        XCTAssertEqual(DashboardState.healedSelection(stored: "grok", available: [], polled: polled), "claude")
        XCTAssertEqual(DashboardState.healedSelection(stored: "codex", available: [], polled: polled), "claude")
        XCTAssertEqual(DashboardState.healedSelection(stored: DashboardState.noSelection, available: [], polled: polled), "claude")
    }

    func testWithClaudeOffTheFirstPolledProviderByIdIsThePick() {
        XCTAssertEqual(
            DashboardState.healedSelection(stored: "claude", available: [], polled: ["grok", "antigravity"]),
            "antigravity"
        )
    }

    func testASelectionOnOfferIsNeverMovedByTheSwitches() {
        XCTAssertEqual(
            DashboardState.healedSelection(stored: "codex", available: ["claude", "codex"], polled: ["claude", "codex"]),
            "codex"
        )
    }

    // MARK: - The admin key is something on, all the way to the widget

    private func widgetFile(claude: Bool, codex: Bool, adminKey: Bool) -> WidgetSnapshot {
        let polled = AppState.polledServiceIDs(
            claudeEnabled: claude, codexEnabled: codex, antigravityEnabled: false, grokEnabled: false,
            hasAdminKey: adminKey
        )
        return WidgetBridge.snapshot(from: [], at: t0, mode: .used, enabledProviders: polled.count)
    }

    func testAnAdminKeyWithEverySwitchOffIsNotNothingOnForTheWidgetEither() {
        let keyOnly = widgetFile(claude: false, codex: false, adminKey: true)
        XCTAssertEqual(keyOnly.enabledProviders, 1)
        XCTAssertFalse(keyOnly.isNothingOn)
        XCTAssertEqual(WidgetEntryRules.allProvidersContent(keyOnly), .message(WidgetEntryRules.nothingReportingMessage))
        XCTAssertFalse(AppState.isNothingOn(polledIDs: AppState.polledServiceIDs(
            claudeEnabled: false, codexEnabled: false, antigravityEnabled: false, grokEnabled: false, hasAdminKey: true
        )))
    }

    func testNoSwitchAndNoKeyIsNothingOnForTheAppAndTheWidgetAlike() {
        let none = widgetFile(claude: false, codex: false, adminKey: false)
        XCTAssertEqual(none.enabledProviders, 0)
        XCTAssertTrue(none.isNothingOn)
        XCTAssertEqual(WidgetEntryRules.allProvidersContent(none), .message(NothingOnCopy.widget))
        XCTAssertTrue(AppState.isNothingOn(polledIDs: []))
    }

    func testAPerProviderWidgetInAFileWithoutTheProviderListReadsNoData() {
        // Claude's own widget, Claude switched off, Codex on, in a file that carries only the
        // count (an older build): not "all providers are off", and it cannot say "Claude is off".
        let file = widgetFile(claude: false, codex: true, adminKey: false)
        XCTAssertEqual(file.enabledProviders, 1)
        XCTAssertNil(file.enabledProviderIDs)
        XCTAssertEqual(WidgetEntryRules.providerContent(file, providerID: "claude", providerName: "Claude"), .message(WidgetEntryRules.noDataMessage))
    }

    func testTheFileTheAppWritesForNothingOnCarriesTheCountAnOlderReaderIgnores() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let written = try encoder.encode(widgetFile(claude: false, codex: false, adminKey: false))
        // A reader that knows nothing of the new key still opens the file (the key is extra).
        struct OldShape: Decodable { let services: [WidgetService]; let updatedAt: Date; let showsRemaining: Bool }
        let old = try decoder.decode(OldShape.self, from: written)
        XCTAssertTrue(old.services.isEmpty)
        // And an old file opens in the new reader as "does not say".
        let legacy = #"{"services": [], "updatedAt": "2026-10-27T09:00:00Z", "showsRemaining": true}"#
        let opened = try decoder.decode(WidgetSnapshot.self, from: Data(legacy.utf8))
        XCTAssertNil(opened.enabledProviders)
        XCTAssertTrue(opened.showsRemaining)
        XCTAssertEqual(WidgetEntryRules.allProvidersContent(opened), .message(WidgetEntryRules.nothingReportingMessage))
        XCTAssertEqual(WidgetEntryRules.providerContent(opened, providerID: "codex", providerName: "Codex"), .message(WidgetEntryRules.noDataMessage))
    }

    // MARK: - The words agree

    func testEverySurfaceNamesTheSettingsTabByItsOwnNameAndSaysTheSameFact() {
        let location = "Settings › \(SettingsTab.providers.rawValue)"
        let surfaces: [(String, String)] = [
            ("hint", NothingOnCopy.hint),
            ("tooltip", NothingOnCopy.tooltip),
            ("sentence", NothingOnCopy.sentence),
            ("button", NothingOnCopy.button),
            ("widget", NothingOnCopy.widget),
        ]
        for (name, words) in surfaces {
            XCTAssertTrue(words.contains(location), "\(name): \(words)")
        }
        for (name, words) in surfaces where name != "hint" && name != "button" {
            XCTAssertTrue(words.lowercased().contains(NothingOnCopy.title.lowercased()), "\(name): \(words)")
        }

        // The surfaces take their words from the rule, not from copies of it.
        let empty = UsageSnapshot(services: [], fetchedAt: t0, isStale: false, lastError: nil)
        XCTAssertEqual(
            StatusBarController.tooltipText(snapshot: empty, pollsNothing: true, now: t0),
            NothingOnCopy.tooltip
        )
        XCTAssertEqual(FloatingMiniLayout.content(for: nil, pollsNothing: true).emptyText, NothingOnCopy.sentence)
        XCTAssertEqual(
            WidgetEntryRules.allProvidersContent(WidgetSnapshot(services: [], updatedAt: t0, enabledProviders: 0)),
            .message(NothingOnCopy.widget)
        )
        XCTAssertEqual(PopoverView.emptyBody(pollsNothing: true, services: []), .nothingOn)
    }

    func testNothingOnIsNotLoadingOnAnySurfaceBeforeTheFirstPoll() {
        let empty = UsageSnapshot(services: [], fetchedAt: Date(timeIntervalSince1970: 0), isStale: false, lastError: nil)
        XCTAssertFalse(AppState.isNothingOn(polledIDs: nil))
        XCTAssertEqual(PopoverView.emptyBody(pollsNothing: false, services: []), .loading)
        XCTAssertEqual(FloatingMiniLayout.content(for: nil, pollsNothing: false).emptyText, "Loading…")
        XCTAssertNotEqual(
            StatusBarController.tooltipText(snapshot: empty, pollsNothing: false, now: t0),
            NothingOnCopy.tooltip
        )
    }

    // MARK: - The installed rule and the stored file

    func testAStoredFileThatIsNotAnObjectHoldsNoReading() throws {
        let array = directory.appendingPathComponent("array.json")
        try Data("[\"claude\"]".utf8).write(to: array)
        XCTAssertEqual(LastKnownStore.storedServiceIDs(fileURL: array), [])
        let empty = directory.appendingPathComponent("empty.json")
        try Data("{}".utf8).write(to: empty)
        XCTAssertEqual(LastKnownStore.storedServiceIDs(fileURL: empty), [])
        XCTAssertFalse(ClaudeOAuthProvider.isClaudeInstalled(
            home: "/test-home", fileExists: { _ in false },
            lastKnownServiceIDs: { LastKnownStore.storedServiceIDs(fileURL: array) }
        ))
    }

    func testAFailedClaudeIsNotKeptSoItDoesNotCountAsInstalled() async {
        // `remember` skips a failing service: a signed-out Claude with nothing to show leaves
        // no entry, so a Mac that only ever failed is not "Claude installed".
        let file = directory.appendingPathComponent("last-known.json")
        await LastKnownStore(fileURL: file).remember([signedOutClaude(), codexReading()])
        XCTAssertEqual(LastKnownStore.storedServiceIDs(fileURL: file), ["codex"])
    }
}
