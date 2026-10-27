// KeepAwakeCore: the keep-awake feature's rules, state, engine, readings and XPC contract.
// Compiled into both the app (so its test bundle covers it) and the omelette-keepawake daemon.
import Foundation

/// The internal battery as the floor sees it: whether it is the power source, and its charge.
struct KeepAwakePower: Equatable, Sendable {
    var onBattery: Bool
    var percent: Int
}

/// Keep awake with the lid closed (spec 2026-10-26, § Design › Behaviour): timed only, from
/// one minute to seven days, and ended by itself on battery below 25 %.
enum KeepAwakeRules {
    static let minimumDuration: TimeInterval = 60
    static let maximumDuration: TimeInterval = 604_800
    static let maximumDays = 7
    static let batteryFloorPercent = 25
    /// How often the daemon looks at the deadline and the battery while armed.
    static let tickInterval: TimeInterval = 60

    /// The popover's three steppers.
    struct Parts: Equatable, Sendable {
        var days: Int
        var hours: Int
        var minutes: Int
    }

    private static let maximumMinutes = 10_080

    /// The fields' total in seconds. Nothing is clamped: a negative value, a zero total or a
    /// total over seven days is refused (nil), and the block says why; hours and minutes over
    /// their range carry over (90 min is 1 h 30 min). Bounded before multiplying, so an
    /// absurd value cannot overflow.
    static func duration(days: Int, hours: Int, minutes: Int) -> TimeInterval? {
        guard days >= 0, hours >= 0, minutes >= 0,
              days <= maximumDays, hours <= 24 * maximumDays, minutes <= maximumMinutes
        else { return nil }
        let totalMinutes = days * 1_440 + hours * 60 + minutes
        guard totalMinutes >= 1, totalMinutes <= maximumMinutes else { return nil }
        return TimeInterval(totalMinutes * 60)
    }

    /// The privileged side's check: it refuses anything outside one minute to seven days
    /// rather than capping it (plan D4).
    static func accepts(duration: TimeInterval) -> Bool {
        duration.isFinite && duration >= minimumDuration && duration <= maximumDuration
    }

    /// A remembered duration back into the three steppers, brought inside 1 minute … 7 days.
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
