import Combine
import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.5 Rendering and Codex's P5d plan review 5: the manifests, large
/// with forty events, are read once off the main thread. Until then the store says so, the habitat
/// shows a bare column, and nothing on the main thread can read them or wait for them.
@MainActor
final class PetAssetStoreTests: XCTestCase {
    /// What the read saw, from whichever thread it ran on.
    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var threads: [Bool] = []

        func note(isMain: Bool) {
            lock.lock()
            threads.append(isMain)
            lock.unlock()
        }

        var seen: [Bool] {
            lock.lock()
            defer { lock.unlock() }
            return threads
        }
    }

    func testNothingIsThereOrReadUntilLoaded() {
        let reads = Reads()
        let store = PetAssetStore(read: {
            reads.note(isMain: Thread.isMainThread)
            return PetAssets(library: .empty)
        })
        XCTAssertNil(store.assets, "not loaded")
        XCTAssertEqual(reads.seen, [])
    }

    func testALoadReadsOnceOffTheMainThreadAndPublishes() async {
        let reads = Reads()
        let store = PetAssetStore(read: {
            reads.note(isMain: Thread.isMainThread)
            return PetAssets(library: .empty)
        })
        var changes = 0
        let watch = store.objectWillChange.sink { changes += 1 }
        let first = store.load()
        let second = store.load()
        await first.value
        await second.value
        watch.cancel()
        XCTAssertNotNil(store.assets)
        XCTAssertEqual(reads.seen, [false], "once, off the main thread")
        XCTAssertEqual(changes, 1)
    }
}
