import XCTest
@testable import Omelette

/// Cloud session credits spec § Published data: `status.json` keeps `percent` and adds
/// `usedDollars` / `limitDollars` on the pool's entry only; the CLI and MCP readers
/// tolerate files without them; the file's version stays 2. UTC and en_GB pinned.
final class CloudCreditsPublishedVerificationTests: XCTestCase {
    private var directory: URL!
    private let utc = TimeZone(identifier: "UTC")!
    private let locale = Locale(identifier: "en_GB")
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = utc
        c.locale = Locale(identifier: "en_GB")
        return c
    }
    /// Sunday 2026-10-04 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_791_115_200)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudCreditsPublishedVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func claudeBuckets() throws -> [UsageBucket] {
        try ClaudeOAuthProvider.usage(fromPayload: Data(Fixture.cloudCreditsPayload.utf8)).buckets
    }

    private func build(_ services: [ServiceSnapshot]) -> StatusSnapshot {
        StatusFileWriter.build(services: services, costs: [:], agents: .none, now: now, calendar: calendar, locale: locale)
    }

    private func claudeSnapshot(_ buckets: [UsageBucket]) -> ServiceSnapshot {
        Fixture.snapshot(id: "claude", displayName: "Claude", plan: "Max 5x", buckets: buckets, at: now)
    }

    private func window(
        _ id: String, _ label: String, _ percent: Double,
        resetsIn: TimeInterval? = nil, kind: String? = nil, used: Double? = nil, limit: Double? = nil
    ) -> StatusSnapshot.Window {
        StatusSnapshot.Window(
            id: id, label: label, percent: percent, resetsAt: resetsIn.map { now.addingTimeInterval($0) },
            kind: kind, usedDollars: used, limitDollars: limit
        )
    }

    private func service(
        _ windows: [StatusSnapshot.Window], id: String = "claude", name: String = "Claude",
        retained: Bool = false, retainedAt: Date? = nil
    ) -> StatusSnapshot.Service {
        StatusSnapshot.Service(
            id: id, name: name, state: "ok", retained: retained, retainedAt: retainedAt, plan: "Max 5x",
            windows: windows, todayCost: nil, weekCost: nil, todayTokens: nil, apiEquivalent: nil
        )
    }

    // MARK: - The published JSON

    func testTheFileCarriesTheDollarKeysOnTheCreditPoolsEntryAndNowhereElse() throws {
        let data = try StatusFile.encoder.encode(build([claudeSnapshot(try claudeBuckets())]))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(text.components(separatedBy: "\"usedDollars\"").count - 1, 1, text)
        XCTAssertEqual(text.components(separatedBy: "\"limitDollars\"").count - 1, 1, text)
        XCTAssertFalse(text.contains("null"), "absent keys are omitted, never written as null")

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 2, "version stays 2")
        XCTAssertEqual(StatusSnapshot.currentVersion, 2)
        let windows = try XCTUnwrap(((object["services"] as? [[String: Any]])?.first)?["windows"] as? [[String: Any]])
        for w in windows where (w["id"] as? String) != "iguana_necktie" {
            XCTAssertNil(w["usedDollars"], "\(w["id"] ?? "?")")
            XCTAssertNil(w["limitDollars"], "\(w["id"] ?? "?")")
        }
        let pool = try XCTUnwrap(windows.first { ($0["id"] as? String) == "iguana_necktie" })
        XCTAssertEqual(pool["percent"] as? Double, 92.368272, "percent stays alongside the dollars")
        XCTAssertEqual(pool["kind"] as? String, "other")
        XCTAssertEqual(pool["label"] as? String, "Cloud session credits")
        XCTAssertEqual(pool["usedDollars"] as? Double, 230.92068)
        XCTAssertEqual(pool["limitDollars"] as? Double, 250)
    }

    func testThePublishedFileRoundTripsThroughDiskAndLoad() throws {
        let built = build([claudeSnapshot(try claudeBuckets())])
        let url = directory.appendingPathComponent("status.json")
        try StatusFile.encoder.encode(built).write(to: url)
        let loaded = try XCTUnwrap(StatusFile.load(from: url), "version 2 file must still load")
        XCTAssertEqual(loaded, built)
        let pool = try XCTUnwrap(loaded.service(id: "claude")?.windows.first { $0.id == "iguana_necktie" })
        XCTAssertEqual(pool.usedDollars, 230.92068)
        XCTAssertEqual(pool.limitDollars, 250)
        XCTAssertTrue(pool.isCreditPool)
        XCTAssertTrue(pool.isBonusPool)
    }

    func testAPromoWindowPublishesNoDollarKeys() throws {
        let promo = Fixture.bucket(id: "seven_day_promotional", label: "Promo pool", percent: 40, kind: .other)
        let built = build([claudeSnapshot([promo])])
        let w = try XCTUnwrap(built.service(id: "claude")?.windows.first)
        XCTAssertNil(w.limitDollars)
        XCTAssertFalse(w.isCreditPool)
        XCTAssertTrue(w.isPromotional)
    }

    func testAFileWrittenBy301StillLoadsAndPrintsEverywhere() throws {
        // A complete status.json as 3.0.1 wrote it: no dollar keys, no showsRemaining.
        let json = """
        {
          "version": 2,
          "updatedAt": "2026-10-04T12:00:00Z",
          "agents": {"needsYou": 0, "working": 0, "sessions": []},
          "services": [{
            "id": "claude", "name": "Claude", "state": "ok", "retained": false, "plan": "Max 5x",
            "windows": [
              {"id": "five_hour", "label": "Current session", "percent": 7, "kind": "session", "resetsAt": "2026-10-04T12:49:59Z"},
              {"id": "seven_day", "label": "All models", "percent": 69, "kind": "weekly", "resetsAt": "2026-10-08T09:59:59Z"},
              {"id": "iguana_necktie", "label": "Iguana Necktie", "percent": 92.368272, "kind": "other", "resetsAt": "2026-11-05T07:59:00Z"}
            ]
          }]
        }
        """
        let url = directory.appendingPathComponent("status.json")
        try Data(json.utf8).write(to: url)
        let loaded = try XCTUnwrap(StatusFile.load(from: url))
        XCTAssertEqual(loaded.version, 2)
        XCTAssertTrue(loaded.services[0].windows.allSatisfy { $0.usedDollars == nil && $0.limitDollars == nil })
        // Every reader renders it, as a rate-limit window, without trouble.
        let status = StatusText.render(snapshot: loaded, now: now, calendar: calendar, locale: locale)
        XCTAssertTrue(status.contains("Iguana Necktie 92%"), status)
        let line = StatusLineText.render(snapshot: loaded, now: now, colour: false, calendar: calendar, locale: locale)
        XCTAssertTrue(line.contains("◐"), line)
        let mcp = MCPSummary.usage(snapshot: loaded, now: now, calendar: calendar, locale: locale)
        XCTAssertTrue(mcp.contains("Claude (Max 5x)"), mcp)
    }

    // MARK: - omelette status

    func testStatusPrintsDollarsAndExpiryForAPoolAndPercentForTheRest() throws {
        let snapshot = build([claudeSnapshot(try claudeBuckets())])
        let text = StatusText.render(snapshot: snapshot, now: now, calendar: calendar, locale: locale)
        XCTAssertTrue(text.contains("Cloud session credits $231 used of $250, expires 5 Nov, 7:59"), text)
        XCTAssertTrue(text.contains("Current session 7%"), text)
        XCTAssertTrue(text.contains("All models 69%"), text)
        XCTAssertFalse(text.contains("92%"), "the pool's percent is not printed: \(text)")
    }

    func testStatusPrintsDollarsEvenWhenTheAppCountsDown() throws {
        let snapshot = build([claudeSnapshot(try claudeBuckets())])
        let text = StatusText.windowText(
            try XCTUnwrap(snapshot.service(id: "claude")?.windows.first { $0.isCreditPool }),
            mode: .remaining, now: now, calendar: calendar, locale: locale
        )
        XCTAssertEqual(text, "Cloud session credits $231 used of $250, expires 5 Nov, 7:59")
        XCTAssertFalse(text.contains("left"))
    }

    func testTheTerminalSpellsTheDollarSignWhateverTheMachinesLocale() {
        let pool = window("p", "Included credits", 40, resetsIn: 86_400, kind: "other", used: 100, limit: 250)
        for loc in ["en_GB", "de_DE", "fr_FR", "ja_JP"] {
            let text = CreditCopy.terminalFigures(pool, now: now, calendar: calendar, locale: Locale(identifier: loc))
            XCTAssertTrue(text?.hasPrefix("$100 used of $250") == true, "\(loc): \(text ?? "nil")")
        }
    }

    func testAPoolWithNoExpiryPrintsJustItsDollars() {
        let pool = window("p", "Included credits", 40, kind: "other", used: 100, limit: 250)
        XCTAssertEqual(CreditCopy.terminalFigures(pool, now: now, calendar: calendar, locale: locale), "$100 used of $250")
        XCTAssertEqual(StatusText.windowText(pool, now: now, calendar: calendar, locale: locale), "Included credits $100 used of $250")
    }

    func testAWindowThatIsNotAPoolHasNoFigures() {
        XCTAssertNil(CreditCopy.terminalFigures(window("a", "A", 40), now: now, calendar: calendar, locale: locale))
    }

    func testAThousandDollarLimitPrintsItsSeparator() {
        let pool = window("p", "Included credits", 0, kind: "other", used: 0, limit: 1000)
        XCTAssertEqual(CreditCopy.terminalFigures(pool, now: now, calendar: calendar, locale: locale), "$0 used of $1,000")
    }

    func testAPoolDoesNotChangeAnOrdinaryWindowsLine() {
        let line = StatusText.windowText(
            window("seven_day", "All models", 69, resetsIn: 3 * 86_400, kind: "weekly"),
            now: now, calendar: calendar, locale: locale
        )
        XCTAssertEqual(line, "All models 69%, resets in 3d 0h (Wed 12:00)")
    }

    // MARK: - status line

    func testTheStatusLineLeadsWithTheSessionNotThePool() throws {
        let snapshot = build([claudeSnapshot(try claudeBuckets())])
        let line = StatusLineText.render(snapshot: snapshot, now: now, colour: false, calendar: calendar, locale: locale)
        XCTAssertEqual(line, "◐ 7% · resets in 49m")
    }

    func testWithoutASessionTheStatusLineLeadsWithTheWeeklyNotThePool() {
        let s = service([window("iguana_necktie", "Cloud session credits", 92, kind: "other", used: 231, limit: 250), window("seven_day", "All models", 69, kind: "weekly")])
        XCTAssertEqual(StatusLineText.headlineWindow(s)?.id, "seven_day")
    }

    func testTheStatusLineFallsBackToThePoolOnlyWhenItIsAllThereIs() {
        let s = service([window("iguana_necktie", "Cloud session credits", 92, kind: "other", used: 231, limit: 250)])
        XCTAssertEqual(StatusLineText.headlineWindow(s)?.id, "iguana_necktie")
    }

    func testAScopedCapBeatsACreditPoolInTheStatusLineWhenThereIsNoCoreWindow() {
        // Second tier of the fallback: model-scoped windows lead, the pool never stands in for them.
        let s = service([
            window("iguana_necktie", "Cloud session credits", 92, kind: "other", used: 231, limit: 250),
            window("seven_day_opus", "Opus only", 30, kind: "modelSpecific"),
        ])
        XCTAssertEqual(StatusLineText.headlineWindow(s)?.id, "seven_day_opus")
    }

    func testAScopedCapBeatsACreditPoolInTheMcpAdviceWhenThereIsNoCoreWindow() {
        let claude = service([
            window("iguana_necktie", "Cloud session credits", 92, kind: "other", used: 231, limit: 250),
            window("seven_day_opus", "Opus only", 30, kind: "modelSpecific"),
        ])
        let snapshot = StatusSnapshot(version: 2, updatedAt: now, services: [claude], agents: .none)
        XCTAssertEqual(MCPSummary.worstWindow(snapshot, now: now)?.window.id, "seven_day_opus")
    }

    func testTheStatusLinePromoRuleIsUnchanged() {
        let s = service([window("seven_day_promotional", "Promo pool", 99, kind: "other"), window("seven_day", "All models", 10, kind: "weekly")])
        XCTAssertEqual(StatusLineText.headlineWindow(s)?.id, "seven_day")
    }

    func testAPoolThatCarriesAKindOfSessionStillNeverLeads() {
        // Not a shape the app produces, but the rule is keyed on the dollars, not on kind.
        let s = service([window("x", "Pool", 99, kind: "session", used: 1, limit: 2), window("seven_day", "All models", 10, kind: "weekly")])
        XCTAssertEqual(StatusLineText.headlineWindow(s)?.id, "seven_day")
    }

    // MARK: - get_usage

    func testTheMcpSentenceQuotesThePoolAsDollarsAndTheAdviceIgnoresIt() throws {
        let snapshot = build([claudeSnapshot(try claudeBuckets())])
        let text = MCPSummary.usage(snapshot: snapshot, now: now, calendar: calendar, locale: locale)
        XCTAssertTrue(text.contains("cloud session credits $231 used of $250, expires 5 Nov, 7:59"), text)
        XCTAssertTrue(text.contains("Claude's all models window is 69% used"), text)
        XCTAssertFalse(text.contains("92%"), text)
    }

    func testTheAdviceNamesAnotherProvidersFullerWindowOverAHotterPool() {
        let claude = service([
            window("seven_day", "All models", 40, kind: "weekly"),
            window("iguana_necktie", "Cloud session credits", 92, kind: "other", used: 231, limit: 250),
        ])
        let codex = service([window("codex_weekly", "Weekly", 80, kind: "weekly")], id: "codex", name: "Codex")
        let snapshot = StatusSnapshot(version: 2, updatedAt: now, services: [claude, codex], agents: .none)
        let advice = MCPSummary.advice(for: snapshot, now: now, calendar: calendar, locale: locale)
        XCTAssertTrue(advice.hasPrefix("Codex's weekly window is 80% used"), advice)
    }

    func testTheWorstWindowFallsBackToThePoolOnlyWhenItIsTheOnlyReading() {
        let claude = service([window("iguana_necktie", "Cloud session credits", 92, kind: "other", used: 231, limit: 250)])
        let snapshot = StatusSnapshot(version: 2, updatedAt: now, services: [claude], agents: .none)
        XCTAssertEqual(MCPSummary.worstWindow(snapshot, now: now)?.window.id, "iguana_necktie")
    }

    func testARetainedCreditPoolStillPrintsAsDollars() {
        let stamp = now.addingTimeInterval(-3 * 3600)
        let s = service(
            [window("iguana_necktie", "Cloud session credits", 92, resetsIn: 31 * 86_400, kind: "other", used: 231, limit: 250)],
            retained: true, retainedAt: stamp
        )
        let sentence = MCPSummary.serviceSentence(s, now: now, calendar: calendar, locale: locale)
        XCTAssertTrue(sentence.contains("cloud session credits $231 used of $250"), sentence)
        let line = StatusText.serviceLine(s, width: 6, now: now, calendar: calendar, locale: locale)
        XCTAssertTrue(line.contains("Cloud session credits $231 used of $250"), line)
        XCTAssertTrue(line.contains("last known"), line)
    }

    // MARK: - docs the spec's package 5 asks for

    private func repoFile(_ name: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()
        url.deleteLastPathComponent()
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("UsageTracker.xcodeproj").path) else {
            throw XCTSkip("could not locate the repo root from #filePath")
        }
        return try String(contentsOf: url.appendingPathComponent(name), encoding: .utf8)
    }

    func testTheReadmeLimitsTableMentionsTheCreditsAsDollars() throws {
        let readme = try repoFile("README.md")
        XCTAssertTrue(readme.contains("Cloud session credits: shown as dollars, never drives the menu bar"))
    }

    func testTheChangelogCarriesAnUnreleasedClaudeLineAboveTheLastRelease() throws {
        let changelog = try repoFile("CHANGELOG.md")
        let unreleased = try XCTUnwrap(changelog.range(of: "## [Unreleased]"))
        let release = try XCTUnwrap(changelog.range(of: "## [3.0.1]"))
        XCTAssertLessThan(unreleased.lowerBound, release.lowerBound)
        let section = String(changelog[unreleased.upperBound..<release.lowerBound])
        XCTAssertTrue(section.contains("### Claude"))
        XCTAssertTrue(section.contains("Cloud session credits"))
        XCTAssertTrue(section.contains("Included"))
    }
}
