import XCTest
@testable import Omelette

/// Verifier for notch-island spec 2026-10-29 § 3.3 / § 3.5 (whole beads on the device-pixel grid,
/// motion never leaves the habitat, the sky follows the local clock) and the owner's notes of
/// 2026-10-30 (the pet always on the floor; sky sun / sunset / moon): the habitat's geometry on
/// every display scale, and the sky and mood on the minute in zones other than UTC.
final class PetHabitatRulesVerificationTests: XCTestCase {
    private let column: CGFloat = 150
    private let epsilon: CGFloat = 1e-6

    // MARK: - Geometry

    func testTheFloorEndsAtTheColumnsEdgeOnEveryDisplayScale() {
        for backing in [1, 1.25, 1.5, 1.75, 2, 2.25, 2.5, 2.6, 3, 4] as [CGFloat] {
            let scale = PetHabitatRules.scale(petBeads: 35, backingScale: backing)
            let roam = PetHabitatRules.roamBeads(petBeads: 35, scale: scale)
            XCTAssertGreaterThanOrEqual(scale.pixelsPerBead, 1, "\(backing)x")
            XCTAssertLessThanOrEqual(scale.pointsPerBead, 1.5 + epsilon, "\(backing)x: a bead never above 1.5 pt")
            let atFarEdge = CGFloat(roam + 35) * scale.pointsPerBead
            XCTAssertLessThanOrEqual(atFarEdge, column + epsilon, "\(backing)x: the pet at the far end stays inside the column")
            XCTAssertGreaterThan(
                CGFloat(roam + 1 + 35) * scale.pointsPerBead, column - epsilon,
                "\(backing)x: one more bead would leave it, so the floor is the whole column"
            )
        }
    }

    func testThePetAtTheFarEndOfTheFloorIsInsideTheColumnAndOnDevicePixels() {
        for backing in [1, 1.5, 2, 2.6, 3] as [CGFloat] {
            let scale = PetHabitatRules.scale(petBeads: 35, backingScale: backing)
            let roam = PetHabitatRules.roamBeads(petBeads: 35, scale: scale)
            let side = scale.points(beads: 35)
            for height: CGFloat in [40, 300.3, 600.3, 713.7] {
                let footY = PetHabitatRules.floorY(height: height, petSide: side)
                for x in [0, 1, roam / 2, roam, roam + 40] {
                    let origin = PetHabitatRules.origin(xBeads: x, footY: footY, petBeads: 35, roamBeads: roam, scale: scale)
                    let label = "\(backing)x, height \(height), bead \(x)"
                    XCTAssertGreaterThanOrEqual(origin.x, 0, label)
                    XCTAssertLessThanOrEqual(origin.x + side, column + epsilon, label)
                    XCTAssertEqual(origin.x * backing, (origin.x * backing).rounded(), accuracy: 1e-6, "\(label): x on a pixel")
                    XCTAssertEqual(origin.y * backing, (origin.y * backing).rounded(), accuracy: 1e-6, "\(label): y on a pixel")
                    XCTAssertEqual(
                        origin.y + side, footY, accuracy: 0.5 / backing + epsilon,
                        "\(label): the feet are on the floor to the device pixel"
                    )
                }
            }
        }
    }

    func testTheFloorMovesWithTheColumnsHeightAloneAndNeverAbovePetsOwnHeight() {
        // The floor depends on the column's height alone; two heights one point apart are one point apart.
        XCTAssertEqual(
            PetHabitatRules.floorY(height: 601, petSide: 52.5) - PetHabitatRules.floorY(height: 600, petSide: 52.5), 1
        )
        XCTAssertEqual(PetHabitatRules.floorY(height: 0, petSide: 52.5), 52.5, "an unmeasured column: the pet's own height")
        XCTAssertEqual(PetHabitatRules.floorY(height: 86.5, petSide: 52.5), 52.5, "the band's top meets the pet's head exactly")
        XCTAssertEqual(PetHabitatRules.floorY(height: 87, petSide: 52.5), 53)
    }

    func testThePointerOverTheContentIsFalseForAPointerThatIsNotANumber() {
        let content = CGSize(width: 612, height: 640)
        XCTAssertFalse(PetHabitatRules.pointerOverContent(CGPoint(x: CGFloat.nan, y: 300), contentSize: content))
        XCTAssertFalse(PetHabitatRules.pointerOverContent(CGPoint(x: 300, y: CGFloat.nan), contentSize: content))
    }

    // MARK: - The sky and the mood on the minute

    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }

    /// `hour:minute:second` on the calendar's `year-month-day`, plus a fraction of a second.
    private func moment(
        _ calendar: Calendar, _ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0, _ s: Int = 0, plus: TimeInterval = 0
    ) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: s))!
            .addingTimeInterval(plus)
    }

    func testTheSkyTurnsAtTheLocalHourInZonesThatAreNotWholeHoursFromUTC() {
        for zone in ["Asia/Kolkata", "America/New_York", "Pacific/Auckland", "Asia/Kathmandu"] {
            let cal = calendar(zone)
            let sky = { (h: Int, m: Int, s: Int, plus: TimeInterval) in
                PetSkyRules.sky(at: self.moment(cal, 2026, 10, 28, h, m, s, plus: plus), calendar: cal)
            }
            XCTAssertEqual(sky(5, 59, 59, 0.999), .night, "\(zone) 05:59:59.999")
            XCTAssertEqual(sky(6, 0, 0, 0), .day, "\(zone) 06:00:00")
            XCTAssertEqual(sky(17, 59, 59, 0.999), .day, "\(zone) 17:59:59.999")
            XCTAssertEqual(sky(18, 0, 0, 0), .dusk, "\(zone) 18:00:00")
            XCTAssertEqual(sky(21, 59, 59, 0.999), .dusk, "\(zone) 21:59:59.999")
            XCTAssertEqual(sky(22, 0, 0, 0), .night, "\(zone) 22:00:00")
            XCTAssertEqual(sky(0, 0, 0, 0), .night, "\(zone) midnight")
        }
    }

    func testTheSkyKeepsTheLocalClockOnTheDaysTheClocksChange() {
        let newYork = calendar("America/New_York")
        // 2026-11-01: the 01:00 hour happens twice, the day is 25 hours long.
        for day in [(2026, 11, 1), (2026, 3, 8)] {
            let at = { (h: Int, s: TimeInterval) in
                PetSkyRules.sky(at: self.moment(newYork, day.0, day.1, day.2, h, plus: s), calendar: newYork)
            }
            XCTAssertEqual(at(5, 3_599), .night, "\(day) 05:59:59")
            XCTAssertEqual(at(6, 0), .day, "\(day) 06:00")
            XCTAssertEqual(at(18, 0), .dusk, "\(day) 18:00")
            XCTAssertEqual(at(22, 0), .night, "\(day) 22:00")
        }
    }

    /// With keep awake armed, the mood's night and the sky's moon turn together on the second the
    /// local clock reaches 22:00, and end together at 06:00, on a half-hour zone.
    func testTheMoodAndTheMoonTurnTogetherAtBothEndsOfTheNight() {
        let cal = calendar("Asia/Kolkata")
        let locale = Locale(identifier: "en_GB")
        let deadline = moment(cal, 2026, 10, 29, 12)
        let input = PetMoodInput(
            sessions: [], services: [], enabledIDs: nil, claudeBinaryFound: true,
            keepAwake: .armed(deadline: deadline, floorEnabled: true)
        )
        func scene(_ h: Int, _ m: Int, _ s: Int, plus: TimeInterval = 0) -> PetHabitatScene {
            PetHabitatRules.scene(
                input, petName: "Cat", mode: .used, now: moment(cal, 2026, 10, 28, h, m, s, plus: plus),
                calendar: cal, locale: locale
            )
        }
        XCTAssertEqual(scene(21, 59, 59, plus: 0.999).sky, .dusk)
        XCTAssertEqual(scene(21, 59, 59, plus: 0.999).presentation.pose, .idle)
        XCTAssertEqual(scene(22, 0, 0).sky, .night)
        XCTAssertEqual(scene(22, 0, 0).presentation.pose, .sleep)
        XCTAssertEqual(scene(5, 59, 59, plus: 0.999).sky, .night)
        XCTAssertEqual(scene(5, 59, 59, plus: 0.999).presentation.pose, .sleep)
        XCTAssertEqual(scene(6, 0, 0).sky, .day)
        XCTAssertEqual(scene(6, 0, 0).presentation.pose, .idle)
        XCTAssertNotNil(scene(22, 0, 0).presentation.line, "the night's own words")
        XCTAssertNil(scene(6, 0, 0).presentation.line, "idle: none")
    }
}
