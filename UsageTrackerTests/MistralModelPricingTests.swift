import XCTest
@testable import Omelette

/// Spec 2026-11-10 Mistral provider § Local usage (P2), Model and price; plan R5: a vibe session
/// is priced from models.dev's `mistral` family by `active_model`, then by the id vibe sent
/// (`model_name`): first as exact keys, then by the family's display names read in the id's
/// spelling, then by dropping trailing parts. A name that two models share prices only while
/// they share one rate. The rows are models.dev's as fetched on 2026-11-11.
final class MistralModelPricingTests: XCTestCase {
    private let large4 = ModelPrice(inputPerM: 0.7, outputPerM: 2.1, cacheReadPerM: 0.07, cacheCreate5mPerM: 0, cacheCreate1hPerM: 0)
    private let medium35 = ModelPrice(inputPerM: 1.5, outputPerM: 7.5, cacheReadPerM: 0.15, cacheCreate5mPerM: 0, cacheCreate1hPerM: 0)
    private let glm = ModelPrice(inputPerM: 1.4, outputPerM: 4.4, cacheReadPerM: 0.14, cacheCreate5mPerM: 0, cacheCreate1hPerM: 0)
    private let glmFlash = ModelPrice(inputPerM: 0.15, outputPerM: 0.5, cacheReadPerM: 0.03, cacheCreate5mPerM: 0, cacheCreate1hPerM: 0)

    override func setUp() {
        super.setUp()
        MistralModelPricing.update(ModelsDevPricing.parseFamily(ModelsDevMistralFixture.root, provider: ModelsDevPricing.vibeFamily))
    }

    override func tearDown() {
        MistralModelPricing.update([:])
        super.tearDown()
    }

    func testAKeyOfTheFamilyPricesExactly() {
        XCTAssertEqual(MistralModelPricing.price(activeModel: "zai-glm-5-3-flash", modelName: "zai-glm-5-3-flash"), glmFlash)
    }

    func testVibesDefaultAliasIsPricedByItsModelsDevName() {
        // vibe 3.1.0's default model: alias mistral-medium-3.5, sent as mistral-vibe-cli-latest.
        // Neither is a key; models.dev names mistral-medium-2604 "Mistral Medium 3.5".
        XCTAssertEqual(MistralModelPricing.price(activeModel: "mistral-medium-3.5", modelName: "mistral-vibe-cli-latest"), medium35)
    }

    func testTheIDVibeSentIsTriedAsAKeyBeforeAnyNameOrShorterLine() {
        XCTAssertEqual(MistralModelPricing.price(activeModel: "glm-5-3", modelName: "zai-glm-5-3"), glm)
        var family = MistralModelPricing.current
        family["glm-5"] = MistralModelPricing.Model(
            price: ModelPrice(inputPerM: 1, outputPerM: 3.2, cacheReadPerM: 0.2, cacheCreate5mPerM: 0, cacheCreate1hPerM: 0),
            name: "GLM-5"
        )
        MistralModelPricing.update(family)
        XCTAssertEqual(
            MistralModelPricing.price(activeModel: "glm-5-3", modelName: "zai-glm-5-3"), glm,
            "a bare glm-5 row is a shorter line of the alias and loses to the exact id sent"
        )
    }

    func testAnIDThatIsNeitherKeyNorNameFallsBackToItsLine() {
        XCTAssertEqual(
            MistralModelPricing.price(activeModel: "mistral-large-4-0-3", modelName: "mistral-large-4-0"), large4,
            "mistral-large-4-0-3, then -4-0, then -4"
        )
    }

    func testADuplicateNamePricesOnlyWhileItsModelsShareOneRate() {
        // "Devstral 2" names devstral-2512 and devstral-latest, "GLM-5.2" names glm-5-2 and
        // zai-glm-5-2, each pair at one rate on 2026-11-11.
        XCTAssertEqual(MistralModelPricing.price(activeModel: "devstral-2", modelName: nil)?.inputPerM, 0.4)
        XCTAssertEqual(MistralModelPricing.price(activeModel: "glm-5.2", modelName: nil), glm)
        MistralModelPricing.update(
            ModelsDevPricing.parseFamily(ModelsDevMistralFixture.rootWithDifferingDuplicates, provider: ModelsDevPricing.vibeFamily)
        )
        XCTAssertNil(
            MistralModelPricing.price(activeModel: "devstral-2", modelName: nil),
            "two models named Devstral 2 at two rates cannot say which one ran"
        )
    }

    func testANameReadsInTheIDsSpelling() {
        XCTAssertEqual(MistralModelPricing.nameKey("Mistral Medium 3.5"), "mistral-medium-3.5")
        XCTAssertEqual(MistralModelPricing.nameKey("GLM-5.3-Flash"), "glm-5.3-flash")
        XCTAssertEqual(MistralModelPricing.nameKey("Codestral (latest)"), "codestral-latest")
        XCTAssertEqual(MistralModelPricing.nameKey("  Devstral   2 "), "devstral-2")
        XCTAssertEqual(MistralModelPricing.nameKey("mistral-medium-3.5"), "mistral-medium-3.5")
    }

    func testAModelWithNoRateOrNoMatchIsNotPriced() {
        XCTAssertNil(MistralModelPricing.price(activeModel: "voxtral-mini-latest", modelName: nil), "a name and no token rate")
        XCTAssertNil(MistralModelPricing.price(activeModel: "llama-3.3-70b", modelName: "llama-3.3-70b"))
        XCTAssertNil(MistralModelPricing.price(activeModel: nil, modelName: nil))
        MistralModelPricing.update([:])
        XCTAssertNil(
            MistralModelPricing.price(activeModel: "mistral-medium-3.5", modelName: "mistral-vibe-cli-latest"),
            "nothing loaded yet: tokens without dollars"
        )
    }
}
