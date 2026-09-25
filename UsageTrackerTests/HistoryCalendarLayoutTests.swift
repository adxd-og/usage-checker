import XCTest
@testable import Omelette

/// Spec § Screens, History → Calendar: today is ringed 1.5 pt past its square. The grid
/// scrolls in a clipping view with today in its last column, so the content keeps room
/// for the ring at the edges the clip touches.
final class HistoryCalendarLayoutTests: XCTestCase {
    func testTheGridKeepsRoomForTodaysRingAtTheClipEdges() {
        XCTAssertGreaterThanOrEqual(
            HistoryLayout.calendarGridEdgeInset,
            HistoryLayout.todayRingWidth / 2,
            "a ring drawn half its width past the square is cut by the scroll view's clip"
        )
    }
}
