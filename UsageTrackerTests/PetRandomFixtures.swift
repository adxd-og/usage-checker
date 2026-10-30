import Foundation
@testable import Omelette

/// A `PetRandom` that draws the given values in order, then 0.5 for ever: each test states the
/// chances it relies on (a bit's deadline, the bit's kind) instead of a seed.
enum PetRandomFixture {
    static func sequence(_ values: [Double]) -> PetRandom {
        let queue = Queue(values)
        return PetRandom { queue.next() }
    }

    private final class Queue {
        private var values: [Double]

        init(_ values: [Double]) {
            self.values = values
        }

        func next() -> Double {
            values.isEmpty ? 0.5 : values.removeFirst()
        }
    }
}
