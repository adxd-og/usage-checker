import Foundation

/// The Claude plan as the credentials name it. Since 2026-10-30 Anthropic calls the
/// former Max 5x "Max" and the former Max 20x "Ultra"; the credentials may still say
/// `max` with a `5x` / `20x` rate-limit tier, or already `ultra`.
enum SubscriptionTier: String, Equatable, Sendable {
    case free
    case pro
    case max
    case ultra
    case team
    case enterprise
    case unknown

    init(rawSubscriptionType: String?, rateLimitTier: String?) {
        let s = (rawSubscriptionType ?? "").lowercased()
        let t = (rateLimitTier ?? "").lowercased()
        switch s {
        case "free": self = .free
        case "pro": self = .pro
        case "team": self = .team
        case "enterprise": self = .enterprise
        case "max": self = t.contains("20x") ? .ultra : .max
        case "ultra": self = .ultra
        default:
            self = .unknown
        }
    }

    var displayName: String {
        switch self {
        case .free: return "Claude Free"
        case .pro: return "Claude Pro"
        case .max: return "Claude Max"
        case .ultra: return "Claude Ultra"
        case .team: return "Claude Team"
        case .enterprise: return "Claude Enterprise"
        case .unknown: return "Claude"
        }
    }

    var isEnterpriseLike: Bool {
        self == .team || self == .enterprise
    }
}
