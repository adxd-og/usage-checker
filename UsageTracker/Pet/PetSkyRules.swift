import CoreGraphics
import Foundation

/// The habitat's sky at one moment (notch-island spec 2026-10-29 § 3.3).
enum PetSky: Equatable, Sendable {
    case day
    case dusk
    case night
}

/// The habitat's sky (notch-island spec 2026-10-29 § 3.3: "a sky following the local clock";
/// habitat advisory § 4: day, dusk, night, the moon from 22:00 to 06:00): one small mark at the
/// column's top, read from the clock, never ticked while the island is closed. No fill, no edge
/// (owner 2026-10-30). Pure.
enum PetSkyRules {
    /// Dusk from 18:00 until the night begins (`PetMoodRules.nightStartHour`, 22:00).
    static let duskStartHour = 18
    /// The mark's size: the text floor's.
    static let symbolSize: CGFloat = 11

    /// The sky at `date` on `calendar`'s clock: night as keep awake's (22:00–06:00), dusk from
    /// 18:00, day otherwise.
    static func sky(at date: Date, calendar: Calendar) -> PetSky {
        if PetMoodRules.isNight(date, calendar: calendar) { return .night }
        return calendar.component(.hour, from: date) >= duskStartHour ? .dusk : .day
    }

    /// The SF Symbol drawn for `sky`.
    static func symbol(_ sky: PetSky) -> String {
        switch sky {
        case .day: "sun.max"
        case .dusk: "sunset"
        case .night: "moon.stars"
        }
    }
}
