import Foundation

/// The three spans behind Dashboard → Activity's cost cards, as day starts.
///
/// A card that says "Last 30 days" means thirty calendar days ending today, so its
/// cutoff is the start of the day 29 days back. Cutting at the current time of day —
/// which is what the grid did — excluded the boundary day entirely, because every
/// `CLIDailySummary.day` is a day start: the 90-day card was quietly 89 days long.
///
/// Spec: docs/superpowers/specs/2026-09-17-activity-year-retention-design.md § Cards.
enum ActivityCardRule {
    /// Calendar days each card covers, today included.
    static let thirtyDays = 30
    static let ninetyDays = 90
    static let yearDays = 365

    /// The earliest day each card counts. Computed by calendar days rather than by
    /// subtracting seconds: 364 x 86 400 lands an hour off across a daylight-saving
    /// change and, near midnight, on the day before.
    static func cutoffs(
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> (thirty: Date, ninety: Date, year: Date) {
        let today = calendar.startOfDay(for: now)
        func start(_ days: Int) -> Date {
            calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        }
        return (start(thirtyDays), start(ninetyDays), start(yearDays))
    }
}
