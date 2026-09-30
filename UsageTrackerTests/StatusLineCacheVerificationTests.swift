import XCTest
@testable import Omelette

// Independent verification of the status line's prompt-cache timer, derived from
// `docs/superpowers/specs/2026-09-30-statusline-cache-timer.md` (§ Design: Input, Rule,
// Line; § Decisions) and the session rulings: a garbled `expires_at` drops the whole
// `prompt_cache`; `null` or absent `expires_at` with `warm: true` is `cache cold`;
// `warm` and `caching_observed` must be JSON booleans; the segment may lead the line
// when there is no prefix. Not derived from the executor's tests.

// MARK: - Parser

/// § Input: `StatusLineInput.promptCache` from `prompt_cache`.
final class StatusLineCacheParserVerificationTests: XCTestCase {
    private func parse(_ json: String) -> StatusLineInput {
        StatusLineInput.parse(Data(json.utf8))
    }

    /// A payload shaped like Claude Code's: model, context window, `prompt_cache`.
    private func payload(cache fields: String) -> String {
        #"{"model":{"display_name":"Opus"},"context_window":{"used_percentage":42},"prompt_cache":{\#(fields)}}"#
    }

    private let expiry = Date(timeIntervalSince1970: 1_788_697_200)

    // MARK: present

    func testAFullPromptCacheObjectIsRead() {
        let input = parse(payload(cache: """
        "warm":true,"caching_observed":true,"ttl":"1h","expires_at":1788697200,\
        "last_miss_at":null,"last_miss_cause":null,"hit_ratio":0.93,"cache_read_tokens":100
        """))

        XCTAssertEqual(
            input.promptCache,
            StatusLineInput.PromptCache(warm: true, ttl: "1h", expiresAt: expiry, cachingObserved: true)
        )
        XCTAssertEqual(input.model, "Opus")
        XCTAssertEqual(input.contextUsedPercent, 42)
    }

    func testAFractionalEpochIsKept() {
        let input = parse(payload(cache: #""warm":true,"caching_observed":true,"ttl":"5m","expires_at":1788697200.25"#))
        XCTAssertEqual(input.promptCache?.expiresAt, Date(timeIntervalSince1970: 1_788_697_200.25))
    }

    func testANumericStringExpiryIsRead() {
        let input = parse(payload(cache: #""warm":true,"caching_observed":true,"ttl":"1h","expires_at":"1788697200""#))
        XCTAssertEqual(input.promptCache?.expiresAt, expiry)
        XCTAssertEqual(input.promptCache?.warm, true)
    }

    func testAWarmFalseObjectIsRead() {
        let input = parse(payload(cache: #""warm":false,"caching_observed":true,"ttl":"1h","expires_at":null"#))
        XCTAssertEqual(
            input.promptCache,
            StatusLineInput.PromptCache(warm: false, ttl: "1h", expiresAt: nil, cachingObserved: true)
        )
    }

    func testCachingObservedFalseIsRead() {
        let input = parse(payload(cache: #""warm":false,"caching_observed":false,"expires_at":null"#))
        XCTAssertEqual(input.promptCache?.cachingObserved, false)
        XCTAssertEqual(input.promptCache?.warm, false)
    }

    // MARK: null / absent expiry

    func testANullExpiryIsNilAndTheObjectSurvives() {
        let input = parse(payload(cache: #""warm":true,"caching_observed":true,"ttl":"5m","expires_at":null"#))
        let cache = input.promptCache
        XCTAssertNotNil(cache)
        XCTAssertNil(cache?.expiresAt)
        XCTAssertEqual(cache?.warm, true)
        XCTAssertEqual(CacheLifeRules.segment(cache: cache, now: expiry)?.text, "cache cold")
    }

    func testAnAbsentExpiryIsNilAndTheObjectSurvives() {
        let input = parse(payload(cache: #""warm":true,"caching_observed":true,"ttl":"5m""#))
        XCTAssertNotNil(input.promptCache)
        XCTAssertNil(input.promptCache?.expiresAt)
        XCTAssertEqual(CacheLifeRules.segment(cache: input.promptCache, now: expiry)?.text, "cache cold")
    }

    // MARK: absent / malformed object

    func testAMissingPromptCacheIsNil() {
        let input = parse(#"{"model":{"display_name":"Opus"},"context_window":{"used_percentage":42}}"#)
        XCTAssertNil(input.promptCache)
        XCTAssertEqual(input.model, "Opus")
        XCTAssertEqual(input.contextUsedPercent, 42)
    }

    func testAPromptCacheThatIsNotAnObjectIsNil() {
        for shape in ["null", "[]", #""warm""#, "true", "42", "{}"] {
            let input = parse(#"{"model":{"display_name":"Opus"},"prompt_cache":\#(shape)}"#)
            XCTAssertNil(input.promptCache, "prompt_cache: \(shape)")
            XCTAssertEqual(input.model, "Opus", "the rest of the payload still reads: \(shape)")
        }
    }

    // MARK: warm and caching_observed must be JSON booleans

    func testWarmMustBeAJSONBoolean() {
        for value in ["1", "0", #""true""#, #""false""#, "null", "{}", "[]", #""yes""#] {
            let input = parse(payload(cache: #""warm":\#(value),"caching_observed":true,"expires_at":1788697200"#))
            XCTAssertNil(input.promptCache, "warm: \(value) drops the whole object")
        }
        let missing = parse(payload(cache: #""caching_observed":true,"expires_at":1788697200"#))
        XCTAssertNil(missing.promptCache, "warm absent")
    }

    func testCachingObservedMustBeAJSONBoolean() {
        for value in ["1", "0", #""true""#, #""false""#, "null", "{}", "[]"] {
            let input = parse(payload(cache: #""warm":true,"caching_observed":\#(value),"expires_at":1788697200"#))
            XCTAssertNil(input.promptCache, "caching_observed: \(value) drops the whole object")
        }
        let missing = parse(payload(cache: #""warm":true,"expires_at":1788697200"#))
        XCTAssertNil(missing.promptCache, "caching_observed absent")
    }

    // MARK: garbled expires_at drops the whole prompt_cache

    func testAGarbledExpiryDropsTheWholePromptCache() {
        let garbled = ["true", "false", #""soon""#, #""""#, "{}", "[]", "[1788697200]", #""1e400""#, #""nan""#, #""inf""#]
        for value in garbled {
            let input = parse(payload(cache: #""warm":true,"caching_observed":true,"ttl":"1h","expires_at":\#(value)"#))
            XCTAssertNil(input.promptCache, "expires_at: \(value) drops the whole object")
            XCTAssertEqual(input.model, "Opus", "the rest of the payload still reads: \(value)")
            XCTAssertEqual(input.contextUsedPercent, 42, "the rest of the payload still reads: \(value)")
        }
    }

    /// `1e400` written as a bare JSON number overflows `JSONSerialization` itself, so
    /// the document is rejected whole. Whatever the parser does with the rest, the
    /// prompt cache must not come out of it.
    func testAnOverflowingNumberLiteralAsExpiryYieldsNoPromptCache() {
        let input = parse(payload(cache: #""warm":true,"caching_observed":true,"ttl":"1h","expires_at":1e400"#))
        XCTAssertNil(input.promptCache)
    }

    // MARK: ttl

    func testTheTTLIsTrimmedAndOtherwiseKeptAsGiven() {
        func ttl(_ literal: String) -> String? {
            parse(payload(cache: #""warm":true,"caching_observed":true,"ttl":\#(literal),"expires_at":1788697200"#))
                .promptCache?.ttl
        }
        XCTAssertEqual(ttl(#""5m""#), "5m")
        XCTAssertEqual(ttl(#""1h""#), "1h")
        XCTAssertEqual(ttl(#"" 1h ""#), "1h", "trimmed")
        XCTAssertEqual(ttl(#""2h""#), "2h", "anything else is kept as given")
        XCTAssertEqual(ttl(#""1H""#), "1H", "not normalised")
    }

    func testAMissingOrNonStringTTLLeavesTheObjectStanding() {
        let none = parse(payload(cache: #""warm":true,"caching_observed":true,"expires_at":1788697200"#))
        XCTAssertNotNil(none.promptCache)
        XCTAssertNil(none.promptCache?.ttl)
        let number = parse(payload(cache: #""warm":true,"caching_observed":true,"ttl":3600,"expires_at":1788697200"#))
        XCTAssertNotNil(number.promptCache)
        XCTAssertNil(number.promptCache?.ttl)
    }

    /// The parser feeds the rule: a padded `" 1h "` still gets the hour thresholds.
    func testAPaddedHourTTLStillGetsTheHourThresholdsThroughTheParser() {
        let now = expiry.addingTimeInterval(-4 * 60)
        let cache = parse(payload(cache: #""warm":true,"caching_observed":true,"ttl":" 1h ","expires_at":1788697200"#))
            .promptCache
        XCTAssertEqual(CacheLifeRules.segment(cache: cache, now: now)?.state, .closing)
    }

    // MARK: unchanged neighbours

    func testTheModelAndContextWindowReadExactlyAsBefore() {
        XCTAssertEqual(
            parse(#"{"model":{"display_name":" Opus 4.5 "},"context_window":{"used_percentage":61.5}}"#),
            StatusLineInput(model: "Opus 4.5", contextUsedPercent: 61.5)
        )
        XCTAssertEqual(parse(#"{"context_window":{"used_percentage":150}}"#).contextUsedPercent, 100)
        XCTAssertEqual(parse(#"{"context_window":{"used_percentage":-3}}"#).contextUsedPercent, 0)
        XCTAssertEqual(parse(#"{"context_window":{"used_percentage":"61.5"}}"#).contextUsedPercent, 61.5)
        XCTAssertNil(parse(#"{"context_window":{"used_percentage":true}}"#).contextUsedPercent)
        XCTAssertNil(parse(#"{"model":"claude-opus-4-5"}"#).model, "an id is not a name")
        XCTAssertNil(parse(#"{"model":{"id":"claude-opus-4-5"}}"#).model)
        XCTAssertNil(parse(#"{"model":{"display_name":"  "}}"#).model)
    }

    func testEmptyInvalidAndNonObjectPayloadsAreStillNone() {
        XCTAssertEqual(StatusLineInput.parse(Data()), .none)
        XCTAssertEqual(parse("not json"), .none)
        XCTAssertEqual(parse("[1,2,3]"), .none)
        XCTAssertEqual(parse("{}"), .none)
        XCTAssertNil(StatusLineInput.none.promptCache)
        XCTAssertNil(StatusLineInput.none.model)
        XCTAssertNil(StatusLineInput.none.contextUsedPercent)
    }

    func testAPayloadWithOnlyAPromptCacheIsNotNone() {
        let input = parse(#"{"prompt_cache":{"warm":true,"caching_observed":true,"ttl":"1h","expires_at":1788697200}}"#)
        XCTAssertNil(input.model)
        XCTAssertNil(input.contextUsedPercent)
        XCTAssertNotNil(input.promptCache)
        XCTAssertNotEqual(input, .none)
    }

    func testTheInitialiserDefaultsThePromptCacheToNil() {
        XCTAssertNil(StatusLineInput(model: "Opus", contextUsedPercent: 42).promptCache)
        XCTAssertEqual(
            StatusLineInput(model: "Opus", contextUsedPercent: 42),
            StatusLineInput(model: "Opus", contextUsedPercent: 42, promptCache: nil)
        )
    }
}

// MARK: - The line

/// § Line: where the segment sits, when it prints, how it is coloured.
final class StatusLineCacheLineVerificationTests: XCTestCase {
    /// Sunday 2026-09-06 11:20:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_788_693_600)
    private let utc = TimeZone(identifier: "UTC")!
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = utc
        c.locale = Locale(identifier: "en_GB")
        return c
    }
    private let locale = Locale(identifier: "en_GB")

    private let esc = "\u{1B}"
    private let dim = "\u{1B}[2m"
    private let yellow = "\u{1B}[2;33m"
    private let red = "\u{1B}[2;31m"
    private let reset = "\u{1B}[0m"

    private func snapshot(
        percent: Double = 42,
        resetsIn: TimeInterval? = 70 * 60,
        todayCost: Double? = 4.2,
        needsYou: Int = 1,
        updatedAt: Date? = nil
    ) -> StatusSnapshot {
        StatusSnapshot(
            version: 1,
            updatedAt: updatedAt ?? now,
            services: [
                StatusSnapshot.Service(
                    id: "claude", name: "Claude", state: "ok", retained: false, retainedAt: nil,
                    plan: nil,
                    windows: [
                        StatusSnapshot.Window(
                            id: "five_hour", label: "Session", percent: percent,
                            resetsAt: resetsIn.map { now.addingTimeInterval($0) }, kind: "session"
                        ),
                    ],
                    todayCost: todayCost, weekCost: nil, todayTokens: nil, apiEquivalent: true
                ),
            ],
            agents: StatusSnapshot.Agents(needsYou: needsYou, working: 0, sessions: [])
        )
    }

    private func cache(
        expiresIn seconds: TimeInterval?, warm: Bool = true, ttl: String? = "1h", observed: Bool = true
    ) -> StatusLineInput.PromptCache {
        StatusLineInput.PromptCache(
            warm: warm, ttl: ttl, expiresAt: seconds.map { now.addingTimeInterval($0) },
            cachingObserved: observed
        )
    }

    private func render(
        _ snapshot: StatusSnapshot?,
        model: String? = "Fable 5.1",
        context: Double? = 55,
        cache: StatusLineInput.PromptCache?,
        colour: Bool = false,
        provider: String = "claude"
    ) -> String {
        StatusLineText.render(
            snapshot: snapshot, provider: provider, now: now,
            input: StatusLineInput(model: model, contextUsedPercent: context, promptCache: cache),
            colour: colour, calendar: calendar, locale: locale
        )
    }

    // MARK: place

    func testTheSegmentSitsRightAfterThePrefixAndBeforeTheGauge() {
        let line = render(snapshot(), cache: cache(expiresIn: 47 * 60 + 10))

        XCTAssertEqual(
            line,
            "Fable 5.1 [######----] 55% · cache 47m · ◐ 42% · resets in 1h 10m · ≈$4.20 today · ⚑ 1"
        )
        let bar = line.range(of: "55%")!.upperBound
        let segment = line.range(of: "cache 47m")!
        let gauge = line.range(of: "◐")!
        XCTAssertTrue(bar <= segment.lowerBound && segment.upperBound <= gauge.lowerBound, line)
    }

    /// The spec's own example line.
    func testTheSpecExampleLineIsWhatTheLinePrints() {
        let line = render(
            snapshot(percent: 3, resetsIn: 4 * 3600 + 14 * 60, todayCost: 10.35, needsYou: 0),
            cache: cache(expiresIn: 47 * 60 + 12)
        )
        XCTAssertEqual(
            line, "Fable 5.1 [######----] 55% · cache 47m · ◐ 3% · resets in 4h 14m · ≈$10.35 today"
        )
    }

    func testWithNoSegmentTheLineIsExactlyWhatItWasBefore() {
        let before = StatusLineText.render(
            snapshot: snapshot(), now: now,
            input: StatusLineInput(model: "Fable 5.1", contextUsedPercent: 55),
            colour: false, calendar: calendar, locale: locale
        )
        XCTAssertEqual(render(snapshot(), cache: nil), before)
        XCTAssertEqual(
            render(snapshot(), cache: cache(expiresIn: 47 * 60, observed: false)), before,
            "caching_observed false prints the same line as no prompt_cache at all"
        )
        XCTAssertEqual(
            render(snapshot(), cache: cache(expiresIn: nil, warm: false, observed: false)), before
        )
        XCTAssertFalse(before.contains("cache"), before)
    }

    func testTheGaugeFollowsTheSegmentWithNoDoubledOrTrailingSeparator() {
        let alone = render(snapshot(todayCost: nil, needsYou: 0), cache: cache(expiresIn: 47 * 60))
        XCTAssertEqual(alone, "Fable 5.1 [######----] 55% · cache 47m · ◐ 42% · resets in 1h 10m")
        let emptyAccount = render(
            StatusSnapshot(
                version: 1, updatedAt: now,
                services: [],
                agents: StatusSnapshot.Agents(needsYou: 0, working: 0, sessions: [])
            ),
            cache: cache(expiresIn: 47 * 60)
        )
        XCTAssertEqual(emptyAccount, "Fable 5.1 [######----] 55% · cache 47m")
    }

    func testAWaitingAgentStillTrailsTheAccountNotTheSegment() {
        let line = render(snapshot(), cache: cache(expiresIn: 47 * 60), provider: "codex")
        XCTAssertEqual(line, "Fable 5.1 [######----] 55% · cache 47m · ⚑ 1", "any provider: the cache is the session's")
    }

    func testAModelWithoutAContextReadingStillGetsTheSegmentAfterIt() {
        XCTAssertEqual(
            render(snapshot(), context: nil, cache: cache(expiresIn: 47 * 60)),
            "Fable 5.1 · cache 47m · ◐ 42% · resets in 1h 10m · ≈$4.20 today · ⚑ 1"
        )
    }

    // MARK: with and without a snapshot

    func testTheSegmentPrintsWithNoSnapshot() {
        XCTAssertEqual(
            render(nil, cache: cache(expiresIn: 47 * 60)),
            "Fable 5.1 [######----] 55% · cache 47m"
        )
    }

    func testTheSegmentPrintsWithAStaleSnapshotAndTheAccountStaysHidden() {
        let stale = snapshot(updatedAt: now.addingTimeInterval(-3600))
        XCTAssertEqual(
            render(stale, cache: cache(expiresIn: 47 * 60)),
            "Fable 5.1 [######----] 55% · cache 47m"
        )
        let justStale = snapshot(updatedAt: now.addingTimeInterval(-600))
        XCTAssertEqual(
            render(justStale, cache: cache(expiresIn: 47 * 60)),
            "Fable 5.1 [######----] 55% · cache 47m",
            "exactly ten minutes old is stale"
        )
    }

    func testAColdCachePrintsWithAndWithoutASnapshot() {
        XCTAssertEqual(
            render(nil, cache: cache(expiresIn: -5)),
            "Fable 5.1 [######----] 55% · cache cold"
        )
        XCTAssertEqual(
            render(snapshot(), cache: cache(expiresIn: nil, warm: true)),
            "Fable 5.1 [######----] 55% · cache cold · ◐ 42% · resets in 1h 10m · ≈$4.20 today · ⚑ 1"
        )
    }

    // MARK: no prefix

    func testWithNoPrefixTheSegmentLeadsTheLine() {
        XCTAssertEqual(
            render(snapshot(), model: nil, context: nil, cache: cache(expiresIn: 47 * 60)),
            "cache 47m · ◐ 42% · resets in 1h 10m · ≈$4.20 today · ⚑ 1"
        )
        XCTAssertEqual(
            render(nil, model: nil, context: nil, cache: cache(expiresIn: 47 * 60)),
            "cache 47m"
        )
        XCTAssertEqual(
            render(nil, model: nil, context: nil, cache: cache(expiresIn: -1)),
            "cache cold"
        )
    }

    func testWithNoPrefixAndNoSegmentTheLineIsTheAccountAlone() {
        XCTAssertEqual(
            render(snapshot(), model: nil, context: nil, cache: nil),
            "◐ 42% · resets in 1h 10m · ≈$4.20 today · ⚑ 1"
        )
        XCTAssertEqual(render(nil, model: nil, context: nil, cache: nil), "")
    }

    // MARK: colour

    func testTheSegmentIsWrappedInItsStateColourAndTheAccountIsNotColoured() {
        let cases: [(String, StatusLineInput.PromptCache, String)] = [
            ("warm 47m", cache(expiresIn: 47 * 60 + 10), dim),
            ("warm 5:00 on 1h", cache(expiresIn: 300, ttl: "1h"), dim),
            ("closing 4:59 on 1h", cache(expiresIn: 299, ttl: "1h"), yellow),
            ("warm 1:00 on 5m", cache(expiresIn: 60, ttl: "5m"), dim),
            ("closing 0:59 on 5m", cache(expiresIn: 59, ttl: "5m"), yellow),
            ("expired", cache(expiresIn: 0), red),
            ("warm false", cache(expiresIn: 47 * 60, warm: false), red),
        ]
        for (label, cache, colour) in cases {
            let line = render(snapshot(), cache: cache, colour: true)
            let parts = line.components(separatedBy: " · ")
            XCTAssertEqual(parts.count, 6, "\(label): \(line.debugDescription)")
            guard parts.count == 6 else { continue }
            let plain = CacheLifeRules.segment(cache: cache, now: now)!.text
            XCTAssertEqual(parts[1], colour + plain + reset, "\(label)")
            for account in parts[2...] {
                XCTAssertFalse(account.contains(esc), "\(label): the account part is not coloured: \(account.debugDescription)")
            }
        }
    }

    func testTheColouredLineIsThePrefixThenTheColouredSegmentThenThePlainAccount() {
        let prefix = StatusLineText.sessionPrefix(model: "Fable 5.1", contextUsedPercent: 55, colour: true)
        XCTAssertTrue(prefix.contains(esc), "the prefix itself is coloured")
        let line = render(snapshot(), cache: cache(expiresIn: 4 * 60, ttl: "1h"), colour: true)
        XCTAssertEqual(
            line,
            prefix + " · " + yellow + "cache 4m" + reset + " · ◐ 42% · resets in 1h 10m · ≈$4.20 today · ⚑ 1"
        )
    }

    func testTheColouredSegmentAloneWhenThereIsNoPrefixAndNoSnapshot() {
        XCTAssertEqual(
            render(nil, model: nil, context: nil, cache: cache(expiresIn: 47 * 60), colour: true),
            dim + "cache 47m" + reset
        )
        XCTAssertEqual(
            render(nil, model: nil, context: nil, cache: cache(expiresIn: -1), colour: true),
            red + "cache cold" + reset
        )
    }

    func testWithColourOffNoEscapeCodeAppearsAnywhere() {
        let caches: [StatusLineInput.PromptCache?] = [
            nil,
            cache(expiresIn: 47 * 60),
            cache(expiresIn: 200, ttl: "1h"),
            cache(expiresIn: 30, ttl: "5m"),
            cache(expiresIn: -1),
            cache(expiresIn: nil, warm: false),
            cache(expiresIn: 30, observed: false),
        ]
        for snap in [snapshot(), nil, snapshot(updatedAt: now.addingTimeInterval(-7200))] as [StatusSnapshot?] {
            for cache in caches {
                for (model, context) in [("Fable 5.1", 55.0), (nil, nil), ("Opus", nil)] as [(String?, Double?)] {
                    let line = render(snap, model: model, context: context, cache: cache, colour: false)
                    XCTAssertFalse(line.contains(esc), line.debugDescription)
                }
            }
        }
    }

    func testAnExtremeExpiryStillRendersOneLine() {
        let far = StatusLineInput.PromptCache(
            warm: true, ttl: "1h", expiresAt: Date(timeIntervalSince1970: Double.greatestFiniteMagnitude),
            cachingObserved: true
        )
        let line = render(snapshot(), cache: far)
        XCTAssertFalse(line.contains("\n"))
        XCTAssertTrue(line.hasPrefix("Fable 5.1 [######----] 55% · cache "), line)
    }
}

// MARK: - CLI end to end

/// The built `omelette` binary, run the way Claude Code runs it: JSON on stdin, one
/// line back. `OmeletteCLIEndToEndTests` is `final`, so its `runCLI` harness is
/// repeated here with the same shape (a temp status file in `OMELETTE_STATUS_FILE`, both
/// pipes drained before the wait).
final class StatusLineCacheEndToEndVerificationTests: XCTestCase {
    private var directory: URL!
    private var statusURL: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatusLineCacheVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        statusURL = directory.appendingPathComponent("status.json")
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: AgentPaths.bundledCLIURL.path),
            "omelette missing at \(AgentPaths.bundledCLIURL.path)"
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private struct Run {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// A fresh snapshot with no reset time, so two runs a second apart print the same line.
    private func publishFreshSnapshot() throws {
        let snapshot = StatusSnapshot(
            version: StatusSnapshot.currentVersion,
            updatedAt: Date(),
            services: [
                StatusSnapshot.Service(
                    id: "claude", name: "Claude", state: "ok", retained: false, retainedAt: nil,
                    plan: nil,
                    windows: [
                        StatusSnapshot.Window(
                            id: "five_hour", label: "Session", percent: 37, resetsAt: nil, kind: "session"
                        ),
                    ],
                    todayCost: nil, weekCost: nil, todayTokens: nil, apiEquivalent: true
                ),
            ],
            agents: StatusSnapshot.Agents(needsYou: 0, working: 0, sessions: [])
        )
        var data = try StatusFile.encoder.encode(snapshot)
        data.append(0x0A)
        try data.write(to: statusURL, options: [.atomic])
    }

    private func runCLI(_ arguments: [String], stdin input: String? = nil) throws -> Run {
        let process = Process()
        process.executableURL = AgentPaths.bundledCLIURL
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment[StatusFile.environmentKey] = statusURL.path
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin
        try process.run()
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        try stdin.fileHandleForWriting.close()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    private func session(cache: String?) -> String {
        let head = #"{"model":{"display_name":"Opus"},"context_window":{"used_percentage":42.4}"#
        guard let cache else { return head + "}" }
        return head + #","prompt_cache":\#(cache)}"#
    }

    private func liveCache(expiresIn seconds: Int, ttl: String = "1h") -> String {
        let expiresAt = Int(Date().timeIntervalSince1970) + seconds
        return #"{"warm":true,"caching_observed":true,"ttl":"\#(ttl)","expires_at":\#(expiresAt)}"#
    }

    func testTheSegmentSitsBetweenThePrefixAndTheGauge() throws {
        try publishFreshSnapshot()

        let run = try runCLI(["statusline", "--no-color"], stdin: session(cache: liveCache(expiresIn: 2850)))

        XCTAssertEqual(run.status, 0)
        XCTAssertTrue(run.stderr.isEmpty, run.stderr)
        let line = run.stdout
        XCTAssertTrue(line.hasPrefix("Opus [####------] 42% · cache "), line)
        XCTAssertTrue(line.contains("cache 47m") || line.contains("cache 46m"), line)
        XCTAssertTrue(line.hasSuffix("m · ◐ 37%\n"), line.debugDescription)
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 1)
        XCTAssertFalse(line.contains("\u{1B}"), "--no-color: no escape code anywhere")
        let cacheAt = try XCTUnwrap(line.range(of: "cache "))
        let gaugeAt = try XCTUnwrap(line.range(of: "◐"))
        let percentAt = try XCTUnwrap(line.range(of: "42%"))
        XCTAssertTrue(percentAt.upperBound <= cacheAt.lowerBound && cacheAt.upperBound <= gaugeAt.lowerBound, line)
    }

    func testCachingObservedFalsePrintsTheSameLineAsNoPromptCache() throws {
        try publishFreshSnapshot()
        let unobserved = #"{"warm":false,"caching_observed":false,"ttl":"5m","expires_at":null}"#

        let with = try runCLI(["statusline", "--no-color"], stdin: session(cache: unobserved))
        let without = try runCLI(["statusline", "--no-color"], stdin: session(cache: nil))

        XCTAssertEqual(with.status, 0)
        XCTAssertEqual(with.stdout, without.stdout)
        XCTAssertEqual(without.stdout, "Opus [####------] 42% · ◐ 37%\n")
        XCTAssertFalse(with.stdout.contains("cache"), with.stdout)
    }

    func testAnExpiredCachePrintsColdWithNoNegativeCountdown() throws {
        try publishFreshSnapshot()
        let past = Int(Date().timeIntervalSince1970) - 3600
        let cache = #"{"warm":true,"caching_observed":true,"ttl":"1h","expires_at":\#(past)}"#

        let run = try runCLI(["statusline", "--no-color"], stdin: session(cache: cache))

        XCTAssertEqual(run.stdout, "Opus [####------] 42% · cache cold · ◐ 37%\n")
    }

    func testANullExpiryWithWarmTruePrintsCold() throws {
        try publishFreshSnapshot()
        let cache = #"{"warm":true,"caching_observed":true,"ttl":"1h","expires_at":null}"#

        let run = try runCLI(["statusline", "--no-color"], stdin: session(cache: cache))

        XCTAssertEqual(run.stdout, "Opus [####------] 42% · cache cold · ◐ 37%\n")
    }

    func testAGarbledPromptCachePrintsNoSegmentAndKeepsThePrefix() throws {
        try publishFreshSnapshot()
        let garbled = [
            #"{"warm":true,"caching_observed":true,"ttl":"1h","expires_at":"soon"}"#,
            #"{"warm":true,"caching_observed":true,"ttl":"1h","expires_at":true}"#,
            #"{"warm":1,"caching_observed":true,"ttl":"1h","expires_at":1}"#,
            #"{"warm":true,"caching_observed":"true","ttl":"1h","expires_at":1}"#,
        ]
        for cache in garbled {
            let run = try runCLI(["statusline", "--no-color"], stdin: session(cache: cache))
            XCTAssertEqual(run.status, 0, cache)
            XCTAssertEqual(run.stdout, "Opus [####------] 42% · ◐ 37%\n", cache)
        }
    }

    func testTheSegmentPrintsWithNoStatusFileAtAll() throws {
        let run = try runCLI(["statusline", "--no-color"], stdin: session(cache: liveCache(expiresIn: 2850)))

        XCTAssertEqual(run.status, 0)
        XCTAssertTrue(run.stdout.hasPrefix("Opus [####------] 42% · cache 4"), run.stdout)
        XCTAssertFalse(run.stdout.contains("◐"), "no snapshot: the session's half alone")
    }

    func testAPipedPayloadColoursTheSegmentByItsStateAndTheAccountNot() throws {
        try publishFreshSnapshot()

        let warm = try runCLI(["statusline"], stdin: session(cache: liveCache(expiresIn: 2850)))
        XCTAssertTrue(warm.stdout.contains("\u{1B}[2mcache 4"), warm.stdout.debugDescription)
        XCTAssertTrue(warm.stdout.hasSuffix("m\u{1B}[0m · ◐ 37%\n"), warm.stdout.debugDescription)

        let closing = try runCLI(["statusline"], stdin: session(cache: liveCache(expiresIn: 200, ttl: "1h")))
        XCTAssertTrue(closing.stdout.contains("\u{1B}[2;33mcache "), closing.stdout.debugDescription)
        XCTAssertTrue(closing.stdout.hasSuffix("s\u{1B}[0m · ◐ 37%\n") || closing.stdout.hasSuffix("m\u{1B}[0m · ◐ 37%\n"), closing.stdout.debugDescription)

        let past = Int(Date().timeIntervalSince1970) - 60
        let cold = try runCLI(
            ["statusline"],
            stdin: session(cache: #"{"warm":true,"caching_observed":true,"ttl":"1h","expires_at":\#(past)}"#)
        )
        XCTAssertTrue(cold.stdout.contains("\u{1B}[2;31mcache cold\u{1B}[0m · ◐ 37%"), cold.stdout.debugDescription)
    }

    func testTheSegmentIsThereForAnotherProviderToo() throws {
        try publishFreshSnapshot()

        let run = try runCLI(
            ["statusline", "--provider", "codex", "--no-color"], stdin: session(cache: liveCache(expiresIn: 2850))
        )

        XCTAssertEqual(run.status, 0)
        XCTAssertTrue(run.stdout.hasPrefix("Opus [####------] 42% · cache 4"), run.stdout)
        XCTAssertFalse(run.stdout.contains("◐"), "codex is not in the snapshot")
    }

    func testTheHelpTheBinaryPrintsExplainsTheTimer() throws {
        let run = try runCLI(["--help"])

        XCTAssertEqual(run.status, 0)
        XCTAssertTrue(run.stdout.contains("cache 47m"), run.stdout)
        XCTAssertTrue(run.stdout.contains(CacheLifeRules.coldText), run.stdout)
    }
}

// MARK: - Docs

/// The words the user reads: `--help`, CHANGELOG 3.0.1, README.
final class StatusLineCacheDocsVerificationTests: XCTestCase {
    /// The repository root, from this file's own path: `<root>/UsageTrackerTests/<file>`.
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func read(_ name: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    private func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    func testTheHelpMentionsColdInTheSameWordsTheLinePrints() {
        XCTAssertTrue(CLIText.usage.contains(CacheLifeRules.coldText), CLIText.usage)
        XCTAssertTrue(CLIText.usage.contains("\"\(CacheLifeRules.coldText)\""), CLIText.usage)
    }

    /// The spec's legend line, with line breaks read as spaces: `omelette --help` wraps
    /// at 80 columns elsewhere.
    func testTheHelpCarriesTheSpecsLegendWords() {
        let expected = #"cache 47m how long the session's prompt cache stays warm; "cache cold" means the next turn writes it again"#
        XCTAssertTrue(collapsed(CLIText.usage).contains(expected), CLIText.usage)
    }

    func testTheHelpStillListsTheOtherMarks() {
        XCTAssertTrue(CLIText.usage.contains("≈"))
        XCTAssertTrue(CLIText.usage.contains(CLIText.apiEquivalentSuffix))
        XCTAssertTrue(CLIText.usage.contains("omelette statusline"))
    }

    func testTheChangelogHasA301SectionAboveA300WithTheLine() throws {
        let changelog = try read("CHANGELOG.md")
        let newer = try XCTUnwrap(changelog.range(of: "## [3.0.1]"), "no 3.0.1 section")
        let older = try XCTUnwrap(changelog.range(of: "## [3.0.0]"), "no 3.0.0 section")
        XCTAssertTrue(newer.lowerBound < older.lowerBound, "3.0.1 sits above 3.0.0")

        let section = String(changelog[newer.lowerBound..<older.lowerBound])
        let heading = try XCTUnwrap(section.range(of: "### Command line"), "the line goes under Command line")
        let entry = try XCTUnwrap(section.range(of: "cache 47m"))
        XCTAssertTrue(heading.upperBound <= entry.lowerBound)
        let collapsedSection = collapsed(section)
        XCTAssertTrue(collapsedSection.contains("omelette statusline"), section)
        XCTAssertTrue(collapsedSection.contains(CacheLifeRules.coldText), section)
        XCTAssertFalse(section.contains("## [3.0.0]"))
    }

    func testTheReadmeExampleLineHasTheCacheTimer() throws {
        let readme = try read("README.md")
        let line = try XCTUnwrap(
            readme.split(separator: "\n").first { $0.contains("cache 47m") && $0.contains("◐") },
            "no README line with `cache 47m` and the gauge"
        )
        XCTAssertTrue(line.contains("[######----]"), String(line))
        let prefix = try XCTUnwrap(line.range(of: "] 55%"))
        let cacheAt = try XCTUnwrap(line.range(of: "cache 47m"))
        let gaugeAt = try XCTUnwrap(line.range(of: "◐"))
        XCTAssertTrue(prefix.upperBound <= cacheAt.lowerBound && cacheAt.upperBound <= gaugeAt.lowerBound, String(line))
    }

    /// The README's example is what the line prints for those numbers, not a picture
    /// of a line the code cannot produce.
    func testTheReadmeExampleIsExactlyWhatTheCodePrints() throws {
        let now = Date(timeIntervalSince1970: 1_788_693_600)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_GB")
        let snapshot = StatusSnapshot(
            version: 1, updatedAt: now,
            services: [
                StatusSnapshot.Service(
                    id: "claude", name: "Claude", state: "ok", retained: false, retainedAt: nil, plan: nil,
                    windows: [
                        StatusSnapshot.Window(
                            id: "five_hour", label: "Session", percent: 42,
                            resetsAt: now.addingTimeInterval(70 * 60), kind: "session"
                        ),
                    ],
                    todayCost: 4.2, weekCost: nil, todayTokens: nil, apiEquivalent: true
                ),
            ],
            agents: StatusSnapshot.Agents(needsYou: 1, working: 0, sessions: [])
        )
        let cache = StatusLineInput.PromptCache(
            warm: true, ttl: "1h", expiresAt: now.addingTimeInterval(47 * 60 + 5), cachingObserved: true
        )
        let line = StatusLineText.render(
            snapshot: snapshot, now: now,
            input: StatusLineInput(model: "Fable 5.1", contextUsedPercent: 55, promptCache: cache),
            colour: false, calendar: calendar, locale: locale
        )

        XCTAssertTrue(try read("README.md").contains("`\(line)`"), line)
    }
}
