import XCTest
@testable import Omelette

/// Spec 2026-10-25 (Claude switch and sign-in) § Design › Package 2, Sign in: the provider says
/// why Claude is signed out — not signed in, keychain permission, unreadable, expired — where
/// it used to swallow the read and decode errors (`try?`), and keeps today's order of sources:
/// the copy in memory, Claude Code's credentials file, then its keychain item (the direct
/// silent read, then the same item through `/usr/bin/security`). Sources are closures here;
/// nothing touches a keychain or the network.
final class ClaudeSignedOutReasonTests: XCTestCase {
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

    private var live: ClaudeCredentials.OAuth { oauth("live", expiresAt: nowMS + 3_600_000) }
    private var stale: ClaudeCredentials.OAuth { oauth("stale", expiresAt: nowMS - 3_600_000) }
    private var newer: ClaudeCredentials.OAuth { oauth("newer", expiresAt: nowMS + 7_200_000) }

    /// How often each source was asked.
    private final class Asked { var file = 0; var item = 0; var security = 0 }

    /// The provider's sources, as closures over fixed answers. The renewal guard's two reads
    /// say no: these tests never reach a renewal.
    private func sources(file: ClaudeCredentials.OAuth?, item: ClaudeSourceRead) -> ClaudeCredentialSources {
        ClaudeCredentialSources(
            file: { file }, item: { item }, itemViaSecurityTool: { .refused }, keychainUnlocked: { false }
        )
    }

    // MARK: - Which credentials a poll uses

    func testALiveCopyInMemoryIsUsedWithoutAskingClaudeCode() {
        let asked = Asked()
        let result = ClaudeOAuthProvider.resolve(
            cached: live, now: now,
            file: { asked.file += 1; return nil },
            item: { asked.item += 1; return .absent }
        )
        XCTAssertEqual(result, .use(live, fromSource: false))
        XCTAssertEqual(asked.file + asked.item, 0)
    }

    func testAStaleCopyGivesWayToANewerItem() {
        let newer = self.newer
        XCTAssertEqual(
            ClaudeOAuthProvider.resolve(cached: stale, now: now, file: { nil }, item: { .found(newer) }),
            .use(newer, fromSource: true)
        )
    }

    func testAStaleCopyStillBeatsNothingTheUsageAPIDecides() {
        XCTAssertEqual(
            ClaudeOAuthProvider.resolve(cached: stale, now: now, file: { nil }, item: { .refused }),
            .use(stale, fromSource: false)
        )
    }

    func testTheCredentialsFileAloneIsEnough() {
        let live = self.live
        XCTAssertEqual(
            ClaudeOAuthProvider.resolve(cached: nil, now: now, file: { live }, item: { .refused }),
            .use(live, fromSource: true)
        )
    }

    func testNoSignInAnywhereIsNotFound() {
        XCTAssertEqual(
            ClaudeOAuthProvider.resolve(cached: nil, now: now, file: { nil }, item: { .absent }),
            .signedOut(.notFound, message: ClaudeSignInCopy.notFoundMessage)
        )
    }

    func testAnItemOmeletteMayNotReadIsDenied() {
        XCTAssertEqual(
            ClaudeOAuthProvider.resolve(cached: nil, now: now, file: { nil }, item: { .refused }),
            .signedOut(.denied, message: ClaudeSignInCopy.deniedMessage)
        )
    }

    func testAnItemThatCannotBeReadIsUnreadableInItsOwnWords() {
        let words = "Keychain read failed (status -25300)"
        XCTAssertEqual(
            ClaudeOAuthProvider.resolve(cached: nil, now: now, file: { nil }, item: { .unreadable(words) }),
            .signedOut(.unreadable, message: words)
        )
    }

    // MARK: - The item: direct read, then security

    func testTheDirectReadAnswersAloneWhenItFindsTheItem() {
        let asked = Asked()
        XCTAssertEqual(ClaudeSourceRead.combining(direct: .found(live), security: { asked.security += 1; return .refused }), .found(live))
        XCTAssertEqual(asked.security, 0)
    }

    func testAnAbsentItemIsNotAskedForTwice() {
        let asked = Asked()
        XCTAssertEqual(ClaudeSourceRead.combining(direct: .absent, security: { asked.security += 1; return .refused }), .absent)
        XCTAssertEqual(asked.security, 0)
    }

    func testSecurityReadsAnItemTheDirectReadWasRefused() {
        let live = self.live
        XCTAssertEqual(ClaudeSourceRead.combining(direct: .refused, security: { .found(live) }), .found(live))
    }

    func testRefusedTwiceIsRefused() {
        XCTAssertEqual(ClaudeSourceRead.combining(direct: .refused, security: { .refused }), .refused)
    }

    func testSecurityFindingNoSignInAnswersARefusedDirectRead() {
        XCTAssertEqual(ClaudeSourceRead.combining(direct: .refused, security: { .absent }), .absent)
    }

    func testAnUnreadableItemStaysUnreadable() {
        XCTAssertEqual(ClaudeSourceRead.combining(direct: .unreadable("decode"), security: { .absent }), .unreadable("decode"))
    }

    func testSecurityCanFindTheItemUnreadable() {
        XCTAssertEqual(ClaudeSourceRead.combining(direct: .refused, security: { .unreadable("parse") }), .unreadable("parse"))
    }

    // MARK: - After a 401

    func testTheNewestReadingWinsAndTheFileWinsATie() {
        XCTAssertEqual(ClaudeOAuthProvider.newest(file: live, item: .found(newer)), newer)
        let sameExpiry = oauth("from-item", expiresAt: live.expiresAt)
        XCTAssertEqual(ClaudeOAuthProvider.newest(file: live, item: .found(sameExpiry)), live)
        XCTAssertNil(ClaudeOAuthProvider.newest(file: nil, item: .refused))
    }

    // MARK: - The provider

    func testTheProviderSaysWhyClaudeIsSignedOut() async {
        let at = now
        let cases: [(ClaudeSourceRead, SignedOutReason, String)] = [
            (.absent, .notFound, ClaudeSignInCopy.notFoundMessage),
            (.refused, .denied, ClaudeSignInCopy.deniedMessage),
            (.unreadable("Could not parse credentials: x"), .unreadable, "Could not parse credentials: x"),
        ]
        for (item, reason, message) in cases {
            let snapshot = await ClaudeOAuthProvider(
                cache: ClaudeCredentialsCache(), sources: sources(file: nil, item: item), now: { at }
            ).fetch()
            XCTAssertEqual(snapshot.state, .notSignedIn, "\(reason)")
            XCTAssertEqual(snapshot.signedOutReason, reason)
            XCTAssertEqual(snapshot.stateMessage, message)
            XCTAssertEqual(snapshot.fetchedAt, at)
        }
    }

    /// The spec's test: each source state, with and without the last numbers kept beside it,
    /// ends in the way out the UI offers.
    func testEachSourceStateEndsInItsWayOutWithAndWithoutKeptNumbers() async {
        let at = now
        let earlier = now.addingTimeInterval(-600)
        let kept = Fixture.snapshot(
            id: "claude", displayName: "Claude",
            buckets: [Fixture.bucket(id: "five_hour", label: "Current session", percent: 40, kind: .session)],
            at: earlier
        )
        let cases: [(ClaudeSourceRead, ClaudeRecovery)] = [
            (.absent, .signIn), (.refused, .keychainAccess), (.unreadable("Keychain read failed (status -25300)"), .noAction),
        ]
        for (item, recovery) in cases {
            let fresh = await ClaudeOAuthProvider(
                cache: ClaudeCredentialsCache(), sources: sources(file: nil, item: item), now: { at }
            ).fetch()
            for previous in [UsageSnapshot.empty, UsageSnapshot(services: [kept], fetchedAt: earlier, isStale: false, lastError: nil)] {
                let shown = AppState.mergingPoll(
                    previous: previous,
                    next: UsageSnapshot(services: [fresh], fetchedAt: at, isStale: false, lastError: nil)
                ).services[0]
                XCTAssertEqual(shown.isRetained, !previous.services.isEmpty)
                XCTAssertEqual(ClaudeSignInCopy.recovery(for: shown, binaryFound: true), recovery, "\(item)")
            }
        }
    }
}
