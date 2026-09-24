import Foundation

/// `omelette statusline` — one line for Claude Code's status bar, and never more.
///
/// `Fable [####------] 42% · ◐ 61% · resets in 1h 28m · ≈$386.64 today · ⚑ 1` — or
/// `… · ◐ 39% left · …` when the app is showing what is left. The prefix is the
/// session Claude Code piped in (`StatusLineInput`), everything after it is the
/// account. Parts with nothing to say are dropped rather than shown empty, and a
/// snapshot that is missing or stale leaves the prefix standing on its own: a status
/// line that lies is worse than one that is blank, and an error message in that bar
/// would sit there for the rest of the session.
enum StatusLineText {
    static let defaultProvider = "claude"

    /// Fixed, not percent-shaped. A glyph that changed four times a session in a bar
    /// people glance at would be movement without information — the number beside it
    /// already says how full the window is.
    static let gauge = "◐"

    /// Agents waiting for a decision. The one part of the line that is not about
    /// `provider`: a waiting agent is waiting whichever CLI it is.
    static let flag = "⚑"

    /// Ten characters wide, `#` filled and `-` empty: the shape the owner's own status
    /// line script drew before Omelette had one, kept so the bar reads the same.
    static let barWidth = 10
    static let barFilled = "#"
    static let barEmpty = "-"

    /// Dim throughout — a status bar is read at a glance and beside a prompt, and full
    /// brightness there competes with the text the user is actually typing.
    enum ANSI {
        static let model = "\u{1B}[2;36m"   // dim cyan
        static let roomy = "\u{1B}[2;32m"   // dim green, under half full
        static let filling = "\u{1B}[2;33m" // dim yellow, from half
        static let tight = "\u{1B}[2;31m"   // dim red, from 80%
        static let percent = "\u{1B}[2m"
        static let reset = "\u{1B}[0m"
    }

    static func render(
        snapshot: StatusSnapshot?,
        provider: String = defaultProvider,
        now: Date,
        input: StatusLineInput = .none,
        colour: Bool = true,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let prefix = sessionPrefix(
            model: input.model, contextUsedPercent: input.contextUsedPercent, colour: colour
        )
        // The session's numbers do not go stale with the app's: Claude Code piped them
        // in a moment ago, and losing the model name because Omelette is closed would
        // be dropping the one part of the line that is still true.
        guard let snapshot, snapshot.isFresh(now: now) else { return prefix }
        var parts: [String] = prefix.isEmpty ? [] : [prefix]

        let service = snapshot.service(id: provider)
        if let service {
            parts.append(contentsOf: windowParts(
                service, mode: snapshot.percentMode, now: now, calendar: calendar, locale: locale
            ))
        }
        if let cost = service.flatMap(todayCostText) {
            parts.append(cost)
        }
        if snapshot.agents.needsYou > 0 {
            parts.append("\(flag) \(snapshot.agents.needsYou)")
        }
        return parts.joined(separator: " · ")
    }

    /// `Fable [####------] 42%` — the model Claude Code is running and how full its
    /// context window is, in front of the account's numbers.
    ///
    /// The bar counts what is **used**, always. A context window filling up is a
    /// different quantity from the rate-limit windows beside it, so the app's
    /// "show what is left" switch (`PercentDisplay.Mode`) deliberately does not reach
    /// it: "58% left" of a context window would read as a limit the user does not have.
    ///
    /// A missing name falls back to "Claude" — Claude Code always sends one, and a bar
    /// with nothing in front of it is worse than a generic name. With neither a name
    /// nor a reading there is no prefix at all: run by hand in a terminal there is no
    /// session, and the word "Claude" in front of the numbers would be an invention.
    static func sessionPrefix(model: String?, contextUsedPercent: Double?, colour: Bool) -> String {
        guard model != nil || contextUsedPercent != nil else { return "" }
        let name = model ?? "Claude"
        guard let used = contextUsedPercent else {
            return colour ? ANSI.model + name + ANSI.reset : name
        }
        let clamped = max(0, min(100, used))
        let filled = Int((clamped / 100 * Double(barWidth)).rounded())
        let bar = "[" + String(repeating: barFilled, count: filled)
            + String(repeating: barEmpty, count: barWidth - filled) + "]"
        let percent = "\(Int(clamped.rounded()))%"
        guard colour else { return "\(name) \(bar) \(percent)" }
        let barColour = clamped >= 80 ? ANSI.tight : (clamped >= 50 ? ANSI.filling : ANSI.roomy)
        return ANSI.model + name + ANSI.reset
            + " " + barColour + bar + ANSI.reset
            + " " + ANSI.percent + percent + ANSI.reset
    }

    /// The window the line speaks for: the session window when the provider has one,
    /// otherwise the fullest window that is neither a promo pool nor model-scoped —
    /// the same choice `WidgetService.headlineBucket` makes for the widget's ring, so
    /// the two surfaces never lead with different numbers. A promo pool leads only when
    /// it is all the account has.
    static func headlineWindow(_ service: StatusSnapshot.Service) -> StatusSnapshot.Window? {
        if let session = service.windows.first(where: { $0.kind == "session" && !$0.isPromotional }) {
            return session
        }
        let core = service.windows.filter { !$0.isPromotional && $0.kind != "modelSpecific" }
        let pool = core.isEmpty ? service.windows.filter { !$0.isPromotional } : core
        return (pool.isEmpty ? service.windows : pool).max(by: { $0.percent < $1.percent })
    }

    /// What a retained number says when the file carries no stamp for it. The writer
    /// always sets one; the type allows nil, and a bare number would read as live.
    static let retainedWithoutStamp = "last known"

    /// The gauge and its reset for one provider: `◐ 61%`, `resets in 1h 28m`.
    ///
    /// A retained provider keeps its window — the number is the last one it reported —
    /// but says how old it is in `RetainedCopy`'s words, `◐ 95% (as of 14:05)`, and its
    /// reset goes once that moment has passed: "resets now" on a window that started
    /// over hours ago is the one part of the line that is plainly false. A live window
    /// keeps "resets now"; it is seconds past, and the next poll replaces it.
    static func windowParts(
        _ service: StatusSnapshot.Service,
        mode: PercentDisplay.Mode,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> [String] {
        guard let window = headlineWindow(service) else { return [] }
        var head = "\(gauge) \(PercentDisplay.percentPhrase(window.percent, mode: mode))"
        if service.retained {
            let age = service.retainedAt.map {
                RetainedCopy.asOf($0, now: now, calendar: calendar, locale: locale)
            } ?? retainedWithoutStamp
            head += " (\(age))"
        }
        var parts = [head]
        if let at = window.resetsAt, !(service.retained && at <= now),
           let reset = ResetCopy.relative(resetsAt: at, now: now) {
            // The status bar is the one surface where width is scarce; the absolute
            // time `ResetCopy.both` adds belongs in the popover, not here.
            parts.append("resets \(reset)")
        }
        return parts
    }

    // MARK: - Dollars

    /// In front of today's dollars when they are an API-list-price equivalent of local
    /// CLI usage rather than a bill. One character: this bar has no room for
    /// `CLIText.apiEquivalentSuffix`, and `omelette --help` says what it means.
    static let apiEquivalentMarker = "≈"

    /// `$386.64 today`, or `≈$386.64 today` for a subscription, whose dollars are what
    /// the same tokens would cost through the API, not what it bills. nil when nothing
    /// was spent. Its own function so the window half of the line can change without
    /// touching it.
    static func todayCostText(_ service: StatusSnapshot.Service) -> String? {
        guard let today = service.todayCost, today > 0 else { return nil }
        let amount = String(format: "$%.2f today", today)
        return service.apiEquivalent == true ? apiEquivalentMarker + amount : amount
    }
}
