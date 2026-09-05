import XCTest
@testable import Omelette

/// Independent verification of `HookHelper/main.swift`'s widened `shrinkingToolInput`
/// against
/// `docs/superpowers/specs/2026-09-06-clear-requests-and-codex-approvals-design.md`
/// § "Helper" and the plan's Task 4 size budget. The helper is a separate
/// Foundation-only target with top-level code — it cannot be unit-tested directly, so
/// this spawns the built `omelette-hook` exactly as `OmeletteHookEndToEndTests` does,
/// but is written independently and pins the *exact* per-key caps from the spec
/// (command 4096, description 512, url 2048, plan 1024, question 512, header 64,
/// option label 80, at most 4 questions / 6 options) rather than re-checking the
/// executor's own numbers, plus the keys the spec says must be dropped
/// (`content`, `old_string`, `new_string`, `prompt`, `planFilePath`) and the
/// "shrink only when oversized" trigger.
final class OmeletteHookShrinkVerificationTests: XCTestCase {
    private final class Box: @unchecked Sendable { var events: [AgentEvent] = [] }

    private var socketURL: URL!
    private var server: AgentEventServer?
    private let box = Box()

    override func setUp() {
        socketURL = AgentFixture.temporarySocketURL()
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: AgentPaths.bundledHelperURL.path),
            "omelette-hook missing at \(AgentPaths.bundledHelperURL.path)"
        )
    }

    override func tearDown() {
        server?.stop()
        server = nil
        try? FileManager.default.removeItem(at: socketURL)
    }

    private func startServer() throws {
        let box = self.box
        let server = AgentEventServer(socketURL: socketURL) { event, _ in box.events.append(event) }
        try server.start()
        self.server = server
    }

    @discardableResult
    private func runHelper(stdin input: String) throws -> Int32 {
        let process = Process()
        process.executableURL = AgentPaths.bundledHelperURL
        var environment = ProcessInfo.processInfo.environment
        environment[AgentPaths.socketEnvironmentKey] = socketURL.path
        process.environment = environment
        let stdinPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = stdinPipe
        try process.run()
        stdinPipe.fileHandleForWriting.write(Data(input.utf8))
        try stdinPipe.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Every shrunk payload now ends its detail with the app's own truncation notice
    /// (`AgentToolSummary.truncationNotice`), which is the point of the flag the
    /// helper sets. The caps below are about the text the helper sent, so the notice
    /// is asserted once here and stripped before anything is measured.
    private func detailWithoutNotice(_ detail: String?, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let detail = try XCTUnwrap(detail, file: file, line: line)
        let suffix = "\n" + AgentToolSummary.truncationNotice
        XCTAssertTrue(detail.hasSuffix(suffix), "a shrunk payload must say so", file: file, line: line)
        return String(detail.dropLast(suffix.count))
    }

    private func waitForEvents(_ count: Int, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while box.events.count < count && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return box.events.count >= count
    }

    /// Builds a `PreToolUse` line whose JSON-encoded byte size clears 64 KB — the
    /// helper only shrinks past `maxLineBytes`, so every test pads with a large,
    /// unrelated key (`padding`) that the shrink drops entirely, rather than relying
    /// on any one kept key alone to cross the threshold.
    private func oversizedPayload(toolName: String, extraToolInput: String) -> String {
        let padding = String(repeating: "z", count: 90 * 1024)
        return AgentFixture.claude(
            "PreToolUse",
            extra: #""tool_name":"\#(toolName)","tool_input":{"padding":"\#(padding)",\#(extraToolInput)}"#
        )
    }

    // MARK: - Exact per-key caps

    func testCommandIsKeptToExactlyFourThousandNinetySixCharacters() throws {
        try startServer()
        let command = String(repeating: "c", count: 6_000)
        let payload = oversizedPayload(toolName: "Bash", extraToolInput: #""command":"\#(command)","description":"Warm the cache""#)

        XCTAssertEqual(try runHelper(stdin: payload), 0)
        XCTAssertTrue(waitForEvents(1))
        let event = try XCTUnwrap(box.events.first)
        // The helper's own command cap (4096) and AgentToolSummary's detail cap
        // (also 4096) coincide, so the composed result is exactly 4096 characters
        // with *no* ellipsis: the helper's raw prefix already lands exactly on the
        // app's own boundary, so the app's `cap()` (text.count > limit) never fires a
        // second truncation. A shorter helper keep would show up as fewer than 4096
        // characters; a helper that forwarded the whole 6000 would show up as 4096
        // characters *with* a trailing "…" from the app's own cap. Neither happened.
        let detail = try detailWithoutNotice(event.toolDetail)
        XCTAssertEqual(detail.count, 4096)
        XCTAssertFalse(detail.hasSuffix("…"), "the helper's cap and the app's cap land on the same boundary")
        XCTAssertEqual(detail, String(repeating: "c", count: 4096))
        XCTAssertEqual(event.toolSummary, "Warm the cache")
    }

    func testDescriptionIsKeptToFiveHundredTwelveCharacters() throws {
        try startServer()
        // A Bash description collapses through the app's own 80-char headline cap,
        // which would hide the helper's 512 boundary. Route it through an MCP tool's
        // detail instead: MCP's detail is a compact JSON of the whole (post-shrink)
        // tool_input, capped by the app at 1024 — well above 512 — so the surviving
        // "description" value's exact length pins the helper's own cap.
        let description600 = String(repeating: "d", count: 600)
        let payload = oversizedPayload(toolName: "mcp__server__tool", extraToolInput: #""description":"\#(description600)""#)

        XCTAssertEqual(try runHelper(stdin: payload), 0)
        XCTAssertTrue(waitForEvents(1))
        let event = try XCTUnwrap(box.events.first)
        let detail = try detailWithoutNotice(event.toolDetail)
        XCTAssertFalse(detail.hasSuffix("…"), "well under the app's own 1024 MCP cap, so nothing here should look app-truncated")
        // Sorted-keys JSON puts "_omelette_truncated" (which itself contains one "d",
        // in "truncated") before "description" — pull only the description value out
        // rather than counting "d" over the whole object.
        let marker = #""description":""#
        let afterMarker = try XCTUnwrap(detail.range(of: marker)).upperBound
        let value = detail[afterMarker...].dropLast(2)   // trailing `"}`
        XCTAssertEqual(value.count, 512, "the helper's own description cap, not the app's")
        XCTAssertTrue(value.allSatisfy { $0 == "d" })
    }

    func testUrlIsKeptToTwoThousandFortyEightCharacters() throws {
        try startServer()
        let longPath = String(repeating: "a", count: 3_000)
        let url = "https://example.com/\(longPath)"
        let payload = oversizedPayload(toolName: "WebFetch", extraToolInput: #""url":"\#(url)""#)

        XCTAssertEqual(try runHelper(stdin: payload), 0)
        XCTAssertTrue(waitForEvents(1))
        let event = try XCTUnwrap(box.events.first)
        // The full URL is the detail (AgentToolSummary caps at 4096, well above the
        // helper's own 2048), so its length pins the helper's cap exactly.
        XCTAssertEqual(try detailWithoutNotice(event.toolDetail).count, 2048)
    }

    func testPlanIsKeptToOneThousandTwentyFourCharacters() throws {
        try startServer()
        let plan = "# Title\n" + String(repeating: "s", count: 5_000)
        // A raw newline inside a JSON string literal is invalid JSON — escape it like
        // the real helper's own caller (Claude Code) would.
        let payload = oversizedPayload(toolName: "ExitPlanMode", extraToolInput: #""plan":"\#(plan.replacingOccurrences(of: "\n", with: "\\n"))""#)

        XCTAssertEqual(try runHelper(stdin: payload), 0)
        XCTAssertTrue(waitForEvents(1))
        let event = try XCTUnwrap(box.events.first)
        XCTAssertEqual(event.attention, .plan)
        XCTAssertEqual(try detailWithoutNotice(event.toolDetail).count, 1024)
        XCTAssertEqual(event.toolSummary, "Plan ready for review: Title")
    }

    func testAtMostFourQuestionsAndSixOptionsSurviveWithTheirCapsPerField() throws {
        try startServer()
        // Six questions, the sixth with eight options and an over-long question and
        // header text — everything past the spec's per-field caps must be gone by the
        // time the event reaches the app.
        let longQuestion = String(repeating: "q", count: 700)
        var questions: [String] = []
        for index in 0..<6 {
            let options = (0..<8).map { #"{"label":"opt\#(index)-\#($0)"}"# }.joined(separator: ",")
            questions.append(#"{"question":"\#(longQuestion)","header":"\#(String(repeating: "h", count: 100))","multiSelect":false,"options":[\#(options)]}"#)
        }
        let payload = oversizedPayload(toolName: "AskUserQuestion", extraToolInput: #""questions":[\#(questions.joined(separator: ","))]"#)

        XCTAssertEqual(try runHelper(stdin: payload), 0)
        XCTAssertTrue(waitForEvents(1))
        let event = try XCTUnwrap(box.events.first)
        XCTAssertEqual(event.attention, .question(count: 4, multiSelect: false), "only the first 4 of 6 questions survive the shrink")
        // Each surviving question contributes one "• label" line per surviving
        // option, capped at 6 of the 8 offered, and the question text itself is
        // capped at 512 by the helper before AgentToolSummary ever sees it — collapse
        // does not shrink a single-word repeated character, so the detail's option
        // count is what pins the per-question option cap.
        let firstBlock = try XCTUnwrap(event.toolDetail?.components(separatedBy: "\n\n").first)
        let lines = firstBlock.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.first?.count, 512, "the helper's own 512-char question cap")
        let bulletLines = lines.filter { $0.hasPrefix("• ") }
        XCTAssertEqual(bulletLines.count, 6, "only 6 of the 8 offered options per question survive")
    }

    func testAskUserQuestionOptionLabelIsKeptToEightyCharacters() throws {
        try startServer()
        let longLabel = String(repeating: "l", count: 200)
        let payload = oversizedPayload(
            toolName: "AskUserQuestion",
            extraToolInput: #""questions":[{"question":"Pick one","multiSelect":false,"options":[{"label":"\#(longLabel)"}]}]"#
        )
        XCTAssertEqual(try runHelper(stdin: payload), 0)
        XCTAssertTrue(waitForEvents(1))
        let event = try XCTUnwrap(box.events.first)
        // detail = "Pick one\n• <label>" — the bullet line minus its "• " prefix is
        // exactly the kept label.
        let bulletLine = try XCTUnwrap(event.toolDetail?.split(separator: "\n").first { $0.hasPrefix("• ") })
        XCTAssertEqual(bulletLine.count, 82, "\"• \" (2) + the helper's own 80-char label cap")
    }

    // MARK: - Dropped keys

    func testEditsFileContentAndPromptNeverReachTheApp() throws {
        try startServer()
        let payload = oversizedPayload(
            toolName: "Edit",
            extraToolInput: #""file_path":"/tmp/Big.swift","old_string":"\#(String(repeating: "o", count: 2_000))","new_string":"\#(String(repeating: "n", count: 2_000))""#
        )
        XCTAssertEqual(try runHelper(stdin: payload), 0)
        XCTAssertTrue(waitForEvents(1))
        let event = try XCTUnwrap(box.events.first)
        // file_path survives (it is a kept key); old_string/new_string are not on the
        // kept list at all, so the summary is still exactly what a shrunk Edit
        // produces — a headline and the path, nothing about their contents.
        XCTAssertEqual(event.toolSummary, "Edit Big.swift")
        XCTAssertEqual(try detailWithoutNotice(event.toolDetail), "/tmp/Big.swift")
        XCTAssertEqual(server?.droppedCount, 0)
    }

    func testWriteContentIsDropped() throws {
        try startServer()
        let payload = oversizedPayload(
            toolName: "Write",
            extraToolInput: #""file_path":"/tmp/Notes.txt","content":"\#(String(repeating: "c", count: 4_000))""#
        )
        XCTAssertEqual(try runHelper(stdin: payload), 0)
        XCTAssertTrue(waitForEvents(1))
        let event = try XCTUnwrap(box.events.first)
        XCTAssertEqual(event.toolSummary, "Write Notes.txt")
        XCTAssertEqual(try detailWithoutNotice(event.toolDetail), "/tmp/Notes.txt", "content must not leak into the detail")
    }

    func testWebFetchPromptIsDropped() throws {
        // WebFetch's summary never reads "prompt" either way, so proving the helper
        // actually drops it (rather than the app merely ignoring it) needs a key that
        // shows up verbatim: route it through an MCP tool's detail, which is a
        // compact JSON of the whole surviving tool_input.
        try startServer()
        let payload = oversizedPayload(
            toolName: "mcp__server__tool",
            extraToolInput: #""prompt":"\#(String(repeating: "p", count: 2_000))","url":"https://example.com/x""#
        )
        XCTAssertEqual(try runHelper(stdin: payload), 0)
        XCTAssertTrue(waitForEvents(1))
        let event = try XCTUnwrap(box.events.first)
        XCTAssertFalse((event.toolDetail ?? "").contains("prompt"), "prompt is not a kept key at all")
        XCTAssertTrue((event.toolDetail ?? "").contains("url"), "url is a kept key, so it must still be there")
    }

    func testExitPlanModePlanFilePathIsDroppedByTheHelperToo() throws {
        try startServer()
        let payload = oversizedPayload(
            toolName: "ExitPlanMode",
            extraToolInput: #""plan":"Ship it","planFilePath":"/Users/x/.claude/plans/\#(String(repeating: "p", count: 2_000)).md""#
        )
        XCTAssertEqual(try runHelper(stdin: payload), 0)
        XCTAssertTrue(waitForEvents(1))
        let event = try XCTUnwrap(box.events.first)
        XCTAssertEqual(event.toolSummary, "Plan ready for review: Ship it")
        XCTAssertFalse((event.toolDetail ?? "").contains("plans/"))
    }

    // MARK: - The shrink only fires past maxLineBytes

    func testASmallAskUserQuestionPassesThroughWithoutShrinking() throws {
        try startServer()
        // Small enough that `line.count > maxLineBytes` (64 KB) is false — every field
        // should arrive exactly as sent, proving the trigger, not the cap, decided
        // this.
        let payload = AgentFixture.claude(
            "PreToolUse",
            extra: #""tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Tabs or spaces?","header":"Style","multiSelect":false,"options":[{"label":"Tabs","description":"Hard tabs, no ambiguity"},{"label":"Spaces","description":"Four, always"}]}]}"#
        )
        XCTAssertEqual(try runHelper(stdin: payload), 0)
        XCTAssertTrue(waitForEvents(1))
        let event = try XCTUnwrap(box.events.first)
        XCTAssertEqual(event.toolSummary, "Question: Tabs or spaces?")
        XCTAssertEqual(event.toolDetail, "Tabs or spaces?\n• Tabs\n• Spaces")
        XCTAssertEqual(event.attention, .question(count: 1, multiSelect: false))
        XCTAssertEqual(server?.droppedCount, 0)
    }
}
