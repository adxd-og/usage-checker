import Foundation

/// Where in the habitat the pet stands for a mood (notch-island spec 2026-10-29 § 3.5: height
/// is the pointer). The habitat turns each into a height.
enum PetPlace: Equatable, Sendable {
    /// Level with the agents card.
    case agentsCard
    /// Level with a provider's tile.
    case tile(serviceID: String)
    /// On the sill.
    case sill
    /// Half-way up.
    case middle
    /// On the floor.
    case floor
    /// On the floor, wherever the idle loop has walked it (`PetRuntime.xBeads`).
    case anywhere
}

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
    /// The agents card.
    case agentsCard
    /// Settings › Providers.
    case providersSettings
    /// A pat: a heart for 1.2 s (`PetRuntime.pat`).
    case pat
    /// Nothing to do: a sign-in that cannot be read.
    case nothing
}

/// One mood as the habitat shows it (§ 3.5 "Mood rule").
struct PetMoodPresentation: Equatable, Sendable {
    /// The pose: its animation plays while no bit does, its still shows while the gate is off.
    let pose: PetPose
    /// The idle loop runs, with its bits and the stretch: the calm rows (`runsIdleLoop`).
    let loops: Bool
    let place: PetPlace
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

    /// The table's columns for `mood`: pose, position, mood line, accessibility label, click.
    /// `petName` is the manifest's name, `mode` the user's percent mode.
    static func presentation(
        of mood: PetMood,
        petName: String,
        mode: PercentDisplay.Mode,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> PetMoodPresentation {
        let pose: PetPose
        let place: PetPlace
        let action: PetAction
        switch mood {
        case .needsYou(let waiting):
            pose = .look
            place = .agentsCard
            action = waiting.count == 1 ? .jump(sessionID: waiting[0].id) : .needsYouList
        case .claudeSignedOut(let recovery):
            pose = .look
            place = .tile(serviceID: ClaudeOAuthProvider.serviceID)
            action = recovery == .noAction ? .nothing : .claudeRecovery(recovery)
        case .alert(let alert):
            pose = .look
            place = .tile(serviceID: alert.serviceID)
            action = .providerPage(serviceID: alert.serviceID)
        case .keepAwakeNight:
            pose = .sleep
            place = .sill
            action = .keepAwakeCard
        case .working:
            pose = .idle
            place = .middle
            action = .agentsCard
        case .nothingOn:
            pose = .sleep
            place = .floor
            action = .providersSettings
        case .idle:
            pose = .idle
            place = .anywhere
            action = .pat
        }
        return PetMoodPresentation(
            pose: pose,
            loops: runsIdleLoop(mood),
            place: place,
            line: PetMoodCopy.line(for: mood, mode: mode, now: now, calendar: calendar, locale: locale),
            accessibilityLabel: PetMoodCopy.accessibilityLabel(
                for: mood, petName: petName, mode: mode, now: now, calendar: calendar, locale: locale
            ),
            action: action
        )
    }
}
