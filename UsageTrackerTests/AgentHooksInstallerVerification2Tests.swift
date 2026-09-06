import XCTest
@testable import Omelette

/// Independent verification of the fix batch 35db235..d54ddb4 against
/// `AgentHooksInstaller`'s `[hooks.state]` reader (item 4 of the batch brief):
/// a `#` inside a quoted value, `enabled=false` with no surrounding spaces,
/// `enabled = "false"` as a quoted string rather than a bare boolean, a header
/// carrying both a trailing comment and CRLF line endings at once, and two of our
/// own table entries at different indices inside one file.
final class AgentHooksInstallerVerification2Tests: XCTestCase {
    private var root: URL!
    private let helper = "/Users/tester/Library/Application Support/UsageTracker/bin/omelette-hook"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentHooksInstallerVerification2Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var hooksURL: URL { root.appendingPathComponent("hooks.json") }
    private var configURL: URL { root.appendingPathComponent("config.toml") }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    private static let rtkHooksJSON = """
    {
      "hooks": {
        "PreToolUse": [
          {
            "matcher": "Bash",
            "hooks": [
              {
                "type": "command",
                "command": "rtk hook claude"
              }
            ]
          }
        ]
      }
    }
    """

    private func installedIntoRtkHooks() throws {
        try write(Self.rtkHooksJSON, to: hooksURL)
        try AgentHooksInstaller.installCodexHooks(hooksURL: hooksURL, helperPath: helper)
    }

    /// The seven tables of ours, with the entry indices a merge into the rtk file
    /// produces (`PreToolUse` is 1 because the rtk entry owns 0) — the same fixture
    /// shape `AgentHooksInstallerTests.swift` uses.
    private static let trustedEntries: [(event: String, index: Int)] = [
        ("permission_request", 0), ("session_start", 0), ("user_prompt_submit", 0),
        ("pre_tool_use", 1), ("post_tool_use", 0), ("stop", 0), ("session_end", 0),
    ]

    private func trustTables(
        hooksPath: String, headerSuffix: String = "", body: (String) -> String, skipping missing: Set<String> = []
    ) -> String {
        Self.trustedEntries.filter { !missing.contains($0.event) }.map { entry in
            """
            [hooks.state."\(hooksPath):\(entry.event):\(entry.index):0"]\(headerSuffix)
            \(body(entry.event))
            """
        }.joined(separator: "\n\n")
    }

    private static let hash = #"trusted_hash = "sha256:ff051adf363232a355758bbc96941b87ab8b38bd47e6c5940b1232827a68b6d6""#

    // MARK: - A `#` inside a quoted value is not a comment

    func testAHashInsideAQuotedTrustedHashValueIsPartOfTheHash() throws {
        try installedIntoRtkHooks()
        let text = trustTables(hooksPath: hooksURL.path) { _ in
            #"trusted_hash = "sha256:ab#cd""#
        }
        try write(text, to: configURL)

        XCTAssertEqual(
            AgentHooksInstaller.codexTrust(configURL: configURL, hooksURL: hooksURL), .trusted,
            "the '#' sits inside the quoted string and must not truncate the value or start a comment"
        )
    }

    // MARK: - `enabled=false` with no spaces around `=`

    func testEnabledFalseWithNoSpacesIsStillReadAsFalse() throws {
        try installedIntoRtkHooks()
        let text = trustTables(hooksPath: hooksURL.path) { _ in "\(Self.hash)\nenabled=false" }
        try write(text, to: configURL)

        XCTAssertEqual(
            AgentHooksInstaller.codexTrust(configURL: configURL, hooksURL: hooksURL),
            .awaitingTrust(untrusted: AgentHooksInstaller.codexHookEvents),
            "no space around '=' must not stop 'enabled' and 'false' from being recognised"
        )
    }

    // MARK: - `enabled = "false"` is a TOML string, not the boolean false

    func testEnabledAsAQuotedStringIsNotRecognisedAsDisabling() throws {
        // Real Codex only ever writes `enabled` as a bare boolean. This pins the
        // actual behaviour for the case where it shows up quoted anyway: `assignment`
        // does not unquote the right-hand side before comparing it against the bare
        // literal "false", so a quoted "false" is not equal to it and the entry keeps
        // the default `enabled = true`. FINDING candidate: this is the unsafe
        // direction for a trust check to fail in — an entry meant to read as disabled
        // is instead reported as trusted.
        try installedIntoRtkHooks()
        let text = trustTables(hooksPath: hooksURL.path) { _ in "\(Self.hash)\nenabled = \"false\"" }
        try write(text, to: configURL)

        XCTAssertEqual(
            AgentHooksInstaller.codexTrust(configURL: configURL, hooksURL: hooksURL), .trusted,
            #"a quoted "false" does not match the bare literal the code compares against, so `enabled` stays at its true default"#
        )
    }

    // MARK: - A header with both a trailing comment and CRLF endings

    func testAHeaderWithATrailingCommentAndCRLFTogether() throws {
        try installedIntoRtkHooks()
        let unix = trustTables(hooksPath: hooksURL.path, headerSuffix: " # c") { _ in Self.hash }
        let crlf = unix.replacingOccurrences(of: "\n", with: "\r\n")
        try write(crlf, to: configURL)

        XCTAssertEqual(
            AgentHooksInstaller.codexTrust(configURL: configURL, hooksURL: hooksURL), .trusted,
            "neither the CR nor the short trailing comment should prevent the header from being read"
        )
    }

    // MARK: - Two of our own entries at different indices in one file

    func testTwoEntriesAtDifferentIndicesAreJudgedIndependently() throws {
        // `pre_tool_use` sits at index 1 (the rtk entry owns 0) while every other
        // event sits at index 0. Trust one of each and withhold the other, and
        // confirm the two distinct keys are not confused with one another.
        try installedIntoRtkHooks()
        let text = trustTables(hooksPath: hooksURL.path, body: { _ in Self.hash }, skipping: ["pre_tool_use"])
        try write(text, to: configURL)

        XCTAssertEqual(
            AgentHooksInstaller.codexTrust(configURL: configURL, hooksURL: hooksURL),
            .awaitingTrust(untrusted: ["PreToolUse"]),
            "index 1's table is the only one missing; index 0's tables for every other event must still read as trusted"
        )
    }

    // MARK: - `codexTrustKey` returns the raw path, unescaped

    func testCodexTrustKeyReturnsThePathVerbatimEvenWithTOMLSpecialCharacters() {
        let odd = #"/Users/me/qu"ote\back.json"#
        let key = AgentHooksInstaller.codexTrustKey(
            hooksPath: odd, event: "PreToolUse", entryIndex: 1, hookIndex: 0
        )
        XCTAssertEqual(
            key, "\(odd):pre_tool_use:1:0",
            "the key is built from the raw path; escaping (if any) happens only on the header side, at comparison time"
        )
    }
}
