import Foundation

/// The keep-awake block's, marker's and tooltip's words and rules (spec 2026-10-26, § UI:
/// popover block, menu bar; § Behaviour: Visible, One-time setup). A plain enum, so the
/// status bar's nonisolated tooltip rule may call it. Lives in the app, not in
/// `KeepAwakeCore/`, because it reads `ResetCopy` and `KeepAwakeRegistration`.
enum KeepAwakeCopy {
    /// The block's three steppers: days, hours, minutes.
    enum StepperUnit: CaseIterable, Sendable {
        case days, hours, minutes

        /// The unit after the stepper's number.
        var symbol: String {
            switch self {
            case .days: return "d"
            case .hours: return "h"
            case .minutes: return "min"
            }
        }

        /// What VoiceOver calls the stepper.
        var name: String {
            switch self {
            case .days: return "Days"
            case .hours: return "Hours"
            case .minutes: return "Minutes"
            }
        }

        /// § Behaviour, Timed only: d 0–7, h 0–23, m 0–59.
        var range: ClosedRange<Int> {
            switch self {
            case .days: return 0...KeepAwakeRules.maximumDays
            case .hours: return 0...23
            case .minutes: return 0...59
            }
        }
    }

    static let title = "Keep awake with the lid closed"
    static let applyButton = "Apply"
    static let cancelButton = "Cancel"
    static let dismissButton = "Dismiss"
    static let openLoginItemsButton = "Open Login Items"
    static let approvalText = "Omelette's helper needs your approval once. macOS announces it as “Background Items Added”: switch Omelette on in System Settings › General › Login Items & Extensions, then press Apply again."

    /// "0 d", "4 h", "30 min".
    static func stepperValue(_ value: Int, unit: StepperUnit) -> String {
        "\(value) \(unit.symbol)"
    }

    /// The time left: "52 min", "4 h 52 min", "3 h", "3 d 2 h", "7 d". Minutes round up, so
    /// an armed mode with seconds left reads "1 min", never "0 min", and a fresh five-hour
    /// mode reads "5 h"; from a day on the minutes are dropped.
    static func remaining(_ seconds: TimeInterval) -> String {
        let minutes = Int((max(0, seconds) / 60).rounded(.up))
        let d = minutes / 1_440
        let h = minutes % 1_440 / 60
        let m = minutes % 60
        if d > 0 {
            return h == 0 ? "\(d) d" : "\(d) d \(h) h"
        }
        if h > 0 {
            return m == 0 ? "\(h) h" : "\(h) h \(m) min"
        }
        return "\(m) min"
    }

    /// A moment as the reset times say it (`ResetCopy.absolute`): "18:40" today, "Thu 16:48"
    /// within six days, "2 Nov, 13:48" beyond, "25 Oct, 22:15" for an earlier day.
    static func clock(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        ResetCopy.absolute(resetsAt: date, now: now, calendar: calendar, locale: locale)
            ?? date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
    }

    /// § UI: "Awake until 18:40 · 4 h 52 min left".
    static func armedLine(deadline: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        "Awake until \(Self.clock(deadline, now: now, calendar: calendar, locale: locale)) · \(Self.remaining(deadline.timeIntervalSince(now))) left"
    }

    /// Why a mode ended, one phrase per way it can end.
    static func reason(_ reason: KeepAwakeEndReason) -> String {
        switch reason {
        case .deadline: return "time is up"
        case .batteryFloor: return "battery below \(KeepAwakeRules.batteryFloorPercent) %"
        case .cancelled: return "cancelled"
        case .restarted: return "the Mac or the helper restarted"
        case .stopped: return "the helper was stopped"
        }
    }

    /// § UI: "Ended 14:02 · battery below 25 %".
    static func endedLine(at: Date, reason: KeepAwakeEndReason, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        "Ended \(Self.clock(at, now: now, calendar: calendar, locale: locale)) · \(Self.reason(reason))"
    }
}
