import Foundation

/// The words for a window counted in a dollar allowance (spec 2026-11-10 Mistral provider
/// § Windows): "Vibe: $17.88 of the $300 monthly allowance". Mistral's own count of the
/// allowance, not an API-list-price estimate, so no API-equivalent caption goes with it.
enum AllowanceCopy {
    /// "Vibe: $17.88 of the $300 monthly allowance": used to the cent, the allowance in whole
    /// dollars when it is whole.
    static func line(label: String, allowance: CreditPool, locale: Locale = .current) -> String {
        "\(label): \(used(allowance.usedDollars, locale: locale)) of the \(limit(allowance.limitDollars, locale: locale)) monthly allowance"
    }

    /// One line per window that carries an allowance, in the provider's order; nil when none
    /// does. A prepaid credit pool is not an allowance: its dollars are the spend card's.
    static func caption(for service: ServiceSnapshot, locale: Locale = .current) -> String? {
        let lines = service.buckets.compactMap { bucket in
            bucket.allowance.map { line(label: bucket.label, allowance: $0, locale: locale) }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private static func used(_ amount: Double, locale: Locale) -> String {
        amount.formatted(.currency(code: "USD").precision(.fractionLength(2)).locale(locale))
    }

    private static func limit(_ amount: Double, locale: Locale) -> String {
        let digits = amount == amount.rounded() ? 0 : 2
        return amount.formatted(.currency(code: "USD").precision(.fractionLength(digits)).locale(locale))
    }
}
