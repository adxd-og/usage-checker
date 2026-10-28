import XCTest
@testable import Omelette

/// Verification of the 3.3.0 review fixes (plan 2026-10-28-release-3.3.0-review-fixes, Tasks 2-6,
/// and the session ruling that a refused direct read plus a `security` read that found no sign-in
/// answers "absent"). Spec 2026-10-25 § Package 2: Omelette never obtains a Claude token itself;
/// renewal is starting Claude Code. Real `/bin/sh` stand-ins in temp dirs, an injected registry per
/// test, fake credential sources; nothing touches the keychain, `~/.claude` or Application Support.

// MARK: - Usage endpoint stub

private final class VerificationEndpointStub: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var liveTokens: Set<String> = []
    nonisolated(unsafe) private static var asked: [String] = []

    static func reset(live: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        liveTokens = live
        asked = []
    }

    static var tokensAsked: [String] {
        lock.lock(); defer { lock.unlock() }
        return asked
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url ?? ClaudeOAuthProvider.usageURL
        let token = (request.value(forHTTPHeaderField: "Authorization") ?? "")
            .replacingOccurrences(of: "Bearer ", with: "")
        Self.lock.lock()
        Self.asked.append(token)
        let live = Self.liveTokens.contains(token)
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: url, statusCode: live ? 200 : 401, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = live ? #"{"five_hour":{"utilization":7.0,"resets_at":"2026-10-04T12:49:59+00:00"}}"# : "{}"
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Claude Code's item over time: the n-th read answers `reads[min(n, last)]`; a start of Claude
/// Code is recorded and, when `renewsTo` is set, replaces what the item holds from then on.
private final class ScriptedClaudeCode: @unchecked Sendable {
    private let lock = NSLock()
    private var reads: [ClaudeSourceRead]
    private var itemReads = 0
    private var startCount = 0
    private let renewsTo: ClaudeCredentials.OAuth?

    init(reads: [ClaudeSourceRead], renewsTo: ClaudeCredentials.OAuth? = nil) {
        self.reads = reads
        self.renewsTo = renewsTo
    }

    var starts: Int { lock.lock(); defer { lock.unlock() }; return startCount }

    private func current() -> ClaudeSourceRead {
        let index = min(itemReads, reads.count - 1)
        itemReads += 1
        return reads[index]
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        startCount += 1
        if let renewsTo { reads = [.found(renewsTo)] }
    }

    var sources: ClaudeCredentialSources {
        ClaudeCredentialSources(
            file: { nil },
            item: { self.lock.lock(); defer { self.lock.unlock() }; return self.current() },
            itemViaSecurityTool: { self.lock.lock(); defer { self.lock.unlock() }; return self.current() },
            keychainUnlocked: { true }
        )
    }
}

final class ReleaseFixes330VerificationTests: XCTestCase {
    private var directory: URL!
    private let now = Date(timeIntervalSince1970: 1_793_100_000)
    private var nowMS: Double { now.timeIntervalSince1970 * 1000 }
    private let binary = "/Users/tester/claude"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReleaseFixes330VerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        VerificationEndpointStub.reset(live: ["fresh"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Helpers

    private func oauth(_ token: String, expiresAt: Double) -> ClaudeCredentials.OAuth {
        let json = """
        {"claudeAiOauth":{"accessToken":"\(token)","refreshToken":"r","expiresAt":\(expiresAt),
         "scopes":["user:inference"],"subscriptionType":"max","rateLimitTier":"default_max_20x"}}
        """
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(ClaudeCredentials.self, from: Data(json.utf8)).claudeAiOauth
    }

    private var fresh: ClaudeCredentials.OAuth { oauth("fresh", expiresAt: nowMS + 8 * 3_600_000) }

    private func provider(
        _ claudeCode: ScriptedClaudeCode, gate: ClaudeRenewalGate = ClaudeRenewalGate(), at date: Date? = nil,
        cache: ClaudeCredentialsCache = ClaudeCredentialsCache()
    ) -> ClaudeOAuthProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VerificationEndpointStub.self]
        let at = date ?? now
        let bin = binary
        return ClaudeOAuthProvider(
            http: HTTPClient(session: URLSession(configuration: configuration)),
            cache: cache,
            sources: claudeCode.sources,
            renewal: ClaudeRenewal(gate: gate, locateBinary: { bin }, start: { _ in claudeCode.start() }),
            now: { at }
        )
    }

    private func script(_ body: String) throws -> URL {
        let file = directory.appendingPathComponent("standin-\(UUID().uuidString).sh")
        try body.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }

    private func processIsGone(pidFile: URL) async -> Bool {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        let end = Date().addingTimeInterval(3)
        repeat {
            if kill(pid, 0) != 0 { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        } while Date() < end
        return kill(pid, 0) != 0
    }

    private func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        } while Date() < end
        return condition()
    }

    // MARK: - Task 2: the renewal start is registered on every path and leaves on every path

    func testALaunchFailureLeavesNothingRegistered() async throws {
        let notRunnable = directory.appendingPathComponent("not-executable")
        try "#!/bin/sh\nexit 0\n".write(to: notRunnable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: notRunnable.path)
        let registry = ChildProcessRegistry()

        do {
            try await ClaudePTYStart.run(
                binary: notRunnable.path, arguments: [], environment: ["PATH": "/usr/bin:/bin"],
                directory: directory, duration: 1, grace: 1, registry: registry
            )
            XCTFail("a file that cannot run did not throw")
        } catch let failure as ClaudePTYStart.Failure {
            guard case .launch = failure else { return XCTFail("\(failure)") }
        }
        XCTAssertEqual(registry.runningCount, 0, "a start that never ran is not left in the registry")

        // The registry is still open: a later start in it works.
        let fine = try script("#!/bin/sh\nexit 0\n")
        try await ClaudePTYStart.run(
            binary: fine.path, arguments: [], environment: ["PATH": "/usr/bin:/bin"],
            directory: directory, duration: 5, grace: 1, registry: registry
        )
        XCTAssertEqual(registry.runningCount, 0)
    }

    func testAProgramThatExitsByItselfLeavesTheRegistry() async throws {
        let registry = ChildProcessRegistry()
        let fine = try script("#!/bin/sh\nexit 0\n")
        try await ClaudePTYStart.run(
            binary: fine.path, arguments: [], environment: ["PATH": "/usr/bin:/bin"],
            directory: directory, duration: 5, grace: 1, registry: registry
        )
        XCTAssertEqual(registry.runningCount, 0)
    }

    func testTheDurationRunningOutStopsTheProgramAndLeavesTheRegistry() async throws {
        let registry = ChildProcessRegistry()
        let pidFile = directory.appendingPathComponent("pid")
        let long = try script("#!/bin/sh\necho $$ > '\(pidFile.path)'\nexec /bin/sleep 60\n")
        let started = Date()

        try await ClaudePTYStart.run(
            binary: long.path, arguments: [], environment: ["PATH": "/usr/bin:/bin"],
            directory: directory, duration: 0.6, grace: 1, registry: registry
        )

        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(registry.runningCount, 0)
        let gone = await processIsGone(pidFile: pidFile)
        XCTAssertTrue(gone, "the program was stopped, not left running")
    }

    func testCancellingTheTaskStopsTheProgramAtOnceAndLeavesTheRegistry() async throws {
        let registry = ChildProcessRegistry()
        let pidFile = directory.appendingPathComponent("pid")
        let long = try script("#!/bin/sh\necho $$ > '\(pidFile.path)'\nexec /bin/sleep 60\n")
        let folder = directory!
        let returned = expectation(description: "the start came back after the cancel")
        let task = Task.detached {
            try? await ClaudePTYStart.run(
                binary: long.path, arguments: [], environment: ["PATH": "/usr/bin:/bin"],
                directory: folder, duration: 30, grace: 1, registry: registry
            )
            returned.fulfill()
        }
        defer { task.cancel() }
        let registered = await waitUntil(3) { registry.runningCount == 1 }
        XCTAssertTrue(registered)
        // The script has started and written its pid: the cancel meets a running program.
        let up = await waitUntil(3) { FileManager.default.fileExists(atPath: pidFile.path) }
        XCTAssertTrue(up)

        task.cancel()

        await fulfillment(of: [returned], timeout: 4)
        XCTAssertEqual(registry.runningCount, 0)
        let gone = await processIsGone(pidFile: pidFile)
        XCTAssertTrue(gone, "a cancelled start does not leave Claude Code running")
    }

    /// Quitting sends SIGTERM only. A program that ignores it is not left running past the
    /// start's own duration plus grace: the SIGKILL path still ends it, and the registry empties.
    func testAQuitDuringAProgramThatIgnoresSigtermStillEndsItWhenTheStartIsOver() async throws {
        let registry = ChildProcessRegistry()
        let pidFile = directory.appendingPathComponent("pid")
        let stubborn = try script("""
        #!/bin/sh
        trap '' TERM
        echo $$ > '\(pidFile.path)'
        while :; do /bin/sleep 1; done

        """)
        let folder = directory!
        let returned = expectation(description: "the start came back")
        let task = Task.detached {
            try? await ClaudePTYStart.run(
                binary: stubborn.path, arguments: [], environment: ["PATH": "/usr/bin:/bin"],
                directory: folder, duration: 1.2, grace: 0.5, registry: registry
            )
            returned.fulfill()
        }
        defer { task.cancel() }
        let registered = await waitUntil(3) { registry.runningCount == 1 }
        XCTAssertTrue(registered)
        // The script has installed its trap and written its pid before the quit signals it.
        let up = await waitUntil(3) { FileManager.default.fileExists(atPath: pidFile.path) }
        XCTAssertTrue(up)

        registry.terminateAll()

        await fulfillment(of: [returned], timeout: 8)
        XCTAssertEqual(registry.runningCount, 0)
        let gone = await processIsGone(pidFile: pidFile)
        XCTAssertTrue(gone, "SIGKILL after the grace ended the program that ignored SIGTERM")
    }

    /// The quit can land anywhere around the start, in particular between the registration and the
    /// program's launch, where `terminateAll()` finds nothing running to signal and only the
    /// `didStart` call after `run()` stops the program. Many starts, each quit at a different
    /// instant a few milliseconds in: every one must come back at once, none left to its duration.
    func testAQuitAtAnyInstantAroundTheLaunchNeverLeavesTheProgramRunning() async throws {
        let folder = directory!
        let slowest = await withTaskGroup(of: TimeInterval.self, returning: TimeInterval.self) { group in
            for index in 0..<200 {
                group.addTask {
                    let registry = ChildProcessRegistry()
                    let quitAfter = useconds_t(index % 20) * 400
                    Thread.detachNewThread {
                        usleep(quitAfter)
                        registry.terminateAll()
                    }
                    let started = Date()
                    try? await ClaudePTYStart.run(
                        binary: "/bin/sleep", arguments: ["30"], environment: ["PATH": "/usr/bin:/bin"],
                        directory: folder, duration: 4, grace: 1, registry: registry
                    )
                    return Date().timeIntervalSince(started)
                }
            }
            var worst: TimeInterval = 0
            for await elapsed in group { worst = max(worst, elapsed) }
            return worst
        }
        XCTAssertLessThan(slowest, 3, "a start the quit passed by ran on to its duration")
    }

    func testAClosedRegistryRunsNoProgramAtAll() async throws {
        let registry = ChildProcessRegistry()
        registry.terminateAll()
        let marker = directory.appendingPathComponent("ran")
        let program = try script("#!/bin/sh\n: > '\(marker.path)'\n")

        do {
            try await ClaudePTYStart.run(
                binary: program.path, arguments: [], environment: ["PATH": "/usr/bin:/bin"],
                directory: directory, duration: 5, grace: 1, registry: registry
            )
            XCTFail("a start after the quit did not throw")
        } catch is ClaudePTYStart.Failure {}
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "the program never ran")
    }

    func testARenewalAfterTheQuitCleansUpAndReturnsInsteadOfStartingClaudeCode() async throws {
        let registry = ChildProcessRegistry()
        registry.terminateAll()
        let marker = directory.appendingPathComponent("ran")
        let program = try script("#!/bin/sh\n: > '\(marker.path)'\n")
        let claudeRoot = directory.appendingPathComponent(".claude", isDirectory: true)
        let probe = directory.appendingPathComponent("probe", isDirectory: true)

        await ClaudeRenewalProbe.renew(
            binary: program.path, directory: probe, claudeRoot: claudeRoot, environment: ["PATH": "/usr/bin:/bin"]
        ) { binary, arguments, environment, directory in
            try? await ClaudePTYStart.run(
                binary: binary, arguments: arguments, environment: environment,
                directory: directory, duration: 5, registry: registry
            )
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    // MARK: - Task 3: a symlinked project folder

    func testADanglingSymlinkAsTheProjectFolderIsLeftAlone() throws {
        let claudeRoot = directory.appendingPathComponent(".claude", isDirectory: true)
        let probe = directory.appendingPathComponent("UsageTracker/ClaudeRenewal", isDirectory: true)
        let projects = claudeRoot.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let link = projects.appendingPathComponent(ClaudeRenewalProbe.projectDirectoryName(for: probe))
        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: directory.appendingPathComponent("nowhere").path
        )

        XCTAssertEqual(ClaudeRenewalProbe.removeTranscripts(probeDirectory: probe, claudeRoot: claudeRoot), [])
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path), "the link stays")
    }

    func testARelativeSymlinkAsTheProjectFolderIsLeftAloneAndTheStartStillRuns() async throws {
        let claudeRoot = directory.appendingPathComponent(".claude", isDirectory: true)
        let probe = directory.appendingPathComponent("UsageTracker/ClaudeRenewal", isDirectory: true)
        let projects = claudeRoot.appendingPathComponent("projects", isDirectory: true)
        let real = projects.appendingPathComponent("real-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let kept = real.appendingPathComponent("other.jsonl")
        try Data("{}\n".utf8).write(to: kept)
        let link = projects.appendingPathComponent(ClaudeRenewalProbe.projectDirectoryName(for: probe))
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "real-folder")

        var started = 0
        await ClaudeRenewalProbe.renew(
            binary: "/x/claude", directory: probe, claudeRoot: claudeRoot, environment: [:]
        ) { _, _, _, _ in started += 1 }

        XCTAssertEqual(started, 1, "the start itself is not blocked by the link")
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path), "nothing behind the link was removed")
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
    }

    // MARK: - Task 4: the expiry guard's edges

    func testAnExpiryExactlyAtTheFiveMinuteMarginIsNotExpiredAndStartsNothing() async {
        let onTheEdge = oauth("edge", expiresAt: nowMS + 300_000)
        let claudeCode = ScriptedClaudeCode(reads: [.found(onTheEdge)], renewsTo: fresh)

        let snapshot = await provider(claudeCode).fetch()

        XCTAssertEqual(claudeCode.starts, 0)
        XCTAssertEqual(snapshot.state, .notSignedIn)
        XCTAssertEqual(snapshot.signedOutReason, .expired)
        XCTAssertEqual(VerificationEndpointStub.tokensAsked, ["edge"])
    }

    func testAnExpiryOneMillisecondInsideTheMarginIsExpiredAndStartsClaudeCode() async {
        let inside = oauth("inside", expiresAt: nowMS + 299_999)
        let claudeCode = ScriptedClaudeCode(reads: [.found(inside)], renewsTo: fresh)

        let snapshot = await provider(claudeCode).fetch()

        XCTAssertEqual(claudeCode.starts, 1)
        XCTAssertEqual(snapshot.state, .ok)
        XCTAssertEqual(VerificationEndpointStub.tokensAsked, ["inside", "fresh"])
    }

    func testAnExpiredTokenWithANewerOneNowOnDiskUsesItAndStartsNothing() async {
        // The first read (the poll's start) shows the dead token; by the 401 Claude Code wrote a new one.
        let dead = oauth("dead", expiresAt: nowMS - 3_600_000)
        let claudeCode = ScriptedClaudeCode(reads: [.found(dead), .found(fresh)])

        let snapshot = await provider(claudeCode).fetch()

        XCTAssertEqual(snapshot.state, .ok)
        XCTAssertEqual(claudeCode.starts, 0)
        XCTAssertEqual(VerificationEndpointStub.tokensAsked, ["dead", "fresh"])
    }

    func testANonExpiredTokenTheServerRefusedStillGivesWayToANewerOneOnDisk() async {
        let revoked = oauth("revoked", expiresAt: nowMS + 2 * 3_600_000)
        let cache = ClaudeCredentialsCache()
        cache.save(revoked)
        let claudeCode = ScriptedClaudeCode(reads: [.found(fresh)])

        let snapshot = await provider(claudeCode, cache: cache).fetch()

        XCTAssertEqual(snapshot.state, .ok)
        XCTAssertEqual(claudeCode.starts, 0)
        XCTAssertEqual(VerificationEndpointStub.tokensAsked, ["revoked", "fresh"])
    }

    /// A refused (not expired) poll does not use up the gate's once-in-five-minutes leave.
    func testASkippedStartForALiveTokenDoesNotSpendTheGate() async {
        let gate = ClaudeRenewalGate()
        let revoked = oauth("revoked", expiresAt: nowMS + 2 * 3_600_000)
        _ = await provider(ScriptedClaudeCode(reads: [.found(revoked)]), gate: gate).fetch()

        let dead = oauth("dead", expiresAt: nowMS - 3_600_000)
        let claudeCode = ScriptedClaudeCode(reads: [.found(dead)], renewsTo: fresh)
        let snapshot = await provider(claudeCode, gate: gate, at: now.addingTimeInterval(10)).fetch()

        XCTAssertEqual(claudeCode.starts, 1, "the later expired token still gets its start")
        XCTAssertEqual(snapshot.state, .ok)
    }

    // MARK: - Task 5: an item with no Claude sign-in

    func testOddPayloadsDecideNotSignedInOrUnreadableAsTheRuleSays() throws {
        let notFound = [
            "{}",
            #"{"claudeAiOauth":null}"#,
            #"{"mcpOAuth":{"x":{"accessToken":"t"}},"other":[1,2,3]}"#,
        ]
        for text in notFound {
            XCTAssertNil(try ClaudeCredentials.decodeSignIn(from: Data(text.utf8)), text)
        }
        let unreadable = [
            "",
            "not json",
            "null",
            "[]",
            "42",
            #"{"claudeAiOauth":{}}"#,
            #"{"claudeAiOauth":"signed-in"}"#,
            #"{"claudeAiOauth":[]}"#,
            #"{"claudeAiOauth":{"accessToken":"t"}}"#,
            #"{"claudeAiOauth":{"accessToken":"t","expiresAt":"soon"}}"#,
            #"{"claudeAiOauth":{"expiresAt":1}}"#,
        ]
        for text in unreadable {
            XCTAssertThrowsError(try ClaudeCredentials.decodeSignIn(from: Data(text.utf8)), text)
        }
    }

    func testExtraKeysAroundAndInsideASignInAreIgnored() throws {
        let json = #"{"mcpOAuth":{},"claudeAiOauth":{"accessToken":"t","expiresAt":5,"future":{"a":1}},"z":0}"#
        let oauth = try XCTUnwrap(try ClaudeCredentials.decodeSignIn(from: Data(json.utf8)))
        XCTAssertEqual(oauth.accessToken, "t")
        XCTAssertEqual(oauth.expiresAt, 5)
        XCTAssertNil(oauth.refreshToken)
    }

    func testAnItemOnlyHoldingMcpEntriesEndsInSignInThroughTheProvider() async {
        // The security tool read the item, found no claudeAiOauth; the direct read was refused.
        let item = ClaudeSourceRead.combining(direct: .refused, security: { .absent })
        let claudeCode = ScriptedClaudeCode(reads: [item])

        let snapshot = await provider(claudeCode).fetch()

        XCTAssertEqual(snapshot.state, .notSignedIn)
        XCTAssertEqual(snapshot.signedOutReason, .notFound)
        XCTAssertEqual(snapshot.stateMessage, ClaudeSignInCopy.notFoundMessage)
        XCTAssertEqual(ClaudeSignInCopy.recovery(for: snapshot, binaryFound: true), .signIn)
        XCTAssertEqual(ClaudeSignInCopy.recovery(for: snapshot, binaryFound: false), .install)
        XCTAssertTrue(VerificationEndpointStub.tokensAsked.isEmpty, "no token, no request")
        XCTAssertEqual(claudeCode.starts, 0)
    }

    func testAnUnreadableDirectReadIsNotTurnedIntoSignInBySecurityFindingNothing() async {
        let item = ClaudeSourceRead.combining(direct: .unreadable("Could not parse credentials: x"), security: { .absent })
        let snapshot = await provider(ScriptedClaudeCode(reads: [item])).fetch()

        XCTAssertEqual(snapshot.signedOutReason, .unreadable)
        XCTAssertEqual(snapshot.stateMessage, "Could not parse credentials: x")
        XCTAssertEqual(ClaudeSignInCopy.recovery(for: snapshot, binaryFound: true), .noAction)
    }

    func testTheCombiningTableEndToEnd() {
        let signIn = oauth("t", expiresAt: 1)
        let table: [(ClaudeSourceRead, ClaudeSourceRead, ClaudeSourceRead)] = [
            (.refused, .found(signIn), .found(signIn)),
            (.refused, .absent, .absent),
            (.refused, .refused, .refused),
            (.refused, .unreadable("s"), .unreadable("s")),
            (.unreadable("d"), .found(signIn), .found(signIn)),
            (.unreadable("d"), .absent, .unreadable("d")),
            (.unreadable("d"), .refused, .unreadable("d")),
        ]
        for (direct, security, expected) in table {
            XCTAssertEqual(ClaudeSourceRead.combining(direct: direct, security: { security }), expected, "\(direct) + \(security)")
        }
        var asked = 0
        for direct in [ClaudeSourceRead.found(signIn), .absent] {
            _ = ClaudeSourceRead.combining(direct: direct, security: { asked += 1; return .absent })
        }
        XCTAssertEqual(asked, 0, "a found or absent direct read never asks the tool")
    }
}
