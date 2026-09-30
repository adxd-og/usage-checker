import XCTest
@testable import Omelette

/// The JSON Claude Code pipes into `omelette statusline`. Everything in it is
/// somebody else's format: the parser reads the fields we draw — the model, the
/// context window, the prompt cache (spec 2026-09-30 status line cache timer,
/// § Input) — and treats every other shape — a missing key, a string where a number
/// belongs, an 8 MB blob of nothing — as "no session information", never as an error.
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
}
