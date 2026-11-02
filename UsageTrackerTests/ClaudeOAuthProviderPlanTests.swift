import XCTest
@testable import Omelette

/// The usage endpoint answering 200 with one session window, whatever the token.
private final class PlanEndpointStub: URLProtocol {
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

/// The Claude snapshot's `plan` through the provider: Claude Code's `planDisplayName` from its
/// state file when the file's rate-limit tier is the polled credential's, the
/// `SubscriptionTier` mapping when it is not. The state file sits in a temp dir; "Apex" is a
/// name the mapping cannot produce.
final class ClaudeOAuthProviderPlanTests: XCTestCase {
    private var directory: URL!
    private var configURL: URL { directory.appendingPathComponent(".claude.json") }
    private let now = Date(timeIntervalSince1970: 1_793_100_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeOAuthProviderPlanTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"""
        {"numStartups":412,"oauthAccount":{"organizationType":"claude_max",
         "organizationRateLimitTier":"default_claude_max_20x","userRateLimitTier":null,"planDisplayName":"Apex"}}
        """#.utf8).write(to: configURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func fetch(credentialTier: String) async throws -> ServiceSnapshot {
        let expiresAt = (now.timeIntervalSince1970 + 8 * 3600) * 1000
        let json = """
        {"claudeAiOauth":{"accessToken":"live","refreshToken":"r","expiresAt":\(expiresAt),
         "scopes":["user:inference"],"subscriptionType":"max","rateLimitTier":"\(credentialTier)"}}
        """
        let oauth = try JSONDecoder().decode(ClaudeCredentials.self, from: Data(json.utf8)).claudeAiOauth
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlanEndpointStub.self]
        let at = now
        return await ClaudeOAuthProvider(
            http: HTTPClient(session: URLSession(configuration: configuration)),
            cache: ClaudeCredentialsCache(),
            sources: ClaudeCredentialSources(
                file: { nil }, item: { .found(oauth) }, itemViaSecurityTool: { .found(oauth) }, keychainUnlocked: { true }
            ),
            renewal: ClaudeRenewal(gate: ClaudeRenewalGate(), locateBinary: { nil }, start: { _ in }),
            accountReader: ClaudeCodeAccountReader(fileURL: configURL),
            now: { at }
        ).fetch()
    }

    func testThePlanIsClaudeCodesNameWhenTheTiersMatch() async throws {
        let snapshot = try await fetch(credentialTier: "default_claude_max_20x")

        XCTAssertEqual(snapshot.state, .ok)
        XCTAssertEqual(snapshot.plan, "Claude Apex")
    }

    func testThePlanIsTheMappingWhenTheTiersDiffer() async throws {
        let snapshot = try await fetch(credentialTier: "default_claude_max_5x")

        XCTAssertEqual(snapshot.state, .ok)
        XCTAssertEqual(snapshot.plan, "Claude Max")
    }
}
