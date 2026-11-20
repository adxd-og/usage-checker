import XCTest
@testable import Omelette

/// The JSON Claude Code pipes into `omelette statusline`. Everything in it is
/// somebody else's format: the parser reads the fields we draw — the model, the
/// context window, the prompt cache (spec 2026-09-30 status line cache timer,
/// § Input) — and the ones the app keeps — the rate limits and the session's counters
/// (spec 2026-11-02 Claude limits from the status line, § Design › Wire) — and treats
/// every other shape — a missing key, a string where a number belongs, an 8 MB blob
/// of nothing — as "no session information", never as an error.
final class StatusLineInputTests: XCTestCase {
    private func input(_ json: String) -> StatusLineInput {
        StatusLineInput.parse(Data(json.utf8))
    }

    /// The documented payload of an older Claude Code, with the keys we do not read
    /// left in: the parser keeps `session_id` and `version` and walks past `workspace`,
    /// `cost`'s dollars and the rest without noticing them.
    func testTheShapeClaudeCodeWrites() {
        let payload = """
        {
          "hook_event_name": "Status",
          "session_id": "0f3a5c1e-7b2d-4a91-8c6f-2d5e9b0a4c73",
          "transcript_path": "~/.claude/projects/omelette/0f3a5c1e.jsonl",
          "cwd": "~/Desktop/Usage tracker",
          "model": { "id": "claude-fable-5-1", "display_name": "Fable" },
          "workspace": { "current_dir": "~/Desktop/Usage tracker", "project_dir": "~/Desktop/Usage tracker" },
          "version": "2.5.0",
          "output_style": { "name": "default" },
          "cost": { "total_cost_usd": 1.23, "total_duration_ms": 42000 },
          "exceeds_200k_tokens": false,
          "context_window": { "used_percentage": 42.4, "remaining_percentage": 57.6 }
        }
        """

        XCTAssertEqual(
            input(payload),
            StatusLineInput(
                model: "Fable",
                contextUsedPercent: 42.4,
                sessionID: "0f3a5c1e-7b2d-4a91-8c6f-2d5e9b0a4c73",
                version: "2.5.0"
            )
        )
    }

    func testAPayloadWithoutAModelKeepsTheContext() {
        XCTAssertEqual(
            input(#"{"context_window":{"used_percentage":7}}"#),
            StatusLineInput(model: nil, contextUsedPercent: 7)
        )
        XCTAssertEqual(
            input(#"{"model":{"id":"claude-fable-5-1"},"context_window":{"used_percentage":7}}"#),
            StatusLineInput(model: nil, contextUsedPercent: 7),
            "an id is not a name to show"
        )
    }

    /// `context_window` is absent for the first turns of a session, and on older
    /// Claude Code builds it never arrives at all.
    func testAPayloadWithoutAContextWindowKeepsTheModel() {
        XCTAssertEqual(
            input(#"{"model":{"display_name":"Fable"}}"#),
            StatusLineInput(model: "Fable", contextUsedPercent: nil)
        )
        XCTAssertEqual(
            input(#"{"model":{"display_name":"Fable"},"context_window":{"remaining_percentage":57.6}}"#),
            StatusLineInput(model: "Fable", contextUsedPercent: nil),
            "we draw what is used; a window that only reports what is left tells us nothing to draw"
        )
    }

    /// JSON numbers arrive as numbers, but a hook that builds the payload in a shell
    /// writes them as strings, and the line should still work.
    func testAPercentageWrittenAsAStringIsStillANumber() {
        XCTAssertEqual(input(#"{"context_window":{"used_percentage":"42.4"}}"#).contextUsedPercent, 42.4)
        XCTAssertEqual(input(#"{"context_window":{"used_percentage":"nope"}}"#).contextUsedPercent, nil)
        XCTAssertEqual(input(#"{"context_window":{"used_percentage":true}}"#).contextUsedPercent, nil)
    }

    func testAPercentageOutsideTheRangeIsClamped() {
        XCTAssertEqual(input(#"{"context_window":{"used_percentage":137}}"#).contextUsedPercent, 100)
        XCTAssertEqual(input(#"{"context_window":{"used_percentage":-4}}"#).contextUsedPercent, 0)
    }

    func testGarbageIsNothingRatherThanAnError() {
        for json in [
            "",
            "   ",
            "not json at all",
            "{",
            "[]",
            #""a string""#,
            "null",
            #"{"model":"Fable"}"#,
            #"{"model":{"display_name":42}}"#,
            #"{"context_window":42}"#,
        ] {
            XCTAssertEqual(input(json), StatusLineInput(model: nil, contextUsedPercent: nil), json)
        }
        XCTAssertEqual(StatusLineInput.parse(Data()), StatusLineInput(model: nil, contextUsedPercent: nil))
        XCTAssertEqual(
            StatusLineInput.parse(Data(repeating: 0x41, count: 64 * 1024)),
            StatusLineInput(model: nil, contextUsedPercent: nil),
            "Claude Code's payload is small, but nothing in the contract says so"
        )
    }

    /// A display name that is only spaces would draw a bar with nothing in front of it.
    func testABlankModelNameIsNoName() {
        XCTAssertEqual(input(#"{"model":{"display_name":"   "}}"#).model, nil)
        XCTAssertEqual(input(#"{"model":{"display_name":" Fable "}}"#).model, "Fable")
    }

    // MARK: - prompt_cache

    /// `prompt_cache` inside a payload that also names the model, so a test can see the
    /// cache go without the rest of the session going with it.
    private func promptCache(_ json: String) -> StatusLineInput.PromptCache? {
        input(#"{"model":{"display_name":"Fable 5.1"},"prompt_cache":"# + json + "}").promptCache
    }

    /// The documented shape, with the keys the timer does not read left in: the parser
    /// walks past `hit_ratio` and the miss fields without noticing them.
    func testThePromptCacheClaudeCodeWrites() {
        let payload = """
        {
          "model": { "id": "claude-fable-5-1", "display_name": "Fable 5.1" },
          "context_window": { "used_percentage": 55 },
          "prompt_cache": {
            "warm": true,
            "caching_observed": true,
            "ttl": "1h",
            "expires_at": 1788696420,
            "last_miss_at": null,
            "last_miss_cause": null,
            "hit_ratio": 0.97
          }
        }
        """

        XCTAssertEqual(
            input(payload),
            StatusLineInput(
                model: "Fable 5.1",
                contextUsedPercent: 55,
                promptCache: StatusLineInput.PromptCache(
                    warm: true,
                    ttl: "1h",
                    expiresAt: Date(timeIntervalSince1970: 1_788_696_420),
                    cachingObserved: true
                )
            )
        )
    }

    /// Absent until the main conversation's first API response, and on Claude Code
    /// before 2.1.251. No cache then, and the rest of the payload reads as before.
    func testNoPromptCacheBeforeTheFirstResponse() {
        XCTAssertEqual(
            input(#"{"model":{"display_name":"Fable 5.1"},"context_window":{"used_percentage":55}}"#),
            StatusLineInput(model: "Fable 5.1", contextUsedPercent: 55, promptCache: nil)
        )
        for json in ["null", "42", "\"warm\"", "[]", "{}"] {
            XCTAssertNil(promptCache(json), json)
        }
        XCTAssertEqual(
            input(#"{"model":{"display_name":"Fable 5.1"},"prompt_cache":[]}"#).model,
            "Fable 5.1",
            "a cache we cannot read costs the cache, not the model"
        )
    }

    /// `expires_at` is `null` when the last response reported no cache tokens (Claude
    /// Code sends `warm: false` with it); an older build may leave it out.
    func testANullOrAbsentExpiryIsNoExpiry() {
        XCTAssertEqual(
            promptCache(#"{"warm":false,"caching_observed":true,"ttl":"5m","expires_at":null}"#),
            StatusLineInput.PromptCache(warm: false, ttl: "5m", expiresAt: nil, cachingObserved: true)
        )
        XCTAssertEqual(
            promptCache(#"{"warm":false,"caching_observed":true}"#),
            StatusLineInput.PromptCache(warm: false, ttl: nil, expiresAt: nil, cachingObserved: true)
        )
    }

    /// Epoch seconds as a JSON number, or as a string from a hook that builds the
    /// payload in a shell — the same tolerance as the context percentage.
    func testAnExpiryWrittenAsAStringIsStillATime() {
        XCTAssertEqual(
            promptCache(#"{"warm":true,"caching_observed":true,"expires_at":"1788696420"}"#)?.expiresAt,
            Date(timeIntervalSince1970: 1_788_696_420)
        )
        XCTAssertEqual(
            promptCache(#"{"warm":true,"caching_observed":true,"expires_at":" 1788696420.5 "}"#)?.expiresAt,
            Date(timeIntervalSince1970: 1_788_696_420.5)
        )
        XCTAssertEqual(
            promptCache(#"{"warm":true,"caching_observed":true,"expires_at":1788696420.5}"#)?.expiresAt,
            Date(timeIntervalSince1970: 1_788_696_420.5)
        )
    }

    /// `true` bridges to 1.0 — one second past 1970 — and "soon" is no time at all.
    /// An expiry that is present and not a time is a payload we do not understand;
    /// reading it as "no expiry" would draw a "cache cold" Claude Code never reported.
    func testAnExpiryThatIsNotATimeIsNotACacheWeUnderstand() {
        for expiry in ["true", "false", "\"soon\"", "\"\"", "\"inf\"", "{}", "[]"] {
            XCTAssertNil(
                promptCache(#"{"warm":true,"caching_observed":true,"ttl":"1h","expires_at":"# + expiry + "}"),
                expiry
            )
        }
    }

    /// The two flags are JSON booleans or the object is not one we understand:
    /// guessing `warm` would draw a timer — or a "cold" — that nobody reported.
    func testTheFlagsMustBeBooleans() {
        for json in [
            #"{"warm":1,"caching_observed":true,"expires_at":1788696420}"#,
            #"{"warm":"true","caching_observed":true,"expires_at":1788696420}"#,
            #"{"warm":null,"caching_observed":true,"expires_at":1788696420}"#,
            #"{"caching_observed":true,"expires_at":1788696420}"#,
            #"{"warm":true,"caching_observed":0,"expires_at":1788696420}"#,
            #"{"warm":true,"expires_at":1788696420}"#,
        ] {
            XCTAssertNil(promptCache(json), json)
        }
        XCTAssertEqual(
            input(#"{"model":{"display_name":"Fable 5.1"},"prompt_cache":{"warm":1,"caching_observed":true}}"#),
            StatusLineInput(model: "Fable 5.1", contextUsedPercent: nil, promptCache: nil)
        )
    }

    /// `warm: false` is Claude Code saying the cache is cold. That is a reading, not
    /// garbage, and it is kept.
    func testAColdCacheIsStillACache() {
        XCTAssertEqual(
            promptCache(#"{"warm":false,"caching_observed":true,"ttl":"1h","expires_at":1788696420}"#),
            StatusLineInput.PromptCache(
                warm: false,
                ttl: "1h",
                expiresAt: Date(timeIntervalSince1970: 1_788_696_420),
                cachingObserved: true
            )
        )
    }

    /// "5m" or "1h", trimmed. Anything else is kept as given, and the rule decides what
    /// it means. A blank or a number is no TTL.
    func testTheTTLIsTrimmedAndOtherwiseKeptAsGiven() {
        func ttl(_ value: String) -> String? {
            promptCache(#"{"warm":true,"caching_observed":true,"ttl":"# + value + "}")?.ttl
        }
        XCTAssertEqual(ttl("\" 1h \""), "1h")
        XCTAssertEqual(ttl("\"5m\""), "5m")
        XCTAssertEqual(ttl("\"2h\""), "2h")
        XCTAssertNil(ttl("\"  \""))
        XCTAssertNil(ttl("3600"))
    }

    // MARK: - rate_limits

    /// `rate_limits` inside a payload that also names the model, so a test can see the
    /// windows go without the rest of the session going with them.
    private func rateLimits(_ json: String) -> StatusLineInput.RateLimits? {
        input(#"{"model":{"display_name":"Opus"},"rate_limits":"# + json + "}").rateLimits
    }

    private func window(_ percent: Double, _ resetsAt: TimeInterval) -> StatusLineInput.RateLimits.Window {
        StatusLineInput.RateLimits.Window(usedPercent: percent, resetsAt: Date(timeIntervalSince1970: resetsAt))
    }

    /// Claude Code 2.1.316's payload, both windows known. The line's own fields read as
    /// they always did beside them.
    func testTheRateLimitsClaudeCodeWrites() {
        let parsed = input(StatusLineFixture.payload())

        XCTAssertEqual(
            parsed.rateLimits,
            StatusLineInput.RateLimits(
                fiveHour: StatusLineInput.RateLimits.Window(
                    usedPercent: 23.5, resetsAt: StatusLineFixture.fiveHourResetsAt
                ),
                sevenDay: StatusLineInput.RateLimits.Window(
                    usedPercent: 41.2, resetsAt: StatusLineFixture.sevenDayResetsAt
                )
            )
        )
        XCTAssertEqual(parsed.model, "Opus")
        XCTAssertEqual(parsed.contextUsedPercent, 42.4)
        XCTAssertNil(parsed.promptCache)
    }

    /// Each window is there only when Claude Code knows it.
    func testEachWindowIsThereOnlyWhenKnown() {
        XCTAssertEqual(
            rateLimits(#"{"five_hour":{"used_percentage":23.5,"resets_at":1788703200}}"#),
            StatusLineInput.RateLimits(fiveHour: window(23.5, 1_788_703_200), sevenDay: nil)
        )
        XCTAssertEqual(
            rateLimits(#"{"seven_day":{"used_percentage":41.2,"resets_at":1789065600}}"#),
            StatusLineInput.RateLimits(fiveHour: nil, sevenDay: window(41.2, 1_789_065_600))
        )
    }

    /// Absent before the session's first API response and on a plan without limits. An
    /// object with no window we can read — a gateway's `spend_limit` alone — is no rate
    /// limits either. The rest of the payload reads as before.
    func testNoRateLimitsWithoutAWindow() {
        XCTAssertNil(input(StatusLineFixture.payload(rateLimits: nil)).rateLimits)
        for json in [
            "null",
            "42",
            "true",
            "\"5h\"",
            "[]",
            "{}",
            #"{"spend_limit":{"used_percentage":12,"resets_at":1788703200}}"#,
        ] {
            XCTAssertNil(rateLimits(json), json)
        }
        XCTAssertEqual(
            input(StatusLineFixture.payload(rateLimits: "[]")).model,
            "Opus",
            "limits we cannot read cost the limits, not the model"
        )
    }

    /// Claude Code rounds to one decimal and the decimal is kept: the app tells a
    /// status-line reading from the OAuth endpoint's integers by it.
    func testTheDecimalIsKept() {
        XCTAssertEqual(
            rateLimits(#"{"five_hour":{"used_percentage":0.1,"resets_at":1788703200}}"#)?.fiveHour?.usedPercent,
            0.1
        )
        XCTAssertEqual(
            rateLimits(#"{"five_hour":{"used_percentage":99.9,"resets_at":1788703200}}"#)?.fiveHour?.usedPercent,
            99.9
        )
        XCTAssertEqual(
            rateLimits(#"{"seven_day":{"used_percentage":100,"resets_at":1789065600}}"#)?.sevenDay?.usedPercent,
            100
        )
    }

    func testAWindowPercentOutsideTheRangeIsClamped() {
        XCTAssertEqual(
            rateLimits(#"{"five_hour":{"used_percentage":137,"resets_at":1788703200}}"#)?.fiveHour?.usedPercent,
            100
        )
        XCTAssertEqual(
            rateLimits(#"{"five_hour":{"used_percentage":-4,"resets_at":1788703200}}"#)?.fiveHour?.usedPercent,
            0
        )
    }

    /// The same tolerance as the context percentage and the cache expiry: a hook that
    /// builds the payload in a shell writes numbers as strings.
    func testAPercentOrAResetWrittenAsAStringIsStillANumber() {
        XCTAssertEqual(
            rateLimits(#"{"five_hour":{"used_percentage":"23.5","resets_at":" 1788703200 "}}"#)?.fiveHour,
            window(23.5, 1_788_703_200)
        )
    }

    /// A window is a percent and a reset, or it is not a window we understand: no
    /// guessing a reset, and `true` is not 1 %. The other window stands.
    func testAWindowThatIsNotTheDocumentedShapeIsNoWindow() {
        let seven = #""seven_day":{"used_percentage":41.2,"resets_at":1789065600}"#
        for five in [
            #"{"resets_at":1788703200}"#,
            #"{"used_percentage":23.5}"#,
            #"{"used_percentage":null,"resets_at":1788703200}"#,
            #"{"used_percentage":true,"resets_at":1788703200}"#,
            #"{"used_percentage":"nope","resets_at":1788703200}"#,
            #"{"used_percentage":23.5,"resets_at":null}"#,
            #"{"used_percentage":23.5,"resets_at":false}"#,
            #"{"used_percentage":23.5,"resets_at":"soon"}"#,
            #"{"used_percentage":23.5,"resets_at":{}}"#,
            "23.5",
            "null",
        ] {
            XCTAssertEqual(
                rateLimits(#"{"five_hour":"# + five + "," + seven + "}"),
                StatusLineInput.RateLimits(fiveHour: nil, sevenDay: window(41.2, 1_789_065_600)),
                five
            )
        }
        XCTAssertNil(
            rateLimits(#"{"five_hour":{"used_percentage":true,"resets_at":1788703200}}"#),
            "no window left is no rate limits"
        )
    }

    // MARK: - The session's counters

    /// What tells one reading from the next: the payload has no "last updated" field,
    /// so the app compares the prompt id and the API time between two files.
    func testTheSessionsCountersClaudeCodeWrites() {
        let parsed = input(StatusLineFixture.payload())

        XCTAssertEqual(parsed.sessionID, StatusLineFixture.sessionID)
        XCTAssertEqual(parsed.promptID, StatusLineFixture.promptID)
        XCTAssertEqual(parsed.totalAPIDurationMs, 18_250)
        XCTAssertEqual(parsed.version, "2.1.316")
    }

    /// Ids and the version are strings, trimmed; the API time is a number or a numeric
    /// string, inside `cost`. Any other shape is no counter and costs nothing else.
    func testACounterInAnotherShapeIsNoCounter() {
        XCTAssertEqual(input(#"{"session_id":" abc-123 "}"#).sessionID, "abc-123")
        XCTAssertNil(input(#"{"session_id":42}"#).sessionID)
        XCTAssertNil(input(#"{"session_id":"   "}"#).sessionID)
        XCTAssertNil(input(#"{"prompt_id":7}"#).promptID)
        XCTAssertNil(input(#"{"version":2.1}"#).version)
        XCTAssertEqual(input(#"{"cost":{"total_api_duration_ms":"18250"}}"#).totalAPIDurationMs, 18_250)
        XCTAssertNil(input(#"{"cost":{"total_api_duration_ms":true}}"#).totalAPIDurationMs)
        XCTAssertNil(input(#"{"cost":{"total_api_duration_ms":"soon"}}"#).totalAPIDurationMs)
        XCTAssertNil(input(#"{"cost":18250}"#).totalAPIDurationMs)
        XCTAssertNil(input(#"{"total_api_duration_ms":18250}"#).totalAPIDurationMs, "inside cost, nowhere else")
        XCTAssertEqual(input(#"{"model":{"display_name":"Opus"},"session_id":42,"cost":"x"}"#).model, "Opus")
    }

    // Spec 2026-11-10 hook input hardening § Design › Status line strings.

    func testControlCharactersNeverReachTheModelName() {
        // ESC, BEL, a C1 CSI and DEL, written as JSON escapes: what a hostile or
        // broken `display_name` would carry into the terminal.
        let parsed = input(#"{"model":{"display_name":"\u001b[31mFa\u0007ble\u009b2J\u007f"}}"#)
        XCTAssertEqual(parsed.model, "[31mFable2J")
        // Dropped first, trimmed second: the space the BEL was hiding goes too.
        XCTAssertEqual(input(#"{"model":{"display_name":"\u0007 Fable \u001b"}}"#).model, "Fable")
    }

    func testANameOfOnlyControlCharactersIsNoName() {
        XCTAssertNil(input(#"{"model":{"display_name":"\u001b\u0007\u0000"}}"#).model)
        XCTAssertNil(input(#"{"model":{"display_name":" \u001b \t"}}"#).model)
    }

    func testALineBreakInsideANameCannotSplitTheLine() {
        let parsed = input(#"{"model":{"display_name":"Fable\n5.2\r\n\tbeta"},"context_window":{"used_percentage":42}}"#)
        XCTAssertEqual(parsed.model, "Fable5.2beta")
        let line = StatusLineText.render(
            snapshot: nil, now: Date(timeIntervalSince1970: 1_800_000_000), input: parsed, colour: false
        )
        XCTAssertEqual(line, "Fable5.2beta [####------] 42%")
        XCTAssertFalse(line.unicodeScalars.contains { $0.properties.generalCategory == .control })
    }

    func testTheSessionIDIsStillCheckedAndNeverCleaned() {
        // The id names a file (`StatusLineDrop.fileName`): cleaning it here would turn
        // an id the drop refuses into one it accepts, and give two sessions one file.
        let parsed = input(#"{"session_id":"0f3a\u001b5c1e","version":"2.5.0","model":{"display_name":"Fa\u001bble"}}"#)
        XCTAssertEqual(parsed.model, "Fable")
        XCTAssertEqual(parsed.sessionID, "0f3a\u{1B}5c1e")
        XCTAssertNil(parsed.sessionID.flatMap(StatusLineDrop.fileName(sessionID:)))
    }

    // Spec 2026-11-20 small backlog 2 § B: format characters (Cf) but the two joiners, and the
    // line and paragraph separators (Zl, Zp), go the way control characters do; everything a
    // terminal shows stays.

    func testBidiControlsCannotReorderTheModelName() {
        // U+202E RIGHT-TO-LEFT OVERRIDE prints what follows it backwards; U+2066, U+2067 and
        // U+2068 open an isolate and U+2069 closes it.
        let parsed = input(#"{"model":{"display_name":"Fa\u202Eble \u2066x\u2069 \u2067y\u2069 \u2068z\u2069"}}"#)
        XCTAssertEqual(parsed.model, "Fable x y z")
    }

    func testZeroWidthSpacesTheByteOrderMarkAndTheSoftHyphenNeverReachTheModelName() {
        // U+200B ZERO WIDTH SPACE, U+2060 WORD JOINER, U+FEFF inside a string, U+00AD SOFT HYPHEN.
        let parsed = input(#"{"model":{"display_name":"F\u200Ba\u2060b\uFEFFl\u00ADe"}}"#)
        XCTAssertEqual(parsed.model, "Fable")
    }

    func testALineOrParagraphSeparatorCannotSplitTheLine() {
        let parsed = input(#"{"model":{"display_name":"Fable\u20285.2\u2029beta"},"context_window":{"used_percentage":42}}"#)
        XCTAssertEqual(parsed.model, "Fable5.2beta")
        let line = StatusLineText.render(
            snapshot: nil, now: Date(timeIntervalSince1970: 1_800_000_000), input: parsed, colour: false
        )
        XCTAssertEqual(line, "Fable5.2beta [####------] 42%")
        XCTAssertFalse(line.unicodeScalars.contains {
            [.format, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory)
        })
    }

    func testLettersMarksDigitsAndSymbolsOfEveryScriptStay() {
        // Latin with a combining acute (U+0301, a mark), Greek, Han, Hebrew, an Arabic-Indic
        // digit, a no-break space (U+00A0, a space), a fraction and a check mark.
        let parsed = input(#"{"model":{"display_name":"Me\u0301dium Ελληνικά 日本語 עברית ٣\u00A0½ ✓"}}"#)
        XCTAssertEqual(
            parsed.model.map { Array($0.unicodeScalars) },
            Array("Me\u{301}dium Ελληνικά 日本語 עברית ٣\u{A0}½ ✓".unicodeScalars),
            "scalar by scalar: the mark and the no-break space are still there"
        )
    }

    func testAnEmojiJoinedByAZeroWidthJoinerStaysOneEmoji() {
        // The family emoji is man, woman and girl joined by U+200D: the joiners stay, so it
        // prints as one emoji. The variation selector U+FE0F is a mark and stays with its heart.
        let parsed = input(#"{"model":{"display_name":"Fable \ud83d\udc68\u200d\ud83d\udc69\u200d\ud83d\udc67 \u2764\ufe0f"}}"#)
        XCTAssertEqual(
            parsed.model.map { Array($0.unicodeScalars) },
            Array("Fable \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} \u{2764}\u{FE0F}".unicodeScalars)
        )
    }

    func testAPersianWordKeepsItsZeroWidthNonJoiner() {
        // "mi-khaham", I want: U+200C keeps the prefix mi from joining the verb, as Persian
        // spells it.
        let parsed = input(#"{"model":{"display_name":"\u0645\u06cc\u200c\u062e\u0648\u0627\u0647\u0645"}}"#)
        XCTAssertEqual(
            parsed.model.map { Array($0.unicodeScalars) },
            Array("\u{645}\u{6CC}\u{200C}\u{62E}\u{648}\u{627}\u{647}\u{645}".unicodeScalars)
        )
    }

    func testASubdivisionFlagLosesItsTagsAndShowsAsABlackFlag() {
        // Scotland's flag is U+1F3F4 followed by the tag characters g, b, s, c, t and the cancel
        // tag (U+E0067, U+E0062, U+E0073, U+E0063, U+E0074, U+E007F), all of category Cf: they
        // go, and the plain black flag stays.
        let parsed = input(#"{"model":{"display_name":"Fable \ud83c\udff4\udb40\udc67\udb40\udc62\udb40\udc73\udb40\udc63\udb40\udc74\udb40\udc7f"}}"#)
        XCTAssertEqual(
            parsed.model.map { Array($0.unicodeScalars) },
            Array("Fable \u{1F3F4}".unicodeScalars)
        )
    }

    func testANameOfOnlyInvisibleCharactersIsNoName() {
        XCTAssertNil(input(#"{"model":{"display_name":"\u200B\u202E\u2028\u00AD\u2029"}}"#).model)
        XCTAssertNil(input(#"{"model":{"display_name":" \uFEFF \u2029 "}}"#).model)
    }

    // The joiners stay only beside something they join: a name of joiners alone, or of
    // joiners and spaces, is no name, and the line prints its generic one.

    /// The line for a payload naming the model `json` (a JSON string's body, escapes
    /// included) with 42 % of the context used.
    private func line(displayName json: String) -> String {
        StatusLineText.render(
            snapshot: nil, now: Date(timeIntervalSince1970: 1_800_000_000),
            input: input(#"{"model":{"display_name":""# + json + #""},"context_window":{"used_percentage":42}}"#),
            colour: false
        )
    }

    func testANameOfOnlyJoinersAndSpacesShowsTheGenericName() {
        // The joiner alone, the joiner between spaces, the non-joiner and the joiner together.
        for json in [#"\u200D"#, #" \u200D "#, #"\u200C\u200D"#] {
            XCTAssertNil(input(#"{"model":{"display_name":""# + json + #""}}"#).model, json)
            XCTAssertEqual(line(displayName: json), "Claude [####------] 42%", json)
        }
        // A no-break space and an ideographic space are spaces too.
        XCTAssertEqual(line(displayName: #"\u200C\u00A0\u200D\u3000"#), "Claude [####------] 42%")
    }

    func testAPersianWordAndAJoinedEmojiAloneAreStillNames() {
        XCTAssertEqual(
            line(displayName: #"\u0645\u06CC\u200C\u062E\u0648\u0627\u0647\u0645"#),
            "\u{645}\u{6CC}\u{200C}\u{62E}\u{648}\u{627}\u{647}\u{645} [####------] 42%"
        )
        XCTAssertEqual(
            line(displayName: #"\uD83D\uDC68\u200D\uD83D\uDC69\u200D\uD83D\uDC67"#),
            "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} [####------] 42%"
        )
    }

    func testAJoinerBeforeALetterStaysWithIt() {
        XCTAssertEqual(
            input(#"{"model":{"display_name":"\u200Da"}}"#).model.map { Array($0.unicodeScalars) },
            Array("\u{200D}a".unicodeScalars)
        )
        XCTAssertEqual(
            input(#"{"model":{"display_name":" \u200Ca "}}"#).model.map { Array($0.unicodeScalars) },
            Array("\u{200C}a".unicodeScalars)
        )
    }
}
