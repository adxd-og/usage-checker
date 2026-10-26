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

    /// The steppers' total in seconds: each stepper is clamped to its range (d 0–7, h 0–23,
    /// m 0–59), zero is refused, and the total stops at seven days (plan D4).
    static func duration(days: Int, hours: Int, minutes: Int) -> TimeInterval? {
        let days = min(max(days, 0), maximumDays)
        let hours = min(max(hours, 0), 23)
        let minutes = min(max(minutes, 0), 59)
        let total = TimeInterval(days * 86_400 + hours * 3_600 + minutes * 60)
        guard total > 0 else { return nil }
        return min(total, maximumDuration)
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
