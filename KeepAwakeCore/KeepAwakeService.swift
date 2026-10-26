import Foundation

/// A command's exit status and its output (stdout and stderr together).
struct KeepAwakeCommandResult: Equatable, Sendable {
    var status: Int32
    var output: String
}

/// Everything the daemon does to the machine, behind closures, so the service is tested
/// without pmset, IOKit or launchd.
struct KeepAwakeMachine: Sendable {
    /// `pmset -a disablesleep 0|1`.
    var setSleepDisabled: @Sendable (Bool) -> KeepAwakeCommandResult
    /// `pmset -g`, parsed.
    var readSleepDisabled: @Sendable () -> KeepAwakeFlagReading
    /// `pmset sleepnow`.
    var sleepNow: @Sendable () -> KeepAwakeCommandResult
    /// Both clamshell keys of IOPMrootDomain (plan D5).
    var lid: @Sendable () -> KeepAwakeLid
    /// The internal battery; nil on a Mac without one.
    var power: @Sendable () -> KeepAwakePower?
    /// The next tick; nil cancels it.
    var schedule: @Sendable (Date?) -> Void
    /// When the idle exit is due; nil cancels it.
    var scheduleExit: @Sendable (Date?) -> Void
    /// Live: `exit(status)`, which never returns. The fake records the status and returns.
    var terminate: @Sendable (Int32) -> Void
    /// Live: `Thread.sleep`. Only the stop path waits between its attempts to clear.
    var pause: @Sendable (TimeInterval) -> Void
}

/// The daemon's core (spec 2026-10-26, § Helper): it feeds the engine, applies each decision
/// to the machine and checks it took. Every input reads the lid once, before the flag is
/// applied, as closed **and** causing sleep (plan D5), and passes it to the engine.
///
/// Rules, as the tests cite them:
/// 1. An engine failure (`.invalidDuration`) is replied at once: no pmset, no file write, no
///    schedule.
/// 2. The flag is applied when the input forces it (start, arm, disarm) or when the value
///    differs from the last one applied.
/// 3. Applying `v`: `pmset -a disablesleep v`; a non-zero status is `.commandFailed` and
///    leaves the applied value unknown. Otherwise `pmset -g` must read `.set` for 1 and clear
///    for 0; a mismatch is `.readBack(expected: v)` and leaves it unknown.
/// 4. An arm whose apply failed is rolled back to the engine as it was, and that state's flag
///    applied again; the reply keeps the first failure.
/// 5. Owed sleep (review C4): an output's `sleepNow` makes a sleep owed. While owed, a lid
///    that does not read closed-and-causing-sleep drops it; otherwise, once the flag reads
///    clear, `pmset sleepnow` runs and a zero status drops it. So sleepnow never runs before
///    the clear reads back, and a clear that fails at first still ends in a sleep.
/// 6. The state is saved when it changed during the input (always on start); a save error is
///    logged and otherwise ignored.
/// 7. The next tick is the engine's, or a minute from now while a clear or a sleep is owed.
/// 8. The reply is the engine's state and the first failure.
/// 9. Idle exit (plan D7; review C2). After every input that reaches the apply step, and when a
///    connection opens or closes: not armed, the flag read back clear, no sleep owed and no open
///    connection is idle, and the exit is scheduled a minute later; anything else cancels it.
///    Connections are counted by the listener's id, so an open and a close of the same
///    connection may land in either order: a close that lands first makes its open a no-op.
///    `exitIfIdle` re-checks all of it on the actor and only then terminates with 0, with no
///    `await` in between, so an arm that lands first always keeps the daemon. launchd starts it
///    again on the app's next call (MachServices) or at boot (RunAtLoad).
///    Known and accepted: a connection accepted in the same instant as the exit, whose first
///    message has not reached the actor, loses the race; nothing was set, the app's call fails
///    as unavailable, and its next call starts the daemon again.
/// 10. Stop (review C3, P1a). launchd's SIGTERM (unload, the Login Items switch, unregister) is
///    not followed by a restart after a clean exit, so `terminate(now:)` ends an armed mode as
///    stopped and, when the flag is or may be on, clears it by rule 3: up to three attempts,
///    two seconds apart (inside launchd's 20 s exit timeout). It never sleeps: an unload is not
///    a lid closed in a bag. The state is saved (with the failure when the flag never read
///    clear), and the daemon exits with 0, or with 1 when the flag may still be on, so that
///    launchd restarts a still-loaded job and its start clears again.
actor KeepAwakeService {
    private let machine: KeepAwakeMachine
    private let stateFile: KeepAwakeStateFile
    private var engine = KeepAwakeEngine()
    /// The flag value that last read back; nil while unknown or after a failed apply.
    private var lastApplied: Bool?
    /// A `pmset sleepnow` the service still has to run (review C4).
    private var sleepOwed = false
    /// Open XPC connections by the listener's id; the only count there is (review C2).
    private var openConnections: Set<Int> = []
    /// Connections whose close landed before their open: already gone, so their late open
    /// is ignored (the listener reports both from unordered tasks).
    private var closedBeforeOpen: Set<Int> = []
    /// When the idle exit is due; nil while the daemon is needed.
    private var idleExitAt: Date?

    /// How long the daemon stays idle before it exits (plan D7).
    static let idleExitDelay: TimeInterval = 60
    /// Rule 10: attempts to clear on the way out, and the pause between them.
    static let stopClearAttempts = 3
    static let stopRetryPause: TimeInterval = 2

    init(machine: KeepAwakeMachine, stateFile: KeepAwakeStateFile) {
        self.machine = machine
        self.stateFile = stateFile
    }

    /// Daemon launch: always clear, whatever the state file says (spec § Helper). The flag is
    /// read before the clear (review C5): set, with the lid closed, means sleep.
    func start(now: Date) -> KeepAwakeReply {
        let flagWasSet = machine.readSleepDisabled() == .set
        let lidSleeps = machine.lid().sleepsWhenClosed
        let before = engine.state
        let output = engine.start(persisted: stateFile.load(), flagWasSet: flagWasSet, now: now, lidClosed: lidSleeps)
        if let power = machine.power() {
            _ = engine.power(onBattery: power.onBattery, percent: power.percent, now: now, lidClosed: lidSleeps)
        }
        return apply(output, stateBefore: before, now: now, lidSleeps: lidSleeps, force: true, alwaysSave: true)
    }

    /// Apply. The battery is read afresh first, as a tick does: a low reading from before the
    /// charger went in must not end the new mode, and a missed notification must not let it
    /// start below the floor. A refused duration touches nothing (rule 1).
    func arm(seconds: TimeInterval, floorEnabled: Bool, now: Date) -> KeepAwakeReply {
        let lidSleeps = machine.lid().sleepsWhenClosed
        let stateBefore = engine.state
        guard KeepAwakeRules.accepts(duration: seconds) else {
            let output = engine.arm(duration: seconds, floorEnabled: floorEnabled, now: now, lidClosed: lidSleeps)
            return apply(output, stateBefore: stateBefore, now: now, lidSleeps: lidSleeps, force: true)
        }
        readPower(now: now, lidSleeps: lidSleeps)
        // Rule 4 rolls back to the engine with the fresh reading, so a mode the reading ended
        // stays ended.
        let before = engine
        var output = engine.arm(duration: seconds, floorEnabled: floorEnabled, now: now, lidClosed: lidSleeps)
        output.sleepNow = endedDuringInput(wasArmed: stateBefore.isArmed, lidSleeps: lidSleeps)
        return apply(output, stateBefore: stateBefore, now: now, lidSleeps: lidSleeps, force: true, rollback: before)
    }

    func disarm(now: Date) -> KeepAwakeReply {
        let lidSleeps = machine.lid().sleepsWhenClosed
        let before = engine.state
        let output = engine.disarm(now: now, lidClosed: lidSleeps)
        return apply(output, stateBefore: before, now: now, lidSleeps: lidSleeps, force: true)
    }

    /// The floor switch. The battery is read afresh first, as for Apply.
    func setFloor(enabled: Bool, now: Date) -> KeepAwakeReply {
        let lidSleeps = machine.lid().sleepsWhenClosed
        let before = engine.state
        readPower(now: now, lidSleeps: lidSleeps)
        var output = engine.setFloor(enabled: enabled, now: now, lidClosed: lidSleeps)
        output.sleepNow = endedDuringInput(wasArmed: before.isArmed, lidSleeps: lidSleeps)
        return apply(output, stateBefore: before, now: now, lidSleeps: lidSleeps, force: false)
    }

    /// Feeds the engine the battery as it is now, when there is a battery. Its output is the
    /// input's own to apply: the caller's next engine call settles on top of it.
    private func readPower(now: Date, lidSleeps: Bool) {
        if let power = machine.power() {
            _ = engine.power(onBattery: power.onBattery, percent: power.percent, now: now, lidClosed: lidSleeps)
        }
    }

    /// The engine's sleep rule over a whole input that made two engine calls: an armed mode
    /// ended somewhere in it, and the lid is closed and causes sleep.
    private func endedDuringInput(wasArmed: Bool, lidSleeps: Bool) -> Bool {
        wasArmed && !engine.state.isArmed && lidSleeps
    }

    /// What the app asks for; it settles the deadline and the battery like a tick.
    func state(now: Date) -> KeepAwakeReply {
        tick(now: now)
    }

    /// The wall-clock tick. It also re-reads the battery, for notifications that were missed.
    func tick(now: Date) -> KeepAwakeReply {
        let lidSleeps = machine.lid().sleepsWhenClosed
        let before = engine.state
        let output: KeepAwakeEngine.Output
        if let power = machine.power() {
            output = engine.power(onBattery: power.onBattery, percent: power.percent, now: now, lidClosed: lidSleeps)
        } else {
            output = engine.tick(now: now, lidClosed: lidSleeps)
        }
        return apply(output, stateBefore: before, now: now, lidSleeps: lidSleeps, force: false)
    }

    /// An IOKit power notification. Without a reading nothing changes.
    func powerChanged(now: Date) -> KeepAwakeReply {
        guard let power = machine.power() else {
            return KeepAwakeReply(state: engine.state, failure: nil)
        }
        let lidSleeps = machine.lid().sleepsWhenClosed
        let before = engine.state
        let output = engine.power(onBattery: power.onBattery, percent: power.percent, now: now, lidClosed: lidSleeps)
        return apply(output, stateBefore: before, now: now, lidSleeps: lidSleeps, force: false)
    }

    // MARK: - Idle exit (rule 9)

    /// The listener accepted connection `id`. An open whose close already landed is a
    /// connection that is gone: it is not counted, and its early close is forgotten.
    func connectionOpened(id: Int, now: Date) {
        if closedBeforeOpen.remove(id) == nil {
            openConnections.insert(id)
        }
        scheduleIdleExit(now: now)
    }

    /// Connection `id` was invalidated. A close that lands before its open is remembered, so
    /// the late open does not hold the daemon forever.
    func connectionClosed(id: Int, now: Date) {
        if openConnections.remove(id) == nil {
            closedBeforeOpen.insert(id)
        }
        scheduleIdleExit(now: now)
    }

    /// The exit timer fired: re-check everything here, then exit with 0 in the same step.
    func exitIfIdle(now: Date) {
        guard let idleExitAt, now >= idleExitAt, isIdle else { return }
        NSLog("[keepawake] idle: exiting")
        machine.terminate(0)
    }

    private var isIdle: Bool {
        !engine.state.isArmed && lastApplied == false && !sleepOwed && openConnections.isEmpty
    }

    private func scheduleIdleExit(now: Date) {
        idleExitAt = isIdle ? now + Self.idleExitDelay : nil
        machine.scheduleExit(idleExitAt)
    }

    // MARK: - Stop (rule 10)

    /// SIGTERM or SIGINT: clear, save, then exit (0 when the flag reads clear, 1 otherwise).
    func terminate(now: Date) {
        let before = engine.state
        _ = engine.stop(now: now)
        sleepOwed = false
        var lastFailure: KeepAwakeFailure?
        if before.isArmed || lastApplied != false {
            for attempt in 1...Self.stopClearAttempts {
                if attempt > 1 { machine.pause(Self.stopRetryPause) }
                lastFailure = setFlag(false)
                if lastApplied == false { break }
            }
        }
        let cleared = lastApplied == false
        if !cleared {
            save(engine.state, failure: lastFailure)
        } else if engine.state != before {
            save(engine.state)
        }
        machine.schedule(nil)
        machine.scheduleExit(nil)
        NSLog("[keepawake] stopped by launchd; flag clear: %@", cleared ? "yes" : "no")
        machine.terminate(cleared ? 0 : 1)
    }

    // MARK: - Applying a decision

    private func apply(
        _ output: KeepAwakeEngine.Output,
        stateBefore: KeepAwakeState,
        now: Date,
        lidSleeps: Bool,
        force: Bool,
        rollback: KeepAwakeEngine? = nil,
        alwaysSave: Bool = false
    ) -> KeepAwakeReply {
        // Rule 1.
        if let failure = output.failure {
            return KeepAwakeReply(state: engine.state, failure: failure)
        }
        // Rules 2 and 3.
        var firstFailure: KeepAwakeFailure?
        if force || output.sleepDisabled != lastApplied {
            firstFailure = setFlag(output.sleepDisabled)
        }
        // Rule 4.
        if firstFailure != nil, let rollback {
            engine = rollback
            _ = setFlag(engine.state.isArmed)
        }
        // Rule 5.
        if output.sleepNow { sleepOwed = true }
        if sleepOwed {
            if !lidSleeps {
                sleepOwed = false
            } else if lastApplied == false {
                let result = machine.sleepNow()
                if result.status == 0 {
                    sleepOwed = false
                } else {
                    NSLog("[keepawake] sleepnow: %d", result.status)
                }
            }
        }
        // Rule 6.
        if alwaysSave || engine.state != stateBefore {
            save(engine.state)
        }
        // Rule 7.
        let owed = lastApplied == nil || sleepOwed
        machine.schedule(engine.nextTick(now: now) ?? (owed ? now + KeepAwakeRules.tickInterval : nil))
        // Rule 9.
        scheduleIdleExit(now: now)
        // Rule 8.
        return KeepAwakeReply(state: engine.state, failure: firstFailure)
    }

    /// Rule 3: applies `value` and reads it back; nil when it took.
    private func setFlag(_ value: Bool) -> KeepAwakeFailure? {
        let result = machine.setSleepDisabled(value)
        guard result.status == 0 else {
            lastApplied = nil
            return .commandFailed(command: "pmset", status: result.status)
        }
        let reading = machine.readSleepDisabled()
        let took = value ? reading == .set : reading.isClear
        guard took else {
            lastApplied = nil
            return .readBack(expected: value)
        }
        lastApplied = value
        return nil
    }

    private func save(_ state: KeepAwakeState, failure: KeepAwakeFailure? = nil) {
        do {
            try stateFile.save(state, failure: failure)
        } catch {
            NSLog("[keepawake] state file: %@", String(describing: error))
        }
    }
}
