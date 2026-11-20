import XCTest
@testable import Omelette

/// Spec 2026-11-19 Mistral model names § Rule and § Untrusted names: a vibe session's model is
/// named by models.dev's `mistral` family, found in the order its price is found — `active_model`
/// then `model_name` as exact keys, then a display name that reads as the id, then the shorter
/// line — and a name is used only once it is clean, not empty and at most 64 characters. nil
/// leaves the row to the name the app gives every id. The rows are models.dev's as fetched on
/// 2026-11-11 (`ModelsDevMistralFixture`).
final class MistralModelNamesTests: XCTestCase {
    private var family: [String: MistralModelPricing.Model] {
        ModelsDevPricing.parseFamily(ModelsDevMistralFixture.root, provider: ModelsDevPricing.vibeFamily)
    }

    override func setUp() {
        super.setUp()
        MistralModelPricing.update(family)
    }

    override func tearDown() {
        MistralModelPricing.update([:])
        super.tearDown()
    }

    /// The fixture's family with one row added or replaced, in place of whatever was set before.
    private func update(_ id: String, _ model: MistralModelPricing.Model) {
        var edited = family
        edited[id] = model
        MistralModelPricing.update(edited)
    }

    // MARK: - The lookup order

    func testAPatchIdModelsDevDoesNotListIsNamedByItsLine() {
        XCTAssertEqual(MistralModelPricing.displayName(activeModel: "mistral-large-4-0-3", modelName: nil), "Mistral Large 4")
        XCTAssertEqual(
            MistralModelPricing.displayName(activeModel: "mistral-large-4-0-3", modelName: "mistral-large-4-0"),
            "Mistral Large 4", "neither id is a key or a name: mistral-large-4-0-3, then -4-0, then -4"
        )
    }

    func testAPatchIdModelsDevListsKeepsItsOwnName() {
        XCTAssertEqual(MistralModelPricing.displayName(activeModel: "mistral-large-4-0-8", modelName: nil), "Mistral Large 4.0.8")
    }

    func testTheIdVibeSentNamesTheModelWhenTheAliasIsNoKey() {
        XCTAssertEqual(MistralModelPricing.displayName(activeModel: "mistral-medium-3.5", modelName: "mistral-medium-2604"), "Mistral Medium 3.5")
        XCTAssertEqual(MistralModelPricing.displayName(activeModel: "glm-5-3", modelName: "zai-glm-5-3"), "GLM-5.3")
    }

    func testVibesDefaultAliasIsNamedByTheDisplayNameItReadsAs() {
        // vibe 3.1.0's default: alias mistral-medium-3.5, sent as mistral-vibe-cli-latest; neither
        // is a key, and models.dev names mistral-medium-2604 "Mistral Medium 3.5".
        XCTAssertEqual(
            MistralModelPricing.displayName(activeModel: "mistral-medium-3.5", modelName: "mistral-vibe-cli-latest"),
            "Mistral Medium 3.5"
        )
    }

    func testAnIdThatReadsAsADisplayNameGetsTheNameAsModelsDevSpellsIt() {
        XCTAssertEqual(MistralModelPricing.displayName(activeModel: "devstral-2", modelName: nil), "Devstral 2")
        XCTAssertEqual(MistralModelPricing.displayName(activeModel: "glm-5.2", modelName: nil), "GLM-5.2")
    }

    func testAKeyOutranksAShorterLineAndTheAliasIsTriedFirst() {
        var edited = family
        edited["glm-5"] = MistralModelPricing.Model(price: nil, name: "GLM-5")
        MistralModelPricing.update(edited)
        XCTAssertEqual(
            MistralModelPricing.displayName(activeModel: "glm-5-3", modelName: "zai-glm-5-3"), "GLM-5.3",
            "a bare glm-5 row is a shorter line of the alias and loses to the exact id sent"
        )
        edited["glm-5-3"] = MistralModelPricing.Model(price: nil, name: "GLM-5.3 (alias)")
        MistralModelPricing.update(edited)
        XCTAssertEqual(
            MistralModelPricing.displayName(activeModel: "glm-5-3", modelName: "zai-glm-5-3"), "GLM-5.3 (alias)",
            "both ids are keys now: active_model is tried first"
        )
    }

    func testANameOutranksAShorterLine() {
        update("mistral-medium", MistralModelPricing.Model(price: nil, name: "Mistral Medium (line)"))
        XCTAssertEqual(MistralModelPricing.displayName(activeModel: "mistral-medium-3.5", modelName: nil), "Mistral Medium 3.5")
    }

    func testANewModelTheFamilyDoesNotKnowHasNoNameFromTheRule() {
        XCTAssertNil(MistralModelPricing.displayName(activeModel: "some-new-model", modelName: nil))
        XCTAssertNil(MistralModelPricing.displayName(activeModel: nil, modelName: nil))
        XCTAssertNil(MistralModelPricing.displayName(activeModel: "", modelName: ""))
    }

    func testAnEmptyTableNamesNothing() {
        MistralModelPricing.update([:])
        XCTAssertNil(MistralModelPricing.displayName(activeModel: "mistral-large-4-0-3", modelName: "mistral-large-4-0"))
        XCTAssertNil(MistralModelPricing.displayName(activeModel: "glm-5-3", modelName: "zai-glm-5-3"))
        XCTAssertNil(MistralModelPricing.displayName(activeModel: "mistral-medium-3.5", modelName: "mistral-medium-2604"))
    }

    // MARK: - Rows the price passes over

    func testModelsSharingANameAtTwoRatesStillNameIt() {
        MistralModelPricing.update(
            ModelsDevPricing.parseFamily(ModelsDevMistralFixture.rootWithDifferingDuplicates, provider: ModelsDevPricing.vibeFamily)
        )
        XCTAssertNil(MistralModelPricing.price(activeModel: "devstral-2", modelName: nil), "which one ran is unknown, so no rate")
        XCTAssertEqual(
            MistralModelPricing.displayName(activeModel: "devstral-2", modelName: nil), "Devstral 2",
            "the name is the same whichever ran"
        )
    }

    func testARowWithANameAndNoPriceNamesTheModel() {
        XCTAssertNil(MistralModelPricing.price(activeModel: "voxtral-mini-latest", modelName: nil))
        XCTAssertEqual(MistralModelPricing.displayName(activeModel: "voxtral-mini-latest", modelName: nil), "Voxtral Mini (latest)")
    }

    func testARowWithAPriceAndNoNameIsPassedOver() {
        update("glm-5-3", MistralModelPricing.Model(price: family["zai-glm-5-3"]?.price, name: nil))
        XCTAssertEqual(
            MistralModelPricing.displayName(activeModel: "glm-5-3", modelName: "zai-glm-5-3"), "GLM-5.3",
            "the alias's row names nothing, so the id vibe sent does"
        )
        update("zai-glm-5-3", MistralModelPricing.Model(price: family["zai-glm-5-3"]?.price, name: nil))
        XCTAssertNil(
            MistralModelPricing.displayName(activeModel: "glm-5-3", modelName: "zai-glm-5-3"),
            "no row left with a name: the row reads as it does today"
        )
    }

    // MARK: - Untrusted names

    func testANameIsUsedWithoutItsControlCharactersAndItsOuterWhitespace() {
        update("zai-glm-5-3", MistralModelPricing.Model(price: nil, name: "  GLM\u{1B}[2J-5.3\u{07}\n"))
        XCTAssertEqual(MistralModelPricing.displayName(activeModel: "glm-5-3", modelName: "zai-glm-5-3"), "GLM[2J-5.3")
    }

    func testANameOfControlCharactersOrWhitespaceOnlyIsNoName() {
        update("zai-glm-5-3", MistralModelPricing.Model(price: nil, name: "\u{1B}\u{07}\u{9B}"))
        XCTAssertNil(MistralModelPricing.displayName(activeModel: "zai-glm-5-3", modelName: nil))
        update("zai-glm-5-3", MistralModelPricing.Model(price: nil, name: " \t\n "))
        XCTAssertNil(MistralModelPricing.displayName(activeModel: "zai-glm-5-3", modelName: nil))
        update("zai-glm-5-3", MistralModelPricing.Model(price: nil, name: ""))
        XCTAssertNil(MistralModelPricing.displayName(activeModel: "zai-glm-5-3", modelName: nil))
    }

    func testANameOfSixtyFourCharactersIsUsedAndOneOfSixtyFiveIsNot() {
        let sixtyFour = String(repeating: "M", count: 64)
        update("zai-glm-5-3", MistralModelPricing.Model(price: nil, name: sixtyFour))
        XCTAssertEqual(MistralModelPricing.displayName(activeModel: "zai-glm-5-3", modelName: nil), sixtyFour)
        update("zai-glm-5-3", MistralModelPricing.Model(price: nil, name: sixtyFour + "M"))
        XCTAssertNil(MistralModelPricing.displayName(activeModel: "zai-glm-5-3", modelName: nil))
        update("zai-glm-5-3", MistralModelPricing.Model(price: nil, name: " " + sixtyFour + "\u{07} "))
        XCTAssertEqual(
            MistralModelPricing.displayName(activeModel: "zai-glm-5-3", modelName: nil), sixtyFour,
            "the length is the cleaned name's"
        )
    }

    func testAnUnusableNameLetsTheLookupGoOnToTheNextRow() {
        // mistral-large-4-0-3's own row names it with 65 characters: the shorter line names it.
        update("mistral-large-4-0-3", MistralModelPricing.Model(price: nil, name: String(repeating: "x", count: 65)))
        XCTAssertEqual(MistralModelPricing.displayName(activeModel: "mistral-large-4-0-3", modelName: nil), "Mistral Large 4")
    }
}
