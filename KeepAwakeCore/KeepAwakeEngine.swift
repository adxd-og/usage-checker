import Foundation

/// The daemon's decision maker (spec 2026-10-26, § Helper › Engine): a value with no clock and
/// no machine. Every input returns the flag value to apply (only a start may leave the flag
/// as it is), whether to run `pmset sleepnow` after clearing it, and the state to report and
/// persist.
///
/// The one output rule: `sleepNow` is true when an armed mode ended during this input and the
/// lid is closed (plan D5); clearing the flag with the lid closed leaves the Mac awake (spike
/// step 5), so the end of a mode in a bag has to ask for sleep itself.
///
/// The thermal guard (spec 2026-11-19, § Rule) is one more input, `thermal`, and one more
/// switch, `setThermalGuard`; heat ends an armed mode as `overheated` through the same output.
struct KeepAwakeEngine: Equatable, Sendable {
    struct Output: Equatable, Sendable {
        /// The flag value to apply; nil leaves the flag as it is (a start that finds a flag the
        /// helper did not set, reviewer V3).
        var sleepDisabled: Bool?
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
    /// The thermal guard's switch: every accepted `arm` turns it on, whatever an earlier mode
    /// left (spec 2026-11-19, § Plan decisions accepted by the session, item 6), so a mode an app
    /// that predates the guard arms has it on, and a mode whose app wants it off gets
    /// `setThermalGuard(false)` after Apply.
    private(set) var thermalGuard = true
    /// Where the current hot run began (`KeepAwakeRules.hotSince`); nil while there is none.
    private(set) var hotSince: Date?

    init() {}

    /// Apply: sets the flag until `now + duration`; while armed it replaces the deadline. A
    /// duration outside one minute to 7 d 23 h 59 min is refused and changes nothing. Every
    /// accepted Apply turns the thermal guard on. A new mode starts without the last mode's hot
    /// run; Apply while armed keeps the one counting.
    mutating func arm(duration: TimeInterval, floorEnabled: Bool, now: Date, lidClosed: Bool) -> Output {
        guard KeepAwakeRules.accepts(duration: duration) else {
            return output(wasArmed: state.isArmed, lidClosed: false, failure: .invalidDuration)
        }
        let wasArmed = state.isArmed
        thermalGuard = true
        if !wasArmed { hotSince = nil }
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

    /// A thermal reading (spec 2026-11-19, § Rule). It settles the deadline and the battery
    /// first, so a mode past its deadline ends for the deadline. Then, with the lid closed and
    /// the guard on, `critical` ends an armed mode at this reading and `serious` held for a
    /// minute ends it, as `overheated` at `now` (`KeepAwakeRules.endsForHeat`). Idle and ended
    /// forget any hot run.
    mutating func thermal(level: KeepAwakeThermalLevel, now: Date, lidClosed: Bool) -> Output {
        let wasArmed = state.isArmed
        settle(now: now)
        guard state.isArmed else {
            hotSince = nil
            return output(wasArmed: wasArmed, lidClosed: lidClosed)
        }
        hotSince = KeepAwakeRules.hotSince(level: level, previous: hotSince, now: now, lidClosed: lidClosed, guardEnabled: thermalGuard)
        if KeepAwakeRules.endsForHeat(level: level, hotSince: hotSince, now: now, lidClosed: lidClosed, guardEnabled: thermalGuard) {
            state = .ended(at: now, reason: .overheated)
            hotSince = nil
        }
        return output(wasArmed: wasArmed, lidClosed: lidClosed)
    }

    /// The guard's switch moved (spec 2026-11-19, § Settings). Turning it off forgets the hot
    /// run; turning it on ends nothing by itself: the next reading decides. Any state takes it;
    /// an armed mode keeps its deadline.
    mutating func setThermalGuard(enabled: Bool, now: Date, lidClosed: Bool) -> Output {
        thermalGuard = enabled
        if !enabled { hotSince = nil }
        let wasArmed = state.isArmed
        settle(now: now)
        return output(wasArmed: wasArmed, lidClosed: lidClosed)
    }

    /// Daemon launch (spec § Helper; reviewer V3, which supersedes review C5's "always clear").
    /// The flag is the helper's when the file says so: an armed mode (Apply writes it before
    /// the flag goes on), or `ownsFlag`, a clear that never read back or a sleep still owed.
    /// The helper's flag is cleared, and whether to sleep comes from the flag as `pmset -g`
    /// read it before that clear (C5): set, with the lid closed, is the bag case. A flag that
    /// reads set and is not the helper's (another app, `pmset` by hand) is left as it is, with
    /// the state the file holds: nothing ended, nothing to sleep from. A flag that does not
    /// read set is cleared either way; nothing is lost by it. The file supplies an ended
    /// mode's reason.
    mutating func start(persisted: KeepAwakeState?, ownsFlag: Bool, flagWasSet: Bool, now: Date, lidClosed: Bool) -> Output {
        let ours = ownsFlag || persisted?.isArmed == true
        switch persisted {
        case .armed:
            state = .ended(at: now, reason: .restarted)
        case .ended(let at, let reason):
            state = .ended(at: at, reason: reason)
        case .idle, nil:
            state = flagWasSet && ours ? .ended(at: now, reason: .restarted) : .idle
        }
        guard ours || !flagWasSet else {
            return Output(sleepDisabled: nil, sleepNow: false, state: state, failure: nil)
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

    /// The next tick while armed: a minute from now, or the deadline if that comes first, or the
    /// moment a counting hot run reaches its minute if that comes first (spec 2026-11-19).
    func nextTick(now: Date) -> Date? {
        guard case .armed(let deadline, _) = state else { return nil }
        let next = min(now + KeepAwakeRules.tickInterval, deadline)
        guard let hotSince else { return next }
        return min(next, hotSince + KeepAwakeRules.heatHoldInterval)
    }

    /// Ends an armed mode whose deadline has passed, at the deadline (the moment the app's
    /// local countdown reports too), then one below the battery floor, at `now`.
    private mutating func settle(now: Date) {
        if case .armed(let deadline, _) = state, now >= deadline {
            state = .ended(at: deadline, reason: .deadline)
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
