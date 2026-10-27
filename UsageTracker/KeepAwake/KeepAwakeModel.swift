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
    static let shared = KeepAwakeModel(
        client: KeepAwakeClient(dependencies: .live),
        floorEnabled: { SettingsStore.shared.keepAwakeFloorEnabled },
        rememberDuration: { SettingsStore.shared.keepAwakeDurationMinutes = $0 },
        resetSettings: { SettingsStore.shared.resetKeepAwake() }
    )

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
    /// A reply was lost: the helper's state is unknown until it answers (review C7).
    private(set) var needsReconcile = false
    /// Bumped by every command (Apply, Cancel, the floor switch, Reset) before its call and
    /// again when its outcome returns. A state request remembers the value it started with
    /// and is dropped when it moved: each XPC call has its own connection, so an older
    /// state reply can land after a newer command's (plan review P1b, plan D13).
    private var commandGeneration = 0

    private let client: KeepAwakeClient
    private let floorEnabled: @MainActor () -> Bool
    private let rememberDuration: @MainActor (Int) -> Void
    private let resetSettings: @MainActor () -> Void
    private var countdown: Task<Void, Never>?

    init(
        client: KeepAwakeClient,
        floorEnabled: @escaping @MainActor () -> Bool,
        rememberDuration: @escaping @MainActor (Int) -> Void,
        resetSettings: @escaping @MainActor () -> Void
    ) {
        self.client = client
        self.floorEnabled = floorEnabled
        self.rememberDuration = rememberDuration
        self.resetSettings = resetSettings
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
    /// now when it differs from the one Apply sent (whole-branch review W3).
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

    /// The poll loop's call: asks the helper only while armed or unreconciled.
    func pollIfNeeded(now: Date = Date()) async {
        guard state.isArmed || needsReconcile else { return }
        await ask(now: now)
    }

    /// Settings › Advanced › Reset keep awake (spec § UI, plan D13). The two settings go back
    /// either way.
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

    // MARK: - Private

    private func ask(now: Date) async {
        let generation = commandGeneration
        let outcome = await client.state()
        // A command answered while this request was out: its outcome is the newer word.
        guard generation == commandGeneration else { return }
        await apply(outcome, now: now, generation: generation)
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
