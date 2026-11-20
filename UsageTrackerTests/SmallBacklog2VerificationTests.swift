import XCTest
@testable import Omelette

/// Spec 2026-11-20 small backlog 2, the production halves, probed from the outside:
/// § B (the status line prints no invisible characters), § C (a rate nobody would charge
/// is no price), § E (Retry-After reads the clock it is given and is clamped before anything
/// formats it) and § F (one index of the process table per sample). Every invisible
/// character is written as an escape; this file holds none.
final class SmallBacklog2VerificationTests: XCTestCase {

    // MARK: - § B The status line prints no invisible characters

    private func model(_ name: String, context: Double? = nil) -> String? {
        var root: [String: Any] = ["model": ["display_name": name]]
        if let context { root["context_window"] = ["used_percentage": context] }
        let data = try! JSONSerialization.data(withJSONObject: root)
        return StatusLineInput.parse(data).model
    }

    private func parsed(_ name: String, context: Double? = nil) -> StatusLineInput {
        var root: [String: Any] = ["model": ["display_name": name]]
        if let context { root["context_window"] = ["used_percentage": context] }
        return StatusLineInput.parse(try! JSONSerialization.data(withJSONObject: root))
    }

    private func scalars(_ values: [UInt32]) -> [Unicode.Scalar] {
        values.compactMap(Unicode.Scalar.init)
    }

    /// "Fa<c>ble" with `c` embedded, as the model's display name.
    private func embedded(_ scalar: Unicode.Scalar) -> String? {
        model("Fa" + String(Character(scalar)) + "ble")
    }

    func testEveryBidiControlIsDroppedFromTheModelName() {
        let bidi: [UInt32] = [0x061C, 0x200E, 0x200F] + Array(0x202A...0x202E) + Array(0x2066...0x2069)
        for scalar in scalars(bidi) {
            XCTAssertEqual(embedded(scalar), "Fable", String(format: "U+%04X", scalar.value))
        }
    }

    func testTheOtherInvisibleFormatCharactersAreDroppedFromTheModelName() {
        let invisible: [UInt32] = [0x200B, 0x00AD, 0x180E, 0xFEFF]
            + Array(0x2060...0x2064) + Array(0xFFF9...0xFFFB)
            + [0x0600, 0x06DD, 0x070F, 0x08E2, 0x110BD, 0x1D173, 0x1D17A, 0xE0001]
            + Array(0xE0020...0xE007F)
        for scalar in scalars(invisible) {
            XCTAssertEqual(embedded(scalar), "Fable", String(format: "U+%04X", scalar.value))
        }
    }

    func testTheLineAndParagraphSeparatorsAndEveryControlAreDroppedFromTheModelName() {
        let separators: [UInt32] = [0x2028, 0x2029, 0x0085, 0x007F, 0x0000, 0x001B, 0x000A, 0x000D, 0x0009, 0x009B]
        for scalar in scalars(separators) {
            XCTAssertEqual(embedded(scalar), "Fable", String(format: "U+%04X", scalar.value))
        }
    }

    /// Every scalar of Unicode: exactly Cc, Zl, Zp and Cf but the two joiners go; a letter, mark,
    /// number, punctuation, symbol or space of any script stays. A name is cut to
    /// `maximumModelNameLength` characters and `maximumModelNameScalars` scalars, so the scalars
    /// go through in names within both: the kept ones packed by cluster (a kept mark or a joiner
    /// merges into the cluster before it, so a chunk is cut where the whole string's clusters
    /// end; a cluster too large for one name is split across names), the dropped ones in groups,
    /// each between sentinels.
    func testExactlyTheInvisibleCategoriesGoAcrossAllOfUnicode() {
        var dropped: [Unicode.Scalar] = []
        var kept: [Unicode.Scalar] = [Unicode.Scalar(0x200C)!, Unicode.Scalar(0x200D)!]
        for value in UInt32(0)...0x10FFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: dropped.append(scalar)
            case .format: if value != 0x200C && value != 0x200D { dropped.append(scalar) }
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .nonspacingMark, .spacingMark, .enclosingMark,
                 .decimalNumber, .letterNumber, .otherNumber,
                 .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
                 .initialPunctuation, .finalPunctuation, .otherPunctuation,
                 .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol, .spaceSeparator:
                kept.append(scalar)
            default: break
            }
        }
        XCTAssertGreaterThan(dropped.count, 150)
        XCTAssertGreaterThan(kept.count, 100_000)
        let roomCharacters = StatusLineInput.maximumModelNameLength - 2   // the two sentinels
        let roomScalars = StatusLineInput.maximumModelNameScalars - 2

        // The dropped, in groups of thirty between sentinels: nothing but the sentinels is left.
        var droppedExercised = 0
        var start = 0
        while start < dropped.count {
            let group = Array(dropped[start..<min(start + 30, dropped.count)])
            start += group.count
            var view = String.UnicodeScalarView()
            view.append("x")
            for scalar in group { view.append(scalar); view.append("x") }
            XCTAssertEqual(model(String(view)), String(repeating: "x", count: group.count + 1),
                           "dropped scalars from U+\(String(group[0].value, radix: 16))")
            droppedExercised += group.count
        }
        XCTAssertEqual(droppedExercised, dropped.count, "every dropped scalar went through a name")

        // The kept: units are the whole string's clusters, a cluster that holds more scalars than
        // a name may (a run of marks after a base) split into slices so that each of its scalars
        // still goes through a name. Packed into names of at most `roomCharacters` characters and
        // `roomScalars` scalars between two sentinels.
        var all = String.UnicodeScalarView()
        all.append(contentsOf: kept)
        var units: [(text: String, characters: Int, scalars: Int)] = []
        var splitClusters = 0
        for cluster in String(all) {
            let scalars = Array(cluster.unicodeScalars)
            if scalars.count <= roomScalars {
                units.append((String(cluster), 1, scalars.count))
                continue
            }
            splitClusters += 1
            var from = 0
            while from < scalars.count {
                let slice = String(String.UnicodeScalarView(scalars[from..<min(from + roomScalars, scalars.count)]))
                units.append((slice, slice.count, min(roomScalars, scalars.count - from)))
                from += roomScalars
            }
        }
        var keptExercised = 0
        var chunks = 0
        var index = 0
        while index < units.count {
            var body = ""
            var characters = 0
            var scalars = 0
            while index < units.count,
                  characters + units[index].characters <= roomCharacters,
                  scalars + units[index].scalars <= roomScalars {
                body += units[index].text
                characters += units[index].characters
                scalars += units[index].scalars
                index += 1
            }
            XCTAssertGreaterThan(scalars, 0, "a unit fits an empty name")
            if scalars == 0 { break }
            let name = "x" + body + "x"
            XCTAssertLessThanOrEqual(name.count, StatusLineInput.maximumModelNameLength, "a chunk fits the character cap")
            XCTAssertLessThanOrEqual(name.unicodeScalars.count, StatusLineInput.maximumModelNameScalars, "a chunk fits the scalar cap")
            XCTAssertEqual(model(name).map { Array($0.unicodeScalars) }, Array(name.unicodeScalars),
                           "a chunk of kept scalars starting at U+\(String(body.unicodeScalars.first!.value, radix: 16))")
            keptExercised += body.unicodeScalars.count
            chunks += 1
        }
        XCTAssertEqual(keptExercised, kept.count, "every kept scalar went through a name")
        XCTAssertGreaterThan(chunks, 1_000, "names of at most the caps, not a few long ones")
        NSLog("SB2 sweep: %d kept scalars in %d names, %d clusters split, %d dropped scalars", keptExercised, chunks, splitClusters, droppedExercised)
    }

    func testVariationSelectorsAndCombiningMarksStayWithTheirBase() {
        let name = "Fable \u{2764}\u{FE0F} \u{FE0E} e\u{0301} \u{E0100} \u{20E3}"
        XCTAssertEqual(model(name).map { Array($0.unicodeScalars) }, Array(name.unicodeScalars))
    }

    func testAnAstralPlaneLetterAndAnEmojiStay() {
        let name = "\u{1D400}\u{20000} \u{1F600}"
        XCTAssertEqual(model(name).map { Array($0.unicodeScalars) }, Array(name.unicodeScalars))
    }

    func testBothJoinersStayInTheMiddleOfAName() {
        let name = "a\u{200C}b\u{200D}c"
        XCTAssertEqual(model(name).map { Array($0.unicodeScalars) }, Array(name.unicodeScalars))
    }

    /// A name that is nothing once the invisible characters are gone is no name: the line
    /// falls back to the generic word where it has a context reading, and prints nothing
    /// where it has none.
    func testANameOfOnlyInvisibleCharactersFallsBackToTheGenericName() {
        let hidden = "\u{200B}\u{202E}\u{2066}\u{FEFF}\u{00AD}\u{2028}\u{E0001}"
        XCTAssertNil(model(hidden))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let withContext = StatusLineText.render(
            snapshot: nil, now: now, input: parsed(hidden, context: 42), colour: false
        )
        XCTAssertEqual(withContext, "Claude [####------] 42%")
        let without = StatusLineText.render(snapshot: nil, now: now, input: parsed(hidden), colour: false)
        XCTAssertEqual(without, "")
    }

    func testThePrintedLineOfAHostileNameHoldsNoInvisibleCharacterButTheJoiners() {
        let name = "\u{202E}Fa\u{200B}ble\u{2028}\u{200D}\u{200C}\u{FEFF} 5\u{2066}.2\u{1B}[31m"
        let line = StatusLineText.render(
            snapshot: nil, now: Date(timeIntervalSince1970: 1_800_000_000),
            input: parsed(name, context: 10), colour: true
        )
        let stray = line.unicodeScalars.filter {
            switch $0.properties.generalCategory {
            case .lineSeparator, .paragraphSeparator: return true
            case .format: return $0.value != 0x200C && $0.value != 0x200D
            default: return false
            }
        }
        XCTAssertTrue(stray.isEmpty, "\(stray.map { String($0.value, radix: 16) })")
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 0)
    }

    // MARK: - § C A price nobody would charge is no price

    private func row(_ cost: [String: Any]) -> [String: Any] { ["cost": cost] }

    private func price(_ cost: [String: Any], provider: String = "anthropic", id: String = "claude-probe") -> ModelPrice? {
        ModelsDevPricing.price(provider: provider, id: id, model: row(cost))
    }

    private let kinds = ["input", "output", "cache_read", "cache_write"]

    private func cost(_ kind: String, _ value: Any) -> [String: Any] {
        var cost: [String: Any] = ["input": 3, "output": 15, "cache_read": 0.3, "cache_write": 3.75]
        cost[kind] = value
        return cost
    }

    func testEveryKindPricesAtTheBoundAndNotAboveInEveryFamily() {
        for provider in ModelsDevPricing.providers + [ModelsDevPricing.vibeFamily] {
            for kind in kinds {
                XCTAssertNotNil(price(cost(kind, 10_000.0), provider: provider), "\(provider) \(kind) at the bound")
                XCTAssertNotNil(price(cost(kind, 10_000), provider: provider), "\(provider) \(kind) at the bound, an integer")
                XCTAssertNotNil(price(cost(kind, 10_000.0.nextDown), provider: provider), "\(provider) \(kind) just below")
                XCTAssertNil(price(cost(kind, 10_000.0.nextUp), provider: provider), "\(provider) \(kind) just above")
                XCTAssertNil(price(cost(kind, 10_001), provider: provider), "\(provider) \(kind) an integer above")
                XCTAssertNil(price(cost(kind, Double.greatestFiniteMagnitude), provider: provider), "\(provider) \(kind) huge")
            }
        }
    }

    func testNegativeAndNonFiniteRatesPriceNothingInEveryKind() {
        let bad: [Double] = [-0.000001, -1, -Double.leastNonzeroMagnitude, .nan, .infinity, -.infinity, -Double.greatestFiniteMagnitude]
        for kind in kinds {
            for value in bad {
                XCTAssertNil(price(cost(kind, value)), "\(kind) \(value)")
            }
        }
    }

    func testZeroAndNegativeZeroAreStillAPrice() throws {
        for kind in kinds {
            XCTAssertNotNil(price(cost(kind, 0.0)), "\(kind) 0")
            XCTAssertNotNil(price(cost(kind, 0)), "\(kind) integer 0")
            XCTAssertNotNil(price(cost(kind, -0.0)), "\(kind) -0")
        }
        let free = try XCTUnwrap(price(["input": 0, "output": 0]))
        XCTAssertEqual(free.inputPerM, 0)
        XCTAssertEqual(free.cacheReadPerM, 0)
        XCTAssertEqual(free.cacheCreate5mPerM, 1.0 * 0 * 1.25)
    }

    /// One bad rate among good ones: the row prices nothing at all, not the good rates alone.
    func testOneBadRateAmongGoodOnesLeavesTheWholeRowPriceless() throws {
        let json = """
        {"anthropic": {"models": {
          "claude-good": {"cost": {"input": 5, "output": 25, "cache_read": 0.5, "cache_write": 6.25}},
          "claude-bad-last": {"cost": {"input": 5, "output": 25, "cache_read": 0.5, "cache_write": 62500}}
        }}}
        """
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let prices = try ModelsDevPricing.parse(root)
        XCTAssertEqual(Set(prices.keys), ["claude-good"])
    }

    func testAMistralRowAboveTheBoundKeepsItsNameAndItsNeighbourKeepsItsPrice() throws {
        let json = """
        {"mistral": {"models": {
          "mistral-big": {"name": "Mistral Big", "cost": {"input": 2, "output": 6, "cache_read": 20000}},
          "mistral-ok": {"name": "Mistral Ok", "cost": {"input": 0.4, "output": 2}},
          "mistral-free": {"name": "Mistral Free", "cost": {"input": 0, "output": 0}}
        }}}
        """
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let table = try? ModelsDevPricing.table(root)
        // `table` throws when the four families price nothing; the Mistral family alone is `parseFamily`.
        XCTAssertNil(table)
        let family = ModelsDevPricing.parseFamily(root, provider: ModelsDevPricing.vibeFamily)
        XCTAssertEqual(family["mistral-big"], MistralModelPricing.Model(price: nil, name: "Mistral Big"))
        XCTAssertEqual(family["mistral-ok"]?.price?.outputPerM, 2)
        XCTAssertEqual(family["mistral-free"]?.price?.inputPerM, 0)
    }

    func testAPriceAsAStringIsNoPriceAndARateGivenAsAStringIsNotAPublishedRate() throws {
        XCTAssertNil(price(["input": "5", "output": 25]), "a string input is a missing input")
        XCTAssertNil(price(["input": 5, "output": "25"]), "a string output is a missing output")
        // Not a number, so not a rate: the row prices, with the rate inferred as if it were unpublished.
        let inferred = try XCTUnwrap(price(["input": 5, "output": 25, "cache_read": "99999"]))
        XCTAssertEqual(inferred.cacheReadPerM, 0.5, accuracy: 1e-12)
    }

    /// The rates the app derives are not bounded: an input at the bound gives a cache write of
    /// 12 500 and a 1-hour tier of 20 000, and a cache read inferred from it.
    func testDerivedRatesPastTheBoundStayWhenTheirInputIsBelievable() throws {
        let derived = try XCTUnwrap(price(["input": 10_000, "output": 10_000]))
        XCTAssertEqual(derived.cacheCreate5mPerM, 12_500, accuracy: 1e-9)
        XCTAssertEqual(derived.cacheCreate1hPerM, 20_000, accuracy: 1e-9)
        let openAI = try XCTUnwrap(price(["input": 9_000, "output": 10_000], provider: "openai", id: "gpt-6-probe"))
        XCTAssertEqual(openAI.cacheCreate5mPerM, 11_250, accuracy: 1e-9, "1.25x of 9000 is past the bound and stays")
    }

    /// What a priceless Claude row does downstream: the live table lacks it, so the offline
    /// table answers for an id it knows and the family's newest member for one it does not.
    func testAPricelessClaudeRowFallsBackToTheOfflineTableThroughTheRefresher() async throws {
        let json = """
        {"anthropic": {"models": {
          "claude-opus-4-8": {"cost": {"input": 5, "output": 25000}},
          "claude-opus-9-9": {"cost": {"input": 5, "output": 25000}},
          "claude-haiku-4-5": {"cost": {"input": 1, "output": 5}}
        }}}
        """
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmallBacklog2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cacheURL = directory.appendingPathComponent("cache.json")
        defer {
            ModelPricing.updateDynamic([:])
            MistralModelPricing.update([:])
            try? FileManager.default.removeItem(at: directory)
        }
        ModelPricing.updateDynamic([:])
        let body = Data(json.utf8)
        let refresher = ModelsDevRefresher(cacheURL: cacheURL, fetchTable: {
            try ModelsDevPricing.table(try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any]))
        })
        await refresher.refreshIfStale(now: Date(timeIntervalSince1970: 1_800_000_000))

        let known = ModelPricing.lookup(for: "claude-opus-4-8")
        XCTAssertEqual(known.price, ModelPricing.table["claude-opus-4-8"])
        XCTAssertFalse(known.isFallback, "the offline table names it")
        let unknown = ModelPricing.lookup(for: "claude-opus-9-9")
        XCTAssertEqual(unknown.price, ModelPricing.table["claude-opus-4-8"], "the family's newest member")
        XCTAssertTrue(unknown.isFallback)
        XCTAssertEqual(ModelPricing.lookup(for: "claude-haiku-4-5").price.outputPerM, 5, "its neighbour came through")

        let cache = try XCTUnwrap(ModelsDevPricing.readCache(at: cacheURL))
        XCTAssertEqual(Set(cache.prices.keys), ["claude-haiku-4-5"], "the copy on disk holds no absurd row either")
    }

    // MARK: - § E Retry-After reads the clock it is given

    /// 2026-09-06 12:00:00 GMT, a Sunday.
    private let clock = Date(timeIntervalSince1970: 1_788_696_000)

    private func response(_ value: String?, header: String = "Retry-After") -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.example.invalid/usage")!, statusCode: 429, httpVersion: "HTTP/1.1",
            headerFields: value.map { [header: $0] } ?? [:]
        )!
    }

    private func wait(_ value: String?, header: String = "Retry-After") -> TimeInterval? {
        HTTPClient.retryAfterSeconds(response(value, header: header), now: clock)
    }

    func testTheSecondsFormAtItsEdges() {
        XCTAssertEqual(wait("0"), 0)
        XCTAssertEqual(wait("1"), 1)
        XCTAssertEqual(wait("86400"), 86_400)
        XCTAssertEqual(wait("86401"), 86_400)
        XCTAssertEqual(wait("1e19"), 86_400)
        XCTAssertEqual(wait("inf"), 86_400)
        XCTAssertEqual(wait("-inf"), 0)
        XCTAssertEqual(wait("-1"), 0)
        XCTAssertEqual(wait("1.5"), 1.5)
        XCTAssertEqual(wait("  45  "), 45)
        XCTAssertNil(wait("nan"))
        XCTAssertNil(wait(""))
        XCTAssertNil(wait("   "))
        XCTAssertNil(wait(nil))
        XCTAssertNil(wait("soon"))
    }

    func testTheHeaderNameIsMatchedWhateverItsCase() {
        XCTAssertEqual(wait("30", header: "retry-after"), 30)
        XCTAssertEqual(wait("30", header: "RETRY-AFTER"), 30)
        XCTAssertNil(wait("30", header: "X-Retry-After"))
    }

    func testTheDateFormAheadBehindAndAtTheClock() {
        XCTAssertEqual(wait("Sun, 06 Sep 2026 12:00:01 GMT"), 1)
        XCTAssertEqual(wait("Sun, 06 Sep 2026 12:00:00 GMT"), 0, "exactly now")
        XCTAssertEqual(wait("Sun, 06 Sep 2026 11:59:59 GMT"), 0)
        XCTAssertEqual(wait("Sun, 06 Sep 2026 13:00:00 GMT"), 3_600)
        XCTAssertEqual(wait("Mon, 06 Sep 2027 12:00:00 GMT"), 86_400, "a year ahead is a day")
        XCTAssertEqual(wait("Fri, 31 Dec 9999 23:59:59 GMT"), 86_400)
        XCTAssertEqual(wait("Thu, 01 Jan 1970 00:00:00 GMT"), 0)
    }

    func testTheDateFormMovesWithTheClockItIsGiven() {
        let value = "Sun, 06 Sep 2026 12:10:00 GMT"
        XCTAssertEqual(HTTPClient.retryAfterSeconds(response(value), now: clock), 600)
        XCTAssertEqual(HTTPClient.retryAfterSeconds(response(value), now: clock.addingTimeInterval(540)), 60)
        XCTAssertEqual(HTTPClient.retryAfterSeconds(response(value), now: clock.addingTimeInterval(700)), 0)
    }

    /// Whatever the header says, the text a provider shows for the 429 is built without a trap
    /// and says at most a day.
    func testNoRetryAfterValueMakesTheErrorTextTrapOrPromiseMoreThanADay() throws {
        let values = ["0", "1", "86400", "86401", "1e19", "1e308", "inf", "-inf", "-1", "1.5", "0x10",
                      "9223372036854775807", "9223372036854775808", "Fri, 31 Dec 9999 23:59:59 GMT",
                      "Sun, 06 Sep 2026 12:00:30 GMT"]
        for value in values {
            let seconds = wait(value)
            let text = try XCTUnwrap(HTTPClientError.rateLimited(retryAfter: seconds).errorDescription, value)
            XCTAssertTrue(text.hasPrefix("Rate limited"), text)
            if let found = text.split(whereSeparator: { !$0.isNumber }).first.flatMap({ Int($0) }) {
                XCTAssertLessThanOrEqual(found, 86_400, "\(value): \(text)")
            }
        }
    }

    func testTheErrorTextOfAnUnclampedWaitIsClampedToo() {
        let cases: [(TimeInterval, String)] = [
            (0, "Rate limited (retry after 0s)"),
            (-0.0, "Rate limited (retry after 0s)"),
            (-5, "Rate limited (retry after 0s)"),
            (-.infinity, "Rate limited (retry after 0s)"),
            (0.999, "Rate limited (retry after 0s)"),
            (86_400, "Rate limited (retry after 86400s)"),
            (86_400.5, "Rate limited (retry after 86400s)"),
            (Double(Int.max), "Rate limited (retry after 86400s)"),
            (Double(Int.max).nextUp, "Rate limited (retry after 86400s)"),
            (.greatestFiniteMagnitude, "Rate limited (retry after 86400s)"),
            (.infinity, "Rate limited (retry after 86400s)"),
        ]
        for (seconds, text) in cases {
            XCTAssertEqual(HTTPClientError.rateLimited(retryAfter: seconds).errorDescription, text, "\(seconds)")
        }
        XCTAssertEqual(HTTPClientError.rateLimited(retryAfter: nil).errorDescription, "Rate limited")
        XCTAssertEqual(HTTPClientError.rateLimited(retryAfter: .nan).errorDescription, "Rate limited")
    }

    /// A clamped day-long wait freezes nothing for a day: Mistral keeps a 429 at most five
    /// minutes, whatever the header asks, and the app's own backoff takes `min(wait, 300)`.
    func testMistralHoldsAClampedDayForNoMoreThanItsOwnCeiling() {
        let held: [(String?, TimeInterval)] = [
            ("inf", MistralProvider.maxRateLimitHold), ("1e19", MistralProvider.maxRateLimitHold),
            ("86400", MistralProvider.maxRateLimitHold), ("301", MistralProvider.maxRateLimitHold),
            ("300", 300), ("120", 120), ("1", MistralProvider.minFetchInterval),
            ("0", MistralProvider.minFetchInterval), ("-5", MistralProvider.minFetchInterval),
            ("nan", MistralProvider.minFetchInterval), (nil, MistralProvider.minFetchInterval),
            ("Mon, 06 Sep 2027 12:00:00 GMT", MistralProvider.maxRateLimitHold),
        ]
        for (value, expected) in held {
            let result: Result<MistralBilling, MistralBillingError> = .failure(.rateLimited(retryAfter: wait(value)))
            XCTAssertEqual(MistralProvider.hold(for: result), expected, "\(value ?? "no header")")
        }
    }

    // MARK: - § F One pass over the process table per sample

    private typealias F = AgentProcessFixture
    private typealias Row = AgentResourceRules.ProcessRow

    /// `members(of:in:)` as it stood before the index: the dictionary and the filter, per question.
    private func legacyMembers(of tty: String, in table: [Row]) -> [pid_t] {
        guard !tty.isEmpty else { return [] }
        var children: [pid_t: [pid_t]] = [:]
        for row in table where row.pid > 1 {
            children[row.parent, default: []].append(row.pid)
        }
        var found = Set<pid_t>()
        var queue = table.filter { $0.pid > 1 && $0.tty == tty }.map(\.pid)
        while let pid = queue.popLast() {
            guard found.insert(pid).inserted else { continue }
            queue.append(contentsOf: children[pid] ?? [])
        }
        return found.sorted()
    }

    /// `reading(of:in:usage:at:)` as it stood before the index.
    private func legacyReading(
        of tty: String, in table: [Row], usage: (pid_t) -> AgentResourceRules.Usage?, at now: Date
    ) -> AgentResourceRules.Reading? {
        let started = Dictionary(table.map { ($0.pid, $0.startedAt) }, uniquingKeysWith: { first, _ in first })
        let pids = legacyMembers(of: tty, in: table)
        var cpu: [pid_t: Double] = [:]
        var footprint = 0
        for pid in pids {
            guard let used = usage(pid) else { continue }
            cpu[pid] = used.cpuSeconds.isFinite ? max(0, used.cpuSeconds) : 0
            let (sum, overflow) = footprint.addingReportingOverflow(max(0, used.footprintBytes))
            footprint = overflow ? Int.max : sum
        }
        guard !cpu.isEmpty else { return nil }
        return AgentResourceRules.Reading(
            at: now, cpuSeconds: cpu, footprintBytes: footprint,
            oldestStart: pids.compactMap { started[$0] }.min()
        )
    }

    private func assertSame(_ table: [Row], ttys: [String], _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let index = AgentResourceRules.ProcessIndex(table)
        let usage: (pid_t) -> AgentResourceRules.Usage? = { pid in
            pid % 7 == 0 ? nil : AgentResourceRules.Usage(cpuSeconds: Double(pid) * 1.5, footprintBytes: Int(pid) * 1_000)
        }
        for tty in ttys {
            XCTAssertEqual(AgentResourceRules.members(of: tty, in: table), legacyMembers(of: tty, in: table),
                           "\(label) members(table) \(tty)", file: file, line: line)
            XCTAssertEqual(AgentResourceRules.members(of: tty, in: index), legacyMembers(of: tty, in: table),
                           "\(label) members(index) \(tty)", file: file, line: line)
            XCTAssertEqual(AgentResourceRules.reading(of: tty, in: table, usage: usage, at: F.t0),
                           legacyReading(of: tty, in: table, usage: usage, at: F.t0),
                           "\(label) reading(table) \(tty)", file: file, line: line)
            XCTAssertEqual(AgentResourceRules.reading(of: tty, in: index, usage: usage, at: F.t0),
                           legacyReading(of: tty, in: table, usage: usage, at: F.t0),
                           "\(label) reading(index) \(tty)", file: file, line: line)
        }
    }

    func testTheIndexGivesTheMembersAndFiguresOfTheFixtureTable() {
        let ttys = [F.tab, F.otherTab, F.pane, F.otherPane, F.closedTab, "", "/dev/ttys999"]
        assertSame(F.table, ttys: ttys, "fixture")
        assertSame(F.tableAfterClang, ttys: ttys, "after clang")
        assertSame(F.tableAfterSwiftFrontend, ttys: ttys, "after swift-frontend")
        XCTAssertEqual(AgentResourceRules.members(of: F.tab, in: AgentResourceRules.ProcessIndex(F.table)),
                       [500, 501, 502, 503, 504, 510, 511, 512, 513])
    }

    func testTheIndexGivesTheMembersOfACycleASelfParentAndDuplicatePids() {
        let a = "/dev/ttys020", b = "/dev/ttys021"
        let table: [Row] = [
            F.row(0, 0, nil), F.row(1, 0, a),            // the kernel and launchd, one of them with a tty
            F.row(800, 800, a),                          // its own parent
            F.row(801, 800, nil),                        // below it
            F.row(810, 811, a), F.row(811, 810, nil),    // a two-process cycle
            F.row(812, 812, nil),                        // a self-parented row on no tty, below nobody
            F.row(820, 1, a, started: F.t0), F.row(820, 400, b, started: F.processStart), // one pid, two rows
            F.row(821, 820, nil), F.row(822, 1, nil),    // 822 hangs off launchd
            F.row(830, 1, b),                            // a tty process parented to launchd
            F.row(831, 0, b),                            // and to the kernel
        ]
        assertSame(table, ttys: [a, b, "", "/dev/none"], "hostile")
        let index = AgentResourceRules.ProcessIndex(table)
        XCTAssertEqual(AgentResourceRules.members(of: a, in: index), [800, 801, 810, 811, 820, 821])
        XCTAssertEqual(AgentResourceRules.members(of: b, in: index), [820, 821, 830, 831])
        XCTAssertFalse(AgentResourceRules.members(of: a, in: index).contains(1), "launchd is never a member")
    }

    /// A pid listed twice keeps its first row's start, as the old dictionary did.
    func testAPidListedTwiceKeepsItsFirstStart() {
        let a = "/dev/ttys020"
        let table: [Row] = [F.row(900, 1, a, started: F.t0), F.row(900, 1, a, started: F.t0.addingTimeInterval(-7200))]
        let usage: (pid_t) -> AgentResourceRules.Usage? = { _ in AgentResourceRules.Usage(cpuSeconds: 1, footprintBytes: 1) }
        let reading = AgentResourceRules.reading(of: a, in: AgentResourceRules.ProcessIndex(table), usage: usage, at: F.t0)
        XCTAssertEqual(reading?.oldestStart, F.t0)
        XCTAssertEqual(reading, legacyReading(of: a, in: table, usage: usage, at: F.t0))
    }

    /// A few hundred pseudo-random tables (fixed seed): cycles, self-parents, duplicate pids,
    /// ttys shared and absent, pids 0 and 1 anywhere.
    func testTheIndexAgreesWithTheOldRulesOnRandomTables() {
        var state: UInt64 = 0x9E3779B97F4A7C15
        func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
        let ttys = ["/dev/ttys001", "/dev/ttys002", "/dev/ttys003"]
        for round in 0..<300 {
            let count = 1 + next(40)
            var table: [Row] = []
            for _ in 0..<count {
                let tty: String? = next(4) == 0 ? nil : ttys[next(ttys.count)]
                table.append(F.row(pid_t(next(30)), pid_t(next(30)), tty, started: F.t0.addingTimeInterval(Double(next(1000)))))
            }
            assertSame(table, ttys: ttys + ["", "/dev/ttys404"], "round \(round)")
        }
    }

    private final class Builds: @unchecked Sendable {
        private let lock = NSLock()
        private var rows: [[Row]] = []
        func add(_ table: [Row]) { lock.withLock { rows.append(table) } }
        var tables: [[Row]] { lock.withLock { rows } }
    }

    private func countingSampler(_ machine: FakeMachine, _ builds: Builds) -> AgentResourceSampler {
        AgentResourceSampler(
            table: { machine.readTable() }, usage: { machine.usage($0) }, cores: F.cores,
            index: { rows in builds.add(rows); return AgentResourceRules.ProcessIndex(rows) }
        )
    }

    /// The index is rebuilt for each sample's own table: a process that appeared since the last
    /// sample is a member in this one, and a sample too soon after the last builds nothing.
    func testTheIndexIsBuiltOncePerSampleFromThatSamplesTableAndNeverReused() async {
        let machine = FakeMachine()
        let builds = Builds()
        let sampler = countingSampler(machine, builds)

        let first = await sampler.sample(ttys: [F.tab, F.otherTab, F.pane], now: F.t0)
        XCTAssertEqual(builds.tables.count, 1)
        XCTAssertEqual(first[F.otherTab]?.memoryBytes, 415 * F.mb)

        // Too soon: every tty stands, no table is read and no index built.
        _ = await sampler.sample(ttys: [F.tab, F.otherTab, F.pane], now: F.t0.addingTimeInterval(1))
        XCTAssertEqual(builds.tables.count, 1)
        XCTAssertEqual(machine.tableReads, 1)

        // A new process under the second tab, and the first tab's build gone.
        var table = F.table.filter { $0.pid != 513 }
        table.append(F.row(603, 602, F.otherTab))
        machine.set(table: table, usage: F.usageAt0.merging([603: F.usage(1, 100)]) { _, new in new })
        let second = await sampler.sample(ttys: [F.tab, F.otherTab, F.pane], now: F.t0.addingTimeInterval(5))
        XCTAssertEqual(builds.tables.count, 2, "once more for the next sample, not once per terminal")
        XCTAssertEqual(builds.tables.last, table, "built from the table that sample read")
        XCTAssertEqual(second[F.otherTab]?.memoryBytes, 515 * F.mb, "the new process is a member: 415 + 100")
        XCTAssertEqual(second[F.tab]?.memoryBytes, (1899 - 700) * F.mb, "swift-frontend is gone from the first tab")
        XCTAssertEqual(second[F.pane]?.memoryBytes, 525 * F.mb)
    }

    func testASampleOfOneTerminalAndASampleOfNoneIndexAsTheyShould() async {
        let machine = FakeMachine()
        let builds = Builds()
        let sampler = countingSampler(machine, builds)
        _ = await sampler.sample(ttys: [], now: F.t0)
        XCTAssertEqual(builds.tables.count, 0, "nothing asked, nothing indexed")
        _ = await sampler.sample(ttys: [F.tab], now: F.t0)
        XCTAssertEqual(builds.tables.count, 1)
        // The pane is new, the tab is not due: one build serves the one tty that is.
        _ = await sampler.sample(ttys: [F.tab, F.pane], now: F.t0.addingTimeInterval(1))
        XCTAssertEqual(builds.tables.count, 2)
    }
}
