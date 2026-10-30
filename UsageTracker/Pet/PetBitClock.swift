import Foundation

/// When the idle loop may play a bit (notch-island spec 2026-10-29 § 3.5 Runtime): at most one
/// every 20–40 s of visible open time — time the pet was on screen and animating, added up
/// across opens — and never in an open's first 1.5 s. The habitat's gate starts and ends each
/// visible period (`resume`, `pause`); a closed island adds nothing. Pure.
struct PetBitClock: Equatable, Sendable {
    /// No bit in a visible period's first 1.5 s.
    static let quietStart: TimeInterval = 1.5
    /// Visible time from one bit's start to the next one's.
    static let spacing: ClosedRange<TimeInterval> = 20...40

    /// Visible time of the periods that ended.
    private(set) var banked: TimeInterval = 0
    /// When the running visible period began; nil while paused.
    private(set) var periodStart: Date?
    /// The visible time at which the next bit is due.
    private(set) var nextBitAt: TimeInterval

    init(random: PetRandom) {
        nextBitAt = random.value(in: Self.spacing)
    }

    var isRunning: Bool { periodStart != nil }

    /// A visible period starts; a running one keeps its start.
    mutating func resume(at now: Date) {
        if periodStart == nil { periodStart = now }
    }

    /// The running period ends and its time is banked; a clock set back adds nothing.
    mutating func pause(at now: Date) {
        guard let start = periodStart else { return }
        banked += max(0, now.timeIntervalSince(start))
        periodStart = nil
    }

    /// How long the running period has lasted; 0 while paused.
    func periodAge(at now: Date) -> TimeInterval {
        periodStart.map { max(0, now.timeIntervalSince($0)) } ?? 0
    }

    /// Visible open time so far.
    func visibleTime(at now: Date) -> TimeInterval {
        banked + periodAge(at: now)
    }

    /// On screen, and past this open's first 1.5 s.
    func mayStartBit(at now: Date) -> Bool {
        isRunning && periodAge(at: now) >= Self.quietStart
    }

    /// The idle loop's next bit is due.
    func isDue(at now: Date) -> Bool {
        mayStartBit(at: now) && visibleTime(at: now) >= nextBitAt
    }

    /// A bit started, or a pat put the loop off: the next one is due 20–40 s of visible time
    /// from now.
    mutating func reschedule(at now: Date, random: PetRandom) {
        nextBitAt = visibleTime(at: now) + random.value(in: Self.spacing)
    }
}
