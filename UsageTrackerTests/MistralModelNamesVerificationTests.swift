import XCTest
@testable import Omelette

/// Verifier's tests for spec 2026-11-19 Mistral model names § Rule (the order across the two ids),
/// § Untrusted names (what a usable name is), § Where it shows (Overview rows, History's window
/// rows and the chat's by-model row, resolved from the table as it is when they are built) and
/// § What does not change (prices, tokens, the ledger file, the row's id, other providers' names).
/// Fixtures are models.dev's rows as fetched (`ModelsDevMistralFixture`) and vibe's own sessions
/// (`VibeFixture`) under a per-test temp root; nothing reads the real `~/.vibe`, Application
/// Support, keychain, network or clock.
final class MistralModelNamesVerificationTests: XCTestCase {
    private var directory: URL!
    private var root: URL { directory.appendingPathComponent("unified", isDirectory: true) }
    private var ledgerURL: URL { directory.appendingPathComponent("vibe-usage-ledger-v1.json") }

    /// 2026-11-06 18:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_793_988_000)
    /// 2026-11-06 00:00 UTC.
    private let nov6 = Date(timeIntervalSince1970: 1_793_923_200)
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    private var family: [String: MistralModelPricing.Model] {
        ModelsDevPricing.parseFamily(ModelsDevMistralFixture.root, provider: ModelsDevPricing.vibeFamily)
    }

    /// The same rows and prices with every name removed: what the table was before names mattered.
    private var familyWithoutNames: [String: MistralModelPricing.Model] {
        family.mapValues { MistralModelPricing.Model(price: $0.price, name: nil) }
    }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MistralModelNamesVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        MistralModelPricing.update(family)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        MistralModelPricing.update([:])
    }

    private func name(_ active: String?, _ sent: String? = nil) -> String? {
        MistralModelPricing.displayName(activeModel: active, modelName: sent)
    }

    /// The fixture family with one extra row.
    private func with(_ id: String, name: String?, price: ModelPrice? = nil) {
        var edited = family
        edited[id] = MistralModelPricing.Model(price: price, name: name)
        MistralModelPricing.update(edited)
    }

    private func aggregator(persisted: Bool = true) -> VibeUsageAggregator {
        VibeUsageAggregator(rootURL: root, ledgerURL: persisted ? ledgerURL : nil, calendar: utc)
    }

    private func writeSessions(_ sessions: [VibeFixture.Session]) throws {
        for session in sessions { try VibeFixture.write(session, under: root) }
    }

    // MARK: - Rule: the order across the two ids

    func testANameReadFromEitherIdBeatsAShorterLineOfEitherId() {
        // active_model only has a shorter line (mistral-large-4); model_name reads as "Devstral 2".
        // Step 2 runs over both ids before step 3 starts.
        XCTAssertEqual(name("mistral-large-4-0-3", "devstral-2"), "Devstral 2")
    }

    func testAnExactKeyOfTheIdSentBeatsANameReadFromTheAlias() {
        // Step 1 runs over both ids before step 2: zai-glm-5-3 is a key, "devstral-2" only a name.
        XCTAssertEqual(name("devstral-2", "zai-glm-5-3"), "GLM-5.3")
    }

    func testWhenBothIdsOnlyReadAsNamesTheAliasIsFirst() {
        XCTAssertEqual(name("devstral-2", "glm-5.2"), "Devstral 2")
        XCTAssertEqual(name("glm-5.2", "devstral-2"), "GLM-5.2")
    }

    func testAnExactKeyBeatsAShorterLineOfTheOtherId() {
        // "mistral-large-4-0-3" has a shorter line; the id sent is a key.
        XCTAssertEqual(name("mistral-large-4-0-3", "zai-glm-5-3"), "GLM-5.3")
    }

    func testTheSentIdsShorterLineNamesAModelTheAliasDoesNot() {
        XCTAssertEqual(name("some-new-model", "mistral-large-4-0-3"), "Mistral Large 4")
    }

    func testTheShorterLineWalkStopsAfterThreeParts() {
        XCTAssertEqual(name("mistral-large-4-0-3-9"), "Mistral Large 4", "three parts less: -4-0-3, -4-0, -4")
        XCTAssertNil(name("mistral-large-4-0-3-9-9"), "four parts less is one too many")
    }

    func testAnIdIsReadWhateverItsCase() {
        XCTAssertEqual(name("Mistral-Large-4-0-3"), "Mistral Large 4")
        XCTAssertEqual(name("ZAI-GLM-5-3"), "GLM-5.3")
        XCTAssertEqual(name("DEVSTRAL-2"), "Devstral 2")
    }

    func testAnEmptyOrNilIdIsPassedOverAndTheOtherNamesTheModel() {
        XCTAssertEqual(name(nil, "zai-glm-5-3"), "GLM-5.3")
        XCTAssertEqual(name("", "zai-glm-5-3"), "GLM-5.3")
        XCTAssertEqual(name("zai-glm-5-3", nil), "GLM-5.3")
        XCTAssertEqual(name("zai-glm-5-3", ""), "GLM-5.3")
        XCTAssertNil(name("   ", nil), "an id of blanks reads as nothing")
        XCTAssertNil(name("\n", ""))
    }

    func testAnEmptyTableLeavesEveryIdWithNoNameWhateverItsShape() {
        MistralModelPricing.update([:])
        for id in ["mistral-large-4", "zai-glm-5-3", "devstral-2", "", "x"] {
            XCTAssertNil(name(id, id), id)
        }
    }

    /// The name is found where the price is: whenever both exist they come from one row, and
    /// neither is found without the other on a family whose every row has both.
    func testTheNameIsFoundWhereThePriceIs() {
        let table = family
        let ids: [String?] = [
            "mistral-large-4", "mistral-large-4-0-3", "mistral-large-4-0-8", "mistral-large-4-0-3-9", "mistral-large-4-0-3-9-9",
            "mistral-medium-3.5", "mistral-medium-2604", "mistral-vibe-cli-latest", "mistral-medium-latest",
            "glm-5-3", "zai-glm-5-3", "zai-glm-5-3-flash", "glm-5.3", "glm-5.2", "glm-5-2",
            "devstral-2", "devstral-2512", "devstral-latest", "some-new-model", "", nil,
        ]
        for active in ids {
            for sent in ids {
                let shown = name(active, sent)
                let rate = MistralModelPricing.price(activeModel: active, modelName: sent)
                XCTAssertEqual(shown == nil, rate == nil, "\(active ?? "nil") / \(sent ?? "nil"): named \(shown ?? "nil"), priced \(rate != nil)")
                if let shown, let rate {
                    XCTAssertTrue(
                        table.values.contains { $0.name == shown && $0.price == rate },
                        "\(active ?? "nil") / \(sent ?? "nil"): the name \(shown) and the rate come from different rows"
                    )
                }
            }
        }
    }

    func testRowsSharingANameAtTwoRatesStillGiveItWhateverTheOtherIdIs() {
        MistralModelPricing.update(
            ModelsDevPricing.parseFamily(ModelsDevMistralFixture.rootWithDifferingDuplicates, provider: ModelsDevPricing.vibeFamily)
        )
        XCTAssertEqual(name("devstral-2", "some-new-model"), "Devstral 2")
        XCTAssertEqual(name("some-new-model", "devstral-2"), "Devstral 2")
        XCTAssertNil(MistralModelPricing.price(activeModel: "devstral-2", modelName: "some-new-model"))
    }

    func testARowWithAPriceAndNoNameStillNamesNothingWhileItsPriceStands() {
        MistralModelPricing.update(familyWithoutNames)
        XCTAssertNil(name("zai-glm-5-3", "glm-5-3"))
        XCTAssertNotNil(MistralModelPricing.price(activeModel: "glm-5-3", modelName: "zai-glm-5-3"))
    }

    func testAnUnusableNameInOneRowDoesNotHideAUsableOneInAnotherRowTheIdReadsAs() {
        // Two rows whose names read as the same id: the first by row id has a name of 100 characters
        // (once outer blanks are trimmed), the second a usable one.
        let long = String(repeating: "a", count: 30) + String(repeating: " ", count: 40) + String(repeating: "b", count: 30)
        let short = String(repeating: "a", count: 30) + " " + String(repeating: "b", count: 30)
        var edited = family
        edited["a-row"] = MistralModelPricing.Model(price: nil, name: long)
        edited["b-row"] = MistralModelPricing.Model(price: nil, name: short)
        MistralModelPricing.update(edited)
        let id = String(repeating: "a", count: 30) + "-" + String(repeating: "b", count: 30)
        XCTAssertEqual(name(id), short)
    }

    func testANameNoLongerReadAsAnIdWhenItsRowIsUnusableLeavesNothingToShow() {
        let overlong = String(repeating: "a", count: 65)
        with("only-row", name: overlong)
        XCTAssertNil(name(overlong))
        XCTAssertNil(name("only-row"), "the key is found, its name is unusable, and no shorter line names it")
    }

    func testAtTheShorterLineStepTheAliasIsFirstThenTheIdSent() {
        // Neither id is a key or reads as a name; each has a different shorter line.
        XCTAssertEqual(name("mistral-large-4-0-3", "zai-glm-5-3-9"), "Mistral Large 4")
        XCTAssertEqual(name("zai-glm-5-3-9", "mistral-large-4-0-3"), "GLM-5.3")
    }

    func testTheShorterLineWalkGoesPastARowWithNoUsableName() {
        // mistral-large-4-0 has a row but its name is unusable: the walk goes on to mistral-large-4.
        with("mistral-large-4-0", name: String(repeating: "x", count: 65))
        XCTAssertEqual(name("mistral-large-4-0-3"), "Mistral Large 4")
    }

    func testRowsNamedAlikeButSpelledApartGiveTheSpellingOfTheFirstRowId() {
        var edited = family
        edited["a-row"] = MistralModelPricing.Model(price: nil, name: "Devstral Two")
        edited["b-row"] = MistralModelPricing.Model(price: nil, name: "devstral two")
        MistralModelPricing.update(edited)
        XCTAssertEqual(name("devstral-two"), "Devstral Two")
    }

    func testAnIdOfNoLettersNeverReadsAsARowWhoseNameHasNone() {
        // The price rule's guard, kept: nameKey of both is empty, which is no match.
        with("punctuation-row", name: "***")
        XCTAssertNil(name("!!!"))
        XCTAssertNil(MistralModelPricing.price(activeModel: "!!!", modelName: nil))
    }

    // MARK: - Untrusted names

    func testEveryControlCharacterIsDroppedC0DelAndC1() {
        // NUL, TAB, LF, ESC, a C0 mid-name; DEL; C1 including NEL (U+0085) and CSI (U+009B).
        with("zai-glm-5-3", name: "G\u{00}L\u{09}M\u{0A}-\u{1B}5\u{7F}.\u{85}3\u{9B}\u{9F}")
        XCTAssertEqual(name("zai-glm-5-3"), "GLM-5.3")
    }

    func testANameOfOnlyBlanksOfAnyKindIsNoName() {
        for blank in [" ", "\u{A0}", " \u{A0}\u{2028}\u{2029} ", "\u{7F}\u{85} \u{9B}", "\t\r\n"] {
            with("zai-glm-5-3", name: blank)
            XCTAssertNil(name("zai-glm-5-3"), "U+\(blank.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: "+"))")
        }
    }

    func testNonASCIINamesAreKeptAsTheyAre() {
        with("zai-glm-5-3", name: "Größe 日本語 café")
        XCTAssertEqual(name("zai-glm-5-3"), "Größe 日本語 café")
    }

    func testTheSixtyFourCharacterLimitCountsCharactersNotBytesOrUTF16Units() {
        let accents = String(repeating: "é", count: 64)       // 128 bytes
        let cjk = String(repeating: "日", count: 64)          // 192 bytes
        let emoji = String(repeating: "😀", count: 64)        // 2 UTF-16 units each
        for sixtyFour in [accents, cjk, emoji] {
            with("zai-glm-5-3", name: sixtyFour)
            XCTAssertEqual(name("zai-glm-5-3"), sixtyFour, "64 characters")
            with("zai-glm-5-3", name: sixtyFour + "x")
            XCTAssertNil(name("zai-glm-5-3"), "65 characters")
        }
    }

    func testANameOfSixtyFiveBeforeCleaningAndSixtyFourAfterIsUsed() {
        let sixtyFour = String(repeating: "N", count: 64)
        let middle = String(sixtyFour.prefix(30)) + "\u{07}" + String(sixtyFour.suffix(34))
        XCTAssertEqual(middle.count, 65)
        with("zai-glm-5-3", name: middle)
        XCTAssertEqual(name("zai-glm-5-3"), sixtyFour)
    }

    func testANameOfSixtyFiveAfterCleaningIsNotUsedAndTheShorterLineTakesOver() {
        let sixtyFive = String(repeating: "N", count: 65)
        with("mistral-large-4-0-3", name: "\u{07}" + sixtyFive + "\u{1B}")
        XCTAssertEqual(name("mistral-large-4-0-3"), "Mistral Large 4")
    }

    // MARK: - Where it shows: Overview and History rows

    func testTheOverviewAndHistoryRowsCarryTheSameNamesAndTheOverviewCardListsThem() async throws {
        try writeSessions([VibeFixture.whole(), VibeFixture.glm(), VibeFixture.medium()])
        let vibe = aggregator()
        await vibe.refresh(now: now)
        let today = await vibe.breakdown(now: now)
        let window = await vibe.usage(from: nov6, to: now)
        XCTAssertEqual(Set(today.byModelToday.map(\.model)), ["Mistral Large 4", "GLM-5.3", "Mistral Medium 3.5"])
        XCTAssertEqual(Set(window.models.map(\.model)), Set(today.byModelToday.map(\.model)))
        XCTAssertEqual(Set(OverviewCLIRules.modelRows(today.byModelToday).map(\.model)), Set(today.byModelToday.map(\.model)))
    }

    func testRowsFollowTheTableAsItIsWhenTheyAreBuiltNotAsItWasWhenTheLedgerWasRead() async throws {
        try writeSessions([VibeFixture.glm()])
        MistralModelPricing.update([:])
        let vibe = aggregator()
        await vibe.refresh(now: now)
        let offline = await vibe.breakdown(now: now)
        XCTAssertEqual(offline.byModelToday.map(\.model), ["Glm 5 3"])
        // models.dev answers after the refresh: the next rows built use it, with no new refresh.
        MistralModelPricing.update(family)
        let online = await vibe.breakdown(now: now)
        XCTAssertEqual(online.byModelToday.map(\.model), ["GLM-5.3"])
        XCTAssertEqual(online.byModelToday.map(\.tokens), offline.byModelToday.map(\.tokens))
        let window = await vibe.usage(from: nov6, to: now)
        XCTAssertEqual(window.models.map(\.model), ["GLM-5.3"])
        MistralModelPricing.update([:])
        let back = await vibe.breakdown(now: now)
        XCTAssertEqual(back.byModelToday.map(\.model), ["Glm 5 3"])
    }

    func testIdsOfOneNameAreOneRowWhoseTotalsAreTheirSumAndAListedPatchStaysApart() async throws {
        var line = VibeFixture.repeated()
        line.activeModel = "mistral-large-4"
        line.modelName = nil
        var patch = VibeFixture.pruned()
        patch.activeModel = "mistral-large-4-0-8"
        patch.modelName = nil
        var other = VibeFixture.medium()
        other.activeModel = "mistral-large-4-0-3"    // a third id of the one name
        other.modelName = "mistral-large-4-0"
        try writeSessions([VibeFixture.whole(), line, patch, other, VibeFixture.glm()])
        let vibe = aggregator()
        await vibe.refresh(now: now)
        let b = await vibe.breakdown(now: now)
        let byName = Dictionary(uniqueKeysWithValues: b.byModelToday.map { ($0.model, $0) })
        XCTAssertEqual(Set(byName.keys), ["Mistral Large 4", "Mistral Large 4.0.8", "GLM-5.3"])
        // whole 66 132 + repeated 6 997 + medium's tokens (7 065) under the one name; pruned 797 997; glm 6 866.
        XCTAssertEqual(byName["Mistral Large 4"]?.tokens, 66_132 + 6_997 + 7_065)
        XCTAssertEqual(byName["Mistral Large 4.0.8"]?.tokens, 797_997)
        XCTAssertEqual(byName["GLM-5.3"]?.tokens, 6_866)
        XCTAssertEqual(b.byModelToday.reduce(0) { $0 + $1.tokens }, b.todayTokens, "regrouping loses nothing")
        XCTAssertEqual(b.byModelToday.reduce(0.0) { $0 + $1.cost }, b.todayCost, accuracy: 1e-12)
        XCTAssertEqual(b.byModelToday.reduce(TokenBreakdown.zero) { $0 + $1.breakdown }.total, b.todayTokenBreakdown.total)
    }

    func testAModelTheTableDoesNotKnowStaysItsOwnRowUnderTheNameTheAppGivesIt() async throws {
        var unknown = VibeFixture.repeated()
        unknown.activeModel = "some-new-model"
        unknown.modelName = nil
        try writeSessions([VibeFixture.whole(), unknown])
        let vibe = aggregator(persisted: false)
        await vibe.refresh(now: now)
        let named = await vibe.breakdown(now: now).byModelToday.map(\.model).sorted()
        MistralModelPricing.update([:])
        let bare = await vibe.breakdown(now: now).byModelToday.map(\.model).sorted()
        XCTAssertEqual(named, ["Mistral Large 4", ModelPricing.displayName(for: "some-new-model")].compactMap { $0 }.sorted())
        XCTAssertEqual(bare, ["Mistral Large 4 0 3", ModelPricing.displayName(for: "some-new-model")].compactMap { $0 }.sorted())
    }

    // MARK: - What does not change

    func testNamingChangesNeitherPricesNorTokensNorCountsNorTheLedgerFile() async throws {
        try writeSessions([
            VibeFixture.whole(), VibeFixture.pruned(), VibeFixture.repeated(), VibeFixture.noTotal(), VibeFixture.glm(),
        ])
        // Only sessions priced by an exact key: a model priced through its name's reading (the default
        // medium alias) would lose its price with the names stripped, which says nothing about naming.

        MistralModelPricing.update(familyWithoutNames)
        let bare = aggregator()
        await bare.refresh(now: now)
        let bareDay = await bare.breakdown(now: now)
        let bareWindow = await bare.usage(from: nov6, to: now)
        let bareChats = await bare.sessions(from: nov6, to: now)
        let bareLedger = try Data(contentsOf: ledgerURL)
        try FileManager.default.removeItem(at: ledgerURL)

        MistralModelPricing.update(family)
        let named = aggregator()
        await named.refresh(now: now)
        let namedDay = await named.breakdown(now: now)
        let namedWindow = await named.usage(from: nov6, to: now)
        let namedChats = await named.sessions(from: nov6, to: now)
        let namedLedger = try Data(contentsOf: ledgerURL)

        // The ledger is encoded without sorted keys, so compare it as JSON, not as bytes.
        let namedObject = try JSONSerialization.jsonObject(with: namedLedger) as AnyObject
        let bareObject = try JSONSerialization.jsonObject(with: bareLedger) as AnyObject
        XCTAssertTrue(namedObject.isEqual(bareObject), "ids stay on disk, names are resolved on read")
        let text = String(decoding: namedLedger, as: UTF8.self)
        for shown in ["GLM-5.3", "Mistral Large 4", "Mistral Medium 3.5"] {
            XCTAssertFalse(text.contains(shown), "\(shown) is a name resolved on read, not stored")
        }
        XCTAssertEqual(namedDay.todayCost, bareDay.todayCost, accuracy: 1e-12)
        XCTAssertEqual(namedDay.weekCost, bareDay.weekCost, accuracy: 1e-12)
        XCTAssertEqual(namedDay.monthCost, bareDay.monthCost, accuracy: 1e-12)
        XCTAssertEqual(namedDay.todayTokens, bareDay.todayTokens)
        XCTAssertEqual(namedDay.todayTokenBreakdown.total, bareDay.todayTokenBreakdown.total)
        XCTAssertEqual(namedDay.todayTokenBreakdown.input, bareDay.todayTokenBreakdown.input)
        XCTAssertEqual(namedDay.todayTokenBreakdown.cacheRead, bareDay.todayTokenBreakdown.cacheRead)
        XCTAssertEqual(namedDay.todayTokenBreakdown.output, bareDay.todayTokenBreakdown.output)
        XCTAssertEqual(
            namedDay.todayTokenBreakdown.cost?.total ?? -1, bareDay.todayTokenBreakdown.cost?.total ?? -2, accuracy: 1e-12
        )
        XCTAssertEqual(namedDay.todayTurns, bareDay.todayTurns)
        XCTAssertEqual(namedDay.daily.map(\.totalCost).reduce(0, +), bareDay.daily.map(\.totalCost).reduce(0, +), accuracy: 1e-12)
        XCTAssertEqual(namedDay.projectsWeek.map(\.totalTokens), bareDay.projectsWeek.map(\.totalTokens))
        XCTAssertEqual(namedDay.projectsWeek.map(\.totalCost).reduce(0, +), bareDay.projectsWeek.map(\.totalCost).reduce(0, +), accuracy: 1e-12)
        XCTAssertEqual(namedWindow.cost, bareWindow.cost, accuracy: 1e-12)
        XCTAssertEqual(namedWindow.tokens, bareWindow.tokens)
        XCTAssertEqual(namedWindow.turns, bareWindow.turns)
        XCTAssertEqual(
            namedDay.byModelToday.reduce(0) { $0 + $1.tokens }, bareDay.byModelToday.reduce(0) { $0 + $1.tokens },
            "the rows sum to the same tokens under either spelling"
        )
        XCTAssertEqual(namedDay.byModelToday.reduce(0.0) { $0 + $1.cost }, bareDay.byModelToday.reduce(0.0) { $0 + $1.cost }, accuracy: 1e-12)
        // The chats: everything but the model rows' names is identical, and the row ids and raw ids are.
        XCTAssertEqual(namedChats.map(\.tokens), bareChats.map(\.tokens))
        XCTAssertEqual(namedChats.map(\.id), bareChats.map(\.id))
        XCTAssertEqual(namedChats.flatMap(\.models).map(\.id), bareChats.flatMap(\.models).map(\.id))
        XCTAssertEqual(namedChats.flatMap(\.models).map(\.model), bareChats.flatMap(\.models).map(\.model))
        XCTAssertEqual(namedChats.flatMap(\.models).map(\.tokens), bareChats.flatMap(\.models).map(\.tokens))
    }

    func testEveryVibeChatsModelRowIsNamedAsTheOverviewNamesIt() async throws {
        try writeSessions([VibeFixture.whole(), VibeFixture.glm(), VibeFixture.medium()])
        let vibe = aggregator(persisted: false)
        await vibe.refresh(now: now)
        let today = await vibe.breakdown(now: now)
        let rows = await vibe.sessions(from: nov6, to: now).flatMap(\.models)
        let shown = rows.map { SessionCopy.modelColumns($0).model }
        XCTAssertEqual(Set(shown), Set(today.byModelToday.map(\.model)), "the chat table and the Overview say the same names")
        XCTAssertEqual(
            Set(rows.map(\.id)),
            ["mistral-large-4-0-3|", "glm-5-3|", "mistral-medium-3.5|"], "rows are keyed by the id the log wrote"
        )
    }

    func testAChatOnAModelTheTableDoesNotKnowIsNamedAsTheAppNamesAnyId() async throws {
        var unknown = VibeFixture.repeated()
        unknown.activeModel = "some-new-model"
        unknown.modelName = nil
        try writeSessions([unknown])
        let vibe = aggregator(persisted: false)
        await vibe.refresh(now: now)
        let chats = await vibe.sessions(from: nov6, to: now)
        let row = try XCTUnwrap(chats.first?.models.first)
        XCTAssertNil(row.displayName)
        XCTAssertEqual(SessionCopy.modelColumns(row).model, ModelPricing.displayName(for: "some-new-model") ?? "some-new-model")
    }

    func testTheOtherProvidersNamesDoNotMeetMistralsTable() {
        // A models.dev row that happens to share an id with another provider's model names nothing there.
        var edited = family
        edited["gpt-5.6-terra"] = MistralModelPricing.Model(price: nil, name: "Terra (mistral's)")
        edited["claude-opus-4-5"] = MistralModelPricing.Model(price: nil, name: "Opus (mistral's)")
        MistralModelPricing.update(edited)
        XCTAssertEqual(ModelPricing.displayName(for: "gpt-5.6-terra"), "GPT 5.6 Terra")
        XCTAssertEqual(ModelPricing.displayName(for: "claude-opus-4-5-20251101"), "Opus 4.5")
        let codex = SessionFixture.model(model: "gpt-5.6-terra", effort: "high")
        let claude = SessionFixture.model(model: "claude-opus-4-5-20251101", effort: nil)
        XCTAssertEqual(SessionCopy.modelColumns(codex).model, "GPT 5.6 Terra")
        XCTAssertEqual(SessionCopy.modelColumns(claude).model, "Opus 4.5")
    }

    func testARowEncodedWithAVibeNameDecodesWithItAndOneWithoutAnyKeyStillDecodes() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let named = SessionModelSummary(
            model: "glm-5-3", effort: nil, turns: 1,
            tokens: SessionFixture.tokens(input: 10, output: 1), displayName: "GLM-5.3"
        )
        let back = try decoder.decode(SessionModelSummary.self, from: encoder.encode(named))
        XCTAssertEqual(back.displayName, "GLM-5.3")
        XCTAssertEqual(back.id, "glm-5-3|")
        let bare = SessionModelSummary(model: "glm-5-3", effort: nil, turns: 1, tokens: SessionFixture.tokens(input: 10, output: 1))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(bare)) as? [String: Any])
        XCTAssertNil(object["displayName"], "a nil name writes no key")
        XCTAssertNotEqual(named, bare, "a name is part of the row")
    }
}
