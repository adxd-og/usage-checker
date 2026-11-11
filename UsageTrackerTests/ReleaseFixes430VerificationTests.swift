import Foundation
import XCTest
@testable import Omelette

/// Verification of the 4.3.0 release fix round, one block per ruling:
/// A. `MistralProvider` keeps a 429 for max(60 s, min(Retry-After, 300 s)), every other answer
///    60 s, and nothing it returns carries a `retryAfter` (Mistral spec § States, the 429 row).
/// B. `~/.vibe/.env` is opened only as a regular file of at most 64 KB, symlinks followed
///    (Mistral spec § Credential).
/// C. A label and id from a `_budget` key, and a plan name, lose every `Cc` scalar; nothing left
///    is no window and no chip; an allowance needs finite figures (Mistral spec § Windows).
/// D. `NetworkCachePolicy.purge` removes nothing unless the bundle id is one path component
///    (no-URL-cache spec § Purge).
/// Real temp directories per test; no real home, keychain, Caches or network. The FIFO case is
/// left to `MistralCredentialReaderTests`, and no device node is opened here (on this macOS
/// `Data(contentsOf:)` itself fails on a FIFO or a device, so the reader's regular-file test
/// changes no answer a test can see).
final class ReleaseFixes430VerificationTests: XCTestCase {
    private typealias Answer = MistralFixture.Answer
    private let now = MistralFixture.now
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReleaseFixes430VerificationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // A mode-000 file must be readable to be removed with its folder.
        if let items = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            for item in items {
                chmod(directory.appendingPathComponent(item).path, 0o600)
            }
        }
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixtures

    /// What the injected transport and keychain answer now; a test changes it between polls.
    private actor Script {
        var budget: Answer?
        var subscription: Answer? = Answer(status: 200, body: MistralFixture.subscriptionBody)
        private(set) var requests = 0
        init(budget: Answer?) { self.budget = budget }
        func set(budget: Answer?) { self.budget = budget }
        func set(subscription: Answer?) { self.subscription = subscription }
        func countRequest() { requests += 1 }
    }

    /// The keychain closure is synchronous: it reads a lock-guarded copy.
    private final class KeyBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        init(_ value: String?) { self.value = value }
        func set(_ value: String?) { lock.lock(); self.value = value; lock.unlock() }
        func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func provider(script: Script, key: KeyBox) -> MistralProvider {
        MistralProvider(
            credentials: MistralCredentialReader(
                keychain: { key.get() },
                envFileURL: directory.appendingPathComponent("no-such/.env")
            ),
            fetcher: MistralBillingFetcher(transport: { request in
                await script.countRequest()
                let budget = await script.budget
                let subscription = await script.subscription
                return try await MistralFixture.transport(subscription: subscription, budget: budget)(request)
            })
        )
    }

    private func throttled(_ retryAfter: String?) -> Answer {
        Answer(status: 429, body: "{}", headers: retryAfter.map { ["Retry-After": $0] } ?? [:])
    }

    // MARK: - A: a 429 is held by the provider

    /// The pure rule at and around each bound, including figures a header can only just carry.
    func testTheHoldIsAMinuteToFiveMinutesAtEachBound() {
        func hold(_ retryAfter: TimeInterval?) -> TimeInterval {
            MistralProvider.hold(for: .failure(.rateLimited(retryAfter: retryAfter)))
        }
        let cases: [(TimeInterval?, TimeInterval)] = [
            (nil, 60), (0, 60), (-1, 60), (59.9, 60), (60, 60), (60.5, 60.5), (61, 61),
            (299, 299), (299.9, 299.9), (300, 300), (300.5, 300), (301, 300), (3600, 300),
            (.infinity, 300), (.nan, 60), (-.infinity, 60), (.greatestFiniteMagnitude, 300),
        ]
        for (retryAfter, expected) in cases {
            XCTAssertEqual(hold(retryAfter), expected, "Retry-After \(String(describing: retryAfter))")
        }
    }

    func testEveryOtherAnswerIsKeptTheOrdinaryMinute() {
        let others: [Result<MistralBilling, MistralBillingError>?] = [
            nil,
            .success(MistralBilling(planName: "TEAM", budget: .entries([]))),
            .success(MistralBilling(planName: nil, budget: .noUsageAccess)),
            .success(MistralBilling(planName: nil, budget: .noBilling)),
            .failure(.unauthorized),
            .failure(.badStatus(503)),
            .failure(.decoding("x")),
            .failure(.transport("offline")),
        ]
        for result in others {
            XCTAssertEqual(MistralProvider.hold(for: result), 60, String(describing: result))
        }
        XCTAssertEqual(MistralProvider.minFetchInterval, 60)
        XCTAssertEqual(MistralProvider.maxRateLimitHold, 300)
    }

    /// Through `fetch`: the header text decides the hold, fractions and junk included. A poll
    /// just inside the hold makes no request at all; one at the hold asks again.
    func testA429IsHeldForItsHeaderThroughFetchAtTheBounds() async {
        let cases: [(header: String?, hold: TimeInterval)] = [
            (nil, 60), ("0", 60), ("-5", 60), ("59.9", 60), ("60", 60), ("60.5", 60.5),
            ("299", 299), ("300", 300), ("301", 300), ("nan", 60), ("inf", 300), ("soon", 60),
        ]
        for (header, hold) in cases {
            let script = Script(budget: throttled(header))
            let mistral = provider(script: script, key: KeyBox(MistralFixture.key))
            _ = await mistral.fetch(now: now)
            let afterFirst = await script.requests
            XCTAssertEqual(afterFirst, 2, "one poll is two requests: \(header ?? "no header")")
            _ = await mistral.fetch(now: now.addingTimeInterval(hold - 0.001))
            let inside = await script.requests
            XCTAssertEqual(inside, 2, "inside the hold nothing is asked: \(header ?? "no header")")
            _ = await mistral.fetch(now: now.addingTimeInterval(hold))
            let at = await script.requests
            XCTAssertEqual(at, 4, "at the hold billing is asked again: \(header ?? "no header")")
        }
    }

    /// The hold belongs to the 429 alone: any other answer, whatever Retry-After it carries, is
    /// kept the ordinary minute.
    func testAnAnswerThatIsNoRateLimitIsKeptAMinuteWhateverItsRetryAfterSays() async {
        let long = ["Retry-After": "250"]
        let answers: [(String, Answer?)] = [
            ("200", Answer(status: 200, body: MistralFixture.budgetBody, headers: long)),
            ("500", Answer(status: 500, body: "{}", headers: long)),
            ("503", Answer(status: 503, body: "{}", headers: long)),
            ("401", Answer(status: 401, body: "{}", headers: long)),
            ("403", Answer(status: 403, body: "{}", headers: long)),
            ("404", Answer(status: 404, body: "{}", headers: long)),
            ("unreadable 200", Answer(status: 200, body: "not json", headers: long)),
            ("offline", nil),
        ]
        for (name, budget) in answers {
            let script = Script(budget: budget)
            let mistral = provider(script: script, key: KeyBox(MistralFixture.key))
            _ = await mistral.fetch(now: now)
            _ = await mistral.fetch(now: now.addingTimeInterval(59.9))
            let inside = await script.requests
            XCTAssertEqual(inside, 2, name)
            _ = await mistral.fetch(now: now.addingTimeInterval(60))
            let at = await script.requests
            XCTAssertEqual(at, 4, "\(name): asked again after the ordinary minute, not the header's 250 s")
        }
    }

    /// 429 (120 s), then a 200, then a 429 (90 s), then a 200: each answer carries its own hold.
    func testARateLimitThenAGoodAnswerThenARateLimitEachKeepTheirOwnHold() async {
        let script = Script(budget: throttled("120"))
        let mistral = provider(script: script, key: KeyBox(MistralFixture.key))
        let first = await mistral.fetch(now: now)
        XCTAssertEqual(first.state, .error)

        await script.set(budget: Answer(status: 200, body: MistralFixture.budgetBody))
        let held = await mistral.fetch(now: now.addingTimeInterval(119.9))
        XCTAssertEqual(held.state, .error)
        let second = await mistral.fetch(now: now.addingTimeInterval(120))
        XCTAssertEqual(second.state, .ok)

        await script.set(budget: throttled("90"))
        let keptGood = await mistral.fetch(now: now.addingTimeInterval(179.9))
        XCTAssertEqual(keptGood.state, .ok, "a 200 is kept a minute, not 120 s")
        let third = await mistral.fetch(now: now.addingTimeInterval(180))
        XCTAssertEqual(third.state, .error)

        await script.set(budget: Answer(status: 200, body: MistralFixture.budgetBody))
        let heldAgain = await mistral.fetch(now: now.addingTimeInterval(269.9))
        XCTAssertEqual(heldAgain.state, .error, "the second 429 is held 90 s, not the first's 120 s")
        let fourth = await mistral.fetch(now: now.addingTimeInterval(270))
        XCTAssertEqual(fourth.state, .ok)
        XCTAssertNil(fourth.retryAfter)
    }

    /// A key that goes away while the 429 is held: the held answer stands (nothing is asked);
    /// after the hold the missing key is Not signed in, kept a minute.
    func testAKeyThatVanishesInsideTheHoldChangesNothingUntilTheHoldIsOver() async {
        let script = Script(budget: throttled("120"))
        let key = KeyBox(MistralFixture.key)
        let mistral = provider(script: script, key: key)
        _ = await mistral.fetch(now: now)

        key.set(nil)
        let held = await mistral.fetch(now: now.addingTimeInterval(119))
        XCTAssertEqual(held.state, .error)
        XCTAssertEqual(held.stateMessage, MistralCopy.rateLimitedMessage)
        let inside = await script.requests
        XCTAssertEqual(inside, 2)

        let signedOut = await mistral.fetch(now: now.addingTimeInterval(120))
        XCTAssertEqual(signedOut.state, .notSignedIn)
        let after = await script.requests
        XCTAssertEqual(after, 2, "no key, nothing asked")

        key.set(MistralFixture.key)
        await script.set(budget: Answer(status: 200, body: MistralFixture.budgetBody))
        let stillNone = await mistral.fetch(now: now.addingTimeInterval(179))
        XCTAssertEqual(stillNone.state, .notSignedIn, "the no-key answer is kept the ordinary minute")
        let back = await mistral.fetch(now: now.addingTimeInterval(180))
        XCTAssertEqual(back.state, .ok)
    }

    func testNoAnswerTheProviderGivesCarriesARetryAfter() async {
        let long = ["Retry-After": "120"]
        let budgets: [(String, Answer?)] = [
            ("200", Answer(status: 200, body: MistralFixture.budgetBody, headers: long)),
            ("401", Answer(status: 401, body: "{}", headers: long)),
            ("403", Answer(status: 403, body: "{}", headers: long)),
            ("404", Answer(status: 404, body: "{}", headers: long)),
            ("429", throttled("120")),
            ("429 without header", throttled(nil)),
            ("429 over the cap", throttled("9999")),
            ("500", Answer(status: 500, body: "{}", headers: long)),
            ("503", Answer(status: 503, body: "{}", headers: long)),
            ("unreadable 200", Answer(status: 200, body: "[]", headers: long)),
            ("offline", nil),
        ]
        for (name, budget) in budgets {
            let snapshot = await provider(script: Script(budget: budget), key: KeyBox(MistralFixture.key)).fetch(now: now)
            XCTAssertNil(snapshot.retryAfter, name)
        }
        let noKey = await provider(script: Script(budget: nil), key: KeyBox(nil)).fetch(now: now)
        XCTAssertNil(noKey.retryAfter, "no key")
        for after in [nil, 0, 30, 500, 1e9] as [TimeInterval?] {
            let direct = MistralProvider.snapshot(result: .failure(.rateLimited(retryAfter: after)), now: now)
            XCTAssertNil(direct.retryAfter, String(describing: after))
            XCTAssertEqual(direct.state, .error)
        }
    }

    // MARK: - B: only a small regular file is opened

    private func reader(_ url: URL, keychain: String? = "kc-key") -> MistralCredentialReader {
        MistralCredentialReader(keychain: { keychain }, envFileURL: url)
    }

    private func write(_ text: String, to name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    func testAChainOfSymlinksIsFollowedToASmallFileButNotToABigOne() throws {
        let small = try write("MISTRAL_API_KEY=env-key\n", to: "small.env")
        let link1 = directory.appendingPathComponent("link1")
        let link2 = directory.appendingPathComponent("link2")
        try FileManager.default.createSymbolicLink(at: link1, withDestinationURL: small)
        try FileManager.default.createSymbolicLink(at: link2, withDestinationURL: link1)
        XCTAssertEqual(reader(link2).read(), "env-key")

        let big = try write("MISTRAL_API_KEY=env-key\n#" + String(repeating: "x", count: 70_000) + "\n", to: "big.env")
        let bigLink1 = directory.appendingPathComponent("biglink1")
        let bigLink2 = directory.appendingPathComponent("biglink2")
        try FileManager.default.createSymbolicLink(at: bigLink1, withDestinationURL: big)
        try FileManager.default.createSymbolicLink(at: bigLink2, withDestinationURL: bigLink1)
        XCTAssertEqual(reader(bigLink2).read(), "kc-key", "the size is the target's, not the link's")
        XCTAssertNil(reader(bigLink2, keychain: nil).read(), "a big file is no key and the keychain has none")
    }

    func testABrokenSymlinkAndALoopAreNoKeyFromTheFile() throws {
        let broken = directory.appendingPathComponent("broken")
        try FileManager.default.createSymbolicLink(
            at: broken, withDestinationURL: directory.appendingPathComponent("gone.env")
        )
        XCTAssertEqual(reader(broken).read(), "kc-key")

        let a = directory.appendingPathComponent("loop-a")
        let b = directory.appendingPathComponent("loop-b")
        try FileManager.default.createSymbolicLink(at: a, withDestinationURL: b)
        try FileManager.default.createSymbolicLink(at: b, withDestinationURL: a)
        XCTAssertEqual(reader(a).read(), "kc-key")
    }

    func testAnUnreadableFileAndAnEmptyFileAreNoKeyFromTheFile() throws {
        let locked = try write("MISTRAL_API_KEY=env-key\n", to: "locked.env")
        XCTAssertEqual(chmod(locked.path, 0o000), 0)
        XCTAssertEqual(reader(locked).read(), "kc-key")
        XCTAssertNil(reader(locked, keychain: nil).read())

        let empty = try write("", to: "empty.env")
        XCTAssertEqual(reader(empty).read(), "kc-key")
        let comments = try write("# nothing here\n\n", to: "comments.env")
        XCTAssertEqual(reader(comments).read(), "kc-key")
    }

    /// The size is asked at every read: the same reader sees a file grow past the cap and shrink
    /// back.
    func testAFileThatGrowsPastTheCapBetweenPollsIsNoLongerOpened() throws {
        let url = directory.appendingPathComponent("growing.env")
        let key = MistralCredentialReader(keychain: { "kc-key" }, envFileURL: url)

        try Data("MISTRAL_API_KEY=first\n".utf8).write(to: url)
        XCTAssertEqual(key.read(), "first")

        let cap = MistralCredentialReader.maxEnvFileBytes
        let head = "MISTRAL_API_KEY=second\n#"
        try Data((head + String(repeating: "y", count: cap - head.utf8.count)).utf8).write(to: url)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, cap)
        XCTAssertEqual(key.read(), "second", "exactly the cap is still opened")

        try Data((head + String(repeating: "y", count: cap - head.utf8.count + 1)).utf8).write(to: url)
        XCTAssertEqual(key.read(), "kc-key", "one byte over is not")

        try Data("MISTRAL_API_KEY=third\n".utf8).write(to: url)
        XCTAssertEqual(key.read(), "third")
    }

    func testTheCapIsCountedInBytesNotCharacters() throws {
        // 32 769 two-byte characters: 65 538 bytes, 32 769 characters.
        let head = "MISTRAL_API_KEY=env-key\n#"
        let padding = (MistralCredentialReader.maxEnvFileBytes - head.utf8.count) / 2 + 1
        let url = try write(head + String(repeating: "é", count: padding) + "\n", to: "wide.env")
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertGreaterThan(size, MistralCredentialReader.maxEnvFileBytes)
        XCTAssertLessThan(head.count + padding + 1, MistralCredentialReader.maxEnvFileBytes)
        XCTAssertEqual(reader(url).read(), "kc-key")
    }

    // MARK: - C: what the server chooses is made safe to show

    /// Every scalar of general category `Cc`: C0, DEL and C1.
    private var controls: [Unicode.Scalar] {
        (0x00...0x1F).map { Unicode.Scalar($0)! } + [Unicode.Scalar(0x7F)!] + (0x80...0x9F).map { Unicode.Scalar($0)! }
    }

    func testTheControlScalarsUnderTestAreExactlyTheCcCategory() {
        XCTAssertEqual(controls.count, 65)
        XCTAssertTrue(controls.allSatisfy { $0.properties.generalCategory == .control })
    }

    func testEveryControlScalarInABudgetKeyIsDroppedFromItsIDAndLabel() {
        for control in controls {
            let key = "te\(control)am_se\(control)ats_budget"
            let buckets = MistralBudgetRules.buckets(from: [MistralBudgetEntry(key: key, usagePercentage: 10)])
            XCTAssertEqual(buckets.map(\.id), ["mistral_team_seats"], "U+\(String(control.value, radix: 16))")
            XCTAssertEqual(buckets.map(\.label), ["Team Seats"], "U+\(String(control.value, radix: 16))")
        }
    }

    func testAKeyWhoseNameIsOnlyAControlScalarIsNoWindowAndOneBesideItDoesNotHideTheRest() {
        for control in controls {
            let none = MistralBudgetEntry(key: "\(control)_budget", usagePercentage: 10)
            let good = MistralBudgetEntry(key: "api_budget", usagePercentage: 20)
            let buckets = MistralBudgetRules.buckets(from: [none, good])
            XCTAssertEqual(buckets.map(\.id), ["mistral_api"], "U+\(String(control.value, radix: 16))")
            XCTAssertNil(MistralBudgetRules.name(forKey: "\(control)_budget"))
        }
    }

    /// The control must be in the name: one inside or after the `_budget` suffix leaves a key
    /// that is no budget at all.
    func testAControlInsideOrAfterTheSuffixIsNoBudgetKey() {
        for control in controls {
            XCTAssertNil(MistralBudgetRules.name(forKey: "vibe_bud\(control)get"))
            XCTAssertNil(MistralBudgetRules.name(forKey: "vibe_budget\(control)"))
        }
    }

    /// Only `Cc` goes. Format, separator and private-use scalars and ordinary letters stay.
    func testNothingButControlScalarsIsDroppedFromAName() {
        let kept = ["café", "日本", "a\u{200D}b", "a\u{00AD}b", "a\u{2028}b", "a\u{E000}b", "a\u{FFFD}b", "a b", "ab9"]
        for name in kept {
            XCTAssertEqual(MistralBudgetRules.name(forKey: "\(name)_budget"), name)
            XCTAssertEqual(MistralBudgetRules.bucketID(forKey: "\(name)_budget"), "mistral_\(name)")
        }
        XCTAssertEqual(MistralBudgetRules.label(forKey: "日本_budget"), "日本")
        XCTAssertEqual(MistralCopy.withoutControlCharacters("a\u{200D}b\u{2028}c"), "a\u{200D}b\u{2028}c")
    }

    /// A key that differs from `vibe_budget` only by controls is not the Vibe window's own key:
    /// it is a model-specific window and never leads the headline.
    func testAKeyDifferingFromVibeBudgetOnlyByControlsIsNotTheVibeWindow() {
        let key = "vi\u{1B}be_budget"
        XCTAssertEqual(MistralBudgetRules.kind(forKey: key), .modelSpecific)
        XCTAssertEqual(MistralBudgetRules.name(forKey: key), "vibe")
        XCTAssertFalse(MistralBudgetRules.label(forKey: key).unicodeScalars.contains { $0.properties.generalCategory == .control })
    }

    func testEveryControlScalarInAPlanNameIsDroppedAndAPlanOfOnlyControlsIsNoChip() {
        for control in controls {
            let tag = "U+\(String(control.value, radix: 16))"
            XCTAssertEqual(MistralCopy.planName("ENTER\(control)PRISE"), "Enterprise", tag)
            XCTAssertEqual(MistralCopy.planName("\(control)TEAM\(control)"), "Team", tag)
            XCTAssertNil(MistralCopy.planName("\(control)"), tag)
            XCTAssertNil(MistralCopy.planName(" \(control) \(control)"), tag)
        }
        XCTAssertNil(MistralCopy.planName(nil))
        XCTAssertNil(MistralCopy.planName(""))
        XCTAssertNil(MistralCopy.planName("   "))
    }

    /// Through the provider: a hostile `plan_name` and key reach the snapshot clean.
    func testAPlanAndAWindowFromHostileBillingReachTheSnapshotWithoutControls() async throws {
        let budget = #"{"te\u001bam_budget":{"usage_percentage":12.5,"initial_budget":10,"currency":"USD"},"\u0007_budget":{"usage_percentage":3}}"#
        let script = Script(budget: Answer(status: 200, body: budget))
        await script.set(subscription: Answer(status: 200, body: #"{"plan_name":"SC\u001bALE\u009b"}"#))
        let snapshot = await provider(script: script, key: KeyBox(MistralFixture.key)).fetch(now: now)
        XCTAssertEqual(snapshot.state, .ok)
        XCTAssertEqual(snapshot.plan, "Scale")
        XCTAssertEqual(snapshot.buckets.map(\.id), ["mistral_team"])
        XCTAssertEqual(snapshot.buckets.map(\.label), ["Team"])
    }

    // MARK: - C: finite figures only

    private func assertSafe(_ bucket: UsageBucket, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(bucket.utilization.isFinite, name, file: file, line: line)
        XCTAssertTrue((0...100).contains(bucket.utilization), "\(name): \(bucket.utilization)", file: file, line: line)
        if let allowance = bucket.allowance {
            XCTAssertTrue(allowance.usedDollars.isFinite && allowance.limitDollars.isFinite, name, file: file, line: line)
        }
    }

    func testFiguresThatAreNoNumberOrNoFiniteNumberNeverReachAWindowOrAnAllowance() {
        let inf = Double.infinity
        let figures: [(String, Double, Double?)] = [
            ("nan percent", .nan, 300), ("+inf percent", inf, 300), ("-inf percent", -inf, 300),
            ("nan budget", 10, .nan), ("+inf budget", 10, inf), ("-inf budget", 10, -inf),
            ("huge × huge", 1e308, 1e308), ("huge percent", 1e308, 2), ("max percent", .greatestFiniteMagnitude, 300),
            ("negative budget", 50, -300), ("zero budget", 50, 0), ("negative percent", -40, 300),
        ]
        for (name, percent, budget) in figures {
            let entry = MistralBudgetEntry(key: "vibe_budget", usagePercentage: percent, initialBudget: budget, currency: "USD")
            assertSafe(MistralBudgetRules.bucket(from: entry), name)
        }
        for name in ["nan budget", "+inf budget", "-inf budget", "negative budget", "zero budget", "huge × huge", "huge percent", "max percent"] {
            let (_, percent, budget) = figures.first { $0.0 == name }!
            let entry = MistralBudgetEntry(key: "vibe_budget", usagePercentage: percent, initialBudget: budget, currency: "USD")
            XCTAssertNil(MistralBudgetRules.allowance(entry), name)
        }
    }

    func testThePercentStaysClampedAndALargeFiniteAllowanceStillShows() throws {
        func bucket(_ percent: Double, budget: Double? = nil) -> UsageBucket {
            MistralBudgetRules.bucket(from: MistralBudgetEntry(
                key: "vibe_budget", usagePercentage: percent, initialBudget: budget, currency: "USD"
            ))
        }
        XCTAssertEqual(bucket(-5).utilization, 0)
        XCTAssertEqual(bucket(0).utilization, 0)
        XCTAssertEqual(bucket(100).utilization, 100)
        XCTAssertEqual(bucket(137).utilization, 100)
        XCTAssertEqual(bucket(.nan).utilization, 0)
        XCTAssertEqual(bucket(.infinity).utilization, 100)

        let big = try XCTUnwrap(bucket(50, budget: 1e300).allowance)
        XCTAssertEqual(big.limitDollars, 1e300)
        XCTAssertEqual(big.usedDollars, 5e299, accuracy: 1e286)
        let over = try XCTUnwrap(bucket(150, budget: 300).allowance)
        XCTAssertEqual(over.usedDollars, 450, accuracy: 1e-9, "past the allowance the dollars are Mistral's count")
        XCTAssertEqual(try XCTUnwrap(bucket(-10, budget: 300).allowance).usedDollars, 0)
    }

    /// An out-of-range JSON number through the decoder: whatever it does with `1e999`, no window
    /// leaves the rules with a figure outside 0…100 or a non-finite one.
    func testAnOutOfRangeNumberInBillingsBodyLeavesOnlySafeWindows() throws {
        let bodies = [
            #"{"vibe_budget":{"usage_percentage":1e999,"initial_budget":300,"currency":"USD"}}"#,
            #"{"vibe_budget":{"usage_percentage":5,"initial_budget":1e999,"currency":"USD"}}"#,
            #"{"vibe_budget":{"usage_percentage":-1e999,"initial_budget":1e999,"currency":"USD"}}"#,
            #"{"vibe_budget":{"usage_percentage":1e308,"initial_budget":1e308,"currency":"USD"}}"#,
        ]
        for body in bodies {
            let entries = (try? MistralBillingFetcher.decodeBudget(Data(body.utf8))) ?? []
            for bucket in MistralBudgetRules.buckets(from: entries) { assertSafe(bucket, body) }
        }
    }

    /// The shape billing really answers is unchanged by the filters.
    func testTheLiveShapedAnswerIsUnchanged() async throws {
        let snapshot = await provider(script: Script(budget: Answer(status: 200, body: MistralFixture.budgetBody)), key: KeyBox(MistralFixture.key)).fetch(now: now)
        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertEqual(snapshot.buckets.map(\.id), ["mistral_vibe", "mistral_api"])
        XCTAssertEqual(snapshot.buckets.map(\.label), ["Vibe", "API"])
        let vibe = try XCTUnwrap(snapshot.buckets.first?.allowance)
        XCTAssertEqual(vibe.usedDollars, 17.879, accuracy: 0.001)
        XCTAssertEqual(vibe.limitDollars, 300)
        XCTAssertEqual(MistralBudgetRules.label(forKey: "team_seats_budget"), "Team Seats")
        XCTAssertEqual(MistralCopy.planName("individual"), "Pro")
        XCTAssertEqual(MistralCopy.planName("Scale Up"), "Scale Up")
    }

    // MARK: - D: a bundle id is one path component

    private func makeCacheFile(_ relative: String) throws {
        let url = directory.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    private func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(relative).path)
    }

    /// Ids that reach another folder only by a slash: a trailing one, doubled ones, a leading
    /// one, a dot component and a very long chain.
    func testSlashesInABundleIDPurgeNothingWhereverTheyAre() throws {
        let sentinels = [
            "Caches/Cache.db", "Cache.db", "Caches/x/Cache.db", "Caches/a/b/Cache.db", "Caches/a/Cache.db",
            "Caches/tmp/Cache.db",
        ]
        for path in sentinels { try makeCacheFile(path) }
        let caches = directory.appendingPathComponent("Caches", isDirectory: true)
        let ids = [
            "x/", "x//", "a//b", "//", "/", "./x", "x/.", "a/./b", "a/b/", "../Caches", "../Caches/x",
            "x/../x", "x/..", String(repeating: "a/", count: 500),
        ]
        for id in ids {
            XCTAssertEqual(NetworkCachePolicy.purge(cachesDirectory: caches, bundleID: id), [], id.debugDescription)
            for path in sentinels { XCTAssertTrue(exists(path), "\(id.debugDescription) removed \(path)") }
        }
    }

    /// A backslash, leading dots and dots inside a name are legal file names: the folder is purged
    /// as one component, and only that folder.
    func testAnIDWithDotsOrABackslashIsOneFolderAndIsPurged() throws {
        let sibling = "Caches/neighbour/Cache.db"
        try makeCacheFile(sibling)
        try makeCacheFile("Cache.db")
        let caches = directory.appendingPathComponent("Caches", isDirectory: true)
        for id in ["com.example.app", ".hidden", "...", "a..b", "..a", "a..", "a\\b", "..\\x", "-", " spaced "] {
            try makeCacheFile("Caches/\(id)/Cache.db")
            try makeCacheFile("Caches/\(id)/WebKit/keep")
            XCTAssertEqual(NetworkCachePolicy.purge(cachesDirectory: caches, bundleID: id), ["Cache.db"], id.debugDescription)
            XCTAssertFalse(exists("Caches/\(id)/Cache.db"), id.debugDescription)
            XCTAssertTrue(exists("Caches/\(id)/WebKit/keep"), id.debugDescription)
            XCTAssertTrue(exists(sibling), id.debugDescription)
            XCTAssertTrue(exists("Cache.db"), id.debugDescription)
        }
    }

    func testAVeryLongBundleIDIsHandledWithoutRemovingAnythingElse() throws {
        try makeCacheFile("Caches/Cache.db")
        try makeCacheFile("Cache.db")
        let caches = directory.appendingPathComponent("Caches", isDirectory: true)
        for length in [255, 256, 1_000, 100_000] {
            let id = String(repeating: "a", count: length)
            _ = NetworkCachePolicy.purge(cachesDirectory: caches, bundleID: id)
        }
        XCTAssertTrue(exists("Caches/Cache.db"))
        XCTAssertTrue(exists("Cache.db"))
        let id = String(repeating: "b", count: 200)
        try makeCacheFile("Caches/\(id)/Cache.db-wal")
        XCTAssertEqual(NetworkCachePolicy.purge(cachesDirectory: caches, bundleID: id), ["Cache.db-wal"])
    }
}
