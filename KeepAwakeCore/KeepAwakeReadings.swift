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

/// The lid as IOPMrootDomain reports it (plan D5): two keys of the same registry entry. A
/// missing key, or one that is not a boolean, reads as No.
struct KeepAwakeLid: Equatable, Sendable {
    /// `AppleClamshellState`.
    var closed: Bool
    /// `AppleClamshellCausesSleep`: No in clamshell mode on an external display.
    var causesSleep: Bool

    /// What the service passes as `lidClosed:`: only a closed lid that causes sleep counts, so
    /// a Mac in clamshell mode on an external display is never put to sleep by us.
    var sleepsWhenClosed: Bool { closed && causesSleep }
}

extension KeepAwakeReadings {
    /// The internal battery from `IOPSGetPowerSourceDescription`'s dictionaries (keys as
    /// IOPSKeys.h spells them). A Mac without a present internal battery has no reading, so
    /// its floor never fires. Capacity is scaled to a percent, rounding down.
    static func power(fromDescriptions descriptions: [[String: Any]]) -> KeepAwakePower? {
        guard let battery = descriptions.first(where: { description in
            (description["Type"] as? String) == "InternalBattery" && (description["Is Present"] as? Bool ?? true)
        }), let current = battery["Current Capacity"] as? Int
        else { return nil }
        let maximum = battery["Max Capacity"] as? Int ?? 0
        let percent = maximum > 0 ? current * 100 / maximum : current
        return KeepAwakePower(onBattery: (battery["Power Source State"] as? String) == "Battery Power", percent: percent)
    }

    /// Both clamshell keys from IOPMrootDomain's properties (CF booleans bridge as NSNumber).
    static func lid(fromRootDomain properties: [String: Any]) -> KeepAwakeLid {
        KeepAwakeLid(
            closed: (properties["AppleClamshellState"] as? Bool) == true,
            causesSleep: (properties["AppleClamshellCausesSleep"] as? Bool) == true
        )
    }
}
