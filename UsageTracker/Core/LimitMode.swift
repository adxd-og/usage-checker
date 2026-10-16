import Foundation

/// How the Limits tab measures one account: spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § Accounts without percent
/// windows. A chat is measured either by the half-hour bins of a percent window, or by
/// dollars against a budget, the period's spend or a spend limit.
enum LimitMode: Equatable, Sendable {
    /// The account has a core session or weekly window. Shares come from
    /// `LimitShareRules.share(window:bucketID:readings:log:)`.
    case subscription
    /// No window of its own, billed per use. `weeklyBudget` is the Claude budget set in
    /// Settings. It is nil when none is set, and always nil for Codex, which has no
    /// budget setting.
    case payAsYouGo(weeklyBudget: Double?)
    /// No core window, and extra usage switched on with a monthly limit: an Enterprise
    /// or Team account with a spend limit. In dollars, as `ExtraUsage` holds them.
    case spendLimit(monthlyLimit: Double, usedCredits: Double)
}

extension LimitShareRules {
    /// The account's mode, from its live snapshot.
    ///
    /// The checks run in this order:
    /// 1. A core window makes a subscription. The synthetic budget bucket is not one
    ///    (`windowKinds(of:)`).
    /// 2. A spend limit comes next. A spend-based Enterprise account has no window
    ///    either, so `CostCopy.isPayAsYouGo` is true for it too.
    /// 3. Pay as you go comes last. The weekly budget counts only for Claude, and only
    ///    when one is set.
    ///
    /// nil for an account with nothing to measure, such as one signed out with no
    /// windows.
    nonisolated static func mode(of service: ServiceSnapshot, weeklyBudgetUSD: Double) -> LimitMode? {
        if !windowKinds(of: service).isEmpty { return .subscription }
        if let extra = service.extraUsage, extra.isEnabled, extra.monthlyLimit > 0 {
            return .spendLimit(monthlyLimit: extra.monthlyLimit, usedCredits: extra.usedCredits)
        }
        guard CostCopy.isPayAsYouGo(service) else { return nil }
        let budget = service.id == "claude" && weeklyBudgetUSD > 0 ? weeklyBudgetUSD : nil
        return .payAsYouGo(weeklyBudget: budget)
    }
}
