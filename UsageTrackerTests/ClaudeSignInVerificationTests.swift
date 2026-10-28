import XCTest
@testable import Omelette

/// Tester's cases for spec 2026-10-25 (Claude switch and sign-in) § Design › Package 2: what the
/// coders' tests leave open. The 401 path's guard order with each step failing in turn (ruling
/// 2b), the environment every run of Claude Code gets, the `.command` file under hostile binary
/// paths, and the words and buttons for every reason. Nothing touches the real keychain,
/// `~/.claude`, Terminal, the network or a real `claude`.

// MARK: - The usage endpoint and Claude Code, faked

/// 200 for a token in `live`, 401 for any other.
private final class GuardEndpointStub: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var liveTokens: Set<String> = []
    nonisolated(unsafe) private static var asked: [String] = []

    static func reset(live: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        liveTokens = live
        asked = []
    }

    static var tokensAsked: [String] {
        lock.lock()
        defer { lock.unlock() }
        return asked
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url ?? ClaudeOAuthProvider.usageURL
        let token = (request.value(forHTTPHeaderField: "Authorization") ?? "").replacingOccurrences(of: "Bearer ", with: "")
        Self.lock.lock()
        Self.asked.append(token)
        let live = Self.liveTokens.contains(token)
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: url, statusCode: live ? 200 : 401, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((live ? #"{"five_hour":{"utilization":7.0,"resets_at":"2026-10-04T12:49:59+00:00"}}"# : "{}").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Claude Code's side with a trace: every question the provider asks, in order, and what one
/// start does.
private final class TracedClaudeCode: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    private var held: ClaudeSourceRead
    private var securityScript: [ClaudeSourceRead]
    private let renewsTo: ClaudeCredentials.OAuth?
    private let unlocked: Bool
    private var binary: String?
    private let startDelay: UInt64

    init(
        item: ClaudeSourceRead, renewsTo: ClaudeCredentials.OAuth? = nil, unlocked: Bool = true,
        securityScript: [ClaudeSourceRead] = [], binary: String? = "/opt/test/claude", startDelay: UInt64 = 0
    ) {
        held = item
        self.renewsTo = renewsTo
        self.unlocked = unlocked
        self.securityScript = securityScript
        self.binary = binary
        self.startDelay = startDelay
    }

    var trace: [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    var starts: Int { trace.filter { $0 == "start" }.count }

    func setBinary(_ value: String?) {
        lock.lock()
        defer { lock.unlock() }
        binary = value
    }

    private func applyRenewal() {
        lock.lock()
        defer { lock.unlock() }
        if let renewed = renewsTo { held = .found(renewed) }
    }

    private func note(_ event: String) {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
    }

    var sources: ClaudeCredentialSources {
        ClaudeCredentialSources(
            file: { nil },
            item: { self.lock.lock(); defer { self.lock.unlock() }; return self.held },
            itemViaSecurityTool: {
                self.note("security")
                self.lock.lock()
                defer { self.lock.unlock() }
                return self.securityScript.isEmpty ? self.held : self.securityScript.removeFirst()
            },
            keychainUnlocked: { self.note("unlocked"); return self.unlocked }
        )
    }

    func renewal(gate: ClaudeRenewalGate) -> ClaudeRenewal {
        ClaudeRenewal(
            gate: gate,
            locateBinary: {
                self.note("locate")
                self.lock.lock()
                defer { self.lock.unlock() }
                return self.binary
            },
            start: { _ in
                self.note("start")
                if self.startDelay > 0 { try? await Task.sleep(nanoseconds: self.startDelay) }
                self.applyRenewal()
            }
        )
    }
}

private func tracedFetch(
    _ claudeCode: TracedClaudeCode, gate: ClaudeRenewalGate, at date: Date, cache: ClaudeCredentialsCache
) async -> ServiceSnapshot {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [GuardEndpointStub.self]
    return await ClaudeOAuthProvider(
        http: HTTPClient(session: URLSession(configuration: configuration)),
        cache: cache, sources: claudeCode.sources, renewal: claudeCode.renewal(gate: gate), now: { date }
    ).fetch()
}

final class ClaudeSignInVerificationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_100_000)
    private var nowMS: Double { now.timeIntervalSince1970 * 1000 }

    private func oauth(_ token: String, expiresAt: Double) -> ClaudeCredentials.OAuth {
        let json = """
        {"claudeAiOauth":{"accessToken":"\(token)","refreshToken":"r","expiresAt":\(expiresAt),
         "scopes":["user:inference"],"subscriptionType":"max","rateLimitTier":"default_max_20x"}}
        """
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(ClaudeCredentials.self, from: Data(json.utf8)).claudeAiOauth
    }

    private var dead: ClaudeCredentials.OAuth { oauth("dead", expiresAt: nowMS - 3_600_000) }
    private var fresh: ClaudeCredentials.OAuth { oauth("fresh", expiresAt: nowMS + 8 * 3_600_000) }

    override func setUp() {
        super.setUp()
        GuardEndpointStub.reset(live: ["fresh"])
    }

    private func fetch(
        _ claudeCode: TracedClaudeCode, gate: ClaudeRenewalGate, at date: Date? = nil,
        cache: ClaudeCredentialsCache = ClaudeCredentialsCache()
    ) async -> ServiceSnapshot {
        await tracedFetch(claudeCode, gate: gate, at: date ?? now, cache: cache)
    }

    // MARK: - The guard order: admission, unlocked, security read, binary, attempt

    func testAFullRenewalAsksInTheSpecsOrderAndReadsTheItemOnlyThroughSecurityAfterwards() async {
        let claudeCode = TracedClaudeCode(item: .found(dead), renewsTo: fresh)

        let snapshot = await fetch(claudeCode, gate: ClaudeRenewalGate())

        XCTAssertEqual(snapshot.state, .ok)
        XCTAssertEqual(claudeCode.trace, ["unlocked", "security", "locate", "start", "security"])
    }

    func testACoolingGateIsAskedBeforeAnyKeychainOrBinaryQuestion() async {
        let claudeCode = TracedClaudeCode(item: .found(dead), renewsTo: fresh)
        let gate = ClaudeRenewalGate()
        _ = await gate.attempt(now: now.addingTimeInterval(-10)) { nil }

        let snapshot = await fetch(claudeCode, gate: gate)

        XCTAssertEqual(snapshot.signedOutReason, .expired)
        XCTAssertEqual(claudeCode.trace, [], "a refused attempt reads nothing from the keychain")
    }

    func testAPendingSignInIsAskedBeforeAnyKeychainOrBinaryQuestion() async {
        let claudeCode = TracedClaudeCode(item: .found(dead), renewsTo: fresh)
        let gate = ClaudeRenewalGate()
        await gate.signInLaunched(at: now.addingTimeInterval(-30))

        let snapshot = await fetch(claudeCode, gate: gate)

        XCTAssertEqual(snapshot.signedOutReason, .expired)
        XCTAssertEqual(claudeCode.trace, [])
    }

    func testALockedKeychainNeverRunsTheSecurityReadOrLooksForTheBinary() async {
        let claudeCode = TracedClaudeCode(item: .found(dead), renewsTo: fresh, unlocked: false)

        let snapshot = await fetch(claudeCode, gate: ClaudeRenewalGate())

        XCTAssertEqual(snapshot.signedOutReason, .expired)
        XCTAssertEqual(claudeCode.trace, ["unlocked"], "`security` on a locked keychain raises its password panel")
    }

    func testASecurityReadThatDoesNotFindTheItemStopsBeforeTheBinary() async {
        let answers: [ClaudeSourceRead] = [.refused, .absent, .unreadable("Could not parse credentials: x")]
        for answer in answers {
            let claudeCode = TracedClaudeCode(item: .found(dead), renewsTo: fresh, securityScript: [answer])
            let snapshot = await fetch(claudeCode, gate: ClaudeRenewalGate())
            XCTAssertEqual(snapshot.signedOutReason, .expired, "\(answer)")
            XCTAssertEqual(claudeCode.trace, ["unlocked", "security"], "\(answer)")
        }
    }

    func testNoBinaryStopsBeforeTheStartAndSpendsNoCooldown() async {
        let claudeCode = TracedClaudeCode(item: .found(dead), renewsTo: fresh, binary: nil)
        let gate = ClaudeRenewalGate()

        let first = await fetch(claudeCode, gate: gate)
        XCTAssertEqual(first.signedOutReason, .expired)
        XCTAssertEqual(claudeCode.trace, ["unlocked", "security", "locate"])

        // Claude Code gets installed; the next poll, one second on, may start it at once: a guard
        // that failed is not an attempt, so no five minutes are owed.
        claudeCode.setBinary("/opt/test/claude")
        let second = await fetch(claudeCode, gate: gate, at: now.addingTimeInterval(1))
        XCTAssertEqual(second.state, .ok)
        XCTAssertEqual(claudeCode.starts, 1)
    }

    func testALockedKeychainSpendsNoCooldownEither() async {
        let locked = TracedClaudeCode(item: .found(dead), renewsTo: fresh, unlocked: false)
        let gate = ClaudeRenewalGate()
        _ = await fetch(locked, gate: gate)
        let admission = await gate.admission(now: now.addingTimeInterval(1))
        XCTAssertEqual(admission, .run)
    }

    func testANewerTokenClaudeCodeAlreadyWroteCostsNoGuardQuestion() async {
        let cache = ClaudeCredentialsCache()
        cache.save(oauth("revoked", expiresAt: nowMS + 3_600_000))
        let claudeCode = TracedClaudeCode(item: .found(fresh))

        let snapshot = await fetch(claudeCode, gate: ClaudeRenewalGate(), cache: cache)

        XCTAssertEqual(snapshot.state, .ok)
        XCTAssertEqual(claudeCode.trace, [])
        XCTAssertEqual(GuardEndpointStub.tokensAsked, ["revoked", "fresh"])
    }

    // MARK: - What counts as renewed: the expiry moved past the dead token's

    func testAnItemWhoseExpiryDidNotMoveIsNotARenewal() async {
        let candidates: [ClaudeSourceRead] = [
            .found(oauth("rewritten", expiresAt: dead.expiresAt)),
            .found(oauth("older", expiresAt: dead.expiresAt - 1000)),
            .refused,
            .absent,
            .unreadable("Could not parse credentials: x"),
        ]
        for after in candidates {
            GuardEndpointStub.reset(live: ["fresh", "rewritten", "older"])
            let claudeCode = TracedClaudeCode(item: .found(dead), securityScript: [.found(dead), after])
            let snapshot = await fetch(claudeCode, gate: ClaudeRenewalGate())
            XCTAssertEqual(snapshot.state, .notSignedIn, "\(after)")
            XCTAssertEqual(snapshot.signedOutReason, .expired, "\(after)")
            XCTAssertEqual(claudeCode.starts, 1, "\(after)")
            XCTAssertEqual(GuardEndpointStub.tokensAsked, ["dead"], "no second request on a token that is not newer: \(after)")
        }
    }

    func testTwoPollsAtOnceStartClaudeCodeOnce() async {
        let claudeCode = TracedClaudeCode(item: .found(dead), renewsTo: fresh, startDelay: 300_000_000)
        let gate = ClaudeRenewalGate()
        let at = now
        let first = Task { await tracedFetch(claudeCode, gate: gate, at: at, cache: ClaudeCredentialsCache()) }
        let second = Task { await tracedFetch(claudeCode, gate: gate, at: at, cache: ClaudeCredentialsCache()) }
        let states = [await first.value.state, await second.value.state]

        XCTAssertEqual(claudeCode.starts, 1)
        XCTAssertTrue(states.contains(.ok))
    }

    // MARK: - The environment every run of Claude Code gets

    private let hostileBase: [String: String] = [
        "CLAUDE_CONFIG_DIR": "/elsewhere/cfg",
        "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/elsewhere/secure",
        "CLAUDE_CODE_OAUTH_TOKEN": "desktop-token",
        "CLAUDECODE": "1",
        "ANTHROPIC_API_KEY": "key",
        "ANTHROPIC_AUTH_TOKEN": "token",
        "ANTHROPIC_BASE_URL": "https://proxy.invalid",
        "ANTHROPIC_": "bare prefix",
        "ANTHROPIC_MODEL": "x",
        "DISABLE_AUTOUPDATER": "0",
        "DISABLE_TELEMETRY": "",
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "0",
        "OMELETTE_CLAUDE_RENEWAL": "0",
        "LANG": "en_US.UTF-8",
        "OMELETTE_TEST_KEEP": "kept",
    ]

    func testTheRenewalEnvironmentWhateverTheBaseHolds() {
        let bases: [[String: String]] = [
            hostileBase,
            [:],
            ["USER": "", "HOME": "", "PATH": "", "TERM": ""],
            hostileBase.merging(["USER": "owner", "HOME": "/Users/owner", "PATH": "/usr/bin", "TERM": "xterm-kitty"]) { first, _ in first },
        ]
        for base in bases {
            let environment = ClaudeCLIEnvironment.renewal(
                base: base, loginPATH: ["/opt/login/bin"], home: "/home-fallback", user: "user-fallback"
            )
            for key in ["CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDECODE"] {
                XCTAssertNil(environment[key], key)
            }
            XCTAssertTrue(environment.keys.filter { $0.hasPrefix("ANTHROPIC_") }.isEmpty, "\(environment.keys)")
            for key in ["USER", "HOME", "PATH", "TERM"] {
                XCTAssertFalse((environment[key] ?? "").isEmpty, "\(key) in \(base)")
            }
            XCTAssertEqual(environment["DISABLE_AUTOUPDATER"], "1")
            XCTAssertEqual(environment["DISABLE_TELEMETRY"], "1")
            XCTAssertEqual(environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"], "1")
            XCTAssertEqual(environment["OMELETTE_CLAUDE_RENEWAL"], "1", "the mark is set whatever the base said")
            XCTAssertTrue(environment["PATH"]?.hasPrefix("/opt/login/bin") == true, "the login shell's PATH comes first")
        }
        let environment = ClaudeCLIEnvironment.renewal(base: hostileBase, loginPATH: nil, home: "/h", user: "u")
        XCTAssertEqual(environment["LANG"], "en_US.UTF-8", "the rest of the environment stays")
        XCTAssertEqual(environment["OMELETTE_TEST_KEEP"], "kept")
        XCTAssertEqual(environment["USER"], "u")
    }

    func testThePATHKeepsEachFolderOnceAndNoEmptyOne() {
        XCTAssertEqual(
            ClaudeCLIEnvironment.path(loginPATH: ["", "/a", "/a", "/b"], base: "/a::/c:/b"),
            "/a:/b:/c"
        )
    }

    func testScrubbedIsTheEnvironmentWithoutThoseVariablesAndNothingElseChanged() {
        let scrubbed = ClaudeCLIEnvironment.scrubbed(hostileBase)
        XCTAssertEqual(Set(scrubbed.keys), ["DISABLE_AUTOUPDATER", "DISABLE_TELEMETRY",
                                            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "OMELETTE_CLAUDE_RENEWAL",
                                            "LANG", "OMELETTE_TEST_KEEP"])
        for (key, value) in scrubbed { XCTAssertEqual(hostileBase[key], value) }
    }

    // MARK: - The .command file under hostile binary paths

    /// A stand-in `claude` in `folder`, recording what it was given.
    private func standIn(in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let binary = folder.appendingPathComponent("claude")
        let script = """
        #!/bin/sh
        here="$(/usr/bin/dirname "$0")"
        printf '%s' "$0" > "$here/seen-self"
        /usr/bin/env > "$here/seen-env"
        printf '%s\\n' "$#" > "$here/seen-args"
        for argument in "$@"; do printf '[%s]\\n' "$argument" >> "$here/seen-args"; done

        """
        try script.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return binary
    }

    /// Runs the `.command` text for `binary` with `/bin/sh`, as Terminal would, in a hostile environment.
    private func runCommandFile(for binary: URL, scratch: URL) throws -> Int32 {
        let file = scratch.appendingPathComponent("sign-in.command")
        try ClaudeSignInLauncher.commandFile(binary: binary.path).write(to: file, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [file.path]
        process.environment = [
            "PATH": "/usr/bin:/bin", "HOME": scratch.path,
            "CLAUDE_CONFIG_DIR": "/elsewhere/cfg", "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/elsewhere/secure",
            "CLAUDE_CODE_OAUTH_TOKEN": "desktop-token", "CLAUDECODE": "1",
            "ANTHROPIC_API_KEY": "key", "ANTHROPIC_BASE_URL": "https://proxy.invalid",
            "ANTHROPIC_MULTILINE": "first\nANTHROPIC_SMUGGLED=second",
            "OMELETTE_TEST_KEEP": "kept",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func testTheCommandFileRunsExactlyThatBinaryWithAuthLoginWhateverTheFolderIsCalled() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeSignInVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let names = [
            "plain", "with space", "single'quote", "double\"quote", "dollar$HOME", "dollar$(echo pwned)",
            "back`echo pwned`tick", "new\nline", "back\\slash", "semi;colon", "amp&ersand", "pipe|bar",
            "glob*star", "question?mark", "hash#tag", "paren(thesis)", "tilde~", "unicode-é-☃", "-leading-dash",
            "trailing space ", "bang!",
        ]
        var failures: [String] = []
        for (index, name) in names.enumerated() {
            let folder = scratch.appendingPathComponent("\(index)/\(name)", isDirectory: true)
            let binary = try standIn(in: folder)
            let status = try runCommandFile(for: binary, scratch: scratch)
            let args = try? String(contentsOf: folder.appendingPathComponent("seen-args"), encoding: .utf8)
            let selfPath = try? String(contentsOf: folder.appendingPathComponent("seen-self"), encoding: .utf8)
            let env = (try? String(contentsOf: folder.appendingPathComponent("seen-env"), encoding: .utf8)) ?? ""
            let leaked = ["CLAUDE_CONFIG_DIR=", "CLAUDE_SECURESTORAGE_CONFIG_DIR=", "CLAUDE_CODE_OAUTH_TOKEN=",
                          "CLAUDECODE=", "ANTHROPIC_"].filter { env.contains($0) }
            if status != 0 || args != "2\n[auth]\n[login]\n" || selfPath != binary.path || !leaked.isEmpty || !env.contains("OMELETTE_TEST_KEEP=kept") {
                failures.append("\(name.debugDescription): status \(status), args \(String(describing: args)), self \(String(describing: selfPath)), leaked \(leaked)")
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testAnEqualsSignInTheBinaryPathIsNotTakenForAnAssignment() throws {
        // `env NAME=value command` treats any word holding "=" as an assignment, so a binary under
        // a folder like "a=b" would not be the command that runs.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeSignInVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let folder = scratch.appendingPathComponent("equals=sign", isDirectory: true)
        let binary = try standIn(in: folder)

        let status = try runCommandFile(for: binary, scratch: scratch)

        XCTAssertEqual(status, 0, "the file did not run the binary")
        XCTAssertEqual(try? String(contentsOf: folder.appendingPathComponent("seen-args"), encoding: .utf8), "2\n[auth]\n[login]\n")
    }

    // MARK: - The words and the buttons, every combination

    private func signedOut(_ reason: SignedOutReason?, keptNumbers: Bool) -> ServiceSnapshot {
        let fresh = ServiceSnapshot.notSignedIn(reason: reason, message: "Signed out.", at: now)
        guard keptNumbers else { return fresh }
        let earlier = now.addingTimeInterval(-600)
        let previous = Fixture.snapshot(
            id: "claude", displayName: "Claude",
            buckets: [Fixture.bucket(id: "five_hour", label: "Current session", percent: 40, kind: .session)], at: earlier
        )
        return AppState.mergingPoll(
            previous: UsageSnapshot(services: [previous], fetchedAt: earlier, isStale: false, lastError: nil),
            next: UsageSnapshot(services: [fresh], fetchedAt: now, isStale: false, lastError: nil)
        ).services[0]
    }

    func testEveryReasonBinaryNoteAndKeptNumbersGiveOneConsistentHelp() throws {
        let reasons: [SignedOutReason?] = [nil, .notFound, .expired, .denied, .unreadable]
        let notes: [ClaudeSignInNote?] = [nil, .pending, .failed("boom")]
        for reason in reasons {
            for binaryFound in [true, false] {
                for kept in [false, true] {
                    for note in notes {
                        let label = "\(String(describing: reason)) binary \(binaryFound) kept \(kept) note \(String(describing: note))"
                        let service = signedOut(reason, keptNumbers: kept)
                        let help = try XCTUnwrap(ClaudeSignInCopy.help(for: service, binaryFound: binaryFound, note: note), label)

                        let expectedRecovery: ClaudeRecovery
                        let expectedMessage: String
                        switch reason ?? .notFound {
                        case .notFound:
                            expectedRecovery = binaryFound ? .signIn : .install
                            expectedMessage = binaryFound ? ClaudeSignInCopy.signInHelp : ClaudeSignInCopy.installHelp
                        case .expired:
                            expectedRecovery = binaryFound ? .signIn : .install
                            expectedMessage = binaryFound ? ClaudeSignInCopy.expiredHelp : ClaudeSignInCopy.installHelp
                        case .denied:
                            expectedRecovery = .keychainAccess
                            expectedMessage = ClaudeSignInCopy.deniedHelp
                        case .unreadable:
                            expectedRecovery = .noAction
                            expectedMessage = ClaudeSignInCopy.unreadableHelp
                        }
                        XCTAssertEqual(help.recovery, expectedRecovery, label)
                        XCTAssertEqual(ClaudeSignInCopy.recovery(for: service, binaryFound: binaryFound), expectedRecovery, label)
                        XCTAssertEqual(help.message, expectedMessage, label)

                        let clickCanStart = expectedRecovery == .signIn || expectedRecovery == .install
                        if let note, clickCanStart {
                            XCTAssertEqual(help.note, ClaudeSignInCopy.noteText(note), label)
                            if case .failed = note { XCTAssertTrue(help.noteIsFailure, label) } else { XCTAssertFalse(help.noteIsFailure, label) }
                        } else {
                            XCTAssertNil(help.note, label)
                            XCTAssertFalse(help.noteIsFailure, label)
                        }
                        for text in [help.message, help.note ?? ""] {
                            XCTAssertFalse(text.contains("claude login"), label)
                            XCTAssertFalse(text.contains("`"), label)
                            XCTAssertFalse(text.lowercased().contains("widget"), label)
                        }
                    }
                }
            }
        }
    }

    func testAReasonLeftOnAnyOtherStateOffersNothing() {
        for state in [ServiceState.ok, .notRunning, .error] {
            var service = Fixture.snapshot(id: "claude", state: state, at: now)
            for reason in [SignedOutReason.notFound, .expired, .denied, .unreadable] {
                service.signedOutReason = reason
                XCTAssertNil(ClaudeSignInCopy.recovery(for: service, binaryFound: true), "\(state) \(reason)")
                XCTAssertNil(ClaudeSignInCopy.help(for: service, binaryFound: true, note: .pending), "\(state) \(reason)")
            }
        }
        var codex = Fixture.snapshot(id: "codex", state: .notSignedIn, at: now)
        codex.signedOutReason = .notFound
        XCTAssertNil(ClaudeSignInCopy.recovery(for: codex, binaryFound: true))
        XCTAssertNil(ClaudeSignInCopy.help(for: codex, binaryFound: true, note: nil))
    }

    func testClaudesRowNeverOffersKeychainOrNothingToDo() throws {
        let claude = try XCTUnwrap(ProvidersSettingsCopy.listed.first { $0.id == ProvidersSettingsCopy.claudeID })
        let reasons: [SignedOutReason?] = [nil, .notFound, .expired, .denied, .unreadable]
        for reason in reasons {
            for binaryFound in [true, false] {
                for enabled in [true, false] {
                    for kept in [false, true] {
                        let action = ProvidersSettingsCopy.claudeAction(
                            for: claude, service: signedOut(reason, keptNumbers: kept), isEnabled: enabled, binaryFound: binaryFound
                        )
                        let label = "\(String(describing: reason)) binary \(binaryFound) enabled \(enabled) kept \(kept)"
                        XCTAssertTrue(action == nil || action == .signIn || action == .install, label)
                        if !enabled { XCTAssertNil(action, label) }
                        if reason == .denied || reason == .unreadable { XCTAssertNil(action, label) }
                        if enabled, reason != .denied, reason != .unreadable {
                            XCTAssertEqual(action, binaryFound ? .signIn : .install, label)
                        }
                    }
                }
            }
        }
        for other in ProvidersSettingsCopy.listed where other.id != ProvidersSettingsCopy.claudeID {
            XCTAssertNil(ProvidersSettingsCopy.claudeAction(
                for: other, service: signedOut(.notFound, keptNumbers: false), isEnabled: true, binaryFound: true
            ), other.id)
        }
    }

    func testTheLineAfterAClickNeverAppearsWithoutItsButton() {
        for note in [ClaudeSignInNote.pending, .failed("x")] {
            XCTAssertNil(ProvidersSettingsCopy.claudeNote(note, action: nil))
            for action in [ClaudeRecovery.signIn, .install] {
                XCTAssertNotNil(ProvidersSettingsCopy.claudeNote(note, action: action))
            }
        }
    }
}
