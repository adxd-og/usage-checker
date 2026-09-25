import Foundation

/// How current the numbers on screen are, as the last poll left them.
enum UpdatedStatus: Equatable, Sendable {
    /// At least one provider answered on the last poll.
    case live
    /// Every provider failed on the last poll: the numbers on screen are the last ones
    /// that came through (`UsageSnapshot.isStale`).
    case stale
    /// Nothing has been read yet, neither this launch nor from `LastKnownStore`.
    case never
}

/// What the footnote's dot is painted with.
enum UpdatedDot: Equatable, Sendable {
    /// A 3.0 colour role.
    case token(OMColorToken)
    /// `Color.orange`, as the popover's "Can't refresh" notice.
    case systemOrange
}

/// "Updated 7s ago" and its status dot: the dashboard sidebar's footnote (liquid-glass
/// spec § Removals), in the words of the popover header (`PopoverView.updatedText`) so
/// the two surfaces can share one rule.
enum UpdatedCopy {
    /// The age of `fetchedAt` at `now`. A clock that runs behind the reading counts as
    /// no age at all.
    static func text(fetchedAt: Date, now: Date) -> String {
        guard fetchedAt.timeIntervalSince1970 >= 1 else { return "Never updated" }
        let delta = max(0, now.timeIntervalSince(fetchedAt))
        if delta < 5 { return "Just updated" }
        if delta < 60 { return "Updated \(Int(delta))s ago" }
        if delta < 3600 { return "Updated \(Int(delta / 60))m ago" }
        return "Updated \(Int(delta / 3600))h ago"
    }

    static func status(of snapshot: UsageSnapshot) -> UpdatedStatus {
        guard snapshot.fetchedAt.timeIntervalSince1970 >= 1 else { return .never }
        return snapshot.isStale ? .stale : .live
    }

    /// The dot: the ok green while polls land (the mockups' dot), the system orange of
    /// the popover's stale notice when none did (session ruling R3; 3.0 has no warning
    /// role), secondary before the first reading.
    static func dot(for status: UpdatedStatus) -> UpdatedDot {
        switch status {
        case .live: return .token(.ok)
        case .stale: return .systemOrange
        case .never: return .token(.secondary)
        }
    }

    /// What VoiceOver reads: the line, plus what the dot says when it says more.
    static func accessibilityLabel(text: String, status: UpdatedStatus) -> String {
        status == .stale ? "\(text), can't refresh" : text
    }
}
