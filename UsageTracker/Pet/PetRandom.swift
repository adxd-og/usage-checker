import Foundation

/// The pet's chance (notch-island spec 2026-10-29 § 3.5 Runtime: "injected clock and random
/// source"): a draw in 0 ..< 1 from a source the owner injects — `system()` in the app, a
/// fixed sequence in a test — and the two shapes the runtime needs from it.
struct PetRandom {
    private let source: () -> Double

    /// `source` returns draws in 0 ..< 1; anything else is held inside that range.
    init(unit source: @escaping () -> Double) {
        self.source = source
    }

    /// The system's generator.
    static func system() -> PetRandom {
        PetRandom { Double.random(in: 0..<1) }
    }

    /// The next draw, in 0 ..< 1; a draw that is not a finite number counts as 0.
    func unit() -> Double {
        let draw = source()
        guard draw.isFinite else { return 0 }
        return min(max(draw, 0), 1.0.nextDown)
    }

    /// A value in `range`, uniform: 20 … 40 s between bits. The range is closed: the largest
    /// draws round to its top.
    func value(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + (range.upperBound - range.lowerBound) * unit()
    }

    /// An index below `count`, uniform; 0 without a draw when there is one choice or none.
    func index(below count: Int) -> Int {
        guard count > 1 else { return 0 }
        return min(count - 1, Int(unit() * Double(count)))
    }
}
