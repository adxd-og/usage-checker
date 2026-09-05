import XCTest
@testable import Omelette

final class AgentToolSummaryTests: XCTestCase {
    // MARK: Bash

    func testBashPrefersTheDescriptionAndKeepsTheCommandAsDetail() {
        let summary = AgentToolSummary.make(
            toolName: "Bash",
            toolInput: ["command": "xcodegen generate", "description": "Regenerate the project"]
        )
        XCTAssertEqual(summary?.headline, "Regenerate the project")
        XCTAssertEqual(summary?.detail, "xcodegen generate")
        XCTAssertNil(summary?.attention)
    }

    func testBashWithoutADescriptionUsesTheCommand() {
        let summary = AgentToolSummary.make(toolName: "Bash", toolInput: ["command": "swift test"])
        XCTAssertEqual(summary?.headline, "swift test")
        XCTAssertNil(summary?.detail, "the headline already is the command")
    }

    func testBashKeepsTheOriginalWhitespaceInTheDetail() {
        let command = "cd /tmp &&\n  ls -la"
        let summary = AgentToolSummary.make(toolName: "Bash", toolInput: ["command": command])
        XCTAssertEqual(summary?.headline, "cd /tmp && ls -la")
        XCTAssertEqual(summary?.detail, command)
    }

    func testTheToolNameIsNeverPrefixedToABashHeadline() {
        let summary = AgentToolSummary.make(toolName: "Bash", toolInput: ["command": "ls"])
        XCTAssertEqual(summary?.headline, "ls")
    }

    // MARK: files

    func testFileToolsReadAsAVerbAndABasename() {
        let path = "/Users/me/Desktop/Usage tracker/UsageTracker/UI/PopoverView.swift"
        let summary = AgentToolSummary.make(toolName: "Edit", toolInput: ["file_path": path, "old_string": "a", "new_string": "b"])
        XCTAssertEqual(summary?.headline, "Edit PopoverView.swift")
        XCTAssertEqual(summary?.detail, path)
        XCTAssertEqual(AgentToolSummary.make(toolName: "Write", toolInput: ["file_path": "/tmp/WalletView.swift", "content": "…"])?.headline, "Write WalletView.swift")
        XCTAssertEqual(AgentToolSummary.make(toolName: "Read", toolInput: ["file_path": "/tmp/PopoverView.swift"])?.headline, "Read PopoverView.swift")
        XCTAssertEqual(AgentToolSummary.make(toolName: "MultiEdit", toolInput: ["file_path": "/tmp/A.swift", "edits": []])?.headline, "MultiEdit A.swift")
        XCTAssertEqual(AgentToolSummary.make(toolName: "NotebookEdit", toolInput: ["notebook_path": "/tmp/n.ipynb"])?.headline, "NotebookEdit n.ipynb")
    }

    // MARK: search

    func testSearchToolsKeepTheToolNameAndHaveNoDetail() {
        let grep = AgentToolSummary.make(toolName: "Grep", toolInput: ["pattern": "usageStatusColor", "path": "/tmp"])
        XCTAssertEqual(grep?.headline, "Grep usageStatusColor")
        XCTAssertNil(grep?.detail)
        XCTAssertEqual(AgentToolSummary.make(toolName: "Glob", toolInput: ["pattern": "**/*.swift"])?.headline, "Glob **/*.swift")
    }

    // MARK: web

    func testAURLReadsAsHostAndPath() {
        let url = "https://docs.example.com/hooks/reference?tab=json"
        let summary = AgentToolSummary.make(toolName: "WebFetch", toolInput: ["url": url, "prompt": "what fires"])
        XCTAssertEqual(summary?.headline, "docs.example.com/hooks/reference")
        XCTAssertEqual(summary?.detail, url)
        XCTAssertEqual(AgentToolSummary.make(toolName: "WebFetch", toolInput: ["url": "https://example.com"])?.headline, "example.com")
        XCTAssertEqual(AgentToolSummary.make(toolName: "WebFetch", toolInput: ["url": "https://example.com/"])?.headline, "example.com")
    }

    func testWebSearchUsesTheQueryAndHasNoDetail() {
        let summary = AgentToolSummary.make(toolName: "WebSearch", toolInput: ["query": "swift 6 strict concurrency minimal"])
        XCTAssertEqual(summary?.headline, "swift 6 strict concurrency minimal")
        XCTAssertNil(summary?.detail)
    }

    // MARK: MCP

    func testAnMCPToolNamesItsServerAndReadsItsToolAsWords() {
        let summary = AgentToolSummary.make(
            toolName: "mcp__orion_gemini__gemini_research",
            toolInput: ["prompt": "what changed", "model": "flash"]
        )
        XCTAssertEqual(summary?.headline, "Orion gemini: gemini research")
        XCTAssertEqual(summary?.detail, #"{"model":"flash","prompt":"what changed"}"#)
    }

    func testMCPPartsRejectsWhatIsNotAnMCPName() {
        XCTAssertNil(AgentToolSummary.mcpParts("Bash"))
        XCTAssertNil(AgentToolSummary.mcpParts("mcp__server"))
        XCTAssertNil(AgentToolSummary.mcpParts("mcp____tool"))
        let parts = AgentToolSummary.mcpParts("mcp__notion__notion-fetch")
        XCTAssertEqual(parts?.server, "notion")
        XCTAssertEqual(parts?.tool, "notion-fetch")
        XCTAssertEqual(AgentToolSummary.mcpServerName("claude_ai_Notion"), "Claude ai Notion")
    }

    func testAnMCPDetailIsCappedAtAKilobyte() throws {
        let summary = try XCTUnwrap(AgentToolSummary.make(
            toolName: "mcp__server__tool",
            toolInput: ["blob": String(repeating: "z", count: 4_000)]
        ))
        XCTAssertEqual(summary.detail?.count, AgentToolSummary.maxMCPDetailLength)
        XCTAssertEqual(summary.detail?.hasSuffix("…"), true)
    }

    // MARK: questions

    func testOneQuestionReadsAsAQuestion() throws {
        let input: [String: Any] = ["questions": [
            ["question": "Tabs or spaces?", "header": "Style", "multiSelect": false,
             "options": [["label": "Tabs", "description": "Hard tabs"], ["label": "Spaces", "description": "Four"]]]
        ]]
        let summary = try XCTUnwrap(AgentToolSummary.make(toolName: "AskUserQuestion", toolInput: input))
        XCTAssertEqual(summary.headline, "Question: Tabs or spaces?")
        XCTAssertEqual(summary.detail, "Tabs or spaces?\n• Tabs\n• Spaces")
        XCTAssertEqual(summary.attention, .question(count: 1, multiSelect: false))
    }

    func testSeveralQuestionsAreCountedAndMultiSelectIsSticky() throws {
        let input: [String: Any] = ["questions": [
            ["question": "Which provider?", "multiSelect": true, "options": [["label": "Claude"], ["label": "Codex"]]],
            ["question": "Ship today?", "multiSelect": false, "options": [["label": "Yes"]]],
        ]]
        let summary = try XCTUnwrap(AgentToolSummary.make(toolName: "AskUserQuestion", toolInput: input))
        XCTAssertEqual(summary.headline, "2 questions: Which provider?")
        XCTAssertEqual(summary.detail, "Which provider?\n• Claude\n• Codex\n\nShip today?\n• Yes")
        XCTAssertEqual(summary.attention, .question(count: 2, multiSelect: true))
    }

    func testAQuestionWithNoTextStillAsksForYou() throws {
        let summary = try XCTUnwrap(AgentToolSummary.make(toolName: "AskUserQuestion", toolInput: ["questions": []]))
        XCTAssertEqual(summary.headline, "Question for you")
        XCTAssertNil(summary.detail)
        XCTAssertEqual(summary.attention, .question(count: 1, multiSelect: false))
    }

    // MARK: plans

    func testAPlanHeadlineIsItsTitleWithoutTheHashes() throws {
        let plan = "## Rework the ring\n\nStep one.\nStep two.\n"
        let summary = try XCTUnwrap(AgentToolSummary.make(toolName: "ExitPlanMode", toolInput: ["plan": plan]))
        XCTAssertEqual(summary.headline, "Plan ready for review: Rework the ring")
        XCTAssertEqual(summary.detail, plan)
        XCTAssertEqual(summary.attention, .plan)
    }

    func testAnEmptyPlanIsStillAPlan() throws {
        let summary = try XCTUnwrap(AgentToolSummary.make(toolName: "ExitPlanMode", toolInput: ["plan": "   \n"]))
        XCTAssertEqual(summary.headline, "Plan ready for review")
        XCTAssertNil(summary.detail)
        XCTAssertEqual(summary.attention, .plan)
    }

    func testALongPlanDetailIsCutAt4096() throws {
        let plan = "Title\n" + String(repeating: "x", count: 8_000)
        let summary = try XCTUnwrap(AgentToolSummary.make(toolName: "ExitPlanMode", toolInput: ["plan": plan]))
        XCTAssertEqual(summary.detail?.count, AgentToolSummary.maxDetailLength)
        XCTAssertEqual(summary.detail?.hasSuffix("…"), true)
    }

    // MARK: nothing to say

    func testNothingToSayMeansNil() {
        XCTAssertNil(AgentToolSummary.make(toolName: "Bash", toolInput: nil))
        XCTAssertNil(AgentToolSummary.make(toolName: "Bash", toolInput: ["command": "   \n"]))
        XCTAssertNil(AgentToolSummary.make(toolName: "Bash", toolInput: ["command": 42]))
        XCTAssertNil(AgentToolSummary.make(toolName: nil, toolInput: ["command": "ls"]))
        XCTAssertNil(AgentToolSummary.make(toolName: "", toolInput: ["command": "ls"]))
        XCTAssertNil(AgentToolSummary.make(toolName: "Edit", toolInput: ["old_string": "a"]))
        XCTAssertNil(AgentToolSummary.make(toolName: "WebSearch", toolInput: ["query": "  "]))
        XCTAssertNil(AgentToolSummary.make(toolName: "SomethingNew", toolInput: ["whatever": 1]))
    }

    func testAnUnknownToolWithADescriptionUsesIt() {
        let summary = AgentToolSummary.make(toolName: "SomethingNew", toolInput: ["description": "Warm the cache"])
        XCTAssertEqual(summary?.headline, "Warm the cache")
        XCTAssertNil(summary?.detail)
    }

    // MARK: caps

    func testAHeadlineIsCutAt80CharactersWithAnEllipsis() throws {
        let command = String(repeating: "x", count: 200)
        let summary = try XCTUnwrap(AgentToolSummary.make(toolName: "Bash", toolInput: ["command": command]))
        XCTAssertEqual(summary.headline.count, AgentToolSummary.maxHeadlineLength)
        XCTAssertTrue(summary.headline.hasSuffix("…"))
        XCTAssertEqual(String(summary.headline.dropLast()), String(repeating: "x", count: 79))
        XCTAssertEqual(summary.detail, command, "the detail keeps the whole thing")
    }

    func testExactly80CharactersIsNotCut() {
        let command = String(repeating: "y", count: 80)
        XCTAssertEqual(AgentToolSummary.make(toolName: "Bash", toolInput: ["command": command])?.headline, command)
    }

    // MARK: apply_patch (Codex)

    private func applyPatch(_ patch: String) -> ToolSummary? {
        AgentToolSummary.make(toolName: "apply_patch", toolInput: ["command": patch])
    }

    func testApplyPatchNamesTheFileAndTheVerb() throws {
        let update = try XCTUnwrap(applyPatch("""
        *** Begin Patch
        *** Update File: src/wallet/WalletView.swift
        @@
        -old
        +new
        *** End Patch
        """))
        XCTAssertEqual(update.headline, "Edit WalletView.swift")
        XCTAssertNil(update.attention)

        XCTAssertEqual(applyPatch("*** Add File: src/main.rs")?.headline, "Create main.rs")
        XCTAssertEqual(applyPatch("*** Delete File: /tmp/old.swift")?.headline, "Delete old.swift")
    }

    func testApplyPatchCountsTheOtherFiles() throws {
        let patch = """
        *** Begin Patch
        *** Update File: a.swift
        @@
        -x
        +y
        *** Add File: b.swift
        +new file
        *** Delete File: c.swift
        *** End Patch
        """
        XCTAssertEqual(applyPatch(patch)?.headline, "Edit a.swift +2 more")
    }

    func testApplyPatchKeepsThePatchAsTheDetail() throws {
        let patch = "*** Begin Patch\n*** Update File: a.swift\n@@\n-x\n+y\n*** End Patch"
        let summary = try XCTUnwrap(applyPatch(patch))
        XCTAssertEqual(summary.detail, patch, "the detail is the patch, newlines and all")
    }

    func testApplyPatchWithNothingToName() {
        XCTAssertNil(applyPatch("*** Begin Patch\n*** End Patch"), "no file header, nothing to say")
        XCTAssertNil(AgentToolSummary.make(toolName: "apply_patch", toolInput: [:]))
        XCTAssertNil(AgentToolSummary.make(toolName: "apply_patch", toolInput: ["command": 42]))
    }

    func testApplyPatchHeadlineStaysWithinTheRowsLine() throws {
        let name = String(repeating: "n", count: 200) + ".swift"
        let summary = try XCTUnwrap(applyPatch("*** Update File: /tmp/\(name)"))
        XCTAssertLessThanOrEqual(summary.headline.count, 80)
        XCTAssertTrue(summary.headline.hasSuffix("…"))
    }

    // MARK: truncation

    private static let notice = "[truncated by Omelette — see the terminal for the full text]"

    func testATruncatedInputSaysSoUnderTheDetail() throws {
        let command = String(repeating: "x", count: AgentToolSummary.maxDetailLength)
        let summary = try XCTUnwrap(AgentToolSummary.make(
            toolName: "Bash",
            toolInput: ["command": command, "description": "Rebuild everything", "_omelette_truncated": true]
        ))
        XCTAssertTrue(summary.truncated)
        XCTAssertEqual(summary.headline, "Rebuild everything", "the headline is what it always was")
        let detail = try XCTUnwrap(summary.detail)
        XCTAssertTrue(detail.hasPrefix("xxx"), "the text we did get is still there")
        XCTAssertTrue(detail.hasSuffix("\n" + Self.notice), "got \(detail.suffix(80))")
        let body = detail.dropLast(Self.notice.count + 1)
        XCTAssertEqual(body.count, AgentToolSummary.maxDetailLength, "the notice is added, not carved out of the text")
    }

    func testAnInputThatArrivedWholeCarriesNoNotice() throws {
        let summary = try XCTUnwrap(AgentToolSummary.make(
            toolName: "Bash",
            toolInput: ["command": "xcodegen generate", "description": "Regenerate the project"]
        ))
        XCTAssertFalse(summary.truncated)
        XCTAssertEqual(summary.detail, "xcodegen generate")
    }

    func testTruncationIsStillVisibleWhenThereIsNoDetail() throws {
        let summary = try XCTUnwrap(AgentToolSummary.make(
            toolName: "Grep",
            toolInput: ["pattern": "usageStatusColor", "_omelette_truncated": true]
        ))
        XCTAssertTrue(summary.truncated)
        XCTAssertEqual(summary.headline, "Grep usageStatusColor")
        XCTAssertEqual(summary.detail, Self.notice, "the notice is the whole detail rather than nothing at all")
    }

    func testAQuestionAlsoSaysWhenItsOptionsWereCut() throws {
        let summary = try XCTUnwrap(AgentToolSummary.make(
            toolName: "AskUserQuestion",
            toolInput: [
                "_omelette_truncated": true,
                "questions": [["question": "Ship it?", "options": [["label": "Yes"], ["label": "No"]]]],
            ]
        ))
        XCTAssertTrue(summary.truncated)
        XCTAssertEqual(summary.attention, .question(count: 1, multiSelect: false))
        XCTAssertEqual(summary.detail, "Ship it?\n• Yes\n• No\n" + Self.notice)
    }
}
