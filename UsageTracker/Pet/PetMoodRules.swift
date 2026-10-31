import Foundation

/// The pet's mood (notch-island spec 2026-10-29 § 3.5 "Mood rule"): the first row of the
/// priority table that holds. The pose, words and click of each are
/// `PetMoodRules.presentation(of:…)`'s; every mood stands on the habitat's floor.
enum PetMood: Equatable, Sendable {
    /// 1. Agent sessions wait for the user: every waiting one, the most recently active first.
    case needsYou([AgentSession])
    /// 2. Claude is signed out: the way out its reason calls for (`ClaudeSignInCopy.recovery`).
    case claudeSignedOut(ClaudeRecovery)
    /// 3. A live window at 90 % or more (`PetAlertSelector`).
    case alert(PetAlert)
    /// 4. Keep awake is on and it is night, 22:00 to 06:00 on the local clock.
    case keepAwakeNight(deadline: Date)
    /// 5. Agent sessions are working: how many.
    case working(count: Int)
    /// 6. Every provider is switched off.
    case nothingOn
    /// 7. Nothing to say: the idle loop.
    case idle
}

/// What the mood is decided from: the app's state as it is published.
struct PetMoodInput: Equatable, Sendable {
    /// `AgentSessionStore.sessions`.
    var sessions: [AgentSession]
    /// `AppState.snapshot.services`, in display order.
    var services: [ServiceSnapshot]
    /// `AppState.switchedOnIDs`: the providers switched on this moment; nil before the first poll.
    var enabledIDs: Set<String>?
    /// `ClaudeSignInModel.binaryFound`: Sign in, or the install link.
    var claudeBinaryFound: Bool
    /// `KeepAwakeModel.state`.
    var keepAwake: KeepAwakeState
}

/// The pet's priority table (notch-island spec 2026-10-29 § 3.5 "Mood rule", § 3.9
/// `PetMoodRules`). Pure.
enum PetMoodRules {
    /// Keep awake puts the pet to sleep on the floor from 22:00 …
    static let nightStartHour = 22
    /// … to 06:00, on the clock of the calendar's time zone.
    static let nightEndHour = 6

    /// The first row that holds, at `now` on `calendar`'s clock.
    static func mood(_ input: PetMoodInput, now: Date, calendar: Calendar) -> PetMood {
        let waiting = input.sessions
            .filter { $0.state == .needsYou }
            .sorted { $0.lastEventAt > $1.lastEventAt }
        if !waiting.isEmpty { return .needsYou(waiting) }

        let claude = input.services.first {
            $0.id == ClaudeOAuthProvider.serviceID && input.enabledIDs?.contains($0.id) != false
        }
        if let recovery = ClaudeSignInCopy.recovery(for: claude, binaryFound: input.claudeBinaryFound) {
            return .claudeSignedOut(recovery)
        }

        if let alert = PetAlertSelector.alert(in: input.services, enabledIDs: input.enabledIDs) {
            return .alert(alert)
        }

        if let deadline = KeepAwakeRules.effectiveState(input.keepAwake, now: now).deadline,
           isNight(now, calendar: calendar) {
            return .keepAwakeNight(deadline: deadline)
        }

        let working = input.sessions.filter { $0.state == .working }.count
        if working > 0 { return .working(count: working) }

        if AppState.isNothingOn(polledIDs: input.enabledIDs) { return .nothingOn }
        return .idle
    }

    /// From 22:00 up to 06:00 on `calendar`'s clock.
    static func isNight(_ date: Date, calendar: Calendar) -> Bool {
        let hour = calendar.component(.hour, from: date)
        return hour >= nightStartHour || hour < nightEndHour
    }
}
