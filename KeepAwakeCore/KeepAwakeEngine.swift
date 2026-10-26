import Foundation

/// The daemon's decision maker (spec 2026-10-26, § Helper › Engine): a value with no clock and
/// no machine. Every input returns the flag value to apply, whether to run `pmset sleepnow`
/// after clearing it, and the state to report and persist.
///
/// The one output rule: `sleepNow` is true when an armed mode ended during this input and the
/// lid is closed (plan D5); clearing the flag with the lid closed leaves the Mac awake (spike
/// step 5), so the end of a mode in a bag has to ask for sleep itself.
struct KeepAwakeEngine: Equatable, Sendable {
    struct Output: Equatable, Sendable {
        /// The flag value to apply.
        var sleepDisabled: Bool
        /// Run `pmset sleepnow` after clearing.
        var sleepNow: Bool
        /// What to report and persist.
        var state: KeepAwakeState
        /// `.invalidDuration` only.
        var failure: KeepAwakeFailure?
    }

    private(set) var state: KeepAwakeState = .idle

    init() {}

    /// Apply: sets the flag until `now + duration`; while armed it replaces the deadline. A
    /// duration outside one minute to seven days is refused and changes nothing.
    mutating func arm(duration: TimeInterval, floorEnabled: Bool, now: Date, lidClosed: Bool) -> Output {
        guard KeepAwakeRules.accepts(duration: duration) else {
            return output(wasArmed: state.isArmed, lidClosed: false, failure: .invalidDuration)
        }
        let wasArmed = state.isArmed
        state = .armed(deadline: now + duration, floorEnabled: floorEnabled)
        settle(now: now)
        return output(wasArmed: wasArmed, lidClosed: lidClosed)
    }

    /// Cancel. While idle or ended it still asks for the flag cleared (the reset path).
    mutating func disarm(now: Date, lidClosed: Bool) -> Output {
        let wasArmed = state.isArmed
        settle(now: now)
        if state.isArmed {
            state = .ended(at: now, reason: .cancelled)
        }
        return output(wasArmed: wasArmed, lidClosed: lidClosed)
    }

    /// The wall-clock tick: ends an armed mode at its deadline.
    mutating func tick(now: Date, lidClosed: Bool) -> Output {
        let wasArmed = state.isArmed
        settle(now: now)
        return output(wasArmed: wasArmed, lidClosed: lidClosed)
    }

    /// The next tick while armed: a minute from now, or the deadline if that comes first.
    func nextTick(now: Date) -> Date? {
        guard case .armed(let deadline, _) = state else { return nil }
        return min(now + KeepAwakeRules.tickInterval, deadline)
    }

    /// Ends an armed mode whose deadline has passed.
    private mutating func settle(now: Date) {
        if case .armed(let deadline, _) = state, now >= deadline {
            state = .ended(at: now, reason: .deadline)
        }
    }

    private func output(wasArmed: Bool, lidClosed: Bool, failure: KeepAwakeFailure? = nil) -> Output {
        Output(
            sleepDisabled: state.isArmed,
            sleepNow: wasArmed && !state.isArmed && lidClosed,
            state: state,
            failure: failure
        )
    }
}
