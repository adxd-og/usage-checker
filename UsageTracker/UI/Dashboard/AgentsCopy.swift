import Foundation

/// Every word the dashboard's Agents tab draws (liquid-glass spec § Screens, "Agents";
/// `Dashboard-Agents(-Light).dc.html`). The source filter's segment titles stay beside
/// their ids in `AgentsHistoryView.sourceItems`, where a test pins them.
enum AgentsCopy {
    /// The screen's title; the sidebar's name for the tab.
    static let title = "Agents"
    /// What VoiceOver calls the All / Claude / Codex filter. `OMSegmentedControl` would
    /// otherwise call it "Provider", and "All" is not a provider.
    static let sourcePickerName = "Source"
    /// The one stats tile 3.0 draws: sessions that finished inside the range, from the
    /// chosen source. Agent time and Approval requests are 3.1's (spec § Decisions).
    static let sessionsTile = "Sessions"

    // MARK: Live card

    /// Sentence case (spec § Principles 3).
    static let liveTitle = "Live"

    /// "3 sessions" beside "Live", in the popover's words. Nothing when none are live:
    /// the empty row already says so, and a figure appears once per screen.
    static func liveCount(_ count: Int) -> String? {
        count > 0 ? AgentsSection.sessionsCaption(count) : nil
    }

    /// The card's only row when nothing is running; the popover's empty row says the same.
    static let liveEmpty = "No agent sessions"

    /// The link at the Live card's trailing edge. The chevron is `OMLinkButtonStyle`'s.
    static let historyLink = "All sessions in History"
}
