import XCTest
@testable import Omelette

/// The JSON Claude Code pipes into `omelette statusline`. Everything in it is
/// somebody else's format: the parser reads the two fields we draw and treats every
/// other shape — a missing key, a string where a number belongs, an 8 MB blob of
/// nothing — as "no session information", never as an error.
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
}
