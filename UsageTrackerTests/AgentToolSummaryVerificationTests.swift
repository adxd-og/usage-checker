import XCTest
@testable import Omelette

/// Independent verification of `AgentToolSummary.make` against
/// `docs/superpowers/specs/2026-09-06-clear-requests-and-codex-approvals-design.md`
/// § "Package A" (Summary rules) and the implementation plan's Task 2, exercised
/// directly against the shipped `AgentToolSummary.swift` rather than by re-reading
/// `AgentToolSummaryTests.swift`'s assertions. Targets edge cases beyond the
/// executor's own suite: mixed tab/newline collapsing, a whitespace-only Bash
/// description, a URL with a port and a query string, a plan with several blank
/// lines before its title, `planFilePath` being ignored, and the "detail dropped when
/// it repeats the headline" rule across more than one tool.
final class AgentToolSummaryVerificationTests: XCTestCase {
    // MARK: - Whitespace collapsing

    func testHeadlineCollapsesTabsAndMultipleNewlines() {
        let command = "cd /tmp &&\t\tls\n\n\n-la  extra"
        let summary = AgentToolSummary.make(toolName: "Bash", toolInput: ["command": command])
        XCTAssertEqual(summary?.headline, "cd /tmp && ls -la extra")
        XCTAssertEqual(summary?.detail, command, "the detail keeps the original whitespace")
    }

    func testBashBlankDescriptionFallsBackToTheCommand() {
        // A description of only whitespace must not win over the command — it says
        // nothing a person could read as a sentence.
        let summary = AgentToolSummary.make(
            toolName: "Bash",
            toolInput: ["command": "git status", "description": "   \t  "]
        )
        XCTAssertEqual(summary?.headline, "git status")
        XCTAssertNil(summary?.detail, "the headline already is the command")
    }

    // MARK: - Files

    func testFileToolsKeepTheBasenameEvenWithSpacesInTheDirectory() {
        // NSString.lastPathComponent strips trailing slashes before returning the
        // last component, so a directory path still yields its own name, not the
        // parent's — confirmed with `swift`: ("/Users/me/Desktop/" as
        // NSString).lastPathComponent == "Desktop".
        let path = "/Users/me/Desktop/Usage tracker/UsageTracker/UI/PopoverView.swift"
        let summary = AgentToolSummary.make(toolName: "Read", toolInput: ["file_path": path])
        XCTAssertEqual(summary?.headline, "Read PopoverView.swift")
        XCTAssertEqual(summary?.detail, path)
    }

    func testFileToolsWithOnlyWhitespaceInThePathAreNil() {
        XCTAssertNil(AgentToolSummary.make(toolName: "Write", toolInput: ["file_path": "   "]))
    }

    // MARK: - WebFetch: no scheme, no query, port dropped

    func testWebFetchDropsThePortAndTheQueryString() {
        let url = "https://api.example.com:8443/v1/status?token=secret&verbose=1"
        let summary = AgentToolSummary.make(toolName: "WebFetch", toolInput: ["url": url])
        XCTAssertEqual(summary?.headline, "api.example.com/v1/status")
        XCTAssertFalse(summary?.headline.contains(":8443") ?? true)
        XCTAssertFalse(summary?.headline.contains("token") ?? true)
        XCTAssertEqual(summary?.detail, url, "the full URL, port and query included, is one click away")
    }

    func testWebFetchWithAnUnparsableURLShowsItVerbatim() {
        let raw = "not a url at all"
        XCTAssertEqual(AgentToolSummary.make(toolName: "WebFetch", toolInput: ["url": raw])?.headline, raw)
    }

    // MARK: - MCP naming

    func testMCPUnderscoreToolNameReadsAsWords() {
        let summary = AgentToolSummary.make(
            toolName: "mcp__notion__create_page",
            toolInput: ["title": "Q3 plan"]
        )
        XCTAssertEqual(summary?.headline, "Notion: create page")
    }

    func testMCPMalformedNameWithOnlyTwoPartsFallsThroughToTheDescription() {
        XCTAssertNil(AgentToolSummary.mcpParts("mcp__x"))
        let withDescription = AgentToolSummary.make(toolName: "mcp__x", toolInput: ["description": "Do a thing"])
        XCTAssertEqual(withDescription?.headline, "Do a thing")
        XCTAssertNil(AgentToolSummary.make(toolName: "mcp__x", toolInput: ["foo": "bar"]))
    }

    func testMCPGeminiResearchNaming() {
        let summary = AgentToolSummary.make(
            toolName: "mcp__orion_gemini__gemini_research",
            toolInput: ["query": "swift 6"]
        )
        XCTAssertEqual(summary?.headline, "Orion gemini: gemini research")
    }

    // MARK: - Questions

    func testMultiSelectIsStickyEvenWhenOnlyOneOfSeveralQuestionsSetsIt() {
        let input: [String: Any] = ["questions": [
            ["question": "Deploy now?", "multiSelect": false, "options": [["label": "Yes"], ["label": "No"]]],
            ["question": "Which environments?", "multiSelect": true, "options": [["label": "Staging"], ["label": "Prod"]]],
        ]]
        let summary = try? XCTUnwrap(AgentToolSummary.make(toolName: "AskUserQuestion", toolInput: input))
        XCTAssertEqual(summary?.attention, .question(count: 2, multiSelect: true))
        XCTAssertEqual(summary?.detail, "Deploy now?\n• Yes\n• No\n\nWhich environments?\n• Staging\n• Prod")
    }

    func testOptionsAreFormattedAsBulletLines() throws {
        let input: [String: Any] = ["questions": [
            ["question": "Pick a color", "multiSelect": false,
             "options": [["label": "Red", "description": "warm"], ["label": "Blue", "description": "cool"], ["label": "Green"]]]
        ]]
        let summary = try XCTUnwrap(AgentToolSummary.make(toolName: "AskUserQuestion", toolInput: input))
        XCTAssertEqual(summary.detail, "Pick a color\n• Red\n• Blue\n• Green")
    }

    func testDegenerateEmptyQuestionsArrayStillAsksForYou() throws {
        let summary = try XCTUnwrap(AgentToolSummary.make(toolName: "AskUserQuestion", toolInput: ["questions": []]))
        XCTAssertEqual(summary.headline, "Question for you")
        XCTAssertNil(summary.detail)
        XCTAssertEqual(summary.attention, .question(count: 1, multiSelect: false))
    }

    func testMissingQuestionsKeyIsStillAnAttentionEvent() throws {
        // AskUserQuestion always carries attention, even with a totally malformed
        // tool_input — the tool call itself is the thing needing an answer.
        let summary = try XCTUnwrap(AgentToolSummary.make(toolName: "AskUserQuestion", toolInput: ["unexpected": 1]))
        XCTAssertEqual(summary.attention, .question(count: 1, multiSelect: false))
        XCTAssertEqual(summary.headline, "Question for you")
    }

    // MARK: - Plans

    func testPlanHeadlineSkipsSeveralBlankLinesBeforeTheTitle() throws {
        let plan = "   \n\t\n\n## Rework the wallet ring\n\nStep one.\n"
        let summary = try XCTUnwrap(AgentToolSummary.make(toolName: "ExitPlanMode", toolInput: ["plan": plan]))
        XCTAssertEqual(summary.headline, "Plan ready for review: Rework the wallet ring")
        XCTAssertEqual(summary.attention, .plan)
    }

    func testPlanFilePathIsIgnoredEntirely() throws {
        let plan = "Ship it\n\nDetails."
        let summary = try XCTUnwrap(AgentToolSummary.make(
            toolName: "ExitPlanMode",
            toolInput: ["plan": plan, "planFilePath": "/Users/x/.claude/plans/foo.md"]
        ))
        XCTAssertEqual(summary.headline, "Plan ready for review: Ship it")
        XCTAssertEqual(summary.detail, plan)
        XCTAssertFalse(summary.detail?.contains("foo.md") ?? true)
        XCTAssertFalse(summary.headline.contains("foo.md"))
    }

    func testAPlanWhoseEveryLineIsOnlyHashesHasNoTitle() throws {
        // Every line, once its leading "#"/space/tab run is dropped, is empty — there
        // is nothing left to call a title.
        let summary = try XCTUnwrap(AgentToolSummary.make(toolName: "ExitPlanMode", toolInput: ["plan": "#####\n#### \n##\t"]))
        XCTAssertEqual(summary.headline, "Plan ready for review")
        XCTAssertNotNil(summary.detail, "the plan still has text, even if none of it reads as a title")
    }

    // MARK: - Detail dropped when it repeats the headline

    func testGrepHasNoDetailEvenThoughItHasAPattern() {
        let summary = AgentToolSummary.make(toolName: "Grep", toolInput: ["pattern": "usageStatusColor"])
        XCTAssertEqual(summary?.headline, "Grep usageStatusColor")
        XCTAssertNil(summary?.detail)
    }

    func testWebSearchHasNoDetail() {
        XCTAssertNil(AgentToolSummary.make(toolName: "WebSearch", toolInput: ["query": "swift 6 concurrency"])?.detail)
    }

    // MARK: - Caps

    func testHeadlineOverflowByOneCharacterIsCutWithAnEllipsis() throws {
        let command = String(repeating: "q", count: 81)
        let summary = try XCTUnwrap(AgentToolSummary.make(toolName: "Bash", toolInput: ["command": command]))
        XCTAssertEqual(summary.headline.count, 80)
        XCTAssertTrue(summary.headline.hasSuffix("…"))
    }

    func testMCPDetailAtOrUnderTheKilobyteCapIsNotTruncated() throws {
        // A small MCP input must pass through with no ellipsis at all.
        let summary = try XCTUnwrap(AgentToolSummary.make(toolName: "mcp__server__tool", toolInput: ["a": "b"]))
        XCTAssertEqual(summary.detail, #"{"a":"b"}"#)
        XCTAssertFalse(summary.detail?.hasSuffix("…") ?? true)
    }

    // MARK: - Unknown / nil

    func testUnknownToolWithoutADescriptionIsNil() {
        XCTAssertNil(AgentToolSummary.make(toolName: "SomeFutureTool", toolInput: ["foo": "bar"]))
    }

    func testUnknownToolWithABlankDescriptionIsNil() {
        XCTAssertNil(AgentToolSummary.make(toolName: "SomeFutureTool", toolInput: ["description": "   "]))
    }

    func testNilToolInputIsAlwaysNil() {
        XCTAssertNil(AgentToolSummary.make(toolName: "Bash", toolInput: nil))
        XCTAssertNil(AgentToolSummary.make(toolName: "AskUserQuestion", toolInput: nil))
        XCTAssertNil(AgentToolSummary.make(toolName: "ExitPlanMode", toolInput: nil))
    }

    func testABlankToolNameIsNilEvenWithGoodInput() {
        XCTAssertNil(AgentToolSummary.make(toolName: "", toolInput: ["command": "ls"]))
        XCTAssertNil(AgentToolSummary.make(toolName: nil, toolInput: ["command": "ls"]))
    }
}
