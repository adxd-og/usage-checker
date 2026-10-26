import Foundation

/// The sleep flag as `pmset -g` reports it (plan D9).
enum KeepAwakeFlagReading: String, Codable, Equatable, Sendable {
    /// `SleepDisabled 1`: the Mac does not sleep.
    case set
    /// `SleepDisabled 0`: cleared explicitly.
    case cleared
    /// No `SleepDisabled` line: the flag was never set on this Mac.
    case neverSet
    /// A line whose value is not 0 or 1, or pmset did not answer.
    case unreadable

    /// The Mac sleeps as usual: cleared, or never set.
    var isClear: Bool { self == .cleared || self == .neverSet }
}

/// What the daemon and the app read off the machine, parsed apart from the calls that read
/// it so the parsing is tested.
enum KeepAwakeReadings {
    /// The first line whose first token is exactly `SleepDisabled` decides; its value is
    /// checked, not the line's presence (spec 2026-10-26, Facts).
    static func flag(fromPmset output: String) -> KeepAwakeFlagReading {
        for line in output.split(whereSeparator: \.isNewline) {
            let tokens = line.split(whereSeparator: \.isWhitespace)
            guard tokens.first == "SleepDisabled" else { continue }
            switch tokens.dropFirst().first {
            case "1": return .set
            case "0": return .cleared
            default: return .unreadable
            }
        }
        return .neverSet
    }
}
