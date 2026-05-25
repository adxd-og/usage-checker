import Foundation

enum SubscriptionTier: String, Equatable, Sendable {
    case free
    case pro
    case max5x
    case max20x
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
        case "max":
            if t.contains("20x") { self = .max20x }
            else if t.contains("5x") { self = .max5x }
            else { self = .max5x }
        default:
            self = .unknown
        }
    }

    var displayName: String {
        switch self {
        case .free: return "Claude Free"
        case .pro: return "Claude Pro"
        case .max5x: return "Claude Max 5x"
        case .max20x: return "Claude Max 20x"
        case .team: return "Claude Team"
        case .enterprise: return "Claude Enterprise"
        case .unknown: return "Claude"
        }
    }

    var isEnterpriseLike: Bool {
        self == .team || self == .enterprise
    }
}
