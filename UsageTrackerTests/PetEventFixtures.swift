import Foundation
@testable import Omelette

/// Events built as the validator builds them, for the runtime's tests. Frames "a" and "b"
/// alternate by step.
enum PetEventFixture {
    static let map = PetCharMap(rows: PetFixture.frameRows, side: PetContract.size)!

    static func event(id: String, fps: Double, moves: [(dx: Int, dy: Int)]) -> PetEvent {
        PetEvent(
            id: id,
            fps: fps,
            frames: ["a": map, "b": map],
            steps: moves.enumerated().map {
                PetEventStep(frame: $0.offset % 2 == 0 ? "a" : "b", dx: $0.element.dx, dy: $0.element.dy)
            },
            palette: [:]
        )
    }

    /// Six steps at 4 fps, 1.5 s, inside its frame.
    static let flat = event(id: "flat", fps: 4, moves: Array(repeating: (0, 0), count: 6))
    /// Twelve steps at 8 fps, 1.5 s. Lift by step: 0 2 4 6 6 6 6 4 2 0 0 0.
    static let climb = event(id: "climb", fps: 8, moves: [
        (0, 0), (0, -2), (0, -2), (0, -2), (0, 0), (0, 0), (0, 0), (0, 2), (0, 2), (0, 2), (0, 0), (0, 0),
    ])
    /// Six steps at 4 fps, 1.5 s. Sideways by step: 0 3 6 3 0 0.
    static let drift = event(id: "drift", fps: 4, moves: [(0, 0), (3, 0), (3, 0), (-3, 0), (-3, 0), (0, 0)])
    /// 32 steps at 4 fps: 8 s, longer than any slot.
    static let long = event(id: "long", fps: 4, moves: Array(repeating: (0, 0), count: 32))
    static let both = [flat, climb]
}
