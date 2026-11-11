import XCTest
@testable import Omelette

/// Spec 2026-11-10 Mistral provider § Windows: a window counted in a dollar allowance says how
/// much of it is used, "$17.88 of $300", in a copy that says "of the monthly allowance": Mistral's
/// own count, not an API-list-price estimate. The provider page shows one line per such window,
/// in the provider's order.
final class AllowanceCopyTests: XCTestCase {
    private let locale = Locale(identifier: "en_US")

    func testAWindowSaysItsDollarsOfTheMonthlyAllowance() {
        XCTAssertEqual(
            AllowanceCopy.line(label: "Vibe", allowance: CreditPool(usedDollars: 17.879252, limitDollars: 300), locale: locale),
            "Vibe: $17.88 of the $300 monthly allowance"
        )
    }

    func testAnUntouchedAllowanceSaysNothingUsedToTheCent() {
        XCTAssertEqual(
            AllowanceCopy.line(label: "API", allowance: CreditPool(usedDollars: 0, limitDollars: 30), locale: locale),
            "API: $0.00 of the $30 monthly allowance"
        )
    }

    func testAnAllowanceThatIsNotWholeDollarsKeepsItsCents() {
        XCTAssertEqual(
            AllowanceCopy.line(label: "Vibe", allowance: CreditPool(usedDollars: 1.5, limitDollars: 12.5), locale: locale),
            "Vibe: $1.50 of the $12.50 monthly allowance"
        )
    }

    func testThePageListsEveryWindowWithAnAllowanceInTheProvidersOrder() {
        let service = Fixture.snapshot(id: "mistral", buckets: [
            Fixture.bucket(
                id: "mistral_vibe", label: "Vibe", percent: 6, kind: .weekly,
                allowance: CreditPool(usedDollars: 17.879252, limitDollars: 300)
            ),
            Fixture.bucket(
                id: "mistral_api", label: "API", percent: 0, kind: .modelSpecific,
                allowance: CreditPool(usedDollars: 0, limitDollars: 30)
            ),
            Fixture.bucket(id: "mistral_other", label: "Other", percent: 3, kind: .modelSpecific),
        ])
        XCTAssertEqual(
            AllowanceCopy.caption(for: service, locale: locale),
            "Vibe: $17.88 of the $300 monthly allowance\nAPI: $0.00 of the $30 monthly allowance"
        )
    }

    func testNoAllowanceIsNoLineAndACreditPoolIsNotAnAllowance() {
        let grok = Fixture.snapshot(id: "grok", buckets: [Fixture.bucket(id: "grok_credits", percent: 40, kind: .weekly)])
        XCTAssertNil(AllowanceCopy.caption(for: grok, locale: locale))
        XCTAssertNil(AllowanceCopy.caption(for: Fixture.snapshot(buckets: [Fixture.cloudCredits]), locale: locale))
    }
}
