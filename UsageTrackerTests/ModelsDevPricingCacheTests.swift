import XCTest
@testable import Omelette

/// Spec 2026-11-20 small backlog 2 § C, the copy on disk: the guard a models.dev answer
/// passes runs again when the cache file is read, so a copy written before the guard
/// existed, or damaged on disk, cannot put a rate nobody would charge into the live tables.
/// Every test writes the cache file as text into a temp directory; nothing touches the
/// network or the real Application Support.
final class ModelsDevPricingCacheTests: XCTestCase {
    private var directory: URL!
    /// 2026-09-06 12:00 UTC, the copy's `fetchedAt` below.
    private let t0 = Date(timeIntervalSince1970: 1_788_696_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelsDevPricingCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ModelPricing.updateDynamic([:])
        MistralModelPricing.update([:])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        ModelPricing.updateDynamic([:])
        MistralModelPricing.update([:])
    }

    private var cacheURL: URL { directory.appendingPathComponent("models-dev-pricing.json") }

    private let rateFields = ["inputPerM", "outputPerM", "cacheReadPerM", "cacheCreate5mPerM", "cacheCreate1hPerM"]

    /// One row as the cache file writes it: sane rates, and `value` (a JSON number's text)
    /// for `field`.
    private func row(_ field: String? = nil, _ value: String = "") -> String {
        var rates = [
            "inputPerM": "5", "outputPerM": "25", "cacheReadPerM": "0.5",
            "cacheCreate5mPerM": "6.25", "cacheCreate1hPerM": "10",
        ]
        if let field { rates[field] = value }
        return "{" + rateFields.map { "\"\($0)\": \(rates[$0]!)" }.joined(separator: ", ") + "}"
    }

    private func write(prices: [String: String], mistral: String? = nil) throws {
        let rows = prices.map { "\"\($0.key)\": \($0.value)" }.joined(separator: ", ")
        let family = mistral.map { ", \"mistral\": " + $0 } ?? ""
        let json = #"{"fetchedAt": "2026-09-06T12:00:00Z", "prices": {"# + rows + "}" + family + "}"
        try Data(json.utf8).write(to: cacheURL)
    }

    private let sane = ModelPrice(
        inputPerM: 5, outputPerM: 25, cacheReadPerM: 0.5, cacheCreate5mPerM: 6.25, cacheCreate1hPerM: 10
    )

    func testABelievableCacheReadsAsWritten() throws {
        let prices = [
            "claude-opus-4-8": sane,
            "grok-free": ModelPrice(inputPerM: 0, outputPerM: 0, cacheReadPerM: 0, cacheCreate5mPerM: 0, cacheCreate1hPerM: 0),
            // What `price` makes of an input and an output at the bound, inferred writes included.
            "claude-at-the-bound": ModelPrice(
                inputPerM: 10_000, outputPerM: 10_000, cacheReadPerM: 1_000,
                cacheCreate5mPerM: 12_500, cacheCreate1hPerM: 20_000
            ),
        ]
        let mistral = [
            "mistral-medium-3": MistralModelPricing.Model(
                price: ModelPrice(inputPerM: 0.4, outputPerM: 2, cacheReadPerM: 0.04, cacheCreate5mPerM: 0, cacheCreate1hPerM: 0),
                name: "Mistral Medium 3"
            ),
            "voxtral-mini": MistralModelPricing.Model(price: nil, name: "Voxtral Mini"),
        ]
        ModelsDevPricing.writeCache(ModelsDevPricing.Cache(fetchedAt: t0, prices: prices, mistral: mistral), to: cacheURL)

        let cache = try XCTUnwrap(ModelsDevPricing.readCache(at: cacheURL))
        XCTAssertEqual(cache.fetchedAt, t0)
        XCTAssertEqual(cache.prices, prices)
        XCTAssertEqual(cache.mistral, mistral)
    }

    func testACopyWithoutTheMistralFamilyStillHasNone() throws {
        try write(prices: ["claude-opus-4-8": row()])
        let cache = try XCTUnwrap(ModelsDevPricing.readCache(at: cacheURL))
        XCTAssertNil(cache.mistral)
        XCTAssertEqual(cache.prices, ["claude-opus-4-8": sane])
    }

    func testARowWithAnAbsurdInputIsLeftOutAndItsNeighboursStay() throws {
        try write(prices: [
            "claude-opus-4-5": row(),
            "claude-opus-4-8": row("inputPerM", "1e308"),
            "gpt-5.6": row(),
        ])
        let cache = try XCTUnwrap(ModelsDevPricing.readCache(at: cacheURL))
        XCTAssertEqual(cache.prices, ["claude-opus-4-5": sane, "gpt-5.6": sane])
        XCTAssertEqual(cache.fetchedAt, t0, "the copy's age is when it was fetched, whatever was left out")
    }

    func testAnAbsurdValueInAnyRateLeavesTheRowOut() throws {
        for field in rateFields {
            try write(prices: ["claude-opus-4-8": row(field, "1e308"), "gpt-5.6": row()])
            let cache = try XCTUnwrap(ModelsDevPricing.readCache(at: cacheURL), field)
            XCTAssertEqual(Set(cache.prices.keys), ["gpt-5.6"], field)
        }
    }

    func testANegativeRateLeavesTheRowOut() throws {
        for field in rateFields {
            try write(prices: ["claude-opus-4-8": row(field, "-0.01"), "gpt-5.6": row()])
            let cache = try XCTUnwrap(ModelsDevPricing.readCache(at: cacheURL), field)
            XCTAssertEqual(Set(cache.prices.keys), ["gpt-5.6"], field)
        }
    }

    /// Input, output and cache read are held to the bound a published rate is; the two cache
    /// writes, which `price` may infer at up to twice it, to twice the bound.
    func testEachRateIsHeldToWhatAFetchCouldHaveWritten() throws {
        let bound = ModelsDevPricing.maximumRatePerM
        for (field, limit) in [
            ("inputPerM", bound), ("outputPerM", bound), ("cacheReadPerM", bound),
            ("cacheCreate5mPerM", 2 * bound), ("cacheCreate1hPerM", 2 * bound),
        ] {
            try write(prices: [
                "at-the-limit": row(field, "\(limit)"),
                "just-above": row(field, "\(limit.nextUp)"),
            ])
            let cache = try XCTUnwrap(ModelsDevPricing.readCache(at: cacheURL), field)
            XCTAssertEqual(Set(cache.prices.keys), ["at-the-limit"], field)
        }
    }

    /// No rate reaches the guard as infinity or NaN: `JSONDecoder` refuses a number no
    /// `Double` holds, and JSON has no NaN. A copy holding one does not open at all, and the
    /// launch prices as it does with no copy on disk.
    func testACopyHoldingANumberNoDoubleHoldsDoesNotOpen() throws {
        for value in ["1e999", "-1e999", "NaN", "\"NaN\"", "Infinity"] {
            try write(prices: ["claude-opus-4-8": row("inputPerM", value), "gpt-5.6": row()])
            XCTAssertNil(ModelsDevPricing.readCache(at: cacheURL), value)
        }
    }

    func testAnAbsurdMistralRowKeepsItsNameAndLosesItsPrice() throws {
        let medium = #"{"name": "Mistral Medium 3", "price": \#(row())}"#
        try write(prices: ["claude-opus-4-8": row()], mistral: """
        {"mistral-large-3": {"name": "Mistral Large 3", "price": \(row("outputPerM", "1e308"))},
         "mistral-small-4": {"name": "Mistral Small 4", "price": \(row("cacheReadPerM", "-1"))},
         "mistral-medium-3": \(medium),
         "voxtral-mini": {"name": "Voxtral Mini"}}
        """)
        let cache = try XCTUnwrap(ModelsDevPricing.readCache(at: cacheURL))
        XCTAssertEqual(cache.mistral, [
            "mistral-large-3": MistralModelPricing.Model(price: nil, name: "Mistral Large 3"),
            "mistral-small-4": MistralModelPricing.Model(price: nil, name: "Mistral Small 4"),
            "mistral-medium-3": MistralModelPricing.Model(price: sane, name: "Mistral Medium 3"),
            "voxtral-mini": MistralModelPricing.Model(price: nil, name: "Voxtral Mini"),
        ])
        XCTAssertEqual(cache.prices, ["claude-opus-4-8": sane])
    }

    /// A launch reads the copy before anything else: with a fresh copy it fetches nothing, so
    /// what the copy says is what prices every turn until the next day's check.
    func testALaunchWithAnAbsurdCopyLeavesTheTablesWithoutTheAbsurdRow() async throws {
        try write(
            prices: ["claude-opus-4-8": row("inputPerM", "1e308"), "gpt-5.6": row()],
            mistral: #"{"mistral-large-3": {"name": "Mistral Large 3", "price": \#(row("inputPerM", "1e308"))}}"#
        )
        let refresher = ModelsDevRefresher(cacheURL: cacheURL, fetchTable: {
            throw URLError(.notConnectedToInternet)
        })

        await refresher.refreshIfStale(now: t0.addingTimeInterval(3600))

        XCTAssertNil(ModelPricing.dynamicLookup(for: "claude-opus-4-8"), "the absurd row is not live")
        XCTAssertEqual(ModelPricing.dynamicLookup(for: "gpt-5.6"), sane, "its neighbour is")
        let opus = ModelPricing.lookup(for: "claude-opus-4-8")
        XCTAssertEqual(opus.price, ModelPricing.table["claude-opus-4-8"], "the offline table answers for it")
        XCTAssertEqual(
            MistralModelPricing.current["mistral-large-3"],
            MistralModelPricing.Model(price: nil, name: "Mistral Large 3")
        )
        XCTAssertNil(MistralModelPricing.price(activeModel: "mistral-large-3", modelName: nil))
    }
}
