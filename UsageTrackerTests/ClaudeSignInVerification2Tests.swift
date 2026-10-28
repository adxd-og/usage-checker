import Security
import XCTest
@testable import Omelette

/// Tester's cases for spec 2026-10-25 (Claude switch and sign-in) § Design › Package 2, second
/// file: the terminal Omelette starts Claude Code on, the transcript cleaner's reach, the
/// gate's edges, the binary rule's odd folders, the legacy-item rule's whole table, the passive
/// scanner's ignore list and the hook helper's mark. Folders are temp dirs; no real `claude`,
/// keychain, `~/.claude` or Terminal.
final class ClaudeSignInVerification2Tests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeSignInVerification2Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - The terminal

    private func script(_ text: String) throws -> URL {
        let folder = directory.appendingPathComponent("Application Support/stand in", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let binary = folder.appendingPathComponent("claude")
        try text.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return binary
    }

    private func isRunning(pidFile: URL) throws -> Bool {
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        return kill(pid, 0) == 0
    }

    func testAWholeAndASplitCursorQueryEachGetOneReplyAndNothingElseIsTyped() async throws {
        let binary = try script("""
        #!/bin/sh
        here="$(/usr/bin/dirname "$0")"
        /bin/stty raw -echo
        printf '\\033[6n'
        /bin/sleep 0.4
        printf '\\033['
        /bin/sleep 0.4
        printf '6n'
        exec /bin/cat > "$here/seen-typed"

        """)

        try await ClaudePTYStart.run(
            binary: binary.path, arguments: [], environment: ["PATH": "/usr/bin:/bin"],
            directory: directory, duration: 2.5, grace: 1
        )

        let typed = try Data(contentsOf: binary.deletingLastPathComponent().appendingPathComponent("seen-typed"))
        XCTAssertEqual(typed, ClaudePTYStart.cursorReply + ClaudePTYStart.cursorReply)
    }

    func testAProgramThatIgnoresTheStopIsKilledAfterTheGraceWhileFloodingItsTerminal() async throws {
        let binary = try script("""
        #!/bin/sh
        here="$(/usr/bin/dirname "$0")"
        echo $$ > "$here/pid"
        trap '' TERM
        while :; do echo xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx; done

        """)
        let started = Date()

        try await ClaudePTYStart.run(
            binary: binary.path, arguments: [], environment: ["PATH": "/usr/bin:/bin"],
            directory: directory, duration: 0.6, grace: 0.6
        )

        XCTAssertLessThan(Date().timeIntervalSince(started), 6, "the run must not hang in the exit of a flooded terminal")
        XCTAssertFalse(try isRunning(pidFile: binary.deletingLastPathComponent().appendingPathComponent("pid")))
    }

    func testACancelledPollStopsClaudeCodeAtOnce() async throws {
        let binary = try script("""
        #!/bin/sh
        here="$(/usr/bin/dirname "$0")"
        echo $$ > "$here/pid"
        exec /bin/sleep 60

        """)
        let started = Date()
        let path = binary.path
        let folder = directory!
        let task = Task {
            try await ClaudePTYStart.run(
                binary: path, arguments: [], environment: ["PATH": "/usr/bin:/bin"],
                directory: folder, duration: 60, grace: 1
            )
        }
        try await Task.sleep(nanoseconds: 700_000_000)
        task.cancel()
        try await task.value

        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
        XCTAssertFalse(try isRunning(pidFile: binary.deletingLastPathComponent().appendingPathComponent("pid")))
    }

    // MARK: - The transcript cleaner's reach

    private var claude: URL { directory.appendingPathComponent(".claude", isDirectory: true) }
    private var probe: URL { directory.appendingPathComponent("UsageTracker/ClaudeRenewal", isDirectory: true) }

    private func project(for folder: URL) -> URL {
        claude.appendingPathComponent("projects/\(ClaudeRenewalProbe.projectDirectoryName(for: folder))", isDirectory: true)
    }

    @discardableResult
    private func file(_ name: String, in folder: URL, text: String = "{}\n") throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    func testASiblingProjectWithASimilarNameIsNotTouched() throws {
        let mine = try file("5b0f3a52-8c1d-4e6f-9a7b-1c2d3e4f5a6b.jsonl", in: project(for: probe))
        let neighbours = [
            directory.appendingPathComponent("UsageTracker/ClaudeRenewal2", isDirectory: true),
            directory.appendingPathComponent("UsageTracker/ClaudeRenewal-old", isDirectory: true),
            directory.appendingPathComponent("UsageTracker/ClaudeRenewal/nested", isDirectory: true),
            directory.appendingPathComponent("UsageTracker", isDirectory: true),
        ]
        let theirs = try neighbours.map { try file("a.jsonl", in: project(for: $0)) }

        let removed = ClaudeRenewalProbe.removeTranscripts(probeDirectory: probe, claudeRoot: claude)

        XCTAssertEqual(removed.map(\.lastPathComponent), [mine.lastPathComponent])
        XCTAssertFalse(FileManager.default.fileExists(atPath: mine.path))
        for (neighbour, url) in zip(neighbours, theirs) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(neighbour.path) lost its transcript")
        }
    }

    func testOnlyRegularJsonlFilesInTheProbesFolderGoAndASymlinkReachesNothingOutside() throws {
        let folder = project(for: probe)
        let outside = try file("precious.jsonl", in: directory.appendingPathComponent("outside", isDirectory: true))
        let transcript = try file("a.jsonl", in: folder)
        let notes = try file("notes.txt", in: folder)
        let nested = try file("agent-1.jsonl", in: folder.appendingPathComponent("subagents", isDirectory: true))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("dir.jsonl"), withIntermediateDirectories: true)
        let insideDirectory = try file("keep.txt", in: folder.appendingPathComponent("dir.jsonl", isDirectory: true))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link.jsonl"), withDestinationURL: outside)

        ClaudeRenewalProbe.removeTranscripts(probeDirectory: probe, claudeRoot: claude)

        XCTAssertFalse(FileManager.default.fileExists(atPath: transcript.path))
        for kept in [outside, notes, nested, insideDirectory] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path), "\(kept.lastPathComponent) was removed")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), "a folder that still holds something stays")
    }

    func testNoClaudeFolderAtAllIsNothingToClean() {
        XCTAssertEqual(ClaudeRenewalProbe.removeTranscripts(probeDirectory: probe, claudeRoot: claude), [])
    }

    func testARenewalLeavesTheSessionIDFileAndEveryOtherProjectAlone() async throws {
        let other = try file("keep.jsonl", in: project(for: directory.appendingPathComponent("UsageTracker/Other", isDirectory: true)))
        let writtenByStart = project(for: probe)

        await ClaudeRenewalProbe.renew(
            binary: "/opt/test/claude", directory: probe, claudeRoot: claude, environment: [:]
        ) { _, _, _, _ in
            try? FileManager.default.createDirectory(at: writtenByStart, withIntermediateDirectories: true)
            try? Data("{}\n".utf8).write(to: writtenByStart.appendingPathComponent("x.jsonl"))
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: writtenByStart.path))
        XCTAssertNotNil(ClaudeRenewalProbe.storedSessionID(in: probe), "the id file stays: the scanner ignores that session by it")
    }

    // MARK: - The gate's edges

    private let t0 = Date(timeIntervalSince1970: 1_793_100_000)

    func testAnotherClickReArmsTheTenMinutes() async {
        let gate = ClaudeRenewalGate()
        await gate.signInLaunched(at: t0)
        await gate.signInLaunched(at: t0.addingTimeInterval(500))

        let at700 = await gate.admission(now: t0.addingTimeInterval(700))
        let at1099 = await gate.admission(now: t0.addingTimeInterval(1099))
        let at1100 = await gate.admission(now: t0.addingTimeInterval(1100))

        XCTAssertEqual(at700, .signInPending)
        XCTAssertEqual(at1099, .signInPending)
        XCTAssertEqual(at1100, .run)
    }

    func testTheCooldownCountedFromAnEarlierAttemptEndsWithThePendingSignIn() async {
        let gate = ClaudeRenewalGate()
        _ = await gate.attempt(now: t0) { nil }
        await gate.signInLaunched(at: t0.addingTimeInterval(10))

        let at609 = await gate.admission(now: t0.addingTimeInterval(609))
        let at610 = await gate.admission(now: t0.addingTimeInterval(610))

        XCTAssertEqual(at609, .signInPending)
        XCTAssertEqual(at610, .run, "the sign-in window is over and the last attempt is 610 s old")
    }

    func testNeitherAGoodReadingNorAClosedTerminalForgetsAnAttempt() async {
        let gate = ClaudeRenewalGate()
        _ = await gate.attempt(now: t0) { nil }
        await gate.signInLaunched(at: t0.addingTimeInterval(10))
        await gate.tokenArrived()
        let afterToken = await gate.admission(now: t0.addingTimeInterval(100))
        await gate.signInLaunched(at: t0.addingTimeInterval(110))
        await gate.signInDidNotOpen()
        let afterFailedOpen = await gate.admission(now: t0.addingTimeInterval(120))

        XCTAssertEqual(afterToken, .coolingDown)
        XCTAssertEqual(afterFailedOpen, .coolingDown)
    }

    func testTheRuleAtItsEdges() {
        func admission(_ attemptAgo: TimeInterval?, _ signInAgo: TimeInterval?) -> ClaudeRenewalGate.Admission {
            ClaudeRenewalGate.admission(
                now: t0, lastAttemptAt: attemptAgo.map { t0.addingTimeInterval(-$0) },
                signInLaunchedAt: signInAgo.map { t0.addingTimeInterval(-$0) }
            )
        }
        XCTAssertEqual(admission(299.9, nil), .coolingDown)
        XCTAssertEqual(admission(300, nil), .run)
        XCTAssertEqual(admission(nil, 599.9), .signInPending)
        XCTAssertEqual(admission(nil, 600), .run)
        XCTAssertEqual(admission(1000, 599.9), .signInPending)
        XCTAssertEqual(admission(299.9, 600), .coolingDown, "a finished sign-in window leaves the cooldown standing")
        XCTAssertEqual(admission(nil, nil), .run)
    }

    // MARK: - The binary rule's odd folders

    private var appSupport: URL { directory.appendingPathComponent("Application Support", isDirectory: true) }

    @discardableResult
    private func bundled(version: String, hash: String, modified: Date, executable: Bool = true) throws -> String {
        let folder = appSupport.appendingPathComponent("Claude/claude-code/\(version)/\(hash)/claude.app/Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let binary = folder.appendingPathComponent("claude")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
        try FileManager.default.setAttributes(
            [.posixPermissions: executable ? 0o755 : 0o644, .modificationDate: modified], ofItemAtPath: binary.path
        )
        return binary.path
    }

    private let earlier = Date(timeIntervalSince1970: 1_793_000_000)
    private let later = Date(timeIntervalSince1970: 1_793_100_000)

    func testAFolderThatIsNotAVersionNeverBeatsOneThatIs() throws {
        let numbered = try bundled(version: "2.0.0", hash: "h", modified: earlier)
        try bundled(version: "latest", hash: "h", modified: later)
        XCTAssertEqual(ClaudeBinaryLocator.newestBundled(applicationSupport: appSupport), numbered)
    }

    func testStrayFilesAndBareHashFoldersAreSkipped() throws {
        let usable = try bundled(version: "2.1.300", hash: "usable", modified: earlier)
        let root = appSupport.appendingPathComponent("Claude/claude-code", isDirectory: true)
        try Data().write(to: root.appendingPathComponent(".DS_Store"))
        try Data().write(to: root.appendingPathComponent("2.1.300/.DS_Store"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("9.9.9/no-app-inside", isDirectory: true), withIntermediateDirectories: true
        )
        XCTAssertEqual(ClaudeBinaryLocator.newestBundled(applicationSupport: appSupport), usable)
    }

    func testWithinOneVersionANewerCopyThatCannotRunLosesToAnOlderOneThatCan() throws {
        let runnable = try bundled(version: "2.1.308", hash: "old", modified: earlier)
        try bundled(version: "2.1.308", hash: "new", modified: later, executable: false)
        XCTAssertEqual(ClaudeBinaryLocator.newestBundled(applicationSupport: appSupport), runnable)
    }

    func testNoClaudeCodeFolderIsNoBinary() {
        XCTAssertNil(ClaudeBinaryLocator.newestBundled(applicationSupport: appSupport))
    }

    // MARK: - The legacy item rule, the whole table

    func testTheLegacyRuleAcrossEveryInput() {
        let statuses: [OSStatus] = [errSecSuccess, errSecItemNotFound, errSecAuthFailed, errSecInteractionNotAllowed,
                                    errSecUserCanceled, errSecDuplicateItem, -1]
        for alreadyDone in [true, false] {
            for unlocked in [true, false] {
                for status in statuses {
                    var deletes = 0
                    let result = ClaudeCredentialsCache.removeLegacyItem(
                        alreadyDone: alreadyDone, keychainUnlocked: unlocked
                    ) { deletes += 1; return status }
                    let label = "done \(alreadyDone) unlocked \(unlocked) status \(status)"
                    XCTAssertEqual(deletes, !alreadyDone && unlocked ? 1 : 0, label)
                    if alreadyDone {
                        XCTAssertEqual(result, .alreadyDone, label)
                    } else if !unlocked {
                        XCTAssertEqual(result, .deferred, label)
                    } else if status == errSecSuccess || status == errSecItemNotFound {
                        XCTAssertEqual(result, .done, label)
                    } else {
                        XCTAssertEqual(result, .failed(status), label)
                    }
                }
            }
        }
    }

    // MARK: - The passive scanner's ignore list

    private let renewalID = "5b0f3a52-8c1d-4e6f-9a7b-1c2d3e4f5a6b"
    private let otherID = "37384099-5d4f-423d-ae8b-0eb0c3308aae"
    private let codexID = "019fd6d6-94a9-7611-a007-3c094955e537"
    private let scanNow = Date(timeIntervalSince1970: 1_800_000_000)

    private func transcript(_ id: String, cwd: String) -> String {
        """
        {"type":"mode","sessionId":"\(id)"}
        {"type":"user","sessionId":"\(id)","cwd":"\(cwd)","uuid":"a1"}

        """
    }

    private func scanTree(ignoring: Set<String>) throws -> [AgentSession] {
        let claudeRoot = directory.appendingPathComponent("claude-projects", isDirectory: true)
        let codexRoot = directory.appendingPathComponent("codex-sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        func put(_ text: String, _ path: URL) throws {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: scanNow.addingTimeInterval(-5)], ofItemAtPath: path.path)
        }
        let slug = claudeRoot.appendingPathComponent("-Users-tester-Projects-alpha", isDirectory: true)
        try put(transcript(renewalID, cwd: "/Users/tester/Projects/alpha"), slug.appendingPathComponent("\(renewalID).jsonl"))
        try put(transcript(otherID, cwd: "/Users/tester/Projects/alpha"), slug.appendingPathComponent("\(otherID).jsonl"))
        let components = Calendar.current.dateComponents([.year, .month, .day], from: scanNow.addingTimeInterval(-5))
        let partition = String(format: "%04d/%02d/%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
        try put(
            """
            {"timestamp":"2026-08-06T11:30:14.849Z","type":"session_meta","payload":{"session_id":"\(codexID)","id":"\(codexID)","cwd":"/Users/tester/Projects/beta","originator":"Codex Desktop"}}

            """,
            codexRoot.appendingPathComponent("\(partition)/rollout-2026-08-06T11-30-14-\(codexID).jsonl")
        )
        return PassiveSessionScanner.scan(
            claudeProjects: claudeRoot, codexSessions: codexRoot, now: scanNow, ignoringClaudeSessions: ignoring
        )
    }

    func testTheIgnoreListHidesExactlyTheNamedClaudeSessions() throws {
        XCTAssertEqual(try scanTree(ignoring: []).map(\.sessionID).sorted(), [codexID, otherID, renewalID].sorted(), "control: all three show")
        XCTAssertEqual(try scanTree(ignoring: [renewalID]).map(\.sessionID).sorted(), [codexID, otherID].sorted(),
                       "another session in the same project folder stays")
        let almost = String(renewalID.dropLast()) + "c"
        XCTAssertEqual(try scanTree(ignoring: [almost]).count, 3, "an id that differs in one character hides nothing")
        XCTAssertTrue(try scanTree(ignoring: [codexID]).map(\.sessionID).contains(codexID), "the list names Claude sessions only")
    }

    // MARK: - The hook helper's mark

    func testOnlyTheValueOneIsARenewal() {
        let key = ClaudeRenewalMarker.environmentKey
        XCTAssertTrue(ClaudeRenewalMarker.isRenewal(environment: [key: "1"]))
        for value in ["", "0", "true", "yes", " 1", "1 ", "01", "11", "1\n"] {
            XCTAssertFalse(ClaudeRenewalMarker.isRenewal(environment: [key: value]), value.debugDescription)
        }
        XCTAssertFalse(ClaudeRenewalMarker.isRenewal(environment: [:]))
        XCTAssertFalse(ClaudeRenewalMarker.isRenewal(environment: [key.lowercased(): "1"]))
    }

    func testTheHelperOfARenewalStartStillReadsItsPayloadBeforeItExits() throws {
        // Claude Code writes the hook payload into the helper's stdin. A helper that exited
        // before reading would hand it a closed pipe. The payload comes late here, after the
        // helper has had every chance to leave.
        let previous = signal(SIGPIPE, SIG_IGN)
        defer { signal(SIGPIPE, previous) }
        let process = Process()
        process.executableURL = AgentPaths.bundledHelperURL
        process.arguments = []
        process.environment = ["PATH": "/usr/bin:/bin", ClaudeRenewalMarker.environmentKey: ClaudeRenewalMarker.value]
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        try stdin.fileHandleForReading.close()   // the helper holds the only read end now
        Thread.sleep(forTimeInterval: 0.5)

        let payload = Array(#"{"hook_event_name":"SessionStart","session_id":"sess-1","cwd":"/tmp"}"#.utf8)
        let written = payload.withUnsafeBufferPointer { write(stdin.fileHandleForWriting.fileDescriptor, $0.baseAddress, $0.count) }
        let writeError = errno
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()

        XCTAssertEqual(written, payload.count, "the helper had left: write failed with errno \(writeError)")
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
