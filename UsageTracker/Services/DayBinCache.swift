import Foundation

/// The local day a moment falls in, with the last answer kept: log lines arrive in
/// near-chronological runs, and `Calendar.startOfDay` is far too expensive to ask per
/// turn. Shared by the three cost aggregators.
///
/// The kept day is dropped when the system time zone changes. The aggregators follow
/// the system's calendar (`Calendar.autoupdatingCurrent`), and without the reset the
/// running app kept filing turns under the old zone's midnight for the rest of that
/// day. The reset happens inside the observer, under the lock, so no lookup after the
/// notification can see the old day — an actor hop would leave that window open.
final class DayBinCache: @unchecked Sendable {
    private let lock = NSLock()
    private var kept: (start: Date, next: Date)?
    private let center: NotificationCenter
    private var observer: NSObjectProtocol?

    /// `center` is the app's default one; a test passes its own so it can post the
    /// notification without touching the process.
    init(center: NotificationCenter = .default) {
        self.center = center
        observer = center.addObserver(
            forName: .NSSystemTimeZoneDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            self?.reset()
        }
    }

    deinit {
        if let observer { center.removeObserver(observer) }
    }

    /// The start of `date`'s day in `calendar`.
    func start(of date: Date, in calendar: Calendar) -> Date {
        lock.lock()
        defer { lock.unlock() }
        if let kept, date >= kept.start, date < kept.next { return kept.start }
        let start = calendar.startOfDay(for: date)
        let next = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        kept = (start, next)
        return start
    }

    /// Forgets the kept day; the next lookup asks the calendar again.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        kept = nil
    }
}
