import Foundation
import Combine
import ServiceManagement

/// The app's view of keep awake (spec 2026-10-26, § Behaviour › Visible): what the popover
/// block and the menu bar marker read (Package 2), and what Settings shows.
///
/// `state` is the helper's word; the model only adds a local countdown, so a mode whose
/// deadline passed reads as ended even when the helper does not answer. While armed, the poll
/// loop asks the helper on every tick (`pollIfNeeded`), so a mode the helper ended (floor,
/// restart, stop) drops off within a poll interval. A reply lost to the transport (timeout,
/// broken connection, unreadable) leaves the state unknown, and the poll keeps asking until
/// the helper's state lands or no helper is registered (review C7). A state reply that a
/// command overtook is dropped (`commandGeneration`).
@MainActor
final class KeepAwakeModel: ObservableObject {
    static let shared = live(client: KeepAwakeClient(dependencies: .live), settings: .shared)

    /// The model as the app runs it, and the only way `shared` is built: both switches are read
    /// from `settings` each time they are used, Apply and Reset keep awake write to it, and the
    /// card's level is `processInfo`'s, through the reading the helper takes too
    /// (`KeepAwakeReadings.liveThermal`).
    static func live(
        client: KeepAwakeClient,
        settings: SettingsStore,
        processInfo: ProcessInfo = .processInfo
    ) -> KeepAwakeModel {
        KeepAwakeModel(
            client: client,
            floorEnabled: { settings.keepAwakeFloorEnabled },
            rememberDuration: { settings.keepAwakeDurationMinutes = $0 },
            resetSettings: { settings.resetKeepAwake() },
            thermalGuardEnabled: { settings.keepAwakeThermalGuardEnabled },
            thermalLevel: { KeepAwakeReadings.liveThermal(processInfo) }
        )
    }

    @Published private(set) var registration: KeepAwakeRegistration = .notRegistered
    @Published private(set) var state: KeepAwakeState = .idle
    /// What the last call could not do.
    @Published private(set) var failure: KeepAwakeFailure?
    /// What the last reset could not do.
    @Published private(set) var resetFailure: KeepAwakeFailure?
    /// The sleep flag as pmset last read it, for Settings › Advanced.
    @Published private(set) var flag: KeepAwakeFlagReading?
    /// A reset that could not clear the flag or remove the helper (review C1), or a helper
    /// that stopped with the flag still set (P1b).
    @Published private(set) var resetIncomplete = false
    @Published private(set) var isWorking = false
    /// This Mac's thermal level as the app reads it (spec 2026-11-19, § What the user sees): the
    /// card's "running hot" line. The helper decides the guard on its own reading; this one is
    /// read when the card appears and when macOS says the level changed (`readThermal`).
    @Published private(set) var thermal: KeepAwakeThermalLevel = .nominal
    /// A reply was lost: the helper's state is unknown until it answers (review C7).
    private(set) var needsReconcile = false
    /// The thermal guard as the helper last said it holds it (spec 2026-11-19, § Daemon): taken
    /// from every reply that lands, so nil until one does, and nil again after a reply from a
    /// helper that predates the guard, which is never asked about it. A call that brought no
    /// reply (lost, timed out, a helper that is not ready) leaves it as it was. Two readers: the
    /// switch's path, to know whether the helper has the selector, and the card, which says
    /// "The heat guard starts after this mode ends." while it is nil and a mode is armed (hence
    /// published). The reconciliation decides from the reply in hand, never from this.
    @Published private(set) var helperThermalGuard: Bool?
    /// A `setThermalGuard` is out. At most one ever is (`sendThermalGuard`).
    private var thermalGuardSendOut = false
    /// Bumped by every command (Apply, Cancel, the floor switch, the thermal guard's switch,
    /// Reset) before its call and again when its outcome returns. A state request remembers
    /// the value it started with and is dropped when it moved: each XPC call has its own
    /// connection, so an older state reply can land after a newer command's (plan review P1b,
    /// plan D13).
    private var commandGeneration = 0

    private let client: KeepAwakeClient
    private let floorEnabled: @MainActor () -> Bool
    private let rememberDuration: @MainActor (Int) -> Void
    private let resetSettings: @MainActor () -> Void
    private let thermalGuardEnabled: @MainActor () -> Bool
    private let thermalLevel: @MainActor () -> KeepAwakeThermalLevel
    private var countdown: Task<Void, Never>?

    init(
        client: KeepAwakeClient,
        floorEnabled: @escaping @MainActor () -> Bool,
        rememberDuration: @escaping @MainActor (Int) -> Void,
        resetSettings: @escaping @MainActor () -> Void,
        thermalGuardEnabled: @escaping @MainActor () -> Bool = { true },
        thermalLevel: @escaping @MainActor () -> KeepAwakeThermalLevel = { .nominal }
    ) {
        self.client = client
        self.floorEnabled = floorEnabled
        self.rememberDuration = rememberDuration
        self.resetSettings = resetSettings
        self.thermalGuardEnabled = thermalGuardEnabled
        self.thermalLevel = thermalLevel
    }

    /// Failures after which the request may or may not have reached the helper.
    nonisolated static func leavesStateUnknown(_ failure: KeepAwakeFailure?) -> Bool {
        switch failure {
        case .helperTimedOut, .helperUnavailable, .unreadableReply: return true
        default: return false
        }
    }

    /// What the helper says: on popover open and once at launch.
    func refresh(now: Date = Date()) async {
        await ask(now: now)
    }

    /// Apply: validates and remembers the duration (approved or not), then arms the helper,
    /// registering it first when needed. A floor switch that moved while the call was out
    /// found no armed mode (`floorChanged`), so an armed helper is sent the setting as it is
    /// now when it differs from the one Apply sent (whole-branch review W3). The helper's thermal
    /// guard needs no step here: every `arm` turns it on, and the arm's reply, like every reply,
    /// is reconciled with the setting (`reconcileThermalGuard`, step 6 of `apply`).
    func arm(days: Int, hours: Int, minutes: Int, now: Date = Date()) async {
        guard let seconds = KeepAwakeRules.duration(days: days, hours: hours, minutes: minutes) else {
            failure = .invalidDuration
            return
        }
        rememberDuration(Int(seconds / 60))
        isWorking = true
        defer { isWorking = false }
        let sentFloor = floorEnabled()
        commandGeneration &+= 1
        let outcome = await client.arm(seconds: seconds, floorEnabled: sentFloor)
        commandGeneration &+= 1
        await apply(outcome, now: now)
        let floor = floorEnabled()
        guard outcome.state?.isArmed == true, floor != sentFloor else { return }
        commandGeneration &+= 1
        let corrected = await client.setFloor(enabled: floor)
        commandGeneration &+= 1
        await apply(corrected, now: now)
    }

    /// Cancel.
    func cancel(now: Date = Date()) async {
        isWorking = true
        defer { isWorking = false }
        commandGeneration &+= 1
        let outcome = await client.disarm()
        commandGeneration &+= 1
        await apply(outcome, now: now)
    }

    /// The floor switch moved: an armed helper hears it at once, and so does one whose state
    /// is unknown after a lost reply (it may have armed); otherwise it stays a preference read
    /// at the next Apply.
    func floorChanged(_ enabled: Bool, now: Date = Date()) async {
        guard state.isArmed || needsReconcile else { return }
        isWorking = true
        defer { isWorking = false }
        commandGeneration &+= 1
        let outcome = await client.setFloor(enabled: enabled)
        commandGeneration &+= 1
        await apply(outcome, now: now)
    }

    /// The thermal guard's switch moved (spec 2026-11-19, § Settings): an armed helper that
    /// knows the guard hears it at once, and so does one whose state is unknown after a lost
    /// reply; otherwise the next reply that disagrees brings it (`reconcileThermalGuard`). A
    /// helper that predates the guard (`helperThermalGuard` nil) is asked nothing new.
    ///
    /// The caller passes no value: what goes out is the setting as it reads when the call does
    /// (`sendThermalGuard`), so a switch that has moved again since is never sent stale. While a
    /// `setThermalGuard` is out this adds none: that call sends the setting on when it returns.
    func thermalGuardChanged(now: Date = Date()) async {
        guard helperTakesThermalGuard, !thermalGuardSendOut else { return }
        isWorking = true
        defer { isWorking = false }
        await sendThermalGuard(now: now)
    }

    /// Settings › Advanced › Reset all settings put the floor and heat switches back to their
    /// defaults: an armed helper hears both at once, the floor first, as it would from the
    /// switches themselves (keep-awake spec 2026-10-26, floor switch while armed; thermal guard
    /// spec 2026-11-19, § Settings). The guard's call sends the setting as it reads then, which
    /// the reset put back to its default. A floor answer whose guard differs from the setting
    /// already brings the guard (`reconcileThermalGuard`), and the guard's call then sends it
    /// again; it alone sends it when the floor's answer is lost.
    func allSettingsWereReset(now: Date = Date()) async {
        await floorChanged(SettingsStore.Defaults.keepAwakeFloorEnabled, now: now)
        await thermalGuardChanged(now: now)
    }

    /// The poll loop's call: asks the helper only while armed or unreconciled.
    func pollIfNeeded(now: Date = Date()) async {
        guard state.isArmed || needsReconcile else { return }
        await ask(now: now)
    }

    /// Settings › Advanced › Reset keep awake (spec § UI, plan D13). The three settings (the
    /// battery floor, the heat guard, the last duration) go back either way.
    func reset(now: Date = Date()) async {
        isWorking = true
        defer { isWorking = false }
        commandGeneration &+= 1
        let outcome = await client.reset()
        commandGeneration &+= 1
        resetSettings()
        registration = outcome.registration
        resetIncomplete = !outcome.isComplete
        state = outcome.flag.isClear ? .idle : KeepAwakeRules.effectiveState(state, now: now)
        failure = nil
        flag = outcome.flag
        resetFailure = outcome.failure
        if outcome.isComplete {
            needsReconcile = false
            countdown?.cancel()
            countdown = nil
        } else {
            scheduleCountdown(now: now)
        }
    }

    /// The flag as pmset reads it now, for the Advanced row's caption.
    func readFlag() async {
        flag = await client.readFlag()
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Reads the thermal level now, for the card's "running hot" line.
    func readThermal() {
        thermal = thermalLevel()
    }

    // MARK: - Private

    private func ask(now: Date) async {
        let generation = commandGeneration
        let outcome = await client.state()
        // A command answered while this request was out: its outcome is the newer word.
        guard generation == commandGeneration else { return }
        await apply(outcome, now: now, generation: generation)
    }

    /// The switch reaches the helper: a mode is armed, or may be (a lost reply), and the
    /// helper's last reply carried the guard, so it has the selector.
    private var helperTakesThermalGuard: Bool {
        (state.isArmed || needsReconcile) && helperThermalGuard != nil
    }

    /// Spec 2026-11-19, § Plan decisions accepted by the session, item 6: after every reply
    /// that landed, an armed helper whose reply says its guard differs from the setting is sent
    /// the setting. Every `arm` turns the helper's guard on, so an "off" setting goes out after
    /// Apply; a correction lost to the transport, a switch-on lost while armed, and an Apply
    /// whose own reply was lost are all set right by the next reply that disagrees, the poll's
    /// included. One send per disagreeing reply; none while a send is out (its own reply,
    /// applied inside it, sends nothing, so a helper that keeps answering otherwise is not
    /// answered in a loop); none to a helper whose reply has no `thermalGuard` (item 5).
    private func reconcileThermalGuard(_ outcome: KeepAwakeOutcome, now: Date) async {
        guard !thermalGuardSendOut,
              outcome.state?.isArmed == true,
              let held = outcome.thermalGuard, held != thermalGuardEnabled()
        else { return }
        await sendThermalGuard(now: now)
    }

    /// The one path a `setThermalGuard` takes, from the switch and from the reconciliation,
    /// both of which check that none is out. One call at a time: each XPC call has its own
    /// connection, so two out together could reach the helper in either order and leave it
    /// with the older value. The value is the setting as it reads when the call goes out. A
    /// switch that moved while the call was out is sent when it returns, as long as the helper
    /// still takes it; nothing else is repeated here, so a call that is lost, or a helper that
    /// answers otherwise, gets no more until another reply disagrees.
    ///
    /// A command under `commandGeneration`, as the floor's: a state reply it overtook is
    /// dropped. Its own reply is dropped the same way when another command (Apply, Cancel, the
    /// floor switch, Reset) started or returned while it was out: a correction goes out with no
    /// spinner holding the card's buttons, so its reply can be older than that command's and
    /// would bring back the mode as it was before.
    private func sendThermalGuard(now: Date) async {
        thermalGuardSendOut = true
        defer { thermalGuardSendOut = false }
        var sent: Bool
        repeat {
            sent = thermalGuardEnabled()
            commandGeneration &+= 1
            let generation = commandGeneration
            let outcome = await client.setThermalGuard(enabled: sent)
            let overtaken = generation != commandGeneration
            commandGeneration &+= 1
            if !overtaken {
                await apply(outcome, now: now)
            }
        } while thermalGuardEnabled() != sent && helperTakesThermalGuard
    }

    private func apply(_ outcome: KeepAwakeOutcome, now: Date, generation: Int? = nil) async {
        // 1. Reconcile bookkeeping (C7): clears only when the helper's state lands or there is
        // no helper to ask.
        if Self.leavesStateUnknown(outcome.failure) {
            needsReconcile = true
        } else if outcome.state != nil || outcome.registration != .ready {
            needsReconcile = false
        }
        // 2.
        registration = outcome.registration
        failure = outcome.failure
        // What the helper holds of the thermal guard, from every reply that landed: nil from a
        // helper that predates the guard.
        if outcome.state != nil {
            helperThermalGuard = outcome.thermalGuard
        }
        if outcome.state == nil && outcome.registration != .ready && state.isArmed {
            // 3. A helper that is not registered or not approved is not running: launchd
            // stopped it. It cleared the flag on its way out, unless it could not (P1b).
            state = .ended(at: now, reason: .stopped)
            let reading = await client.readFlag()
            // A command (a Reset) finished during this read: its outcome is the newer word.
            guard generation == nil || generation == commandGeneration else { return }
            flag = reading
            if reading == .set {
                failure = .flagStillSet
                resetIncomplete = true
            }
        } else {
            // 4.
            state = outcome.state ?? KeepAwakeRules.effectiveState(state, now: now)
            // A helper that armed holds the flag again: an earlier reset's "not back to normal
            // yet" no longer applies.
            if outcome.state?.isArmed == true {
                resetIncomplete = false
            }
        }
        // 5.
        scheduleCountdown(now: now)
        // 6. The helper's thermal guard against the setting, from this reply.
        await reconcileThermalGuard(outcome, now: now)
    }

    /// One poll a second after the deadline, so the marker leaves on time even between ticks.
    private func scheduleCountdown(now: Date) {
        countdown?.cancel()
        countdown = nil
        guard case .armed(let deadline, _) = state else { return }
        let seconds = UInt64(max(0, deadline.timeIntervalSince(now)) + 1)
        countdown = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.pollIfNeeded()
        }
    }
}
