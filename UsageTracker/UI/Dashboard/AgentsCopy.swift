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
}
