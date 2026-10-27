// KeepAwakeCore: the keep-awake feature's rules, state, engine, readings and XPC contract.
// Compiled into both the app (so its test bundle covers it) and the omelette-keepawake daemon.
import Foundation

/// The internal battery as the floor sees it: whether it is the power source, and its charge.
struct KeepAwakePower: Equatable, Sendable {
    var onBattery: Bool
    var percent: Int
}

/// Keep awake with the lid closed (spec 2026-10-26, § Design › Behaviour): timed only, from
/// one minute to 7 d 23 h 59 min (more is brought down to it on Apply), and ended by
/// itself on battery below 25 %.
enum KeepAwakeRules {
    static let minimumDuration: TimeInterval = 60
    static let maximumDuration: TimeInterval = 691_140
    static let maximumDays = 7
    static let batteryFloorPercent = 25
    /// How often the daemon looks at the deadline and the battery while armed.
    static let tickInterval: TimeInterval = 60

    /// The popover's three number fields.
    struct Parts: Equatable, Sendable {
        var days: Int
        var hours: Int
        var minutes: Int
    }

    /// 7 d 23 h 59 min: the fields' ceiling (owner, 2026-10-27).
    private static let maximumMinutes = 11_519

    /// The fields' total in seconds. A negative field or a zero total is refused (nil); a
    /// total over the ceiling is brought down to it (owner, 2026-10-27: Apply adapts, the
    /// block only says so). Checked before multiplying, so an absurd value cannot overflow.
    static func duration(days: Int, hours: Int, minutes: Int) -> TimeInterval? {
        guard days >= 0, hours >= 0, minutes >= 0 else { return nil }
        guard days <= maximumDays, hours <= maximumMinutes / 60, minutes <= maximumMinutes else {
            return maximumDuration
        }
        let totalMinutes = days * 1_440 + hours * 60 + minutes
        guard totalMinutes >= 1 else { return nil }
        return TimeInterval(min(totalMinutes, maximumMinutes) * 60)
    }

    /// The privileged side's check: it refuses anything outside one minute to 7 d 23 h 59 min
    /// rather than capping it (plan D4).
    static func accepts(duration: TimeInterval) -> Bool {
        duration.isFinite && duration >= minimumDuration && duration <= maximumDuration
    }

    /// A remembered duration back into the three fields, brought inside 1 minute … 7 d 23 h 59 min.
    static func parts(totalMinutes: Int) -> Parts {
        let total = min(max(totalMinutes, 1), maximumMinutes)
        return Parts(days: total / 1_440, hours: (total % 1_440) / 60, minutes: total % 60)
    }

    /// On battery and below the floor; on the charger the battery never ends the mode.
    static func isBelowFloor(_ power: KeepAwakePower) -> Bool {
        power.onBattery && power.percent < batteryFloorPercent
    }
}

extension KeepAwakeRules {
    /// The app's local countdown (spec § Behaviour › Visible): an armed state past its deadline
    /// reads as ended by the deadline, at the deadline, even before the helper says so.
    static func effectiveState(_ state: KeepAwakeState, now: Date) -> KeepAwakeState {
        if case .armed(let deadline, _) = state, now >= deadline {
            return .ended(at: deadline, reason: .deadline)
        }
        return state
    }

    /// Armed and before its deadline.
    static func isActive(_ state: KeepAwakeState, now: Date) -> Bool {
        effectiveState(state, now: now).isArmed
    }
}
