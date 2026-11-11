import XCTest
@testable import Omelette

/// Verification of the Mistral provider's P1 (spec 2026-11-10 Mistral provider): § Credential
/// (vibe reads `~/.vibe/.env` with python-dotenv, so the file is read the way it reads it),
/// § Fetch and § Windows (odd `/budget` shapes, the window's length in any time zone), § States
/// (every row through retention and the way out), the key's whereabouts (Credential: "never
/// written"), and § Surfaces (the switch, the settings list, the grid, the widget). Nothing here
/// touches the real keychain, `~/.vibe` or a network: every file is in a per-test temp directory
/// and every answer comes from the fixture transport.
final class MistralProviderVerificationTests: XCTestCase {
    private typealias Answer = MistralFixture.Answer
    private let now = MistralFixture.now
    private let locale = Locale(identifier: "en_US")
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MistralProviderVerificationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Helpers

    private func envFile(_ text: String) throws -> URL {
        let url = directory.appendingPathComponent(".env")
        try Data(text.utf8).write(to: url)
        return url
    }

    private func provider(
        key: String? = MistralFixture.key,
        subscription: Answer? = Answer(status: 200, body: MistralFixture.subscriptionBody),
        budget: Answer? = Answer(status: 200, body: MistralFixture.budgetBody),
        requests: MistralFixture.Requests? = nil
    ) -> MistralProvider {
        MistralProvider(
            credentials: MistralCredentialReader(
                keychain: { key }, envFileURL: directory.appendingPathComponent("absent/.env")
            ),
            fetcher: MistralBillingFetcher(
                transport: MistralFixture.transport(subscription: subscription, budget: budget, requests: requests)
            )
        )
    }

    private func budgetBody(_ entries: String) -> Answer {
        Answer(status: 200, body: "{\(entries)}")
    }

    private func entry(_ name: String, percent: String = "10", rest: String = #""initial_budget":100,"currency":"USD","reset_at":"2026-12-01T00:00:00Z""#) -> String {
        #""\#(name)":{"usage_percentage":\#(percent),\#(rest)}"#
    }

    private func services(_ list: [ServiceSnapshot], at date: Date? = nil) -> UsageSnapshot {
        UsageSnapshot(services: list, fetchedAt: date ?? now, isStale: false, lastError: nil)
    }

    private func withDefaultTimeZone<T>(_ identifier: String, _ body: () throws -> T) rethrows -> T {
        let saved = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: identifier)!
        defer { NSTimeZone.default = saved }
        return try body()
    }

    // MARK: - Credential: the .env file as python-dotenv reads it

    /// `dotenv_values` of vibe's own interpreter (python-dotenv 1.2.2), `MISTRAL_API_KEY` of each text.
    /// "" or nil is no key: vibe's `load_dotenv_values` skips an empty value, so the keychain is asked.
    private let dotenvCorpus: [(name: String, text: String, python: String?)] = [
        ("a later empty line cancels an earlier key", "MISTRAL_API_KEY=a\nMISTRAL_API_KEY=\n", nil),
        ("equals signs inside an unquoted value", "MISTRAL_API_KEY=ab=cd==\n", "ab=cd=="),
        ("a quoted value keeps = and # and may carry a comment", "MISTRAL_API_KEY=\"ab=cd#ef==\" # note\n", "ab=cd#ef=="),
        ("an indented comment and an indented assignment", "   # MISTRAL_API_KEY=old\n   MISTRAL_API_KEY=new\n", "new"),
        ("an empty double-quoted value", "MISTRAL_API_KEY=\"\"\n", nil),
        ("an empty single-quoted value", "MISTRAL_API_KEY=''\n", nil),
        ("a lone carriage return ends a line", "OTHER=1\rMISTRAL_API_KEY=k\r", "k"),
        ("a name with no equals sign assigns nothing", "MISTRAL_API_KEY\n", nil),
        ("export with a tab", "export\tMISTRAL_API_KEY=abc\n", "abc"),
        ("export with no value", "export MISTRAL_API_KEY\n", nil),
        ("exportMISTRAL_API_KEY is another name", "exportMISTRAL_API_KEY=abc\n", nil),
        ("a # that starts the value is the value", "MISTRAL_API_KEY=#abc\n", "#abc"),
        ("a # after blanks that start the value is the value", "MISTRAL_API_KEY= #abc\n", "#abc"),
        ("trailing blanks are no part of it", "MISTRAL_API_KEY=abc   \n", "abc"),
        ("blanks inside stay", "MISTRAL_API_KEY=abc def\n", "abc def"),
        ("a comment right after the closing quote", "MISTRAL_API_KEY=\"abc\"#c\n", "abc"),
        ("blanks around = with quotes", "MISTRAL_API_KEY = 'abc'\n", "abc"),
        ("blanks before =", "MISTRAL_API_KEY   =abc\n", "abc"),
        ("a tab before the comment", "MISTRAL_API_KEY=abc\t# c\n", "abc"),
        ("a semicolon is no comment", "MISTRAL_API_KEY=abc;def\n", "abc;def"),
        ("an empty value", "MISTRAL_API_KEY=\n", nil),
        ("an empty quoted value then a comment", "MISTRAL_API_KEY=\"\" # c\n", nil),
    ]

    func testTheEnvFileIsReadAsPythonDotenvReadsItAndAnEmptyValueFallsToTheKeychain() throws {
        for (name, text, python) in dotenvCorpus {
            let reader = MistralCredentialReader(keychain: { "KEYCHAIN" }, envFileURL: try envFile(text))
            XCTAssertEqual(reader.read(), python ?? "KEYCHAIN", name)
        }
    }

    /// python-dotenv cannot parse these statements ("could not parse statement"), so vibe has no key
    /// from the file and uses the keychain's. Brioche showing the budget of a truncated or
    /// half-quoted key would show a budget vibe never runs on.
    func testAStatementPythonDotenvRejectsIsNoKeyFromTheFile() throws {
        let rejected: [(String, String)] = [
            ("an unterminated double quote", "MISTRAL_API_KEY=\"abc\n"),
            ("an unterminated single quote", "MISTRAL_API_KEY='abc\n"),
            ("an unterminated quote above a good line", "MISTRAL_API_KEY=\"abc\nOTHER=1\n"),
            ("text after the closing double quote", "MISTRAL_API_KEY=\"abc\"def\n"),
            ("text after the closing single quote", "MISTRAL_API_KEY='abc' def\n"),
        ]
        for (name, text) in rejected {
            let reader = MistralCredentialReader(keychain: { "KEYCHAIN" }, envFileURL: try envFile(text))
            XCTAssertEqual(reader.read(), "KEYCHAIN", name)
        }
    }

    /// python-dotenv allows blanks before `export` and before the name (`^\s*(?:export\s+)?key`).
    func testAnIndentedLineAndAnIndentedExportAreReadAsPythonDotenvReadsThem() throws {
        let lines = [
            "  MISTRAL_API_KEY=abc", "\tMISTRAL_API_KEY=abc", "  export MISTRAL_API_KEY=abc",
            "\t export \tMISTRAL_API_KEY = abc",
        ]
        for line in lines {
            let reader = MistralCredentialReader(keychain: { "KEYCHAIN" }, envFileURL: try envFile(line + "\n"))
            XCTAssertEqual(reader.read(), "abc", line)
        }
    }

    func testANameThatOnlyContainsOrExtendsTheKeysNameIsNotTheKey() throws {
        let text = "XMISTRAL_API_KEY=x\nMISTRAL_API_KEY_OLD=y\nmistral_api_key=z\nMISTRAL_API_KEY2=w\n"
        let reader = MistralCredentialReader(keychain: { nil }, envFileURL: try envFile(text))
        XCTAssertNil(reader.read())
    }

    func testAnEnvPathThatCannotBeReadFallsToTheKeychain() throws {
        let asDirectory = directory.appendingPathComponent("is-a-directory")
        try FileManager.default.createDirectory(at: asDirectory, withIntermediateDirectories: true)
        XCTAssertEqual(MistralCredentialReader(keychain: { "kc" }, envFileURL: asDirectory).read(), "kc")
        let missing = directory.appendingPathComponent("no/such/.env")
        XCTAssertEqual(MistralCredentialReader(keychain: { "kc" }, envFileURL: missing).read(), "kc")
    }

    func testTheKeychainsKeyLosesItsBlanksAndABlankOneIsNoKey() {
        let missing = directory.appendingPathComponent("absent/.env")
        XCTAssertEqual(MistralCredentialReader(keychain: { "  kc-key \n" }, envFileURL: missing).read(), "kc-key")
        XCTAssertNil(MistralCredentialReader(keychain: { " \n\t" }, envFileURL: missing).read())
    }

    func testTheFileIsReadAgainOnEveryReadSoARemovedLineFallsBackToTheKeychain() throws {
        let url = try envFile("MISTRAL_API_KEY=file-key\n")
        let reader = MistralCredentialReader(keychain: { "kc-key" }, envFileURL: url)
        XCTAssertEqual(reader.read(), "file-key")
        try Data("OTHER=1\n".utf8).write(to: url)
        XCTAssertEqual(reader.read(), "kc-key")
    }

    func testTheKeyFromTheFileIsTheOneBillingIsAskedWith() async throws {
        let requests = MistralFixture.Requests()
        let url = try envFile("MISTRAL_API_KEY=\"file-key\"\r\n")
        let mistral = MistralProvider(
            credentials: MistralCredentialReader(keychain: { "kc-key" }, envFileURL: url),
            fetcher: MistralBillingFetcher(transport: MistralFixture.transport(requests: requests))
        )
        _ = await mistral.fetch(now: now)
        let seen = await requests.seen
        XCTAssertEqual(seen.count, 2)
        for request in seen {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer file-key")
        }
    }

    // MARK: - Fetch: what the subscription says, and what the budget may look like

    func testAPlanThatBillingDoesNotNameIsNoChipAndNoFailure() async {
        let bodies = ["{}", #"{"plan_name":null}"#, #"{"plan_name":5}"#, #"{"plan_name":""}"#, "[]"]
        for body in bodies {
            let snapshot = await provider(subscription: Answer(status: 200, body: body)).fetch(now: now)
            XCTAssertEqual(snapshot.state, .ok, body)
            XCTAssertNil(snapshot.plan, body)
            XCTAssertEqual(snapshot.buckets.map(\.id), ["mistral_vibe", "mistral_api"], body)
        }
    }

    func testAFailedSubscriptionDoesNotFailTheProviderWhateverItAnswers() async {
        let failures: [Answer?] = [
            Answer(status: 401, body: "{}"), Answer(status: 403, body: "{}"), Answer(status: 429, body: "{}"),
            Answer(status: 500, body: ""), nil,
        ]
        for subscription in failures {
            let snapshot = await provider(subscription: subscription).fetch(now: now)
            XCTAssertEqual(snapshot.state, .ok, "\(String(describing: subscription?.status))")
            XCTAssertNil(snapshot.plan)
            XCTAssertEqual(snapshot.buckets.count, 2)
        }
    }

    /// Spec § Fetch: "`subscription` failing leaves the plan name empty". A non-2xx answer is a failure
    /// even when its body happens to carry a plan.
    func testASubscriptionThatAnswersWithAFailureStatusGivesNoPlanWhateverItsBodySays() async {
        for status in [301, 400, 401, 403, 404, 429, 500, 503] {
            let failed = Answer(status: status, body: MistralFixture.subscriptionBody)
            let snapshot = await provider(subscription: failed).fetch(now: now)
            XCTAssertNil(snapshot.plan, "\(status)")
            XCTAssertEqual(snapshot.state, .ok, "\(status)")
        }
    }

    func testAnUnauthorizedBudgetIsSignedOutWhateverTheSubscriptionSaid() async {
        let snapshot = await provider(budget: Answer(status: 401, body: "{}")).fetch(now: now)
        XCTAssertEqual(snapshot.state, .notSignedIn)
        XCTAssertEqual(snapshot.signedOutReason, .expired)
        XCTAssertTrue(snapshot.buckets.isEmpty)
    }

    func testWindowsComeInVibeAPIThenTheRestWhateverOrderTheJSONHasThem() async {
        let body = [entry("zeta_budget"), entry("api_budget"), entry("alpha_budget"), entry("vibe_budget")].joined(separator: ",")
        let snapshot = await provider(budget: budgetBody(body)).fetch(now: now)
        XCTAssertEqual(snapshot.buckets.map(\.id), ["mistral_vibe", "mistral_api", "mistral_alpha", "mistral_zeta"])
        XCTAssertEqual(snapshot.buckets.map(\.kind), [.weekly, .modelSpecific, .modelSpecific, .modelSpecific])
    }

    func testPercentagesBelowZeroAboveAHundredAndWholeNumbersAreClamped() async {
        let body = [
            entry("vibe_budget", percent: "250"), entry("api_budget", percent: "-4"),
            entry("a_budget", percent: "100"), entry("b_budget", percent: "0"), entry("c_budget", percent: "1e9"),
        ].joined(separator: ",")
        let snapshot = await provider(budget: budgetBody(body)).fetch(now: now)
        XCTAssertEqual(snapshot.buckets.map(\.id), ["mistral_vibe", "mistral_api", "mistral_a", "mistral_b", "mistral_c"])
        XCTAssertEqual(snapshot.buckets.map(\.utilization), [100, 0, 100, 0, 100])
        XCTAssertEqual(snapshot.buckets.first?.allowance?.usedDollars, 250, "Mistral's own count past the allowance")
        XCTAssertEqual(snapshot.buckets[1].allowance?.usedDollars, 0)
        XCTAssertEqual(snapshot.headlinePercent, 100)
    }

    func testAPercentThatIsNotANumberDropsTheWindowAndLeavesTheOthers() async {
        let bad = ["true", "false", "null", #""5""#, "[5]", "{}", #""""#]
        for percent in bad {
            let body = [entry("vibe_budget", percent: percent), entry("api_budget")].joined(separator: ",")
            let snapshot = await provider(budget: budgetBody(body)).fetch(now: now)
            XCTAssertEqual(snapshot.state, .ok, percent)
            XCTAssertEqual(snapshot.buckets.map(\.id), ["mistral_api"], percent)
        }
    }

    func testFiguresOfTheWrongShapeCostTheDollarsButNotTheWindow() async {
        let shapes = [
            #""initial_budget":true,"currency":"USD","reset_at":"2026-12-01T00:00:00Z""#,
            #""initial_budget":"300","currency":"USD","reset_at":"2026-12-01T00:00:00Z""#,
            #""initial_budget":null,"currency":"USD","reset_at":"2026-12-01T00:00:00Z""#,
            #""initial_budget":-300,"currency":"USD","reset_at":"2026-12-01T00:00:00Z""#,
            #""initial_budget":0,"currency":"USD","reset_at":"2026-12-01T00:00:00Z""#,
            #""initial_budget":300,"currency":5,"reset_at":"2026-12-01T00:00:00Z""#,
            #""initial_budget":300,"currency":null,"reset_at":"2026-12-01T00:00:00Z""#,
            #""initial_budget":300,"currency":"EUR","reset_at":"2026-12-01T00:00:00Z""#,
            #""currency":"USD","reset_at":"2026-12-01T00:00:00Z""#,
        ]
        for rest in shapes {
            let snapshot = await provider(budget: budgetBody(entry("vibe_budget", percent: "40", rest: rest))).fetch(now: now)
            XCTAssertEqual(snapshot.state, .ok, rest)
            let bucket = snapshot.buckets.first
            XCTAssertEqual(bucket?.utilization, 40, rest)
            XCTAssertEqual(bucket?.resetsAt, MistralFixture.resetAt, rest)
            XCTAssertNil(bucket?.allowance, rest)
            XCTAssertNil(AllowanceCopy.caption(for: snapshot, locale: locale), "no `$` for a figure that is not dollars: \(rest)")
        }
    }

    func testAResetThatIsAbsentMalformedOrNotAStringIsNoResetLine() async {
        let rests = [
            #""initial_budget":100,"currency":"USD""#,
            #""initial_budget":100,"currency":"USD","reset_at":null"#,
            #""initial_budget":100,"currency":"USD","reset_at":"""#,
            #""initial_budget":100,"currency":"USD","reset_at":"next month""#,
            #""initial_budget":100,"currency":"USD","reset_at":1796083200"#,
            #""initial_budget":100,"currency":"USD","reset_at":true"#,
        ]
        for rest in rests {
            let snapshot = await provider(budget: budgetBody(entry("vibe_budget", rest: rest))).fetch(now: now)
            let bucket = snapshot.buckets.first
            XCTAssertEqual(snapshot.state, .ok, rest)
            XCTAssertEqual(bucket?.resetsAt, .distantFuture, rest)
            XCTAssertNil(bucket?.windowLength, rest)
            XCTAssertEqual(bucket?.allowance?.limitDollars, 100, "the dollars do not need a reset: \(rest)")
            XCTAssertNil(bucket.flatMap { ResetCopy.both(resetsAt: $0.resetsAt, now: now) }, rest)
            XCTAssertNil(bucket?.elapsedFraction(now: now), rest)
        }
    }

    /// Spec § Windows: "every top-level key of `/budget` *ending in* `_budget`".
    func testOnlyAKeyEndingInBudgetIsAWindowNotOneThatMerelyContainsIt() async {
        let body = [
            entry("vibe_budget_total"), entry("x_budgets"), entry("my_budget_for_vibe"), entry("api_budget"),
        ].joined(separator: ",")
        let snapshot = await provider(budget: budgetBody(body)).fetch(now: now)
        XCTAssertEqual(snapshot.buckets.map(\.id), ["mistral_api"], "\(snapshot.buckets.map(\.id))")
    }

    func testTheResetIsTheSameInstantInEveryISOSpellingMistralMightUse() async {
        let spellings = [
            "2026-12-01T00:00:00Z", "2026-12-01T00:00:00+00:00", "2026-12-01T00:00:00.000000Z",
            "2026-12-01T00:00:00.5Z", "2026-12-01T01:00:00+01:00", "2026-11-30T16:00:00-08:00",
        ]
        for spelling in spellings {
            let rest = #""initial_budget":100,"currency":"USD","reset_at":"\#(spelling)""#
            let snapshot = await provider(budget: budgetBody(entry("vibe_budget", rest: rest))).fetch(now: now)
            let reset = snapshot.buckets.first?.resetsAt ?? .distantFuture
            XCTAssertEqual(reset.timeIntervalSince1970, MistralFixture.resetAt.timeIntervalSince1970, accuracy: 1, spelling)
        }
    }

    func testAResetAlreadyInThePastKeepsTheWindowAndClaimsNoPace() async {
        let rest = #""initial_budget":100,"currency":"USD","reset_at":"2026-11-01T00:00:00Z""#
        let snapshot = await provider(budget: budgetBody(entry("vibe_budget", percent: "93", rest: rest))).fetch(now: now)
        let bucket = snapshot.buckets.first
        XCTAssertEqual(snapshot.state, .ok)
        XCTAssertEqual(bucket?.utilization, 93)
        XCTAssertNil(bucket?.elapsedFraction(now: now), "a window that should have reset has no pace to speak of")
    }

    func testAnEntryNestedInsideAnotherOrAKeyThatOnlyLooksLikeABudgetIsNoWindow() async {
        let body = [
            #""data":{"vibe_budget":{"usage_percentage":50}}"#,
            #""budget":{"usage_percentage":50}"#,
            #""Vibe_Budget":{"usage_percentage":50}"#,
            #""_budget":{"usage_percentage":50}"#,
            #""usage_percentage":50"#,
        ].joined(separator: ",")
        let snapshot = await provider(budget: budgetBody(body)).fetch(now: now)
        XCTAssertEqual(snapshot.state, .ok)
        XCTAssertTrue(snapshot.buckets.isEmpty, "\(snapshot.buckets.map(\.id))")
        XCTAssertEqual(snapshot.plan, "Pro")
    }

    func testABudgetBodyThatIsNotAnObjectIsAnErrorWithoutTheBodyInIt() async {
        for body in ["[]", "null", "", "<html>gateway</html>", "5"] {
            let snapshot = await provider(budget: Answer(status: 200, body: body)).fetch(now: now)
            XCTAssertEqual(snapshot.state, .error, body)
            XCTAssertTrue(snapshot.buckets.isEmpty, body)
            XCTAssertFalse(snapshot.stateMessage?.isEmpty ?? true, body)
        }
    }

    // MARK: - Windows: the month, in any time zone

    private func monthLengths(resetting resets: [(String, Int)]) throws -> [Int] {
        try resets.map { reset, _ in
            let body = "{\(entry("vibe_budget", rest: #""initial_budget":100,"currency":"USD","reset_at":"\#(reset)""#))}"
            let entries = try MistralBillingFetcher.decodeBudget(Data(body.utf8))
            let length = try XCTUnwrap(MistralBudgetRules.buckets(from: entries).first?.windowDuration, reset)
            return Int((length / 3600).rounded())
        }
    }

    func testTheWindowIsTheCalendarMonthBeforeItsResetAtEveryMonthBoundaryInEveryTimeZone() throws {
        let resets: [(String, Int)] = [
            ("2026-12-01T00:00:00Z", 30), ("2027-01-01T00:00:00Z", 31), ("2027-03-01T00:00:00Z", 28),
            ("2028-03-01T00:00:00Z", 29), ("2026-04-01T00:00:00Z", 31), ("2026-05-01T00:00:00Z", 30),
            ("2026-11-01T00:00:00Z", 31), ("2026-09-01T00:00:00Z", 31),
        ]
        let expected = resets.map { $0.1 * 24 }
        for zone in ["UTC", "America/Los_Angeles", "Pacific/Auckland", "Asia/Kolkata", "Europe/Berlin"] {
            let hours = try withDefaultTimeZone(zone) { try monthLengths(resetting: resets) }
            XCTAssertEqual(hours, expected, "the machine's time zone (\(zone)) must not move the month")
        }
    }

    func testAMonthlyWindowIsNeverTakenForAWeekByPaceOrTheHeader() throws {
        let body = "{\(entry("vibe_budget", percent: "50")),\(entry("api_budget", percent: "10"))}"
        let buckets = MistralBudgetRules.buckets(from: try MistralBillingFetcher.decodeBudget(Data(body.utf8)))
        let vibe = try XCTUnwrap(buckets.first)
        let nov20 = Date(timeIntervalSince1970: 1_795_132_800)
        let fraction = try XCTUnwrap(vibe.elapsedFraction(now: nov20))
        XCTAssertEqual(fraction, 19.0 / 30.0, accuracy: 1e-9, "Nov 20 is 19 of November's 30 days in")
        XCTAssertEqual(PopoverCopy.limitsHeader(for: buckets), "Monthly limits")
    }

    func testEveryCalendarMonthLengthIsMonthlyForTheHeaderAndAWeekPlusASecondIsToo() {
        let day: TimeInterval = 24 * 3600
        for days in [28.0, 29, 30, 31] {
            let bucket = Fixture.bucket(id: "mistral_vibe", label: "Vibe", kind: .weekly, windowLength: days * day)
            XCTAssertEqual(PopoverCopy.limitsHeader(for: [bucket]), "Monthly limits", "\(days)")
        }
        let justOver = Fixture.bucket(id: "x", kind: .weekly, windowLength: 8 * day + 1)
        XCTAssertEqual(PopoverCopy.limitsHeader(for: [justOver]), "Monthly limits")
        XCTAssertEqual(PopoverCopy.limitsHeader(for: []), "Weekly limits")
    }

    /// A row whose length nothing states and nothing infers keeps the header every provider had
    /// before Mistral: "Weekly limits" (a window of unknown length is never called monthly).
    func testRowsOfNoKnownLengthKeepTheWeeklyHeaderAndAMixWithAMonthIsJustLimits() {
        let unknown = Fixture.bucket(id: "other_window", label: "Other", kind: .other)
        XCTAssertNil(unknown.windowDuration)
        XCTAssertEqual(PopoverCopy.limitsHeader(for: [unknown]), "Weekly limits")
        let month = Fixture.bucket(id: "mistral_vibe", label: "Vibe", kind: .weekly, windowLength: 30 * 24 * 3600)
        XCTAssertEqual(PopoverCopy.limitsHeader(for: [unknown, month]), "Limits")
        XCTAssertEqual(PopoverCopy.limitsHeader(for: [month, month]), "Monthly limits")
    }

    // MARK: - States: every row through retention and the way out

    private func shown(after failure: Answer?, key: String? = MistralFixture.key) async -> ServiceSnapshot {
        let good = await provider().fetch(now: now)
        let later = now.addingTimeInterval(600)
        let failed = await provider(key: key, budget: failure).fetch(now: later)
        let merged = AppState.mergingPoll(previous: services([good]), next: services([failed], at: later))
        return merged.services[0]
    }

    func testEveryFailureAfterAGoodReadingKeepsTheWindowsDimmedWithItsOwnState() async {
        let cases: [(String, Answer?, String?, ServiceState)] = [
            ("401", Answer(status: 401, body: "{}"), MistralFixture.key, .notSignedIn),
            ("no key", Answer(status: 200, body: "{}"), nil, .notSignedIn),
            ("403", Answer(status: 403, body: "{}"), MistralFixture.key, .error),
            ("429", Answer(status: 429, body: "{}", headers: ["Retry-After": "90"]), MistralFixture.key, .error),
            ("503", Answer(status: 503, body: ""), MistralFixture.key, .error),
            ("offline", nil, MistralFixture.key, .error),
            ("garbage", Answer(status: 200, body: "[]"), MistralFixture.key, .error),
        ]
        for (name, answer, key, state) in cases {
            let service = await shown(after: answer, key: key)
            XCTAssertEqual(service.state, state, name)
            XCTAssertTrue(service.isRetained, name)
            XCTAssertEqual(service.buckets.map(\.id), ["mistral_vibe", "mistral_api"], name)
            XCTAssertEqual(service.buckets.first?.allowance?.limitDollars, 300, name)
            XCTAssertEqual(service.plan, "Pro", name)
            XCTAssertEqual(service.fetchedAt, now, "the numbers are dated by when they were read: \(name)")
            XCTAssertNotNil(service.stateMessage, name)
        }
    }

    func testARetainedStateKeepsItsReasonItsRetryAndItsWayOut() async {
        let signedOut = await shown(after: Answer(status: 401, body: "{}"))
        XCTAssertEqual(signedOut.signedOutReason, .expired)
        XCTAssertEqual(help(signedOut)?.message, MistralCopy.signedOutHelp)
        XCTAssertEqual(help(signedOut)?.command, "vibe")

        let noKey = await shown(after: nil, key: nil)
        XCTAssertEqual(noKey.signedOutReason, .notFound)
        XCTAssertEqual(help(noKey)?.message, MistralCopy.notSignedInHelp)

        let noAccess = await shown(after: Answer(status: 403, body: "{}"))
        XCTAssertEqual(noAccess.stateMessage, MistralCopy.noUsageAccessMessage)
        XCTAssertEqual(help(noAccess)?.message, MistralCopy.noUsageAccessHelp)

        let limited = await shown(after: Answer(status: 429, body: "{}", headers: ["Retry-After": "90"]))
        XCTAssertEqual(limited.retryAfter, 90)
    }

    private func help(_ service: ServiceSnapshot) -> ProviderStateHelp? {
        ProviderStateHelp.help(for: service, claudeBinaryFound: true, claudeNote: nil, antigravityInstalled: true)
    }

    func testNoBillingAfterAGoodReadingIsAPlanWithNoWindowsAndNotAnError() async {
        let service = await shown(after: Answer(status: 404, body: "{}"))
        XCTAssertEqual(service.state, .ok)
        XCTAssertNil(service.stateMessage)
        XCTAssertFalse(service.isRetained)
        XCTAssertTrue(service.buckets.isEmpty)
        XCTAssertEqual(service.plan, "Pro")
    }

    func testTheFirstAnswerBeingNoUsageAccessShowsThePlanAndNoWindows() async {
        let snapshot = await provider(budget: Answer(status: 403, body: "{}")).fetch(now: now)
        let merged = AppState.mergingPoll(previous: .empty, next: services([snapshot]))
        let service = merged.services[0]
        XCTAssertEqual(service.state, .error)
        XCTAssertEqual(service.plan, "Pro")
        XCTAssertTrue(service.buckets.isEmpty)
        XCTAssertFalse(service.isRetained)
        XCTAssertEqual(help(service)?.message, MistralCopy.noUsageAccessHelp)
    }

    func testTheAllowanceComesBackFromLastKnownJSONAfterARelaunchWhileTheKeyIsRefused() async throws {
        let file = directory.appendingPathComponent("last-known.json")
        let good = await provider().fetch(now: now)
        await LastKnownStore(fileURL: file).remember([good])

        let stored = await LastKnownStore(fileURL: file).load()
        let refused = await provider(budget: Answer(status: 401, body: "{}")).fetch(now: now.addingTimeInterval(86_400))
        let merged = AppState.mergingPoll(previous: .empty, next: services([refused]), stored: stored)
        let service = merged.services[0]
        XCTAssertTrue(service.isRetained)
        XCTAssertEqual(service.state, .notSignedIn)
        XCTAssertEqual(
            AllowanceCopy.caption(for: service, locale: locale),
            "Vibe: $17.88 of the $300 monthly allowance\nAPI: $0.00 of the $30 monthly allowance"
        )
        let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        XCTAssertFalse(text.contains(MistralFixture.key))
    }

    func testAFailedPollIsNeverWrittenOverTheStoredReading() async {
        let file = directory.appendingPathComponent("last-known.json")
        let store = LastKnownStore(fileURL: file)
        await store.remember([await provider().fetch(now: now)])
        for budget in [Answer(status: 401, body: "{}"), Answer(status: 403, body: "{}"), Answer(status: 503, body: "")] {
            await store.remember([await provider(budget: budget).fetch(now: now.addingTimeInterval(60))])
        }
        let stored = await LastKnownStore(fileURL: file).load()
        XCTAssertEqual(stored["mistral"]?.buckets.map(\.id), ["mistral_vibe", "mistral_api"])
        XCTAssertEqual(stored["mistral"]?.plan, "Pro")
    }

    // MARK: - Where the key can end up

    /// An answer that echoes the key back, as a server may in an error body.
    private func echo(_ status: Int) -> Answer {
        Answer(status: status, body: #"{"message":"Invalid API key \#(MistralFixture.key)","key":"\#(MistralFixture.key)"}"#)
    }

    func testAKeyEchoedBackByMistralReachesNeitherTheSnapshotNorAnyFileTheAppWrites() async throws {
        let echoed: [Answer?] = [
            echo(200), echo(400), echo(401), echo(403), echo(404), echo(429), echo(500), echo(502), echo(302),
            Answer(status: 200, body: "<html>\(MistralFixture.key)</html>"),
            Answer(status: 200, body: "[\"\(MistralFixture.key)\"]"),
            Answer(status: 200, body: "{\"vibe_budget\":{\"usage_percentage\":\"\(MistralFixture.key)\"}}"),
        ]
        let file = directory.appendingPathComponent("last-known.json")
        let store = LastKnownStore(fileURL: file)
        for answer in echoed {
            let status = answer?.status ?? 0
            for snapshot in [
                await provider(budget: answer).fetch(now: now),
                await provider(subscription: echo(200), budget: answer).fetch(now: now),
            ] {
                let tag = "\(status) \(snapshot.state)"
                XCTAssertFalse(String(describing: snapshot).contains(MistralFixture.key), tag)
                XCTAssertFalse(String(reflecting: snapshot).contains(MistralFixture.key), tag)
                if let helpText = help(snapshot) { XCTAssertFalse(helpText.message.contains(MistralFixture.key), tag) }

                let statusFile = StatusFileWriter.build(services: [snapshot], costs: [:], agents: .none, now: now)
                let statusJSON = String(decoding: try StatusFile.encoder.encode(statusFile), as: UTF8.self)
                XCTAssertFalse(statusJSON.contains(MistralFixture.key), tag)

                let widget = try JSONEncoder().encode(WidgetBridge.widgetServices(from: [snapshot]))
                XCTAssertFalse(String(decoding: widget, as: UTF8.self).contains(MistralFixture.key), tag)

                let merged = AppState.mergingPoll(previous: services([snapshot]), next: services([snapshot]))
                XCTAssertFalse(String(describing: merged).contains(MistralFixture.key), tag)
                await store.remember([snapshot])
            }
        }
        if let data = try? Data(contentsOf: file) {
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(MistralFixture.key))
        }
    }

    func testAnErrorThatCarriesTheRequestDoesNotPutItsHeadersInTheMessage() async {
        struct Loud: LocalizedError {
            let request: URLRequest
            var errorDescription: String? { "failed: \(request.url?.host ?? "")" }
        }
        let fetcher = MistralBillingFetcher(transport: { request in throw Loud(request: request) })
        let result = await fetcher.fetch(apiKey: MistralFixture.key)
        guard case .failure(.transport(let words)) = result else { return XCTFail("\(result)") }
        XCTAssertFalse(words.contains(MistralFixture.key))
        XCTAssertFalse(String(describing: result).contains(MistralFixture.key))
    }

    // MARK: - The provider keeps its answer 60 s

    func testAnAnswerIsKeptWhateverItWasAndAskedAgainAtSixtySeconds() async {
        for budget in [Answer(status: 401, body: "{}"), Answer(status: 503, body: ""), Answer(status: 200, body: MistralFixture.budgetBody)] {
            let requests = MistralFixture.Requests()
            let mistral = provider(budget: budget, requests: requests)
            let first = await mistral.fetch(now: now)
            let again = await mistral.fetch(now: now.addingTimeInterval(59.9))
            XCTAssertEqual(again.state, first.state, "\(budget.status)")
            XCTAssertEqual(again.fetchedAt, first.fetchedAt, "the kept answer keeps its own time: \(budget.status)")
            let afterOne = await requests.seen.count
            XCTAssertEqual(afterOne, 2, "\(budget.status)")
            _ = await mistral.fetch(now: now.addingTimeInterval(60))
            let afterTwo = await requests.seen.count
            XCTAssertEqual(afterTwo, 4, "\(budget.status)")
        }
    }

    func testNoKeyAsksNothingAtAnyPollAndAKeyAppearingIsSeenAtTheNextAnswer() async throws {
        let url = directory.appendingPathComponent(".env")
        let requests = MistralFixture.Requests()
        let mistral = MistralProvider(
            credentials: MistralCredentialReader(keychain: { nil }, envFileURL: url),
            fetcher: MistralBillingFetcher(transport: MistralFixture.transport(requests: requests))
        )
        let before = await mistral.fetch(now: now)
        XCTAssertEqual(before.state, .notSignedIn)
        try Data("MISTRAL_API_KEY=late-key\n".utf8).write(to: url)
        let after = await mistral.fetch(now: now.addingTimeInterval(61))
        XCTAssertEqual(after.state, .ok)
        let seen = await requests.seen
        XCTAssertEqual(seen.compactMap { $0.value(forHTTPHeaderField: "Authorization") }, ["Bearer late-key", "Bearer late-key"])
    }

    // MARK: - Surfaces

    func testAnExistingUserWithoutVibeHasMistralListedOffAndNeverPolled() {
        let four = ["claude", "codex", "antigravity", "grok"].map { Fixture.snapshot(id: $0) }
        let rows = ProvidersSettingsCopy.rows(services: four)
        XCTAssertEqual(rows.map(\.id), ["claude", "codex", "antigravity", "grok", "mistral"])
        XCTAssertEqual(ProvidersSettingsCopy.status(for: nil, isEnabled: false, now: now).text, "Off")

        let polled = AppState.polledServiceIDs(
            claudeEnabled: true, codexEnabled: true, antigravityEnabled: true, grokEnabled: true,
            mistralEnabled: false, hasAdminKey: false
        )
        XCTAssertEqual(polled, ["claude", "codex", "antigravity", "grok"])
        XCTAssertTrue(DashboardState.switchedOff(polled: polled).contains("mistral"))
        XCTAssertFalse(DashboardState.switchedOff(polled: polled.union(["mistral"])).contains("mistral"))
    }

    func testMistralHasOneSettingsRowEvenWhenItsServiceIsInThePoll() {
        let services = ["claude", "mistral", "anthropic-admin"].map { Fixture.snapshot(id: $0) }
        let rows = ProvidersSettingsCopy.rows(services: services)
        XCTAssertEqual(rows.filter { $0.id == "mistral" }.count, 1)
        XCTAssertEqual(rows.last?.id, "anthropic-admin")
        XCTAssertEqual(rows.first { $0.id == "mistral" }?.hasSwitch, true)
    }

    func testAMistralSwitchedOnReadsConnectedWithItsPlanAndSignInNeededWithoutAKey() async {
        let good = await provider().fetch(now: now)
        XCTAssertEqual(ProvidersSettingsCopy.status(for: good, isEnabled: true, now: now).text, "Connected · Pro")
        let none = await provider(key: nil).fetch(now: now)
        XCTAssertEqual(ProvidersSettingsCopy.status(for: none, isEnabled: true, now: now).text, "Sign in needed")
    }

    func testTheGridForOneToSixProvidersWithMistralLast() {
        let ids = ["claude", "codex", "antigravity", "grok", "mistral"]
        XCTAssertTrue(ProviderGridRules.grid(serviceIDs: ["mistral"], showsCostTile: true).tileRows.isEmpty, "its page is home")
        XCTAssertEqual(
            ProviderGridRules.grid(serviceIDs: ["claude", "mistral"], showsCostTile: true),
            ProviderGridRules.Grid(tileRows: [[.provider("claude"), .provider("mistral")]], costInLowerRow: true)
        )
        XCTAssertEqual(
            ProviderGridRules.grid(serviceIDs: ids, showsCostTile: false),
            ProviderGridRules.Grid(
                tileRows: [
                    [.provider("claude"), .provider("codex")],
                    [.provider("antigravity"), .provider("grok")],
                    [.provider("mistral"), .empty],
                ],
                costInLowerRow: false
            )
        )
        let six = ["claude", "anthropic-admin"] + ids.dropFirst()
        XCTAssertEqual(ProviderGridRules.grid(serviceIDs: six, showsCostTile: true).tileRows.count, 3)
        XCTAssertTrue(ProviderGridRules.grid(serviceIDs: six, showsCostTile: true).costInLowerRow)
    }

    // MARK: - The All providers widget at four, five and six providers

    private func widgetService(_ id: String, _ buckets: [WidgetBucket]) -> WidgetService {
        WidgetService(id: id, name: id.capitalized, icon: "circle", plan: nil, buckets: buckets)
    }

    private let claudeWindows = [
        WidgetBucket(id: "five_hour", label: "Session", percent: 30, kind: "session"),
        WidgetBucket(id: "seven_day", label: "All models", percent: 60, kind: "weekly"),
        WidgetBucket(id: "seven_day_fable", label: "Fable only", percent: 80, kind: "modelSpecific"),
    ]

    func testTheWidgetListsAllFourWithTwoRowsEachFiveWithOneAndSixShowFive() {
        let ids = ["claude", "codex", "antigravity", "grok", "mistral", "extra"]
        for count in [1, 2, 3, 4, 5, 6] {
            let snapshot = WidgetSnapshot(
                services: ids.prefix(count).map { widgetService($0, claudeWindows) }, updatedAt: Date(timeIntervalSince1970: 0)
            )
            let shown = WidgetEntryRules.allProvidersShown(snapshot)
            XCTAssertEqual(shown.map(\.id), Array(ids.prefix(min(count, 5))), "\(count) providers")
            let rows = WidgetEntryRules.windowRowsPerProvider(shown: shown.count)
            XCTAssertEqual(rows, count <= 4 ? 2 : 1, "\(count) providers")
            XCTAssertEqual(
                WidgetEntryRules.windowRows(of: shown[0], limit: rows).map(\.id),
                count <= 4 ? ["five_hour", "seven_day_fable"] : ["five_hour"],
                "\(count) providers"
            )
        }
    }

    func testAProviderWithNoWindowsGetsNoRowsInTheWidgetAndNothingBreaks() {
        let empty = widgetService("mistral", [])
        XCTAssertTrue(WidgetEntryRules.windowRows(of: empty, limit: 1).isEmpty)
        XCTAssertTrue(WidgetEntryRules.windowRows(of: empty, limit: 0).isEmpty)
        XCTAssertTrue(WidgetEntryRules.windowRows(of: widgetService("claude", claudeWindows), limit: 0).isEmpty)
        XCTAssertTrue(WidgetEntryRules.allProvidersShown(WidgetSnapshot(services: [], updatedAt: Date(timeIntervalSince1970: 0))).isEmpty)
    }

    func testMistralsWindowsInTheWidgetCarryNoDollarsAndSurviveRetentionDimmed() async throws {
        let good = await provider().fetch(now: now)
        let widget = try XCTUnwrap(WidgetBridge.widgetServices(from: [good]).first)
        let json = String(decoding: try JSONEncoder().encode(widget), as: UTF8.self)
        XCTAssertFalse(json.lowercased().contains("allowance"))
        XCTAssertFalse(json.contains("17.8"), json)
        XCTAssertEqual(widget.buckets.map(\.percent), [5.9597507033333335, 0])
        let retained = await shown(after: Answer(status: 401, body: "{}"))
        let dimmed = try XCTUnwrap(WidgetBridge.widgetServices(from: [retained]).first)
        XCTAssertTrue(dimmed.isRetained)
        XCTAssertEqual(dimmed.buckets.map(\.id), ["mistral_vibe", "mistral_api"])
    }

    func testStatusJSONCarriesNoDollarsForMistralInAnyState() async throws {
        for answer in [Answer(status: 200, body: MistralFixture.budgetBody), Answer(status: 401, body: "{}")] {
            let service = await shown(after: answer)
            let file = StatusFileWriter.build(services: [service], costs: [:], agents: .none, now: now)
            let json = String(decoding: try StatusFile.encoder.encode(file), as: UTF8.self)
            XCTAssertFalse(json.lowercased().contains("allowance"), json)
            XCTAssertNil(file.services.first?.windows.first?.usedDollars)
            XCTAssertEqual(file.services.first?.windows.map(\.id), ["mistral_vibe", "mistral_api"])
        }
    }
}
