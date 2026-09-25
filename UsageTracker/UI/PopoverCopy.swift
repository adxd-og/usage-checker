import Foundation

/// The popover's own words, which no other surface shares: the header's meta line and
/// a tile's plan line (spec § Screens, "Popover · All" and "Popover · provider";
/// `Main.dc.html`, `Popover-Claude.dc.html`).
enum PopoverCopy {
    /// The plan as the tile prints it under the name: "Max 20x" for Claude, "Plus" for
    /// "Codex Plus". nil when there is none, or when it is only the provider's name
    /// again ("Antigravity").
    static func planLine(plan: String?, displayName: String) -> String? {
        guard let plan = plan?.trimmingCharacters(in: .whitespaces), !plan.isEmpty, plan != displayName
        else { return nil }
        let prefix = displayName + " "
        guard plan.hasPrefix(prefix) else { return plan }
        let rest = String(plan.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }

    /// "Updated just now", "Updated 12s ago", "Updated 4m ago", "Updated 2h ago";
    /// "Never updated" before the first reading.
    static func updatedText(fetchedAt: Date, now: Date) -> String {
        if fetchedAt.timeIntervalSince1970 < 1 { return "Never updated" }
        let delta = max(0, now.timeIntervalSince(fetchedAt))
        if delta < 5 { return "Updated just now" }
        if delta < 60 { return "Updated \(Int(delta))s ago" }
        if delta < 3600 { return "Updated \(Int(delta / 60))m ago" }
        return "Updated \(Int(delta / 3600))h ago"
    }

    /// The header's second line. A provider tab names the provider and its plan first
    /// ("Claude Max 20x · Updated 7s ago"); All says only when it updated.
    static func metaLine(service: ServiceSnapshot?, fetchedAt: Date, now: Date) -> String {
        let updated = updatedText(fetchedAt: fetchedAt, now: now)
        guard let service else { return updated }
        let name = [service.displayName, planLine(plan: service.plan, displayName: service.displayName)]
            .compactMap { $0 }
            .joined(separator: " ")
        return "\(name) · \(updated)"
    }
}
