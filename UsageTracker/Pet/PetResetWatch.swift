import Foundation

/// The limit resets the pet stretches for (notch-island spec 2026-10-29 § 3.5 Runtime: "one
/// stretch per limit reset seen in a live poll, deduplicated by window id + reset time; never
/// on relaunch or a retained refresh"). It remembers each live window's reset time. A window
/// whose reset time moved a minute or more later, read once the old one had passed, has reset.
/// A smaller move is jitter and is followed; a larger move read before the old time passed is
/// undecided, and the old time stays until a poll after it, so the reset is not lost. The
/// first reading of a window after launch only records it; a retained or failed provider is
/// neither read nor recorded; a reset is reported once, however often a poll shows it again.
/// Bonus pools are no limit, and a window with no reset time cannot reset. Pure.
struct PetResetWatch: Equatable, Sendable {
    /// One reset: the window ("claude/five_hour") and the reset time that passed.
    struct Reset: Hashable, Sendable {
        let window: String
        let resetAt: Date
    }

    /// How long a reported reset is kept for deduplication: a week's window and a day.
    static let memory: TimeInterval = 8 * 86_400
    /// A reset time that moves by less is the same reset time read again (seconds of jitter);
    /// a real reset moves it by a window's length, hours or days.
    static let jitter: TimeInterval = 60

    /// Each live window's reset time: as last read, or the old one while a new one waits for it
    /// to pass.
    private(set) var lastResetAt: [String: Date] = [:]
    /// The resets already reported.
    private(set) var reported: Set<Reset> = []

    /// Reads one poll's `services` at `now`; returns the resets it shows that were not
    /// reported before, in display order.
    mutating func observe(_ services: [ServiceSnapshot], now: Date) -> [Reset] {
        var found: [Reset] = []
        for service in services where service.state == .ok {
            for bucket in service.buckets where !bucket.isBonusPool && bucket.resetsAt < .distantFuture {
                let window = "\(service.id)/\(bucket.id)"
                guard let previous = lastResetAt[window] else {
                    lastResetAt[window] = bucket.resetsAt
                    continue
                }
                if bucket.resetsAt.timeIntervalSince(previous) < Self.jitter {
                    lastResetAt[window] = bucket.resetsAt
                } else if now >= previous {
                    lastResetAt[window] = bucket.resetsAt
                    let reset = Reset(window: window, resetAt: previous)
                    if reported.insert(reset).inserted { found.append(reset) }
                }
            }
        }
        reported = reported.filter { now.timeIntervalSince($0.resetAt) < Self.memory }
        return found
    }
}
