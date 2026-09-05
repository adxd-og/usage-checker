import XCTest
@testable import Omelette

/// Independent verification of the Codex hook decoder path and the `apply_patch`
/// summary branch, written from the spec's Package B section rather than adapted
/// from the executor's own `AgentEventDecoderTests` / `AgentToolSummaryTests`.
final class CodexDecoderAndSummaryVerificationTests: XCTestCase {
    private func decodeCodexHook(_ payload: String, requestID: String? = nil) throws -> AgentEvent {
        try AgentEventDecoder.decode(
            AgentFixture.envelope(source: "codex", payload: payload, requestID: requestID, transport: "hook")
        )
    }

    // MARK: - Every Codex hook kind, including one the switch never trained on

    func testNotificationIsUnknownForCodexEvenThoughItsAValidClaudeEventName() throws {
        // Codex has no `Notification` event (only Claude does). If the decoder ever
        // accidentally shared Claude's switch for the hook path, "Notification"
        // would map to `.notificationPermission` / `.notificationIdle` depending on
        // a `notification_type` key Codex never sends — instead it must fall through
        // to `.unknown`.
        let payload = AgentFixture.codexHook("Notification", extra: #""notification_type":"permission_prompt""#)
        let event = try decodeCodexHook(payload)
        XCTAssertEqual(event.kind, .unknown("Notification"))
        XCTAssertEqual(event.source, .codex)
    }

    func testPreCompactAndOtherUnlistedEventsAreUnknownNotAnError() throws {
        for name in ["PreCompact", "PostCompact", "SubagentStart", "SubagentStop", "Interrupt"] {
            let event = try decodeCodexHook(AgentFixture.codexHook(name))
            XCTAssertEqual(event.kind, .unknown(name), name)
        }
    }

    // MARK: - Bash without a description falls back to the command, same as Claude's rule

    func testCodexBashWithNoDescriptionFallsBackToTheCollapsedCommand() throws {
        let payload = AgentFixture.codexHook(
            "PreToolUse",
            extra: #""tool_name":"Bash","tool_input":{"command":"cargo   test\n--release"}"#
        )
        let event = try decodeCodexHook(payload)
        XCTAssertEqual(event.toolName, "Bash")
        XCTAssertEqual(event.toolSummary, "cargo test --release", "no description: the collapsed command is the headline")
        XCTAssertEqual(event.toolDetail, "cargo   test\n--release", "the detail keeps the original whitespace")
    }

    // MARK: - apply_patch through the full decoder (not just AgentToolSummary directly)

    func testApplyPatchPermissionRequestCarriesHeadlineAndDetailThroughTheDecoder() throws {
        let patch = #"*** Begin Patch\n*** Update File: src/wallet/WalletView.swift\n@@\n-old\n+new\n*** End Patch"#
        let payload = AgentFixture.codexHook(
            "PermissionRequest",
            extra: #""tool_name":"apply_patch","tool_input":{"command":"\#(patch)"}"#
        )
        let event = try decodeCodexHook(payload, requestID: AgentFixture.requestID)
        XCTAssertEqual(event.kind, .permissionRequested)
        XCTAssertEqual(event.toolName, "apply_patch")
        XCTAssertEqual(event.toolSummary, "Edit WalletView.swift")
        XCTAssertEqual(event.toolDetail, "*** Begin Patch\n*** Update File: src/wallet/WalletView.swift\n@@\n-old\n+new\n*** End Patch")
        XCTAssertNil(event.attention, "apply_patch is a tool call, never a question or a plan")
        XCTAssertEqual(event.requestID, AgentFixture.requestID)
    }

    func testApplyPatchWithNoRecognisedHeaderProducesNoSummaryAtAllThroughTheDecoder() throws {
        // A patch whose only line is the fence, nothing Update/Add/Delete — the
        // decoder must not invent a headline out of nothing.
        let payload = AgentFixture.codexHook(
            "PreToolUse",
            extra: #""tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** End Patch"}"#
        )
        let event = try decodeCodexHook(payload)
        XCTAssertNil(event.toolSummary)
        XCTAssertNil(event.toolDetail)
    }

    func testApplyPatchDetailIsCappedAtFourKilobytesThroughTheDecoder() throws {
        let filler = String(repeating: "x", count: 5000)
        let payload = AgentFixture.codexHook(
            "PreToolUse",
            extra: #""tool_name":"apply_patch","tool_input":{"command":"*** Update File: a.swift\n\#(filler)"}"#
        )
        let event = try decodeCodexHook(payload)
        let detail = try XCTUnwrap(event.toolDetail)
        XCTAssertLessThanOrEqual(detail.count, 4096)
        XCTAssertTrue(detail.hasSuffix("…"))
    }

    func testApplyPatchWithThreeFilesCountsTheOtherTwoThroughTheDecoder() throws {
        let payload = AgentFixture.codexHook(
            "PreToolUse",
            extra: #""tool_name":"apply_patch","tool_input":{"command":"*** Update File: a.swift\n*** Add File: b.swift\n*** Delete File: c.swift"}"#
        )
        let event = try decodeCodexHook(payload)
        XCTAssertEqual(event.toolSummary, "Edit a.swift +2 more")
    }

    // MARK: - requestID only ever attaches to PermissionRequest, for every other kind

    func testRequestIDNeverLeaksOntoAnyNonPermissionCodexHookKind() throws {
        let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd"]
        for name in events {
            let event = try decodeCodexHook(AgentFixture.codexHook(name), requestID: AgentFixture.requestID)
            XCTAssertNil(event.requestID, "\(name) must never carry a request id even when the envelope has one")
        }
    }

    // MARK: - cwd and empty-string edge cases

    func testEmptyCwdIsPassedThroughAsEmptyStringNotNil() throws {
        // `cwd` has no "must not be empty" guard anywhere in the spec (unlike
        // session_id) — an empty string is a legitimate (if odd) value and must not
        // silently become nil, which would read differently in the UI ("no cwd" vs
        // "cwd is blank").
        let payload = AgentFixture.codexHook("Stop", cwd: "")
        let event = try decodeCodexHook(payload)
        XCTAssertEqual(event.cwd, "")
    }

    func testWhitespaceOnlySessionIDIsAcceptedBecauseOnlyEmptyStringIsRejected() throws {
        // The decoder's guard is `!sessionID.isEmpty`, not a trim-then-check. This
        // pins the exact rule rather than assuming a stricter one.
        let payload = AgentFixture.codexHook("Stop", sessionID: "   ")
        let event = try decodeCodexHook(payload)
        XCTAssertEqual(event.sessionID, "   ")
    }
}
