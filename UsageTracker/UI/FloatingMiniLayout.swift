import SwiftUI

/// What the floating mini window draws, as a pure function of one service
/// snapshot and the live agent sessions.
///
/// The panel is a fixed 260 × 130 (`FloatingWindowController.open`) and never
/// scrolls, so a hero ring leaves room for exactly two bar rows. Deciding which
/// two here — rather than inside the view — is what makes the rule testable.
enum FloatingMiniLayout {
    /// The ring, the windows drawn as bars under it, and the sentence to show
    /// when there is no ring to draw. `hero` and `emptyText` are never both set.
    struct Content: Equatable {
        let hero: UsageBucket?
        let rows: [UsageBucket]
        let emptyText: String?
    }

    /// `maxRows` is 2 because that is what fits at 130 pt; it is a parameter only
    /// so the tests can pin the truncation without depending on the panel size.
    static func content(for service: ServiceSnapshot?, maxRows: Int = 2) -> Content {
        guard let service else {
            return Content(hero: nil, rows: [], emptyText: "Loading…")
        }
        guard let hero = WindowRanking.detailHero(for: service) else {
            return Content(hero: nil, rows: [], emptyText: "You haven't used \(service.displayName) yet")
        }
        return Content(hero: hero, rows: rows(for: service, hero: hero, maxRows: maxRows), emptyText: nil)
    }

    /// The trailing agents count. `OMAgentsPill.Appearance` already owns the
    /// needs-you → working → quiet precedence and the VoiceOver wording, so the
    /// window borrows both instead of inventing a second rule. It deliberately
    /// does not consult `agentsShowInMenuBar`: that switch is about the menu bar
    /// and says nothing about a window the user opened on purpose.
    static func agents(_ sessions: [AgentSession]) -> OMAgentsPill.Appearance? {
        OMAgentsPill.Appearance.make(
            needsYou: sessions.reduce(0) { $0 + ($1.state == .needsYou ? 1 : 0) },
            working: sessions.reduce(0) { $0 + ($1.state == .working ? 1 : 0) },
            total: sessions.count
        )
    }

    // MARK: - Private

    /// Other session windows first — mid-week a weekly often reads higher than the
    /// 5-hour window, and the 5-hour window is the one people check — then the rest
    /// worst-first with ties keeping API order. Promotional pools never take a seat:
    /// running a free bonus dry costs nothing.
    private static func rows(for service: ServiceSnapshot, hero: UsageBucket, maxRows: Int) -> [UsageBucket] {
        let sessions = WindowRanking.sessionRows(for: service, hero: hero).filter { !$0.isPromotional }
        let taken = Set(sessions.map(\.id) + [hero.id])
        let rest = service.buckets.filter { !taken.contains($0.id) && !$0.isPromotional }
        // `sorted` is not stable, so the API index is carried along and breaks ties.
        let ordered = rest.enumerated()
            .sorted { a, b in
                if a.element.clampedPercent != b.element.clampedPercent {
                    return a.element.clampedPercent > b.element.clampedPercent
                }
                return a.offset < b.offset
            }
            .map { $0.element }
        return Array((sessions + ordered).prefix(max(0, maxRows)))
    }
}
