import XCTest
@testable import Omelette

/// A cut-down models.dev `api.json` covering the shapes that actually broke things:
/// long-context `tiers`, `context_over_200k`, and the image/video models that carry
/// `"cost": null`. The parse runs offline — nothing here touches the network.
final class ModelsDevPricingTests: XCTestCase {
    private let fixture = """
    {
      "anthropic": {
        "models": {
          "claude-opus-4-5": {
            "cost": {"input": 5, "output": 25, "cache_read": 0.5, "cache_write": 6.25}
          }
        }
      },
      "openai": {
        "models": {
          "gpt-5.6": {"cost": {"input": 1.25, "output": 10}},
          "gpt-5.4": {"cost": {"input": 2.5, "output": 15}},
          "gpt-5.6-terra": {"cost": {"input": 2, "output": 12}},
          "gpt-6-astra": {"cost": {"input": 10, "output": 50, "cache_write": 9}}
        }
      },
      "xai": {
        "models": {
          "grok-4.6": {
            "cost": {
              "input": 2, "output": 6, "cache_read": 0.5,
              "tiers": [{"input": 4, "output": 12, "cache_read": 1,
                         "tier": {"type": "context", "size": 200000}}],
              "context_over_200k": {"input": 4, "output": 12, "cache_read": 1}
            }
          },
          "grok-imagine-video": {"cost": null}
        }
      },
      "google": {
        "models": {
          "gemini-3.1-pro-preview": {
            "cost": {
              "input": 2, "output": 12, "cache_read": 0.2,
              "tiers": [{"input": 4, "output": 18, "cache_read": 0.4,
                         "tier": {"type": "context", "size": 200000}}],
              "context_over_200k": {"input": 4, "output": 18, "cache_read": 0.4}
            }
          },
          "veo-3.1-generate-preview": {"cost": null}
        }
      },
      "mistral": {
        "models": {"mistral-large": {"cost": {"input": 2, "output": 6}}}
      }
    }
    """

    private func parsed() throws -> [String: ModelPrice] {
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(fixture.utf8)) as? [String: Any]
        )
        return try ModelsDevPricing.parse(root)
    }

    func testProviderListCoversTheFourCLIsWePrice() {
        XCTAssertEqual(Set(ModelsDevPricing.providers), ["anthropic", "openai", "xai", "google"])
    }

    func testXAIPricesLandAtTheBaseRateNotTheLongContextTier() throws {
        let price = try XCTUnwrap(parsed()["grok-4.6"])
        XCTAssertEqual(price.inputPerM, 2)
        XCTAssertEqual(price.outputPerM, 6)
        XCTAssertEqual(price.cacheReadPerM, 0.5)
        // xAI bills no cache writes, so there is no 5m/1h rate to invent.
        XCTAssertEqual(price.cacheCreate5mPerM, 0)
        XCTAssertEqual(price.cacheCreate1hPerM, 0)
    }

    func testGooglePricesLandAtTheBaseRate() throws {
        let price = try XCTUnwrap(parsed()["gemini-3.1-pro-preview"])
        XCTAssertEqual(price.inputPerM, 2)
        XCTAssertEqual(price.outputPerM, 12)
        XCTAssertEqual(price.cacheReadPerM, 0.2)
    }

    func testModelsWithNullCostAreSkipped() throws {
        let prices = try parsed()
        XCTAssertNil(prices["grok-imagine-video"], "an image/video model has no token rate")
        XCTAssertNil(prices["veo-3.1-generate-preview"])
    }

    func testProvidersOutsideTheListAreNotImported() throws {
        // Pricing every provider models.dev knows would bloat the cache with rates no
        // CLI log here can ever reference.
        XCTAssertNil(try parsed()["mistral-large"])
    }

    func testAnthropicKeepsItsInferredCacheWriteRates() throws {
        let price = try XCTUnwrap(parsed()["claude-opus-4-5"])
        XCTAssertEqual(price.cacheCreate5mPerM, 6.25)
        XCTAssertEqual(price.cacheCreate1hPerM, 10, accuracy: 1e-9)
    }

    func testOpenAIFallsBackToATenthOfInputForCacheReads() throws {
        let price = try XCTUnwrap(parsed()["gpt-5.6"])
        XCTAssertEqual(price.cacheReadPerM, 0.125, accuracy: 1e-9)
    }

    // MARK: - OpenAI cache writes

    func testGPT56AndLaterInferACacheWriteRateAtAQuarterOverInput() throws {
        // OpenAI bills cache writes from GPT-5.6 on, at 1.25x the uncached input rate
        // (`ordinary_input = input - cached - cache_write`, and the write is charged at
        // the premium). Until models.dev publishes a `cache_write` for one of these ids,
        // reporting $0 for the bucket understates a real charge.
        let prices = try parsed()
        XCTAssertEqual(try XCTUnwrap(prices["gpt-5.6"]).cacheCreate5mPerM, 1.5625, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(prices["gpt-5.6-terra"]).cacheCreate5mPerM, 2.5, accuracy: 1e-9)
    }

    func testAnOpenAILineOlderThanGPT56InfersNoCacheWriteRate() throws {
        // The lines before 5.6 really do bill cache writes at nothing; inventing a rate
        // for them would overstate every Codex turn that wrote to cache.
        XCTAssertEqual(try XCTUnwrap(try parsed()["gpt-5.4"]).cacheCreate5mPerM, 0)
    }

    func testAPublishedCacheWriteRateWinsOverTheInferredOne() throws {
        // The fixture's 9 is deliberately not 1.25x its input rate of 10, so a build
        // that inferred over the published figure would read 12.5 here.
        XCTAssertEqual(try XCTUnwrap(try parsed()["gpt-6-astra"]).cacheCreate5mPerM, 9, accuracy: 1e-9)
    }

    func testTheCacheWriteInferenceRuleIsPerProviderAndPerLine() throws {
        XCTAssertEqual(
            ModelsDevPricing.inferredCacheWrite5m(provider: "anthropic", modelID: "claude-haiku-4-5", inputPerM: 1),
            1.25, accuracy: 1e-9
        )
        XCTAssertEqual(
            ModelsDevPricing.inferredCacheWrite5m(provider: "openai", modelID: "gpt-6-astra", inputPerM: 10),
            12.5, accuracy: 1e-9
        )
        XCTAssertEqual(
            ModelsDevPricing.inferredCacheWrite5m(provider: "openai", modelID: "gpt-5.2", inputPerM: 1.75), 0
        )
        XCTAssertEqual(
            ModelsDevPricing.inferredCacheWrite5m(provider: "xai", modelID: "grok-4.6", inputPerM: 2), 0
        )
        XCTAssertEqual(
            ModelsDevPricing.inferredCacheWrite5m(provider: "google", modelID: "gemini-3.7-flash", inputPerM: 2), 0
        )
        // A date-stamped id is the same line: normalize before the prefix test.
        XCTAssertTrue(ModelsDevPricing.billsCacheWrites(openAIModelID: "gpt-5.6-luna-20260101"))
        XCTAssertFalse(ModelsDevPricing.billsCacheWrites(openAIModelID: "gpt-5.5-pro"))
        XCTAssertFalse(ModelsDevPricing.billsCacheWrites(openAIModelID: "o3-pro"))
    }

    // MARK: - Shapes that must not take the rest of the payload down with them

    /// models.dev is a community dataset: one entry with a hand-edited `cost` block, or
    /// a provider whose `models` came back as a list, must not cost the models beside it.
    private let malformed = """
    {
      "xai": {
        "models": {
          "grok-4.6": {"cost": {"input": 2, "output": 6, "cache_read": 0.5}},
          "grok-no-output": {"cost": {"input": 2}},
          "grok-free-text": {"cost": "free"},
          "grok-not-a-dict": 42,
          "grok-null-cost": {"cost": null}
        }
      },
      "openai": {"models": [{"id": "gpt-5.6", "cost": {"input": 1, "output": 2}}]},
      "anthropic": {
        "models": {
          "claude-sonnet-4-6": {"cost": {"input": 3, "output": 15}}
        }
      }
    }
    """

    private func parsedMalformed() throws -> [String: ModelPrice] {
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(malformed.utf8)) as? [String: Any]
        )
        return try ModelsDevPricing.parse(root)
    }

    func testABadEntryIsSkippedAndItsNeighboursAreNot() throws {
        let prices = try parsedMalformed()

        let grok = try XCTUnwrap(prices["grok-4.6"], "a valid model beside broken ones must still parse")
        XCTAssertEqual(grok.inputPerM, 2)
        XCTAssertEqual(grok.outputPerM, 6)

        XCTAssertNil(prices["grok-no-output"], "a cost block without an output rate prices nothing")
        XCTAssertNil(prices["grok-free-text"], #"a string "cost" is not a rate table"#)
        XCTAssertNil(prices["grok-not-a-dict"], "a model whose value isn't an object")
        XCTAssertNil(prices["grok-null-cost"])
    }

    func testAProviderWhoseModelsAreAListIsSkippedWhole() throws {
        // `models` as an array can't be walked by key, and guessing at its shape would
        // publish rates nobody checked.
        XCTAssertNil(try parsedMalformed()["gpt-5.6"])
    }

    func testAnAnthropicModelWithoutACacheWriteRateGetsTheInferredOnes() throws {
        // Anthropic always bills cache writes, and prices the 5-minute tier at 1.25× the
        // input rate and the 1-hour tier at 1.6× that. Cache reads fall back to a tenth
        // of input the same way every provider's do.
        let price = try XCTUnwrap(try parsedMalformed()["claude-sonnet-4-6"])
        XCTAssertEqual(price.cacheCreate5mPerM, 3.75, accuracy: 1e-9)   // 3 × 1.25
        XCTAssertEqual(price.cacheCreate1hPerM, 6.0, accuracy: 1e-9)    // 3.75 × 1.6
        XCTAssertEqual(price.cacheReadPerM, 0.3, accuracy: 1e-9)        // 3 × 0.1
    }

    func testAPayloadWithNoPricedProviderIsRejected() throws {
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(#"{"mistral":{"models":{}}}"#.utf8)) as? [String: Any]
        )
        // Better to keep the previous cache than to publish an empty price table.
        XCTAssertThrowsError(try ModelsDevPricing.parse(root))
    }

    // MARK: - A rate nobody would charge (spec 2026-11-20 small backlog 2 § C)

    /// The four rates models.dev publishes.
    private let rateKinds = ["input", "output", "cache_read", "cache_write"]

    /// A model whose `cost` block publishes every rate, sane, and `rate` for `kind`.
    private func model(_ kind: String, _ rate: Double) -> [String: Any] {
        var cost: [String: Any] = ["input": 2.0, "output": 6.0, "cache_read": 0.5, "cache_write": 2.5]
        cost[kind] = rate
        return ["cost": cost]
    }

    func testTheBoundIsTenThousandDollarsPerMillionTokens() {
        XCTAssertEqual(ModelsDevPricing.maximumRatePerM, 10_000)
    }

    func testARateAtTheBoundIsStillAPrice() throws {
        for kind in rateKinds {
            XCTAssertNotNil(ModelsDevPricing.price(provider: "xai", id: "grok-4.6", model: model(kind, 10_000)), kind)
        }
        let price = try XCTUnwrap(ModelsDevPricing.price(provider: "xai", id: "grok-4.6", model: [
            "cost": ["input": 10_000.0, "output": 10_000.0, "cache_read": 10_000.0, "cache_write": 10_000.0],
        ]))
        XCTAssertEqual(price.inputPerM, 10_000)
        XCTAssertEqual(price.outputPerM, 10_000)
        XCTAssertEqual(price.cacheReadPerM, 10_000)
        XCTAssertEqual(price.cacheCreate5mPerM, 10_000)
    }

    func testARateJustAboveTheBoundMakesTheRowPriceless() {
        for kind in rateKinds {
            let justAbove = model(kind, ModelsDevPricing.maximumRatePerM.nextUp)
            XCTAssertNil(ModelsDevPricing.price(provider: "xai", id: "grok-4.6", model: justAbove), kind)
            XCTAssertNil(ModelsDevPricing.price(provider: "xai", id: "grok-4.6", model: model(kind, 1_000_000)), kind)
        }
    }

    func testANegativeRateMakesTheRowPriceless() {
        for kind in rateKinds {
            XCTAssertNil(ModelsDevPricing.price(provider: "xai", id: "grok-4.6", model: model(kind, -0.01)), kind)
        }
    }

    func testARateThatIsNotAFiniteNumberMakesTheRowPriceless() {
        for kind in rateKinds {
            for rate in [Double.nan, .infinity, -.infinity] {
                XCTAssertNil(
                    ModelsDevPricing.price(provider: "xai", id: "grok-4.6", model: model(kind, rate)), "\(kind) \(rate)"
                )
            }
        }
    }

    func testAZeroRateIsStillAPrice() throws {
        let price = try XCTUnwrap(ModelsDevPricing.price(provider: "xai", id: "grok-free", model: [
            "cost": ["input": 0.0, "output": 0.0, "cache_read": 0.0, "cache_write": 0.0],
        ]))
        XCTAssertEqual(
            price,
            ModelPrice(inputPerM: 0, outputPerM: 0, cacheReadPerM: 0, cacheCreate5mPerM: 0, cacheCreate1hPerM: 0)
        )
    }

    /// Every family of the shared table goes through `price`: in each, the absurd row is
    /// skipped and its neighbour keeps its price.
    func testAnAbsurdRowIsSkippedInEveryFamilyAndItsNeighboursKeepTheirPrices() throws {
        let json = """
        {
          "anthropic": {"models": {
            "claude-opus-4-5": {"cost": {"input": 5, "output": 25}},
            "claude-typo": {"cost": {"input": 5, "output": 25000}}
          }},
          "openai": {"models": {
            "gpt-5.6": {"cost": {"input": 1.25, "output": 10}},
            "gpt-typo": {"cost": {"input": -1.25, "output": 10}}
          }},
          "xai": {"models": {
            "grok-4.6": {"cost": {"input": 2, "output": 6}},
            "grok-typo": {"cost": {"input": 2, "output": 6, "cache_read": 50000}}
          }},
          "google": {"models": {
            "gemini-3.1-pro-preview": {"cost": {"input": 2, "output": 12}},
            "gemini-typo": {"cost": {"input": 2, "output": 12, "cache_write": 12000}}
          }}
        }
        """
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let prices = try ModelsDevPricing.parse(root)
        XCTAssertEqual(Set(prices.keys), ["claude-opus-4-5", "gpt-5.6", "grok-4.6", "gemini-3.1-pro-preview"])
    }

    /// The Mistral family keeps a priceless model with its name, as it keeps a speech model.
    func testAnAbsurdMistralRowKeepsItsNameAndLosesItsPrice() throws {
        let json = """
        {"mistral": {"models": {
          "mistral-large-3": {"name": "Mistral Large 3", "cost": {"input": 50000, "output": 6}},
          "mistral-medium-3": {"name": "Mistral Medium 3", "cost": {"input": 0.4, "output": 2}}
        }}}
        """
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let family = ModelsDevPricing.parseFamily(root, provider: ModelsDevPricing.vibeFamily)
        XCTAssertEqual(family["mistral-large-3"], MistralModelPricing.Model(price: nil, name: "Mistral Large 3"))
        XCTAssertEqual(family["mistral-medium-3"]?.price?.inputPerM, 0.4)
    }

    /// The bound reads what models.dev publishes. A rate inferred from a believable input —
    /// cache reads at a tenth, Anthropic's cache writes at 1.25×, the 1-hour tier at 1.6× —
    /// follows it, past the bound when the input sits at it.
    func testOnlyPublishedRatesAreBoundedNotTheOnesInferredFromThem() throws {
        let price = try XCTUnwrap(ModelsDevPricing.price(
            provider: "anthropic", id: "claude-at-the-bound", model: ["cost": ["input": 10_000.0, "output": 10_000.0]]
        ))
        XCTAssertEqual(price.cacheReadPerM, 1_000, accuracy: 1e-9)
        XCTAssertEqual(price.cacheCreate5mPerM, 12_500, accuracy: 1e-9)
        XCTAssertEqual(price.cacheCreate1hPerM, 20_000, accuracy: 1e-9)
    }
}
