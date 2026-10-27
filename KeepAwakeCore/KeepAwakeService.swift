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
///    differs from the last one applied. An output that leaves the flag as it is (a start that
///    found a flag the helper did not set, rule 11; a disarm with nothing armed while the
///    helper holds nothing, tester F1) applies nothing, and the helper holds nothing:
///    `lastApplied` is false, as after a clear.
/// 3. Applying `v`: `pmset -a disablesleep v`; a non-zero status is `.commandFailed` and
///    leaves the applied value unknown. Otherwise `pmset -g` must read `.set` for 1 and clear
///    for 0; a mismatch is `.readBack(expected: v)` and leaves it unknown.
/// 4. An arm whose apply failed is rolled back to the engine as it was, and that state's flag
///    applied again; the reply keeps the first failure. Tester F2: when the helper held no
///    flag of its own before the arm and pmset refused the set (`.commandFailed`), the
///    rollback writes nothing. If the start found the flag another tool's (rule 11), it stays
///    theirs and the helper holds nothing; otherwise the flag is unknown, the helper's to
///    clear (rule 7's retry). A read-back failure may have left the flag on, so that rollback
///    still clears.
/// 5. Owed sleep (review C4): an output's `sleepNow` makes a sleep owed. While owed, a lid
///    that does not read closed-and-causing-sleep drops it; otherwise, once the flag reads
///    clear, `pmset sleepnow` runs and a zero status drops it. So sleepnow never runs before
///    the clear reads back, and a clear that fails at first still ends in a sleep. The debt is
///    saved beside the state (whole-branch review W1), and `start` restores it before its
///    forced apply, so a daemon that dies before its retry still has it paid or dropped.
/// 6. The state is saved when it, the owed sleep or whether the helper owns the flag changed
///    during the input (always on start, and again after rule 12's early save); a save error
///    is logged and otherwise ignored.
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
///    stopped and, when the helper holds the flag or may (never a flag it did not set, rule
///    11), clears it by rule 3: up to three attempts,
///    two seconds apart (inside the plist's 90 s ExitTimeOut). It never sleeps: an unload is not
///    a lid closed in a bag, so an owed sleep is dropped, from the file too. The state is saved
///    (with the failure when the flag never read clear), and the daemon exits with 0, or with
///    1 when the flag may still be on, so that launchd restarts a still-loaded job and its
///    start clears again (the file says the helper owns the flag, rule 11).
/// 11. Start (reviewer V3, superseding review C5's "always clear"). The flag is read first.
///    The file says whether it is the helper's: an armed mode, a sleep owed (rule 5), or
///    `ownsFlag` — the helper set it, or may have, and never saw it read clear (rule 10's
///    exit 1, a clear that failed before a crash). The helper's flag is cleared and, set with
///    the lid closed, slept from; a set flag that is not its own (another app, `pmset` by
///    hand) is left as it is, with the state on file, and the daemon may go idle.
/// 12. Arming writes first (V3). An input that moves the engine into armed saves the armed
///    state before it sets the flag, so a crash between the two leaves "armed" on file and
///    rule 11 clears the flag; a set that fails rolls back (rule 4) and the file is written
///    again.
actor KeepAwakeService {
    private let machine: KeepAwakeMachine
    private let stateFile: KeepAwakeStateFile
    private var engine = KeepAwakeEngine()
    /// The flag value that last read back; nil while unknown or after a failed apply; false
    /// too when the helper holds nothing because the flag it found set was not its own
    /// (rule 2).
    private var lastApplied: Bool?
    /// The start found the flag set and not the helper's (rule 11); true until a value the
    /// helper applies reads back. A set pmset refuses meanwhile leaves it the other tool's
    /// (rule 4).
    private var flagIsAnothers = false
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

    /// Daemon launch (rule 11): clears the flag when it is the helper's or does not read set,
    /// and leaves a set flag the file does not claim. The flag is read before any clear
    /// (review C5): the helper's, set, with the lid closed, means sleep.
    func start(now: Date) -> KeepAwakeReply {
        let flagWasSet = machine.readSleepDisabled() == .set
        let lidSleeps = machine.lid().sleepsWhenClosed
        let before = engine.state
        // A sleep the last daemon still owed (W1): the forced apply below pays it or drops it.
        sleepOwed = stateFile.loadSleepOwed()
        let output = engine.start(
            persisted: stateFile.load(),
            ownsFlag: stateFile.loadOwnsFlag() || sleepOwed,
            flagWasSet: flagWasSet,
            now: now,
            lidClosed: lidSleeps
        )
        if output.sleepDisabled == nil {
            flagIsAnothers = true
            NSLog("[keepawake] start: the flag is set and not the helper's; left as it is")
        }
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

    /// Cancel. With nothing armed and no flag of its own held, there is nothing to clear: the
    /// flag, perhaps another tool's, is left as it is (rule 2, tester F1).
    func disarm(now: Date) -> KeepAwakeReply {
        let lidSleeps = machine.lid().sleepsWhenClosed
        let before = engine.state
        var output = engine.disarm(now: now, lidClosed: lidSleeps)
        if !before.isArmed, lastApplied == false {
            output.sleepDisabled = nil
        }
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

    /// The helper set the flag, or may have, and has not seen it read clear since (rule 11).
    private var ownsFlag: Bool {
        lastApplied != false
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
        let owedBefore = sleepOwed
        let ownedBefore = ownsFlag
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
        } else if engine.state != before || owedBefore || ownedBefore {
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
        let owedBefore = sleepOwed
        let ownedBefore = ownsFlag
        let appliedBefore = lastApplied
        // Rule 12.
        let armedEarly = engine.state.isArmed && !stateBefore.isArmed
        if armedEarly {
            save(engine.state)
        }
        // Rules 2 and 3.
        var firstFailure: KeepAwakeFailure?
        if let value = output.sleepDisabled {
            if force || value != lastApplied {
                firstFailure = setFlag(value)
            }
        } else {
            // Rule 2: a flag the helper did not set; it holds nothing.
            lastApplied = false
        }
        // Rule 4.
        if let failure = firstFailure, let rollback {
            engine = rollback
            if appliedBefore != true, case .commandFailed = failure {
                if flagIsAnothers { lastApplied = false }
            } else {
                _ = setFlag(engine.state.isArmed)
            }
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
        if alwaysSave || armedEarly || engine.state != stateBefore || sleepOwed != owedBefore || ownsFlag != ownedBefore {
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
        flagIsAnothers = false
        return nil
    }

    /// Writes the state with the sleep owed now, and whether the helper owns the flag, beside it.
    private func save(_ state: KeepAwakeState, failure: KeepAwakeFailure? = nil) {
        do {
            try stateFile.save(state, failure: failure, sleepOwed: sleepOwed, ownsFlag: ownsFlag)
        } catch {
            NSLog("[keepawake] state file: %@", String(describing: error))
        }
    }
}
