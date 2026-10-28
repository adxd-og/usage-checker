import XCTest
@testable import Omelette

/// The usage endpoint as the server answers it: 200 with one session window for a token in
/// `live`, 401 for any other. Records every request.
private final class UsageEndpointStub: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var liveTokens: Set<String> = []
    /// Tokens the server answers with 429 and `Retry-After: 300`.
    nonisolated(unsafe) private static var limitedTokens: Set<String> = []
    nonisolated(unsafe) private static var asked: [(url: URL, token: String)] = []

    static func reset(live: Set<String>, limited: Set<String> = []) {
        lock.lock()
        defer { lock.unlock() }
        liveTokens = live
        limitedTokens = limited
        asked = []
    }

    static var tokensAsked: [String] {
        lock.lock()
        defer { lock.unlock() }
        return asked.map(\.token)
    }

    static var urlsAsked: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return asked.map(\.url)
    }

    private static let payload = #"{"five_hour":{"utilization":7.0,"resets_at":"2026-10-04T12:49:59+00:00"}}"#

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url ?? ClaudeOAuthProvider.usageURL
        let token = (request.value(forHTTPHeaderField: "Authorization") ?? "")
            .replacingOccurrences(of: "Bearer ", with: "")
        Self.lock.lock()
        Self.asked.append((url, token))
        let live = Self.liveTokens.contains(token)
        let limited = Self.limitedTokens.contains(token)
        Self.lock.unlock()
        var headers = ["Content-Type": "application/json"]
        if limited { headers["Retry-After"] = "300" }
        let response = HTTPURLResponse(
            url: url, statusCode: live ? 200 : (limited ? 429 : 401), httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((live ? Self.payload : "{}").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Claude Code's side, faked: what its keychain item holds, and what one start of it does.
private final class ClaudeCodeFake: @unchecked Sendable {
    private let lock = NSLock()
    private var held: ClaudeSourceRead
    private var startedWith: [String] = []
    /// What a start writes into the item; nil: the start renews nothing.
    private let renewsTo: ClaudeCredentials.OAuth?
    private let unlocked: Bool
    private let securityRefused: Bool

    init(item: ClaudeSourceRead, renewsTo: ClaudeCredentials.OAuth? = nil, unlocked: Bool = true, securityRefused: Bool = false) {
        held = item
        self.renewsTo = renewsTo
        self.unlocked = unlocked
        self.securityRefused = securityRefused
    }

    var item: ClaudeSourceRead {
        lock.lock()
        defer { lock.unlock() }
        return held
    }

    var starts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return startedWith
    }

    func start(_ binary: String) {
        lock.lock()
        defer { lock.unlock() }
        startedWith.append(binary)
        if let renewsTo { held = .found(renewsTo) }
    }

    var sources: ClaudeCredentialSources {
        ClaudeCredentialSources(
            file: { nil },
            item: { self.item },
            itemViaSecurityTool: { self.securityRefused ? .refused : self.item },
            keychainUnlocked: { self.unlocked }
        )
    }
}

/// Spec 2026-10-25 (Claude switch and sign-in) § Design › Package 2, Renewal through Claude Code
/// and Keychain prompts (ruling 2b): when the usage API answers 401 and Claude Code holds nothing
/// newer, Omelette starts Claude Code so it renews its own sign-in — only while the login keychain
/// is unlocked and the `security` read Claude Code itself makes just went through silently, at
/// most once every five minutes, never during a sign-in from the button — reads the item once
/// after, and counts a renewal only when its expiry moved forward. Omelette never asks a token
/// endpoint. The usage endpoint is a `URLProtocol` stub, Claude Code a fake, the clock fixed per
/// poll.
final class ClaudeRenewalThroughClaudeCodeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_100_000)
    private var nowMS: Double { now.timeIntervalSince1970 * 1000 }
    private let binary = "/Users/tester/Library/Application Support/Claude/claude-code/2.1.308/a93ded4b1b47/claude.app/Contents/MacOS/claude"

    private func oauth(_ token: String, expiresAt: Double) -> ClaudeCredentials.OAuth {
        let json = """
        {"claudeAiOauth":{"accessToken":"\(token)","refreshToken":"r","expiresAt":\(expiresAt),
         "scopes":["user:inference"],"subscriptionType":"max","rateLimitTier":"default_max_20x"}}
        """
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(ClaudeCredentials.self, from: Data(json.utf8)).claudeAiOauth
    }

    /// Expired an hour ago by its own clock; the server says 401.
    private var dead: ClaudeCredentials.OAuth { oauth("dead", expiresAt: nowMS - 3_600_000) }
    /// What Claude Code writes when it renews: eight hours on (verification (2)).
    private var fresh: ClaudeCredentials.OAuth { oauth("fresh", expiresAt: nowMS + 8 * 3_600_000) }

    override func setUp() {
        super.setUp()
        UsageEndpointStub.reset(live: ["fresh"])
    }

    private func provider(
        _ claudeCode: ClaudeCodeFake,
        gate: ClaudeRenewalGate,
        binary: String?,
        at date: Date,
        cache: ClaudeCredentialsCache = ClaudeCredentialsCache()
    ) -> ClaudeOAuthProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UsageEndpointStub.self]
        return ClaudeOAuthProvider(
            http: HTTPClient(session: URLSession(configuration: configuration)),
            cache: cache,
            sources: claudeCode.sources,
            renewal: ClaudeRenewal(gate: gate, locateBinary: { binary }, start: { claudeCode.start($0) }),
            now: { date }
        )
    }

    func testAnExpiredSignInIsRenewedByStartingClaudeCode() async {
        let claudeCode = ClaudeCodeFake(item: .found(dead), renewsTo: fresh)
        let cache = ClaudeCredentialsCache()

        let snapshot = await provider(claudeCode, gate: ClaudeRenewalGate(), binary: binary, at: now, cache: cache).fetch()

        XCTAssertEqual(snapshot.state, .ok)
        XCTAssertEqual(snapshot.buckets.map(\.id), ["five_hour"])
        XCTAssertEqual(claudeCode.starts, [binary])
        XCTAssertEqual(UsageEndpointStub.tokensAsked, ["dead", "fresh"])
        XCTAssertEqual(cache.load(), fresh, "kept in memory for the next poll")
        XCTAssertTrue(
            UsageEndpointStub.urlsAsked.allSatisfy { $0 == ClaudeOAuthProvider.usageURL },
            "the usage endpoint only: Omelette never asks for a token"
        )
    }

    func testAStartThatRenewsNothingLeavesTheSignInExpired() async {
        let claudeCode = ClaudeCodeFake(item: .found(dead))

        let snapshot = await provider(claudeCode, gate: ClaudeRenewalGate(), binary: binary, at: now).fetch()

        XCTAssertEqual(snapshot.state, .notSignedIn)
        XCTAssertEqual(snapshot.signedOutReason, .expired)
        XCTAssertEqual(snapshot.stateMessage, ClaudeSignInCopy.expiredMessage)
        XCTAssertEqual(claudeCode.starts.count, 1)
        XCTAssertEqual(UsageEndpointStub.tokensAsked, ["dead"])
        XCTAssertEqual(ClaudeSignInCopy.recovery(for: snapshot, binaryFound: true), .signIn, "the Sign in button waits")
    }

    func testARenewedTokenTheServerStillRefusesLeavesTheSignInExpired() async {
        UsageEndpointStub.reset(live: [])
        let claudeCode = ClaudeCodeFake(item: .found(dead), renewsTo: fresh)

        let snapshot = await provider(claudeCode, gate: ClaudeRenewalGate(), binary: binary, at: now).fetch()

        XCTAssertEqual(snapshot.state, .notSignedIn)
        XCTAssertEqual(snapshot.signedOutReason, .expired)
        XCTAssertEqual(UsageEndpointStub.tokensAsked, ["dead", "fresh"])
        XCTAssertEqual(ClaudeSignInCopy.recovery(for: snapshot, binaryFound: true), .signIn, "the Sign in button waits")
    }

    func testARateLimitAfterRenewalKeepsTheServersRetryAfter() async {
        UsageEndpointStub.reset(live: [], limited: ["fresh"])
        let claudeCode = ClaudeCodeFake(item: .found(dead), renewsTo: fresh)

        let snapshot = await provider(claudeCode, gate: ClaudeRenewalGate(), binary: binary, at: now).fetch()

        XCTAssertEqual(snapshot.retryAfter, 300)
        XCTAssertEqual(UsageEndpointStub.tokensAsked, ["dead", "fresh"])
    }

    func testALockedKeychainStartsNothing() async {
        let claudeCode = ClaudeCodeFake(item: .found(dead), renewsTo: fresh, unlocked: false)

        let snapshot = await provider(claudeCode, gate: ClaudeRenewalGate(), binary: binary, at: now).fetch()

        XCTAssertEqual(snapshot.signedOutReason, .expired)
        XCTAssertTrue(claudeCode.starts.isEmpty, "Claude Code's own read would raise the password dialog")
    }

    func testAnItemSecurityMayNotReadStartsNothing() async {
        let claudeCode = ClaudeCodeFake(item: .found(dead), renewsTo: fresh, securityRefused: true)

        let snapshot = await provider(claudeCode, gate: ClaudeRenewalGate(), binary: binary, at: now).fetch()

        XCTAssertEqual(snapshot.signedOutReason, .expired)
        XCTAssertTrue(claudeCode.starts.isEmpty, "Claude Code's own read would raise the Allow/Deny dialog")
    }

    func testWithoutClaudeCodeNothingStarts() async {
        let claudeCode = ClaudeCodeFake(item: .found(dead), renewsTo: fresh)

        let snapshot = await provider(claudeCode, gate: ClaudeRenewalGate(), binary: nil, at: now).fetch()

        XCTAssertEqual(snapshot.signedOutReason, .expired)
        XCTAssertTrue(claudeCode.starts.isEmpty)
    }

    func testRepeatedFailingPollsStartClaudeCodeOncePerFiveMinutes() async {
        let claudeCode = ClaudeCodeFake(item: .found(dead))
        let gate = ClaudeRenewalGate()
        for offset: TimeInterval in [0, 60, 120, 299] {
            _ = await provider(claudeCode, gate: gate, binary: binary, at: now.addingTimeInterval(offset)).fetch()
        }
        XCTAssertEqual(claudeCode.starts.count, 1)

        _ = await provider(claudeCode, gate: gate, binary: binary, at: now.addingTimeInterval(300)).fetch()
        XCTAssertEqual(claudeCode.starts.count, 2)
    }

    func testAPendingSignInFromTheButtonHoldsRenewal() async {
        let claudeCode = ClaudeCodeFake(item: .found(dead), renewsTo: fresh)
        let gate = ClaudeRenewalGate()
        await gate.signInLaunched(at: now)

        let snapshot = await provider(claudeCode, gate: gate, binary: binary, at: now.addingTimeInterval(60)).fetch()

        XCTAssertEqual(snapshot.signedOutReason, .expired)
        XCTAssertTrue(claudeCode.starts.isEmpty, "the user is signing in in Terminal")
    }

    func testAGoodReadingEndsThePendingSignIn() async {
        let claudeCode = ClaudeCodeFake(item: .found(fresh))
        let gate = ClaudeRenewalGate()
        await gate.signInLaunched(at: now)

        let snapshot = await provider(claudeCode, gate: gate, binary: binary, at: now.addingTimeInterval(60)).fetch()

        XCTAssertEqual(snapshot.state, .ok)
        let pending = await gate.isSignInPending(now: now.addingTimeInterval(61))
        XCTAssertFalse(pending)
    }

    func testATokenClaudeCodeAlreadyRotatedNeedsNoStart() async {
        // The server turned down a token whose own clock says it is live; Claude Code holds a newer one.
        let revoked = oauth("revoked", expiresAt: nowMS + 3_600_000)
        let cache = ClaudeCredentialsCache()
        cache.save(revoked)
        let claudeCode = ClaudeCodeFake(item: .found(fresh))

        let snapshot = await provider(claudeCode, gate: ClaudeRenewalGate(), binary: binary, at: now, cache: cache).fetch()

        XCTAssertEqual(snapshot.state, .ok)
        XCTAssertTrue(claudeCode.starts.isEmpty)
        XCTAssertEqual(UsageEndpointStub.tokensAsked, ["revoked", "fresh"])
    }
}
