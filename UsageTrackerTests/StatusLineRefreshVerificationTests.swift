import XCTest
@testable import Omelette

/// Independent verification of package M2 (2026-09-10-statusline-refresh-design.md):
/// the status-line installer writes `refreshInterval: 60`, an entry of ours that lacks
/// it (or carries a foreign value) offers Update rather than a new state, a foreign
/// command is still never touched, and the docs/preview agree with what install writes.
///
/// New file, independent of `StatusLineInstallerTests` / `CommandLineSettingsTextTests`:
/// derives cases from the spec and the diff rather than trusting the executor's own
/// tests. Production code and the executor's tests are not modified.
final class StatusLineRefreshVerificationTests: XCTestCase {
    private var root: URL!
    private let cli = "/Users/tester/Library/Application Support/UsageTracker/bin/omelette"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatusLineRefreshVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var settingsURL: URL { root.appendingPathComponent("settings.json") }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    private func json(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])
    }

    private var status: HookInstallStatus {
        StatusLineInstaller.status(settingsURL: settingsURL, cliPath: cli)
    }

    // MARK: - Update rewrites only the statusLine object

    /// Spec: "rewrites only the `statusLine` object (backup as before)". A settings.json
    /// with a `hooks`, `model` and `permissions` block of Claude Code's own, plus our
    /// (stale) statusLine, must come out the other side of Update with every one of
    /// those three keys byte-for-byte identical — not "roughly the same", the same
    /// canonical JSON — and the backup must hold the exact bytes from before the write.
    func testUpdatePreservesEveryOtherTopLevelKeyExactly() throws {
        let before = #"""
        {"model":"opus","permissions":{"allow":["Bash(git *)"],"deny":[]},"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"'/opt/theirs/notify'","async":true}]}]},"statusLine":{"type":"command","command":"'\#(cli)' statusline"}}
        """#
        try write(before, to: settingsURL)
        let beforeParsed = try json(at: settingsURL)
        let modelBefore = beforeParsed["model"]
        let permissionsBefore = SettingsFile.canonicalJSON(try XCTUnwrap(beforeParsed["permissions"] as? [String: Any]))
        let hooksBefore = SettingsFile.canonicalJSON(try XCTUnwrap(beforeParsed["hooks"] as? [String: Any]))

        XCTAssertEqual(status, .outdated)
        try StatusLineInstaller.install(settingsURL: settingsURL, cliPath: cli)
        XCTAssertEqual(status, .installed)

        let after = try json(at: settingsURL)
        XCTAssertEqual(after["model"] as? String, modelBefore as? String)
        XCTAssertEqual(
            SettingsFile.canonicalJSON(try XCTUnwrap(after["permissions"] as? [String: Any])),
            permissionsBefore
        )
        XCTAssertEqual(
            SettingsFile.canonicalJSON(try XCTUnwrap(after["hooks"] as? [String: Any])),
            hooksBefore
        )
        // Only the statusLine key may differ between before and after.
        var afterWithoutStatusLine = after
        afterWithoutStatusLine.removeValue(forKey: "statusLine")
        var beforeWithoutStatusLine = beforeParsed
        beforeWithoutStatusLine.removeValue(forKey: "statusLine")
        XCTAssertEqual(
            SettingsFile.canonicalJSON(afterWithoutStatusLine),
            SettingsFile.canonicalJSON(beforeWithoutStatusLine),
            "every key other than statusLine is untouched by Update"
        )

        let backup = SettingsFile.backupURL(for: settingsURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertEqual(
            String(decoding: try Data(contentsOf: backup), as: UTF8.self),
            before,
            "the backup is the file exactly as it was before Update, not reformatted"
        )
    }

    // MARK: - needsUpdate on odd interval shapes

    /// The plan pins this shape by name: an interval written as the JSON string "60" is
    /// not the JSON number 60, so it needs an update. `as? Int` on a `String` is nil.
    func testAStringSixtyIsNotTheSameAsTheNumberAndNeedsAnUpdate() {
        let entry: [String: Any] = [
            "type": "command",
            "command": StatusLineInstaller.command(cliPath: cli),
            "refreshInterval": "60",
        ]
        XCTAssertTrue(StatusLineInstaller.needsUpdate(existing: entry))
    }

    func testAStringSixtyInTheFileReadsAsOutdatedNotInstalled() throws {
        try write(
            #"{"statusLine":{"type":"command","command":"'\#(cli)' statusline","refreshInterval":"60"}}"#,
            to: settingsURL
        )
        XCTAssertEqual(status, .outdated)
    }

    /// A negative interval is not 60 either way it could be misread (as "faster than
    /// ours" or as a sentinel) — it is simply not the value this build writes.
    func testANegativeIntervalNeedsAnUpdate() {
        let entry: [String: Any] = [
            "type": "command",
            "command": StatusLineInstaller.command(cliPath: cli),
            "refreshInterval": -1,
        ]
        XCTAssertTrue(StatusLineInstaller.needsUpdate(existing: entry))
    }

    func testAZeroIntervalNeedsAnUpdate() {
        let entry: [String: Any] = [
            "type": "command",
            "command": StatusLineInstaller.command(cliPath: cli),
            "refreshInterval": 0,
        ]
        XCTAssertTrue(StatusLineInstaller.needsUpdate(existing: entry))
    }

    func testAZeroIntervalInTheFileReadsAsOutdatedAndInstallFixesIt() throws {
        try write(
            #"{"statusLine":{"type":"command","command":"'\#(cli)' statusline","refreshInterval":0}}"#,
            to: settingsURL
        )
        XCTAssertEqual(status, .outdated)

        try StatusLineInstaller.install(settingsURL: settingsURL, cliPath: cli)

        XCTAssertEqual(status, .installed)
        XCTAssertEqual(try (json(at: settingsURL)["statusLine"] as? [String: Any])?["refreshInterval"] as? Int, 60)
    }

    // MARK: - A statusLine that is not an object

    /// Spec / rulings: an unreadable statusLine is a conflict (a refusal to overwrite),
    /// never a crash. Covers shapes beyond the executor's own string case: an array,
    /// a bare number and a bare bool sitting where the object should be.
    func testNonObjectStatusLineShapesAreConflictsNeverCrashes() throws {
        let shapes = [
            #"{"statusLine":["not","an","object"]}"#,
            #"{"statusLine":42}"#,
            #"{"statusLine":true}"#,
            #"{"statusLine":null}"#,
        ]
        for shape in shapes {
            try write(shape, to: settingsURL)
            let result = status
            if case .conflict = result {
                // expected: unreadable, refused
            } else {
                XCTFail("\(shape) -> \(result), expected .conflict")
            }
            XCTAssertThrowsError(try StatusLineInstaller.install(settingsURL: settingsURL, cliPath: cli), shape)
        }
    }

    /// `"statusLine": null` is JSON's way of saying "no value" — `file["statusLine"]`
    /// still returns `Optional(NSNull())`, which is not nil at the dictionary level, so
    /// this is a real edge distinct from the key being entirely absent.
    func testStatusLineExplicitlyNullIsARefusalNotTreatedAsAbsent() throws {
        try write(#"{"statusLine":null}"#, to: settingsURL)
        XCTAssertNotEqual(status, .notInstalled, "an explicit null is not the same as no key at all")
    }

    // MARK: - status() on files that do not exist, are empty, or are invalid

    func testStatusOnAMissingFileIsNotInstalled() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsURL.path))
        XCTAssertEqual(status, .notInstalled)
    }

    func testStatusOnAnEmptyFileIsNotInstalled() throws {
        try write("", to: settingsURL)
        XCTAssertEqual(status, .notInstalled)
    }

    func testStatusOnBlankWhitespaceIsNotInstalled() throws {
        try write("   \n\t \n", to: settingsURL)
        XCTAssertEqual(status, .notInstalled)
    }

    func testStatusOnInvalidJSONIsAConflictWithTheSharedUnparsableReason() throws {
        try write("{ this is not json", to: settingsURL)
        XCTAssertEqual(status, .conflict(AgentHooksInstaller.unparsableReason))
    }

    // MARK: - Fresh install adds exactly the three keys and nothing else

    func testInstallIntoAFileWithNoStatusLineAtAllAddsOnlyTheThreeKeys() throws {
        try write(#"{"model":"opus","permissions":{"allow":[]}}"#, to: settingsURL)

        try StatusLineInstaller.install(settingsURL: settingsURL, cliPath: cli)

        let file = try json(at: settingsURL)
        XCTAssertEqual(file.keys.sorted(), ["model", "permissions", "statusLine"])
        let entry = try XCTUnwrap(file["statusLine"] as? [String: Any])
        XCTAssertEqual(entry.keys.sorted(), ["command", "refreshInterval", "type"])
        XCTAssertEqual(file["model"] as? String, "opus")
    }

    // MARK: - A foreign command that happens to carry refreshInterval: 60

    /// Ownership is decided before the interval is even looked at (`isOurs` gates the
    /// function before `needsUpdate` runs) — a command that is not ours is a conflict
    /// no matter what its refreshInterval says, including the exact value we write.
    func testAForeignCommandWithOurExactIntervalIsStillAConflict() throws {
        try write(
            #"{"statusLine":{"type":"command","command":"bash \"$HOME/.claude/statusline-command.sh\"","refreshInterval":60}}"#,
            to: settingsURL
        )

        XCTAssertEqual(status, .conflict("bash \"$HOME/.claude/statusline-command.sh\""))
        XCTAssertThrowsError(try StatusLineInstaller.install(settingsURL: settingsURL, cliPath: cli)) {
            XCTAssertEqual($0 as? StatusLineInstaller.Error, .conflict("bash \"$HOME/.claude/statusline-command.sh\""))
        }
        XCTAssertEqual(
            try (json(at: settingsURL)["statusLine"] as? [String: Any])?["refreshInterval"] as? Int, 60,
            "their line, interval and all, is untouched"
        )
    }

    // MARK: - Docs and preview agree with what install writes, and the constant is one source

    /// The test host's working directory is "/", not the repo (`#file` and
    /// `FileManager.currentDirectoryPath` both verified empty of anything useful), so
    /// README.md is found by walking up from the test bundle's own location — which
    /// lives under `build/DerivedData` inside the repo — until a directory containing
    /// it turns up. No `/Users/<name>` path is hardcoded to do it.
    private func findRepoRoot() throws -> URL {
        var candidate = Bundle(for: Self.self).bundleURL
        for _ in 0..<25 {
            candidate = candidate.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("README.md").path) {
                return candidate
            }
        }
        throw XCTSkip("could not locate the repo root by walking up from the test bundle")
    }

    func testReadmeSnippetContainsTheExactRefreshIntervalLine() throws {
        let readmeURL = try findRepoRoot().appendingPathComponent("README.md")
        let readme = try String(contentsOf: readmeURL, encoding: .utf8)
        XCTAssertTrue(readme.contains("\"refreshInterval\": 60"), "README snippet must show the literal we write")
    }

    /// The caption is the only other place the number is spelled out for a human. Both
    /// it and the README must agree with `StatusLineInstaller.refreshInterval`, so a
    /// change to the constant cannot silently leave the copy saying something else.
    func testCaptionRefreshIntervalMatchesTheInstallerConstant() {
        let caption = CommandLineSettingsText.statusLineCaption
        XCTAssertTrue(
            caption.contains("\"refreshInterval\": \(StatusLineInstaller.refreshInterval)"),
            caption
        )
    }

    func testThePreviewEqualsWhatInstallActuallyWrites() throws {
        try StatusLineInstaller.install(settingsURL: settingsURL, cliPath: cli)
        let written = try XCTUnwrap(json(at: settingsURL)["statusLine"] as? [String: Any])

        let preview = StatusLineInstaller.previewJSON(cliPath: cli)
        let previewedEntry = try XCTUnwrap(
            (JSONSerialization.jsonObject(with: Data(preview.utf8)) as? [String: Any])?["statusLine"] as? [String: Any]
        )

        XCTAssertEqual(SettingsFile.canonicalJSON(written), SettingsFile.canonicalJSON(previewedEntry))
    }

    // MARK: - desiredEntry quoting of an awkward path

    /// A path with both a space (so it needs quoting at all) and an apostrophe (so the
    /// quoting has to escape something inside the quotes) — the two hard cases at once.
    /// `desiredEntry`'s command has to be exactly what `command(cliPath:)` produces, and
    /// running it through a real shell has to recover the original path.
    func testDesiredEntryQuotesASpaceAndAnApostropheCorrectly() throws {
        let awkward = "/Users/o'brien/My Folder/omelette"
        let entry = StatusLineInstaller.desiredEntry(commandPath: awkward)
        let command = try XCTUnwrap(entry["command"] as? String)

        XCTAssertEqual(command, StatusLineInstaller.command(cliPath: awkward))
        XCTAssertEqual(command, "'/Users/o'\\''brien/My Folder/omelette' statusline")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf '%s %s' \(command)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(output, awkward + " statusline")
    }
}
