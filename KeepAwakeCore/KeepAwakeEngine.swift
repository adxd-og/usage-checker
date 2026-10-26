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
    /// The last battery reading; nil until the first.
    private(set) var power: KeepAwakePower?

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

    /// The floor switch moved (spec § Behaviour, floor switch while armed): an armed mode takes
    /// the new value, and turning it on while already low ends the mode at once. Idle and
    /// ended stay as they are.
    mutating func setFloor(enabled: Bool, now: Date, lidClosed: Bool) -> Output {
        let wasArmed = state.isArmed
        if case .armed(let deadline, _) = state {
            state = .armed(deadline: deadline, floorEnabled: enabled)
        }
        settle(now: now)
        return output(wasArmed: wasArmed, lidClosed: lidClosed)
    }

    /// A battery reading (spec § Behaviour, Battery floor): on battery below 25 % with the floor
    /// on, an armed mode ends. It settles the deadline too.
    mutating func power(onBattery: Bool, percent: Int, now: Date, lidClosed: Bool) -> Output {
        power = KeepAwakePower(onBattery: onBattery, percent: percent)
        let wasArmed = state.isArmed
        settle(now: now)
        return output(wasArmed: wasArmed, lidClosed: lidClosed)
    }

    /// Daemon launch → always clear, regardless of the file (spec § Helper). Whether to sleep
    /// comes from the flag as `pmset -g` read it before the start's clear, not from the file
    /// (review C5): a crash with the lid closed is the bag case even when the armed state never
    /// reached the file, which only supplies an ended mode's reason.
    mutating func start(persisted: KeepAwakeState?, flagWasSet: Bool, now: Date, lidClosed: Bool) -> Output {
        switch persisted {
        case .armed:
            state = .ended(at: now, reason: .restarted)
        case .ended(let at, let reason):
            state = .ended(at: at, reason: reason)
        case .idle, nil:
            state = flagWasSet ? .ended(at: now, reason: .restarted) : (persisted ?? .idle)
        }
        return Output(sleepDisabled: false, sleepNow: flagWasSet && lidClosed, state: state, failure: nil)
    }

    /// launchd stopped the helper (review C3): an armed mode ends as stopped. Never sleeps: an
    /// unload is not the bag case.
    mutating func stop(now: Date) -> Output {
        let wasArmed = state.isArmed
        settle(now: now)
        if state.isArmed {
            state = .ended(at: now, reason: .stopped)
        }
        return output(wasArmed: wasArmed, lidClosed: false)
    }

    /// The next tick while armed: a minute from now, or the deadline if that comes first.
    func nextTick(now: Date) -> Date? {
        guard case .armed(let deadline, _) = state else { return nil }
        return min(now + KeepAwakeRules.tickInterval, deadline)
    }

    /// Ends an armed mode whose deadline has passed, then one below the battery floor.
    private mutating func settle(now: Date) {
        if case .armed(let deadline, _) = state, now >= deadline {
            state = .ended(at: now, reason: .deadline)
        }
        if case .armed(_, true) = state, let power, KeepAwakeRules.isBelowFloor(power) {
            state = .ended(at: now, reason: .batteryFloor)
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
