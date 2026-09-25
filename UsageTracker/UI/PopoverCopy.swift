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

    /// A weekly row's label on a provider tab: "Fable only" → "Fable"; "All models"
    /// stays whole (a row has room a 160 pt tile does not).
    static func limitRowLabel(_ label: String) -> String {
        label.hasSuffix(" only") ? String(label.dropLast(" only".count)) : label
    }

    /// The header's second line. A provider tab names the provider and its plan first
    /// ("Claude Max 20x · Updated 7s ago"); All says only when it updated. The age is
    /// `UpdatedCopy`'s, so it reads as the dashboard sidebar's footnote does.
    static func metaLine(service: ServiceSnapshot?, fetchedAt: Date, now: Date) -> String {
        let updated = UpdatedCopy.text(fetchedAt: fetchedAt, now: now)
        guard let service else { return updated }
        let name = [service.displayName, planLine(plan: service.plan, displayName: service.displayName)]
            .compactMap { $0 }
            .joined(separator: " ")
        return "\(name) · \(updated)"
    }
}
