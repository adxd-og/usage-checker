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

/// An event as `pet.json` holds it, built in code so a test can break one rule at a time.
extension PetFixture {
    /// Paints o at (0, 0) and the prop x at (2, 0).
    static let eventRows = rows(side: 35, beads: [(0, 0, "o"), (2, 0, "x")])

    /// "hop": frames a and b, six steps at 4 fps (1.5 s), up 4 and across 2 and back, the prop x red.
    static func event(id: String = "hop") -> [String: Any] {
        [
            "id": id,
            "fps": 4,
            "frames": ["a": eventRows, "b": frameRows],
            "steps": steps([("a", 0, 0), ("b", 0, -2), ("a", 2, -2), ("b", 0, 2), ("a", -2, 2), ("b", 0, 0)]),
            "palette": ["x": "#ff0000"],
        ]
    }

    static func steps(_ moves: [(String, Any, Any)]) -> [[String: Any]] {
        moves.map { ["f": $0.0, "dx": $0.1, "dy": $0.2] }
    }

    /// `count` steps on frame a that move nothing.
    static func stillSteps(_ count: Int) -> [[String: Any]] {
        steps(Array(repeating: ("a", 0, 0), count: count))
    }
}

extension PetRuntime {
    /// A tick `seconds` after `PetRuntimeFixture.t0`, with the shipped cat's animations.
    mutating func at(
        _ seconds: TimeInterval,
        pose: PetPose = .idle,
        loops: Bool = true,
        activity: PetUserActivity = .none,
        roam: Int = PetRuntimeFixture.roam,
        events: [PetEvent] = PetEventFixture.both
    ) -> PetFrame {
        tick(
            at: PetRuntimeFixture.t0 + seconds, pose: pose, loops: loops, activity: activity,
            animations: PetRuntimeFixture.animations, roamBeads: roam, events: events
        )
    }
}
