import Foundation

/// Where "All sessions in History ›" goes (liquid-glass spec § Screens, "Agents";
/// § Principles 4; ruling R4, 2026-09-25). Always History, which owns the per-session
/// list. History is about one provider, so a filter on Claude or Codex takes that
/// provider along, and All leaves the dashboard's provider as it is. An agent source's
/// raw value is its provider's service id (`AgentSourceServiceIDTests`). A provider that
/// is not on the picker yet is healed back by `DashboardState`, as any stale selection is.
enum AgentsLinkRules {
    static func target(source: AgentSource?) -> (tab: DashboardTab, serviceID: String?) {
        (.history, source?.rawValue)
    }
}
