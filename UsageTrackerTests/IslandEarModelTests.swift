import Combine
import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.6, § 3.8: the ears re-read when the app's state changes, with no
/// timer, and report only what moved. `@Published` sends before the value lands, so a signal is read
/// one main-queue turn later.
@MainActor
final class IslandEarModelTests: XCTestCase {
    @MainActor
    private final class Box {
        var ears = IslandEars.none
        var heard: [IslandEars] = []
    }

    private final class Source {
        @Published var value = 0
    }

    private let moon = IslandEars(
        left: nil,
        right: IslandEars.Ear(mark: .moon, action: .open(subject: nil, reveal: .keepAwake), label: "moon")
    )

    func testOnlyAChangeIsHeard() {
        let box = Box()
        let model = IslandEarModel(read: { box.ears })
        model.onChange = { box.heard.append($0) }
        model.refresh()
        XCTAssertEqual(box.heard, [])
        box.ears = moon
        model.refresh()
        model.refresh()
        XCTAssertEqual(box.heard, [moon])
        XCTAssertEqual(model.ears, moon)
    }

    /// Codex's plan review 4: no state changed, so no signal fires; only the displays did.
    func testADisplayChangeReadsTheEarsBeforeTheWindowIsPlaced() {
        let box = Box()
        let model = IslandEarModel(read: { box.ears })
        model.onChange = { box.heard.append($0) }
        box.ears = moon
        var placedWith: [IslandEars] = []
        model.displaysChanged { placedWith.append(model.ears) }
        XCTAssertEqual(placedWith, [moon])
        XCTAssertEqual(box.heard, [moon])
    }

    func testASignalIsReadOnceItsValueHasLanded() async {
        let source = Source()
        let box = Box()
        let moon = self.moon
        let model = IslandEarModel(read: { source.value == 1 ? moon : IslandEars.none })
        let heard = expectation(description: "the ears heard it")
        model.onChange = { box.heard.append($0); heard.fulfill() }
        model.watch(source.$value.dropFirst())
        source.value = 1
        await fulfillment(of: [heard], timeout: 2)
        XCTAssertEqual(box.heard, [moon])
    }
}
