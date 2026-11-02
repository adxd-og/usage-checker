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

    /// The documented payload, with the keys we do not read left in: the parser has to
    /// walk past `session_id`, `workspace`, `cost` and the rest without noticing them.
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

        XCTAssertEqual(input(payload), StatusLineInput(model: "Fable", contextUsedPercent: 42.4))
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
}
