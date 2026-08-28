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
          "gpt-5.6": {"cost": {"input": 1.25, "output": 10}}
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
        XCTAssertEqual(price.cacheCreate5mPerM, 0)
    }

    func testAPayloadWithNoPricedProviderIsRejected() throws {
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(#"{"mistral":{"models":{}}}"#.utf8)) as? [String: Any]
        )
        // Better to keep the previous cache than to publish an empty price table.
        XCTAssertThrowsError(try ModelsDevPricing.parse(root))
    }
}
