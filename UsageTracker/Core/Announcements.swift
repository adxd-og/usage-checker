import Foundation

/// Time-bound announcements that need to disappear automatically when the underlying
/// promo / change expires. Update these constants if Anthropic ships a new policy.
enum Announcements {
    /// Temporary +50% weekly-limit boost across all Pro/Max/Team plans.
    /// Announced 13 May 2026, ends 13 July 2026.
    static let weeklyBonusStart: Date = ISO8601DateFormatter().date(from: "2026-05-13T00:00:00Z")!
    static let weeklyBonusEnd: Date = ISO8601DateFormatter().date(from: "2026-07-13T23:59:59Z")!

    static func weeklyBonus(at now: Date = Date()) -> WeeklyBonus {
        if now >= weeklyBonusStart && now <= weeklyBonusEnd {
            return .active(endsAt: weeklyBonusEnd)
        }
        return .inactive
    }

    /// Fable 5 is included in Pro/Max/Team/Enterprise at no extra cost only through
    /// 22 June 2026; from 23 June it draws extra-usage credits instead.
    static let fableIncludedStart: Date = ISO8601DateFormatter().date(from: "2026-06-09T00:00:00Z")!
    static let fableIncludedEnd: Date = ISO8601DateFormatter().date(from: "2026-06-22T23:59:59Z")!

    static func fableIncluded(at now: Date = Date()) -> WeeklyBonus {
        if now >= fableIncludedStart && now <= fableIncludedEnd {
            return .active(endsAt: fableIncludedEnd)
        }
        return .inactive
    }
}

enum WeeklyBonus: Equatable, Sendable {
    case active(endsAt: Date)
    case inactive

    var isActive: Bool {
        if case .active = self { return true }
        return false
    }

    var endsAt: Date? {
        if case .active(let d) = self { return d }
        return nil
    }
}
