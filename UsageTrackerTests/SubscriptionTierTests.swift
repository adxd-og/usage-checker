import XCTest
@testable import Omelette

/// Anthropic's plan rename of 2026-10-30: Max 5x is "Max", Max 20x is "Ultra". The
/// credentials keep saying `max` with a rate-limit tier, or already say `ultra`.
final class SubscriptionTierTests: XCTestCase {
    func testTheFormerMax20xIsUltra() {
        let tier = SubscriptionTier(rawSubscriptionType: "max", rateLimitTier: "default_claude_max_20x")
        XCTAssertEqual(tier, .ultra)
        XCTAssertEqual(tier.displayName, "Claude Ultra")
    }

    func testTheFormerMax5xIsMax() {
        let tier = SubscriptionTier(rawSubscriptionType: "max", rateLimitTier: "default_claude_max_5x")
        XCTAssertEqual(tier, .max)
        XCTAssertEqual(tier.displayName, "Claude Max")
    }

    func testAMaxWithNoTierIsMax() {
        XCTAssertEqual(SubscriptionTier(rawSubscriptionType: "Max", rateLimitTier: nil), .max)
    }

    func testCredentialsThatAlreadySayUltraReadAsUltra() {
        XCTAssertEqual(SubscriptionTier(rawSubscriptionType: "ultra", rateLimitTier: nil).displayName, "Claude Ultra")
    }

    func testTheOtherPlansKeepTheirNames() {
        XCTAssertEqual(SubscriptionTier(rawSubscriptionType: "pro", rateLimitTier: nil).displayName, "Claude Pro")
        XCTAssertEqual(SubscriptionTier(rawSubscriptionType: "team", rateLimitTier: nil).displayName, "Claude Team")
        XCTAssertEqual(SubscriptionTier(rawSubscriptionType: "something_new", rateLimitTier: nil).displayName, "Claude")
    }
}
