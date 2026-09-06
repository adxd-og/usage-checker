import XCTest
@testable import Omelette

/// Independent verification of the fix batch 35db235..d54ddb4 against
/// `AgentToolSummary`: items 1, 7 and 11 of the batch brief, attacking inputs the
/// executor's own `AgentToolSummaryTests.swift` did not try — `_omelette_truncated`
/// present but false or a non-Bool, `plain()`'s suffix rule with headlines and
/// details that are not file paths, a patch with trailing spaces but no `\r`, and a
/// URL carrying an explicit port.
final class AgentToolSummaryVerification2Tests: XCTestCase {
    private func applyPatch(_ patch: String) -> ToolSummary? {
        AgentToolSummary.make(toolName: "apply_patch", toolInput: ["command": patch])
    }

    // MARK: - Item 1: `_omelette_truncated` is a Bool that must be exactly true

    func testTruncatedFlagPresentButFalseIsNotTruncated() throws {
        let summary = try XCTUnwrap(AgentToolSummary.make(
            toolName: "Bash",
            toolInput: ["command": "xcodegen generate", "description": "Regenerate the project", "_omelette_truncated": false]
        ))
        XCTAssertFalse(summary.truncated)
        XCTAssertEqual(summary.detail, "xcodegen generate", "no notice appended when the flag says nothing was cut")
    }

    func testTruncatedFlagAsANonBoolStringIsNotTruncated() throws {
        // The helper's flag is always a JSON boolean; a string "true" is not the
        // same value and must not be read as one via a loose truthy check.
        let summary = try XCTUnwrap(AgentToolSummary.make(
            toolName: "Bash",
            toolInput: ["command": "xcodegen generate", "description": "Regenerate the project", "_omelette_truncated": "true"]
        ))
        XCTAssertFalse(summary.truncated, "a String is not a Bool; `as? Bool` must fail rather than coerce")
        XCTAssertEqual(summary.detail, "xcodegen generate")
    }

    func testTruncatedFlagAsAnIntegerIsNotTruncated() throws {
        let summary = try XCTUnwrap(AgentToolSummary.make(
            toolName: "Bash",
            toolInput: ["command": "xcodegen generate", "_omelette_truncated": 1]
        ))
        XCTAssertFalse(summary.truncated)
    }

    func testTruncatedFlagOnATailWithNilDetailProducesNoSummaryAtAll() {
        // A tool whose rule yields nil (nothing to say) stays nil even when the
        // truncation flag is set — there is no summary to mark.
        XCTAssertNil(AgentToolSummary.make(
            toolName: "Grep",
            toolInput: ["pattern": "   ", "_omelette_truncated": true]
        ))
    }

    // MARK: - Item 7: `plain()`'s suffix rule, exercised directly via Bash's description/command split

    func testADetailThatDoesNotMatchTheHeadlineIsKept() throws {
        let summary = try XCTUnwrap(AgentToolSummary.make(
            toolName: "Bash", toolInput: ["description": "Edit a.swift", "command": "b.swift"]
        ))
        XCTAssertEqual(summary.headline, "Edit a.swift")
        XCTAssertEqual(summary.detail, "b.swift", "unrelated detail must not be dropped")
    }

    func testADetailThatIsExactlyTheHeadlinesSuffixIsDropped() {
        let summary = AgentToolSummary.make(
            toolName: "Bash", toolInput: ["description": "Edit a.swift", "command": "a.swift"]
        )
        XCTAssertNil(summary?.detail, "the headline already ends with the whole detail")
    }

    func testADetailLongerThanTheHeadlineCannotBeItsSuffixAndIsKept() throws {
        // A detail that is *longer* than the headline can never be a suffix of it —
        // `hasSuffix` must say so rather than crash or misreport on a longer string.
        let headline = "Edit a.swift"
        let longDetail = "Edit a.swift and also update every test that touches it"
        let summary = try XCTUnwrap(AgentToolSummary.make(
            toolName: "Bash", toolInput: ["description": headline, "command": longDetail]
        ))
        XCTAssertEqual(summary.headline, headline)
        XCTAssertEqual(summary.detail, longDetail, "longer than the headline, so it cannot repeat it")
    }

    func testADetailThatIsASuffixButNotTheWholeStringIsStillDropped() {
        // "Edit WalletView.swift" ends with "WalletView.swift" even though the
        // headline carries more before it — the rule is `hasSuffix`, not equality.
        let summary = AgentToolSummary.make(
            toolName: "Bash", toolInput: ["description": "Edit WalletView.swift", "command": "WalletView.swift"]
        )
        XCTAssertNil(summary?.detail)
    }

    // MARK: - Item 11: patchFiles trims more than just `\r`, and shortURL handles a port

    func testTrailingSpacesWithNoCarriageReturnAreStillTrimmedFromTheFilename() throws {
        let patch = "*** Begin Patch\n*** Update File: src/main.rs   \n@@\n-x\n+y\n*** End Patch"
        let summary = try XCTUnwrap(applyPatch(patch))
        XCTAssertEqual(summary.headline, "Edit main.rs", "trailing spaces on the header line must not become part of the path")
    }

    func testAURLWithAPortDropsThePortAlongWithTheSchemeAndQuery() {
        XCTAssertEqual(
            AgentToolSummary.shortURL("https://example.com:8443/hooks?tab=json"),
            "example.com/hooks"
        )
    }

    func testASchemelessHostWithAPortIsStillShortened() {
        // A bare host the agent pasted without a scheme is exactly the shape
        // `parsed()` was added to handle ("Agents paste bare hosts — ... which
        // URLComponents reads as one long path with no host at all"). A host with a
        // port is just as plausible a paste (a local dev server, an internal tool)
        // and belongs to the same case, so it should shorten the same way the
        // port-less bare host already does (`shortURL("example.com/hooks?tab=json")
        // == "example.com/hooks"`, covered by the executor's own
        // AgentToolSummaryTests.swift).
        XCTAssertEqual(
            AgentToolSummary.shortURL("example.com:8443/hooks"),
            "example.com/hooks"
        )
    }
}
