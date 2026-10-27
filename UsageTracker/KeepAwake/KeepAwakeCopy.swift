import Foundation

/// The keep-awake block's, marker's and tooltip's words and rules (spec 2026-10-26, § UI:
/// popover block, menu bar; § Behaviour: Visible, One-time setup). A plain enum, so the
/// status bar's nonisolated tooltip rule may call it. Lives in the app, not in
/// `KeepAwakeCore/`, because it reads `ResetCopy` and `KeepAwakeRegistration`.
enum KeepAwakeCopy {
    /// The block's three number fields: days, hours, minutes.
    enum DurationUnit: CaseIterable, Sendable {
        case days, hours, minutes

        /// The unit after the field's number.
        var symbol: String {
            switch self {
            case .days: return "d"
            case .hours: return "h"
            case .minutes: return "min"
            }
        }

        /// What VoiceOver calls the field.
        var name: String {
            switch self {
            case .days: return "Days"
            case .hours: return "Hours"
            case .minutes: return "Minutes"
            }
        }

        /// Fool-proofing (owner, 2026-10-27): the field itself stops here, so nobody types
        /// 230 hours. The total rule still has the last word: 7 d 24 h is brought down to the ceiling.
        var maximum: Int {
            switch self {
            case .days: return KeepAwakeRules.maximumDays
            case .hours: return 24
            case .minutes: return 60
            }
        }
    }

    static let title = "Keep awake with the lid closed"
    static let applyButton = "Apply"
    static let cancelButton = "Cancel"
    static let dismissButton = "Dismiss"
    static let openLoginItemsButton = "Open Login Items"
    static let approvalText = "Omelette's helper needs your approval once. macOS announces it as “Background Items Added”: switch Omelette on in System Settings › General › Login Items & Extensions, then press Apply again."

    /// VoiceOver's value for a field: the number and its unit.
    static func unitValue(_ value: Int, unit: DurationUnit) -> String {
        "\(value) \(unit.symbol)"
    }

    /// A field's text as a number, read on every keystroke: ASCII digits only (spaces around
    /// them ignored), anything else counts as nothing typed. At most nine digits are read, so
    /// a long run cannot overflow; the limit line explains it.
    static func fieldNumber(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) else { return 0 }
        return Int(trimmed.prefix(9)) ?? 0
    }

    /// What a field holds after a keystroke: ASCII digits only (a keystroke that brings in
    /// anything else is refused and the previous text stays), empty allowed, leading zeros
    /// dropped, and the number capped at the unit's `maximum`.
    static func fieldText(_ typed: String, previous: String, unit: DurationUnit) -> String {
        let trimmed = typed.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        guard trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) else { return previous }
        let number = Int(trimmed.prefix(9)) ?? 0
        return String(min(number, unit.maximum))
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

extension KeepAwakeCopy {
    /// The status line above the fields.
    enum Status: Equatable, Sendable {
        case idle
        case armed(deadline: Date)
        case approval
        case ended(at: Date, reason: KeepAwakeEndReason)
    }

    /// Which line the block shows, from the local countdown (`KeepAwakeRules.effectiveState`):
    /// armed › ended › approval › idle. An end shows only when it is later than the moment
    /// Dismiss or Apply last dismissed through (plan D3): the helper keeps reporting an end
    /// across its restarts, and an app-inferred stop and the helper's own record of it carry
    /// different moments, so a dismissal hides every end up to a moment, not one value.
    static func status(registration: KeepAwakeRegistration, state: KeepAwakeState, dismissedThrough: TimeInterval, now: Date) -> Status {
        switch KeepAwakeRules.effectiveState(state, now: now) {
        case .armed(let deadline, _):
            return .armed(deadline: deadline)
        case .ended(let at, let reason) where at.timeIntervalSince1970 > dismissedThrough:
            return .ended(at: at, reason: reason)
        case .idle, .ended:
            return registration == .requiresApproval ? .approval : .idle
        }
    }

    /// § UI: Apply needs a duration `KeepAwakeRules.duration` accepts and no call in flight.
    static func canApply(days: Int, hours: Int, minutes: Int, isWorking: Bool) -> Bool {
        !isWorking && KeepAwakeRules.duration(days: days, hours: hours, minutes: minutes) != nil
    }

    /// § UI: a typed total over the ceiling is brought down to it, and the block says so under
    /// the fields. Zero, negatives and in-range totals get no line.
    static let limitNotice = "Up to 7 d 23 h 59 min, for your safety. Apply sets that."

    /// § UI: the line under the fields while the typed total is over the ceiling. It explains
    /// what Apply will do; it blocks nothing. Negatives and zero get no line.
    static func entryNotice(days: Int, hours: Int, minutes: Int) -> String? {
        guard days >= 0, hours >= 0, minutes >= 0 else { return nil }
        let over = Double(days) > Double(KeepAwakeRules.maximumDays)
            || Double(hours) > KeepAwakeRules.maximumDuration / 3_600
            || Double(minutes) > KeepAwakeRules.maximumDuration / 60
            || Double(days) * 1_440 + Double(hours) * 60 + Double(minutes) > KeepAwakeRules.maximumDuration / 60
        return over ? limitNotice : nil
    }

    /// Where the block's minute timer starts (plan D5): the latest point at or before `now` on
    /// the deadline's minute grid, where `remaining`'s rounded-up minute changes. `now` with
    /// no deadline; the deadline itself once it has passed.
    static func tickAnchor(deadline: Date?, now: Date) -> Date {
        guard let deadline else { return now }
        guard deadline > now else { return deadline }
        return deadline.addingTimeInterval(-60 * (deadline.timeIntervalSince(now) / 60).rounded(.up))
    }
}

extension KeepAwakeCopy {
    /// § UI, Menu bar: the tooltip's first line while keep awake is on, "Keep awake until
    /// 18:40"; nil once the local countdown has passed the deadline, and when not armed.
    static func tooltipLine(_ state: KeepAwakeState, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String? {
        guard case .armed(let deadline, _) = KeepAwakeRules.effectiveState(state, now: now) else { return nil }
        return "Keep awake until \(Self.clock(deadline, now: now, calendar: calendar, locale: locale))"
    }
}

extension KeepAwakeCopy {
    /// § UI, Menu bar: the marker before the usage label while keep awake is on (plan D6).
    static let menuBarGlyph = "☾"

    /// The marker while armed and before the deadline (the local countdown drops it at the
    /// deadline, § Behaviour, Visible); nil otherwise.
    static func menuBarMarker(_ state: KeepAwakeState, now: Date) -> String? {
        KeepAwakeRules.isActive(state, now: now) ? Self.menuBarGlyph : nil
    }
}
