import SwiftUI

/// What the floating mini window draws, as a pure function of one service
/// snapshot and the live agent sessions.
///
/// The panel is a fixed 260 × 130 (`FloatingWindowController.open`) and never
/// scrolls, so a hero ring leaves room for exactly two bar rows. Deciding which
/// two here — rather than inside the view — is what makes the rule testable.
enum FloatingMiniLayout {
    /// The ring, the windows drawn as bars under it, and what to show when there is
    /// no ring to draw: a pay-as-you-go week of spend, or a sentence. At most one of
    /// `hero`, `weekCost` and `emptyText` is set.
    struct Content: Equatable {
        let hero: UsageBucket?
        let rows: [UsageBucket]
        let emptyText: String?
        /// When the ring and the bars were last true, for a provider that stopped
        /// reporting; nil while it is live. The view dims them to the tile's 0.55, drops
        /// their pace markers and puts the tile's state chip in the header.
        var retainedAt: Date? = nil
        /// A healthy account with no window and money spent this week: pay-as-you-go
        /// with no budget set. Defaulted, because only `noWindowsContent` sets it.
        var weekCost: Double? = nil
    }

    /// `maxRows` is 2 because that is what fits at 130 pt; it is a parameter only
    /// so the tests can pin the truncation without depending on the panel size.
    static func content(for service: ServiceSnapshot?, maxRows: Int = 2) -> Content {
        guard let service else {
            return Content(hero: nil, rows: [], emptyText: "Loading…")
        }
        guard let hero = WindowRanking.detailHero(for: service) else {
            return noWindowsContent(for: service)
        }
        return Content(
            hero: hero,
            rows: rows(for: service, hero: hero, maxRows: maxRows),
            emptyText: nil,
            retainedAt: service.retainedAt
        )
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

    /// The number at the end of one bar row: "76%" / "24%".
    static func rowPercentText(_ bucket: UsageBucket, mode: PercentDisplay.Mode) -> String {
        PercentDisplay.percentText(bucket.clampedPercent, mode: mode)
    }

    /// What VoiceOver reads for the ring at the top of the panel.
    static func heroAccessibilityLabel(_ hero: UsageBucket, mode: PercentDisplay.Mode) -> String {
        "\(hero.label), \(PercentDisplay.spoken(hero.clampedPercent, mode: mode))"
    }

    /// What VoiceOver reads for one bar row. The full window name, not the 62 pt
    /// column's shortened one: a screen reader has no column to fit.
    static func rowAccessibilityLabel(_ bucket: UsageBucket, mode: PercentDisplay.Mode) -> String {
        "\(bucket.label), \(PercentDisplay.spoken(bucket.clampedPercent, mode: mode))"
    }

    /// The opacity of the ring and the bars: the tile's 0.55 for last-known numbers.
    static func numbersOpacity(_ content: Content) -> Double {
        content.retainedAt == nil ? 1 : 0.55
    }

    /// Where one window's pace marker goes, or nil for none. A retained window has no
    /// pace: the marker would compare a live clock with a number that stopped moving.
    static func pace(for bucket: UsageBucket, in content: Content, now: Date = Date()) -> Double? {
        content.retainedAt == nil ? bucket.elapsedFraction(now: now) : nil
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

    /// A service with no window to ring. "Haven't used" is true in only one of three
    /// cases. A healthy pay-as-you-go account with no budget set publishes no window
    /// (`AppState.applyPayAsYouGo`) but has the week's spend. A provider that failed has
    /// its own message. Only a healthy provider with nothing at all is unused.
    private static func noWindowsContent(for service: ServiceSnapshot) -> Content {
        if service.state == .ok, let weekCost = service.weekCost, weekCost > 0 {
            return Content(hero: nil, rows: [], emptyText: nil, weekCost: weekCost)
        }
        guard service.state == .ok else {
            return Content(hero: nil, rows: [], emptyText: stateText(for: service))
        }
        return Content(hero: nil, rows: [], emptyText: "You haven't used \(service.displayName) yet")
    }

    /// The provider's own words when it gave any, else the state chip's word.
    private static func stateText(for service: ServiceSnapshot) -> String {
        let message = service.stateMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return message.isEmpty ? RetainedCopy.chipText(for: service.state) : message
    }
}
