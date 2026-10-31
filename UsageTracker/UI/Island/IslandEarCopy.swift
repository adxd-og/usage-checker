import CoreGraphics
import Foundation

/// The ears' words (notch-island spec 2026-10-29 § 3.5, § 3.6, § 3.8): the number as the right ear
/// sets it, and what VoiceOver hears for each ear.
enum IslandEarCopy {
    /// Two lines at the text floor need this much height: 14 pt a line, measured.
    static let twoLineHeight: CGFloat = 28

    /// "92%" counting up. Counting down, "8%" over "left", since "8% left" is 38 pt wide at the text
    /// floor (plan OWNER 3); an ear too short for two lines keeps the number.
    static func numberLines(_ used: Double, mode: PercentDisplay.Mode, earHeight: CGFloat) -> [String] {
        let number = PercentDisplay.percentText(used, mode: mode)
        guard mode == .remaining, earHeight >= twoLineHeight else { return [number] }
        return [number, PercentDisplay.suffix(mode: mode)]
    }

    static func waiting(_ waiting: [AgentSession]) -> String {
        waiting.count == 1
            ? "\(PetMoodCopy.waitingLine(project: waiting[0].projectName)), go to it"
            : "\(waiting.count) agents are waiting, open Omelette"
    }

    static func signedOut(_ recovery: ClaudeRecovery) -> String {
        "\(ClaudeSignInCopy.petLine(recovery)), open Claude"
    }

    static func alert(_ alert: PetAlert, mode: PercentDisplay.Mode) -> String {
        let reading = PercentDisplay.spoken(alert.usedPercent, mode: mode)
        return "\(alert.serviceName) \(PetMoodCopy.windowWord(alert.bucket)) \(reading), open \(alert.serviceName)"
    }

    static func moon(deadline: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        "Keep awake until \(KeepAwakeCopy.clock(deadline, now: now, calendar: calendar, locale: locale)), open Omelette"
    }
}
