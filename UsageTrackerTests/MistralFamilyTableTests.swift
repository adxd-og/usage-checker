import XCTest
@testable import Omelette

/// Spec 2026-11-10 Mistral provider § Local usage (P2), Model and price; plan R5–R6: models.dev's
/// `mistral` family is read with its display names into a table of its own, kept in the v4
/// cache, and loaded by the refresher from the network and then from that cache. The other CLIs'
/// table stays the four families, so an id Mistral shares with one of them keeps each family's
/// rate (review finding 8).
final class MistralFamilyTableTests: XCTestCase {
    private var directory: URL!
    /// 2026-11-11 09:00 UTC.
    private let t0 = Date(timeIntervalSince1970: 1_794_387_600)
    private var cacheURL: URL { directory.appendingPathComponent("models-dev-pricing.json") }
    private let gpt56 = ModelPrice(inputPerM: 1.25, outputPerM: 10, cacheReadPerM: 0.125, cacheCreate5mPerM: 1.5625, cacheCreate1hPerM: 2.5)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MistralFamilyTableTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ModelPricing.updateDynamic([:])
        MistralModelPricing.update([:])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        ModelPricing.updateDynamic([:])
        MistralModelPricing.update([:])
    }

    private var family: [String: MistralModelPricing.Model] {
        ModelsDevPricing.parseFamily(ModelsDevMistralFixture.root, provider: ModelsDevPricing.vibeFamily)
    }

    func testTheMistralFamilyIsReadWithItsNamesApartFromTheOtherFamilies() throws {
        XCTAssertEqual(family.count, 11)
        let medium = try XCTUnwrap(family["mistral-medium-2604"])
        XCTAssertEqual(medium.name, "Mistral Medium 3.5")
        XCTAssertEqual(medium.price, ModelPrice(
            inputPerM: 1.5, outputPerM: 7.5, cacheReadPerM: 0.15, cacheCreate5mPerM: 0, cacheCreate1hPerM: 0
        ))
        XCTAssertEqual(
            family["voxtral-mini-latest"], MistralModelPricing.Model(price: nil, name: "Voxtral Mini (latest)"),
            "a speech model keeps its name and has no token rate"
        )
        XCTAssertThrowsError(
            try ModelsDevPricing.parse(ModelsDevMistralFixture.root), "the four families' table takes none of these rows"
        )
    }

    func testAnIDTwoFamiliesShareKeepsEachFamilysRate() throws {
        // Invented: no id was shared on 2026-11-11. Mistral reselling an OpenAI model at its own rate.
        let text = #"{"openai":{"models":{"gpt-oss-120b":{"cost":{"input":0.15,"output":0.6}}}},"mistral":{"models":{"gpt-oss-120b":{"cost":{"input":0.2,"output":0.8},"name":"GPT OSS 120B"}}}}"#
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let table = try ModelsDevPricing.table(root)
        XCTAssertEqual(table.prices["gpt-oss-120b"]?.inputPerM, 0.15, "Codex keeps OpenAI's rate")
        XCTAssertEqual(table.mistral["gpt-oss-120b"]?.price?.inputPerM, 0.2, "vibe gets Mistral's")
        XCTAssertEqual(ModelsDevPricing.providers, ["anthropic", "openai", "xai", "google"])
    }

    func testTheV4CacheKeepsTheFamilyAndAnOlderCopyStillOpens() throws {
        XCTAssertEqual(ModelsDevPricing.cacheFileName, "models-dev-pricing-v4.json")
        ModelsDevPricing.writeCache(
            ModelsDevPricing.Cache(fetchedAt: t0, prices: ["gpt-5.6": gpt56], mistral: family), to: cacheURL
        )
        XCTAssertEqual(ModelsDevPricing.readCache(at: cacheURL)?.mistral, family)
        try Data(#"{"fetchedAt":"2026-11-11T09:00:00Z","prices":{}}"#.utf8).write(to: cacheURL)
        let older = try XCTUnwrap(ModelsDevPricing.readCache(at: cacheURL))
        XCTAssertNil(older.mistral)
    }

    func testTheRefresherLoadsTheFamilyFromItsAnswerThenFromTheCache() async throws {
        let answer = ModelsDevPricing.Table(prices: ["gpt-5.6": gpt56], mistral: family)
        let fetching = ModelsDevRefresher(cacheURL: cacheURL, fetchTable: { answer })
        await fetching.refreshIfStale(now: t0)
        XCTAssertEqual(MistralModelPricing.current, answer.mistral)
        MistralModelPricing.update([:])
        let offline = ModelsDevRefresher(cacheURL: cacheURL, fetchTable: { throw URLError(.notConnectedToInternet) })
        await offline.refreshIfStale(now: t0.addingTimeInterval(3_600))
        XCTAssertEqual(MistralModelPricing.current, answer.mistral, "the copy on disk prices vibe's sessions offline")
    }
}
