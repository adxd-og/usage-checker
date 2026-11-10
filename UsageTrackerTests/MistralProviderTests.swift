import AppKit
import XCTest
@testable import Omelette

/// Spec 2026-11-10 Mistral provider § Fetch, § States and Decisions 3. The provider reads vibe's
/// key, asks billing, and shows each answer as the States table says: Not signed in without a
/// key (nothing asked), Signed out on a 401 with the last numbers kept by retention, the plan
/// with no windows on a 403 (No usage access) or a 404, an error otherwise, and a 429's
/// Retry-After for the backoff. It keeps an answer 60 s, and the key reaches neither the
/// snapshot nor `status.json`, which stays version 2.
final class MistralProviderTests: XCTestCase {
    private typealias Answer = MistralFixture.Answer
    private let now = MistralFixture.now

    /// A key the injected keychain read hands over, and an `.env` path that never exists.
    private func provider(
        key: String? = MistralFixture.key,
        subscription: Answer? = Answer(status: 200, body: MistralFixture.subscriptionBody),
        budget: Answer? = Answer(status: 200, body: MistralFixture.budgetBody),
        requests: MistralFixture.Requests? = nil
    ) -> MistralProvider {
        MistralProvider(
            credentials: MistralCredentialReader(
                keychain: { key },
                envFileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("MistralProviderTests-\(UUID().uuidString)/.env")
            ),
            fetcher: MistralBillingFetcher(
                transport: MistralFixture.transport(subscription: subscription, budget: budget, requests: requests)
            )
        )
    }

    func testTheLiveAnswerIsAProPlanWithVibeAndAPIWindows() async throws {
        let snapshot = await provider().fetch(now: now)
        XCTAssertEqual(snapshot.id, "mistral")
        XCTAssertEqual(snapshot.displayName, "Mistral")
        XCTAssertEqual(snapshot.icon, "cat")
        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertEqual(snapshot.state, .ok)
        XCTAssertNil(snapshot.stateMessage)
        XCTAssertEqual(snapshot.fetchedAt, now)
        XCTAssertEqual(snapshot.buckets.map(\.id), ["mistral_vibe", "mistral_api"])
        XCTAssertEqual(snapshot.buckets.map(\.label), ["Vibe", "API"])
        XCTAssertEqual(snapshot.buckets.map(\.utilization), [5.9597507033333335, 0])
        XCTAssertEqual(snapshot.buckets.map(\.resetsAt), [MistralFixture.resetAt, MistralFixture.resetAt])
        let vibe = try XCTUnwrap(snapshot.buckets.first?.allowance)
        XCTAssertEqual(vibe.usedDollars, 17.879, accuracy: 0.001)
        XCTAssertEqual(vibe.limitDollars, 300)
        XCTAssertEqual(snapshot.headlinePercent, 5.9597507033333335)
    }

    func testNoKeyAnywhereIsNotSignedInAndAsksNothing() async {
        let requests = MistralFixture.Requests()
        let snapshot = await provider(key: nil, requests: requests).fetch(now: now)
        XCTAssertEqual(snapshot.state, .notSignedIn)
        XCTAssertEqual(snapshot.signedOutReason, .notFound)
        XCTAssertEqual(snapshot.stateMessage, MistralCopy.notSignedInMessage)
        XCTAssertNil(snapshot.plan)
        XCTAssertTrue(snapshot.buckets.isEmpty)
        let seen = await requests.seen
        XCTAssertTrue(seen.isEmpty, "no key, no request; an OIDC-only sign-in reads the same")
    }

    func testA401IsSignedOut() async {
        let snapshot = await provider(budget: Answer(status: 401, body: "{}")).fetch(now: now)
        XCTAssertEqual(snapshot.state, .notSignedIn)
        XCTAssertEqual(snapshot.signedOutReason, .expired)
        XCTAssertEqual(snapshot.stateMessage, MistralCopy.signedOutMessage)
        XCTAssertTrue(snapshot.buckets.isEmpty)
    }

    func testA403KeepsThePlanWithNoWindowsAndSaysNoUsageAccess() async {
        let snapshot = await provider(budget: Answer(status: 403, body: #"{"detail":"forbidden"}"#)).fetch(now: now)
        XCTAssertEqual(snapshot.state, .error)
        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertTrue(snapshot.buckets.isEmpty)
        XCTAssertEqual(snapshot.stateMessage, MistralCopy.noUsageAccessMessage)
    }

    func testA404OrNoBudgetKeyIsThePlanWithNoWindowsAndNoError() async {
        let answers = [Answer(status: 404, body: "{}"), Answer(status: 200, body: #"{"usage_percentage":0.0}"#)]
        for budget in answers {
            let snapshot = await provider(budget: budget).fetch(now: now)
            XCTAssertEqual(snapshot.state, .ok, "\(budget.status)")
            XCTAssertEqual(snapshot.plan, "Pro")
            XCTAssertTrue(snapshot.buckets.isEmpty)
            XCTAssertNil(snapshot.stateMessage)
        }
    }

    func testA429HonoursRetryAfterThroughTheBackoff() async {
        let stated = await provider(budget: Answer(status: 429, body: "{}", headers: ["Retry-After": "30"])).fetch(now: now)
        XCTAssertEqual(stated.state, .error)
        XCTAssertEqual(stated.stateMessage, MistralCopy.rateLimitedMessage)
        XCTAssertEqual(stated.retryAfter, 30)
        let unstated = await provider(budget: Answer(status: 429, body: "{}")).fetch(now: now)
        XCTAssertEqual(unstated.retryAfter, 60, "no header: a minute, as Claude's")
    }

    func testAServerOrNetworkFailureIsAnErrorWhoseLastNumbersStayDimmed() async {
        let good = await provider().fetch(now: now)
        let failed = await provider(budget: Answer(status: 503, body: "")).fetch(now: now.addingTimeInterval(120))
        XCTAssertEqual(failed.state, .error)
        XCTAssertEqual(failed.stateMessage, "HTTP 503 (service unavailable)")
        let offline = await provider(budget: nil).fetch(now: now)
        XCTAssertEqual(offline.state, .error)
        XCTAssertFalse(offline.stateMessage?.isEmpty ?? true)

        let shown = AppState.retainingLastGoodServices(
            previous: UsageSnapshot(services: [good], fetchedAt: now, isStale: false, lastError: nil),
            next: UsageSnapshot(services: [failed], fetchedAt: now.addingTimeInterval(120), isStale: false, lastError: nil)
        )
        let kept = shown.services.first
        XCTAssertEqual(kept?.buckets.map(\.id), ["mistral_vibe", "mistral_api"])
        XCTAssertEqual(kept?.isRetained, true)
        XCTAssertEqual(kept?.plan, "Pro")
    }

    func testTheLastAnswerIsKeptForSixtySeconds() async {
        let requests = MistralFixture.Requests()
        let mistral = provider(requests: requests)
        _ = await mistral.fetch(now: now)
        _ = await mistral.fetch(now: now.addingTimeInterval(59))
        var seen = await requests.seen
        XCTAssertEqual(seen.count, 2, "one poll is two calls; a second poll inside 60 s asks nothing")
        _ = await mistral.fetch(now: now.addingTimeInterval(60))
        seen = await requests.seen
        XCTAssertEqual(seen.count, 4)
        XCTAssertEqual(MistralProvider.minFetchInterval, 60)
    }

    func testTheKeyNeverReachesTheSnapshotOrStatusJSON() async throws {
        let answers: [Answer?] = [
            Answer(status: 200, body: MistralFixture.budgetBody), Answer(status: 401, body: "{}"),
            Answer(status: 403, body: "{}"), Answer(status: 503, body: ""), nil,
        ]
        for budget in answers {
            let snapshot = await provider(budget: budget).fetch(now: now)
            XCTAssertFalse(String(describing: snapshot).contains(MistralFixture.key), "\(snapshot.state)")
            let file = StatusFileWriter.build(services: [snapshot], costs: [:], agents: .none, now: now)
            XCTAssertEqual(file.version, 2, "a new service id is additive")
            XCTAssertEqual(file.services.map(\.id), ["mistral"])
            let json = String(decoding: try StatusFile.encoder.encode(file), as: UTF8.self)
            XCTAssertFalse(json.contains(MistralFixture.key), "\(snapshot.state)")
        }
    }

    func testTheSwitchDefaultsOnOnlyWhereVibeHasAHome() {
        let home = URL(fileURLWithPath: "/tmp/home", isDirectory: true)
        XCTAssertTrue(MistralProvider.vibeHomeExists(home: home) { $0 == "/tmp/home/.vibe" })
        XCTAssertFalse(MistralProvider.vibeHomeExists(home: home) { _ in false })
    }

    func testWithoutTheBundledMarkTheTileDrawsTheCatSymbol() {
        XCTAssertEqual(MistralProvider.icon, "cat")
        XCTAssertNotNil(NSImage(systemSymbolName: MistralProvider.icon, accessibilityDescription: nil))
    }
}
