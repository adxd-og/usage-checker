import Foundation

/// What a click on the pet, or VoiceOver's action on the habitat, does (§ 3.5, § 3.8, D11).
enum PetAction: Equatable, Sendable {
    /// Jump to the one waiting session (`AgentSession.id`).
    case jump(sessionID: String)
    /// Several wait: the Needs-you list.
    case needsYouList
    /// Claude's way out: Sign in, the install link, or Settings › Advanced.
    case claudeRecovery(ClaudeRecovery)
    /// That provider's page.
    case providerPage(serviceID: String)
    /// The keep-awake card.
    case keepAwakeCard
    /// Settings › Providers.
    case providersSettings
    /// A pat: a heart for 1.2 s (`PetRuntime.pat`).
    case pat
    /// Nothing to do: a sign-in that cannot be read.
    case nothing
}

/// One mood as the habitat shows it (§ 3.5 "Mood rule"). It has no place: every mood stands on
/// the habitat's floor (owner 2026-10-30, P5c plan; `PetHabitatRules.floorY`).
struct PetMoodPresentation: Equatable, Sendable {
    /// The pose: its animation plays while no bit does, its still shows while the gate is off.
    let pose: PetPose
    /// The idle loop runs, with its bits and the stretch: the calm rows (`runsIdleLoop`).
    let loops: Bool
    /// The line under the habitat; nil when idle.
    let line: String?
    /// Never empty (§ 3.5).
    let accessibilityLabel: String
    let action: PetAction
}

extension PetMoodRules {
    /// The calm rows, where the idle loop runs (walk, blink, nap, the stretch): Idle and, by the
    /// owner's ruling of 2026-10-30, Agent working (the spec's table gives the loop to Idle
    /// alone). The alert rows hold still; keep awake at night and nothing on sleep. No default:
    /// a new mood has to choose.
    static func runsIdleLoop(_ mood: PetMood) -> Bool {
        switch mood {
        case .working, .idle: true
        case .needsYou, .claudeSignedOut, .alert, .keepAwakeNight, .nothingOn: false
        }
    }

    /// The table's columns for `mood`: pose, mood line, accessibility label, click. The table's
    /// Position column is the floor for every row (owner 2026-10-30, P5c plan): the mood shows
    /// through pose and line. `petName` is the manifest's name, `mode` the user's percent mode.
    static func presentation(
        of mood: PetMood,
        petName: String,
        mode: PercentDisplay.Mode,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> PetMoodPresentation {
        let pose: PetPose
        let action: PetAction
        switch mood {
        case .needsYou(let waiting):
            pose = .look
            action = waiting.count == 1 ? .jump(sessionID: waiting[0].id) : .needsYouList
        case .claudeSignedOut(let recovery):
            pose = .look
            action = recovery == .noAction ? .nothing : .claudeRecovery(recovery)
        case .alert(let alert):
            pose = .look
            action = .providerPage(serviceID: alert.serviceID)
        case .keepAwakeNight:
            pose = .sleep
            action = .keepAwakeCard
        case .working:
            pose = .idle
            action = .pat
        case .nothingOn:
            pose = .sleep
            action = .providersSettings
        case .idle:
            pose = .idle
            action = .pat
        }
        return PetMoodPresentation(
            pose: pose,
            loops: runsIdleLoop(mood),
            line: PetMoodCopy.line(for: mood, mode: mode, now: now, calendar: calendar, locale: locale),
            accessibilityLabel: PetMoodCopy.accessibilityLabel(
                for: mood, petName: petName, mode: mode, now: now, calendar: calendar, locale: locale
            ),
            action: action
        )
    }
}
