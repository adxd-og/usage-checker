import Foundation

/// `omelette statusline` — one line for Claude Code's status bar, and never more.
///
/// `◐ 42% · resets in 1h 10m · $4.20 today · ⚑ 1`. Parts with nothing to say are
/// dropped rather than shown empty, and a snapshot that is missing or stale renders as
/// the empty string: a status line that lies is worse than one that is blank, and an
/// error message in that bar would sit there for the rest of the session.
enum StatusLineText {
    static let defaultProvider = "claude"

    /// Fixed, not percent-shaped. A glyph that changed four times a session in a bar
    /// people glance at would be movement without information — the number beside it
    /// already says how full the window is.
    static let gauge = "◐"

    /// Agents waiting for a decision. The one part of the line that is not about
    /// `provider`: a waiting agent is waiting whichever CLI it is.
    static let flag = "⚑"

    static func render(snapshot: StatusSnapshot?, provider: String = defaultProvider, now: Date) -> String {
        guard let snapshot, snapshot.isFresh(now: now) else { return "" }
        var parts: [String] = []

        let service = snapshot.service(id: provider)
        if let window = service.flatMap(headlineWindow) {
            parts.append("\(gauge) \(Int(window.percent.rounded()))%")
            if let at = window.resetsAt, let reset = ResetCopy.relative(resetsAt: at, now: now) {
                // The status bar is the one surface where width is scarce; the absolute
                // time `ResetCopy.both` adds belongs in the popover, not here.
                parts.append("resets \(reset)")
            }
        }
        if let today = service?.todayCost, today > 0 {
            parts.append(String(format: "$%.2f today", today))
        }
        if snapshot.agents.needsYou > 0 {
            parts.append("\(flag) \(snapshot.agents.needsYou)")
        }
        return parts.joined(separator: " · ")
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
}
