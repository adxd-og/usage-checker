import XCTest
@testable import Omelette

/// The usage endpoint answering 200 with one session window, whatever the token.
private final class VerifyPlanEndpointStub: URLProtocol {
    private static let payload = #"{"five_hour":{"utilization":7.0,"resets_at":"2026-10-04T12:49:59+00:00"}}"#

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url ?? ClaudeOAuthProvider.usageURL, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Verification of the Claude plan name taken from Claude Code's `~/.claude.json`: shapes the
/// file can take that are not the happy one, the tier rule end to end through the reader, a
/// file that moves (renamed over, created late, behind a symlink), and the provider's other
/// snapshot fields staying as they were. Every file lives in a temp dir.
final class ClaudePlanNameVerificationTests: XCTestCase {
    private var directory: URL!
    private var configURL: URL { directory.appendingPathComponent(".claude.json") }
    private let t1 = Date(timeIntervalSince1970: 1_793_000_000)
    private let t2 = Date(timeIntervalSince1970: 1_793_000_060)
    private let now = Date(timeIntervalSince1970: 1_793_100_000)
    private let ultra20x = "default_claude_max_20x"
    private let max5x = "default_claude_max_5x"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudePlanNameVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ text: String, to url: URL? = nil, modified: Date) throws {
        let url = url ?? configURL
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    private func file(account: String) -> String { #"{"numStartups":1,"oauthAccount":\#(account)}"# }

    private func plan(fileAccount: ClaudeCodeAccount?, credentialTier: String?) -> String {
        ClaudePlanName.plan(configAccount: fileAccount, subscriptionType: "max", rateLimitTier: credentialTier)
    }

    // MARK: - Files that are not the happy shape mean the mapping

    func testEveryBrokenShapeOfTheFileReadsAsNoAccountAndTheMappingShows() async throws {
        let shapes: [(String, String)] = [
            ("empty file", ""),
            ("top level array", "[]"),
            ("top level string", #""oauthAccount""#),
            ("empty object", "{}"),
            ("oauthAccount null", file(account: "null")),
            ("oauthAccount string", file(account: #""Ultra""#)),
            ("oauthAccount array", file(account: "[]")),
            ("planDisplayName a number", file(account: #"{"planDisplayName":5,"organizationRateLimitTier":"default_claude_max_20x"}"#)),
            ("planDisplayName an object", file(account: #"{"planDisplayName":{},"organizationRateLimitTier":"default_claude_max_20x"}"#)),
            ("tier a number", file(account: #"{"planDisplayName":"Apex","organizationRateLimitTier":20}"#)),
            ("tier an array", file(account: #"{"planDisplayName":"Apex","organizationRateLimitTier":["default_claude_max_20x"]}"#)),
            ("a byte order mark and a stray byte", "\u{FEFF}{\u{0}"),
        ]
        for (label, text) in shapes {
            try write(text, modified: t1)
            let account = await ClaudeCodeAccountReader(fileURL: configURL).account()
            XCTAssertNil(account, label)
            XCTAssertEqual(plan(fileAccount: account, credentialTier: ultra20x), "Claude Ultra", label)
        }
    }

    func testADirectoryWhereTheFileShouldBeReadsAsNoAccount() async throws {
        try FileManager.default.createDirectory(at: configURL, withIntermediateDirectories: true)

        let account = await ClaudeCodeAccountReader(fileURL: configURL).account()

        XCTAssertNil(account)
    }

    // MARK: - The tier rule, from the file's real shape

    func testAUserTierWithoutAnOrganizationTierDoesNotMakeAMatch() async throws {
        // The spec counts `organizationRateLimitTier` only.
        try write(
            file(account: #"{"planDisplayName":"Apex","organizationRateLimitTier":null,"userRateLimitTier":"default_claude_max_20x"}"#),
            modified: t1
        )

        let account = await ClaudeCodeAccountReader(fileURL: configURL).account()

        XCTAssertEqual(plan(fileAccount: account, credentialTier: ultra20x), "Claude Ultra")
    }

    func testAMatchingTierWithANullNameShowsTheMapping() async throws {
        try write(
            file(account: #"{"planDisplayName":null,"organizationRateLimitTier":"default_claude_max_5x"}"#),
            modified: t1
        )

        let account = await ClaudeCodeAccountReader(fileURL: configURL).account()

        XCTAssertEqual(plan(fileAccount: account, credentialTier: max5x), "Claude Max")
    }

    func testTheFilesNameIsUsedWhenItsTierIsTheCredentialsAndNotWhenItIsNot() async throws {
        try write(
            file(account: #"{"planDisplayName":"Apex","organizationRateLimitTier":"default_claude_max_20x","userRateLimitTier":null}"#),
            modified: t1
        )

        let account = await ClaudeCodeAccountReader(fileURL: configURL).account()

        XCTAssertEqual(plan(fileAccount: account, credentialTier: ultra20x), "Claude Apex")
        XCTAssertEqual(plan(fileAccount: account, credentialTier: max5x), "Claude Max")
        XCTAssertEqual(plan(fileAccount: account, credentialTier: nil), "Claude Max")
    }

    func testANameWrappedInWhitespaceThatSaysClaudeIsStillKeptAsIs() {
        let account = ClaudeCodeAccount(planDisplayName: "  Claude Ultra \n", organizationRateLimitTier: ultra20x)
        XCTAssertEqual(plan(fileAccount: account, credentialTier: ultra20x), "Claude Ultra")
    }

    // MARK: - The file moves

    func testAFileCreatedAfterAMissedReadIsReadOnTheNextPoll() async throws {
        let reader = ClaudeCodeAccountReader(fileURL: configURL)
        let before = await reader.account()
        XCTAssertNil(before)

        try write(
            file(account: #"{"planDisplayName":"Ultra","organizationRateLimitTier":"default_claude_max_20x"}"#),
            modified: t1
        )
        let after = await reader.account()

        XCTAssertEqual(after?.planDisplayName, "Ultra")
    }

    func testABrokenFileMendedByClaudeCodeIsReadAgain() async throws {
        let reader = ClaudeCodeAccountReader(fileURL: configURL)
        try write(#"{"oauthAccount":{"planDisplayName":"Ul"#, modified: t1)
        let broken = await reader.account()
        XCTAssertNil(broken)

        try write(
            file(account: #"{"planDisplayName":"Ultra","organizationRateLimitTier":"default_claude_max_20x"}"#),
            modified: t2
        )
        let mended = await reader.account()

        XCTAssertEqual(mended?.planDisplayName, "Ultra")
    }

    func testAFileThatReadAsNoAccountIsNotParsedAgainWhileItsDateAndSizeStandStill() async throws {
        // Memory holds the nil too: a file Claude Code left broken or signed out is not parsed on
        // every poll. The same-length valid text under the same date proves no second parse.
        let valid = file(account: #"{"planDisplayName":"Ultra","organizationRateLimitTier":"x"}"#)
        let broken = String(valid.dropLast()) + "X"
        let reader = ClaudeCodeAccountReader(fileURL: configURL)
        try write(broken, modified: t1)
        let first = await reader.account()

        try write(valid, modified: t1)
        let second = await reader.account()

        XCTAssertNil(first)
        XCTAssertNil(second)
    }

    func testAFileRenamedOverTheOldOneIsReadAgain() async throws {
        // How an editor or a careful writer saves: a temp file moved over the name.
        let reader = ClaudeCodeAccountReader(fileURL: configURL)
        try write(
            file(account: #"{"planDisplayName":"Ultra","organizationRateLimitTier":"default_claude_max_20x"}"#),
            modified: t1
        )
        _ = await reader.account()

        let temporary = directory.appendingPathComponent(".claude.json.tmp")
        try write(
            file(account: #"{"planDisplayName":"Apex","organizationRateLimitTier":"default_claude_max_20x"}"#),
            to: temporary, modified: t2
        )
        _ = try FileManager.default.replaceItemAt(configURL, withItemAt: temporary)
        let account = await reader.account()

        XCTAssertEqual(account?.planDisplayName, "Apex")
    }

    func testAFileSignedOutAfterBeingSignedInReadsAsNoAccountAgain() async throws {
        let reader = ClaudeCodeAccountReader(fileURL: configURL)
        try write(
            file(account: #"{"planDisplayName":"Ultra","organizationRateLimitTier":"default_claude_max_20x"}"#),
            modified: t1
        )
        let signedIn = await reader.account()
        XCTAssertEqual(signedIn?.planDisplayName, "Ultra")

        try write(#"{"numStartups":2}"#, modified: t2)
        let signedOut = await reader.account()

        XCTAssertNil(signedOut)
    }

    func testAStateFileBehindASymlinkIsReadAgainWhenTheTargetIsRewritten() async throws {
        // Dotfile managers keep `~/.claude.json` as a link. The link itself never changes; the
        // file it points at does, and the spec asks for a new parse when the file's date or
        // size moved.
        let target = directory.appendingPathComponent("dotfiles-claude.json")
        try write(
            file(account: #"{"planDisplayName":"Ultra","organizationRateLimitTier":"default_claude_max_20x"}"#),
            to: target, modified: t1
        )
        try FileManager.default.createSymbolicLink(at: configURL, withDestinationURL: target)
        let reader = ClaudeCodeAccountReader(fileURL: configURL)
        let first = await reader.account()
        XCTAssertEqual(first?.planDisplayName, "Ultra")

        try write(
            file(account: #"{"planDisplayName":"Apex","organizationRateLimitTier":"default_claude_max_20x"}"#),
            to: target, modified: t2
        )
        let second = await reader.account()

        XCTAssertEqual(second?.planDisplayName, "Apex")
    }

    // MARK: - Through the provider

    private func fetch(credentialTier: String, reader: ClaudeCodeAccountReader) async throws -> ServiceSnapshot {
        let expiresAt = (now.timeIntervalSince1970 + 8 * 3600) * 1000
        let json = """
        {"claudeAiOauth":{"accessToken":"live","refreshToken":"r","expiresAt":\(expiresAt),
         "scopes":["user:inference"],"subscriptionType":"max","rateLimitTier":"\(credentialTier)"}}
        """
        let oauth = try JSONDecoder().decode(ClaudeCredentials.self, from: Data(json.utf8)).claudeAiOauth
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VerifyPlanEndpointStub.self]
        let at = now
        return await ClaudeOAuthProvider(
            http: HTTPClient(session: URLSession(configuration: configuration)),
            cache: ClaudeCredentialsCache(),
            sources: ClaudeCredentialSources(
                file: { nil }, item: { .found(oauth) }, itemViaSecurityTool: { .found(oauth) }, keychainUnlocked: { true }
            ),
            renewal: ClaudeRenewal(gate: ClaudeRenewalGate(), locateBinary: { nil }, start: { _ in }),
            accountReader: reader,
            now: { at }
        ).fetch()
    }

    func testOnlyThePlanMovesWhenTheFileCountsAndTheProviderIsBuiltAfreshEveryPoll() async throws {
        try write(
            file(account: #"{"planDisplayName":"Apex","organizationRateLimitTier":"default_claude_max_20x"}"#),
            modified: t1
        )
        let reader = ClaudeCodeAccountReader(fileURL: configURL)
        let absent = ClaudeCodeAccountReader(fileURL: directory.appendingPathComponent("absent.json"))

        let named = try await fetch(credentialTier: ultra20x, reader: reader)
        let mapped = try await fetch(credentialTier: ultra20x, reader: absent)

        XCTAssertEqual(named.plan, "Claude Apex")
        XCTAssertEqual(mapped.plan, "Claude Ultra")
        // Nothing but the plan differs.
        let renamed = ServiceSnapshot(
            id: mapped.id, displayName: mapped.displayName, icon: mapped.icon, plan: "Claude Apex",
            accountLabel: mapped.accountLabel, buckets: mapped.buckets, extraUsage: mapped.extraUsage,
            weekCost: mapped.weekCost, state: mapped.state, stateMessage: mapped.stateMessage,
            fetchedAt: mapped.fetchedAt, retryAfter: mapped.retryAfter, isCarriedOver: mapped.isCarriedOver,
            signedOutReason: mapped.signedOutReason
        )
        XCTAssertEqual(named, renamed)
        XCTAssertEqual(named.buckets.count, 1)

        // A later poll, a new provider, the same reader: Anthropic's rename shows with no release.
        try write(
            file(account: #"{"planDisplayName":"Zenith","organizationRateLimitTier":"default_claude_max_20x"}"#),
            modified: t2
        )
        let renamedLater = try await fetch(credentialTier: ultra20x, reader: reader)
        XCTAssertEqual(renamedLater.plan, "Claude Zenith")
    }
}
