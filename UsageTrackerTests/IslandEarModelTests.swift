import Combine
import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.6, § 3.8, with spec 2026-11-03 § Ears and hint: the ears of every
/// island display, keyed by display id, re-read when the app's state changes, with no timer, and
/// reported only when they moved. `@Published` sends before the value lands, so a signal is read one
/// main-queue turn later.
@MainActor
final class IslandEarModelTests: XCTestCase {
    @MainActor
    private final class Box {
        var ears: [UInt32: IslandEars] = [:]
        var heard: [[UInt32: IslandEars]] = []
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
        box.ears = [1: moon]
        model.refresh()
        model.refresh()
        XCTAssertEqual(box.heard, [[1: moon]])
        XCTAssertEqual(model.ears, [1: moon])
    }

    /// Codex's plan review 4: no state changed, so no signal fires; only the displays did. A display
    /// that arrives with its island arrives with its ears.
    func testADisplayChangeReadsTheEarsBeforeTheWindowIsPlaced() {
        let box = Box()
        let model = IslandEarModel(read: { box.ears })
        model.onChange = { box.heard.append($0) }
        box.ears = [1: moon, 2: moon]
        var placedWith: [[UInt32: IslandEars]] = []
        model.displaysChanged { placedWith.append(model.ears) }
        XCTAssertEqual(placedWith, [[1: moon, 2: moon]])
        XCTAssertEqual(box.heard, [[1: moon, 2: moon]])
    }

    func testASignalIsReadOnceItsValueHasLanded() async {
        let source = Source()
        let box = Box()
        let moon = self.moon
        let model = IslandEarModel(read: { source.value == 1 ? [1: moon] : [:] })
        let heard = expectation(description: "the ears heard it")
        model.onChange = { box.heard.append($0); heard.fulfill() }
        model.watch(source.$value.dropFirst())
        source.value = 1
        await fulfillment(of: [heard], timeout: 2)
        XCTAssertEqual(box.heard, [[1: moon]])
    }
}
