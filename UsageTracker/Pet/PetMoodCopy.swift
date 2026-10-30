import Foundation

/// Every word the pet says (notch-island spec 2026-10-29 § 3.5 "Mood rule", § 3.8): the mood
/// line under the habitat and what VoiceOver reads for the habitat, one per mood, the label
/// never empty. Percentages go through `PercentDisplay`, so "used" or "left" follows the
/// user's setting; Claude's sign-in words are `ClaudeSignInCopy`'s, keep awake's clock is the
/// card's.
enum PetMoodCopy {
    // MARK: - The mood line

    static let nothingOnLine = "Nothing on"

    /// The line under the habitat; nil while the pet is idle.
    static func line(
        for mood: PetMood,
        mode: PercentDisplay.Mode,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String? {
        switch mood {
        case .needsYou(let waiting):
            return waiting.count == 1 ? waitingLine(project: waiting[0].projectName) : "\(waiting.count) waiting"
        case .claudeSignedOut(let recovery):
            return ClaudeSignInCopy.petLine(recovery)
        case .alert(let alert):
            return "\(alert.serviceName) \(windowWord(alert.bucket)) \(PercentDisplay.percentPhrase(alert.usedPercent, mode: mode))"
        case .keepAwakeNight(let deadline):
            return "Awake until \(KeepAwakeCopy.clock(deadline, now: now, calendar: calendar, locale: locale))"
        case .working(let count):
            return "\(count) working"
        case .nothingOn:
            return nothingOnLine
        case .idle:
            return nil
        }
    }

    /// "Usage tracker is waiting"; a session with no project name is "An agent".
    static func waitingLine(project: String) -> String {
        let name = project.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(name.isEmpty ? "An agent" : name) is waiting"
    }

    /// A window as the line names it after the provider: the tile's short label, the plain
    /// window words of session and weekly windows in lower case ("week", "session", "weekly",
    /// "credits"), a model's name as it is ("Opus", or an Antigravity model's own name).
    static func windowWord(_ bucket: UsageBucket) -> String {
        let label = OMProviderTile.shortLabel(for: bucket)
        guard bucket.kind == .session || bucket.kind == .weekly else { return label }
        return label.prefix(1).lowercased() + String(label.dropFirst())
    }

    // MARK: - VoiceOver

    /// The habitat's accessibility label: the pet, what is going on, and what a double-tap
    /// does. `petName` is the manifest's name ("Cat").
    static func accessibilityLabel(
        for mood: PetMood,
        petName: String,
        mode: PercentDisplay.Mode,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        switch mood {
        case .needsYou(let waiting):
            return waiting.count == 1
                ? "\(petName): \(waitingLine(project: waiting[0].projectName)), double-tap to go to it"
                : "\(petName): \(waiting.count) agents are waiting, double-tap to see them"
        case .claudeSignedOut(let recovery):
            let line = ClaudeSignInCopy.petLine(recovery)
            switch recovery {
            case .signIn: return "\(petName): \(line), double-tap to sign in"
            case .install: return "\(petName): \(line), double-tap to install it"
            case .keychainAccess: return "\(petName): \(line), double-tap to open \(SettingsTab.advanced.rawValue) settings"
            case .noAction: return "\(petName): \(line)"
            }
        case .alert(let alert):
            let reading = PercentDisplay.spoken(alert.usedPercent, mode: mode)
            return "\(petName): \(alert.serviceName) \(windowWord(alert.bucket)) \(reading), double-tap to open \(alert.serviceName)"
        case .keepAwakeNight(let deadline):
            let clock = KeepAwakeCopy.clock(deadline, now: now, calendar: calendar, locale: locale)
            return "\(petName) is asleep, the Mac stays awake until \(clock), double-tap to open keep awake"
        case .working(let count):
            return "\(petName): \(count) working, double-tap to see the agents"
        case .nothingOn:
            return "\(petName) is asleep, nothing is on, double-tap to open \(SettingsTab.providers.rawValue) settings"
        case .idle:
            return "\(petName), double-tap to pat"
        }
    }
}
