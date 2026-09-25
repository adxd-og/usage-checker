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
}
