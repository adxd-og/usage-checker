import Foundation

/// The limits every event keeps (notch-island spec 2026-10-29 § 3.5, "Owner 2026-10-30 (events)").
/// `PetManifestValidator` checks them.
extension PetContract {
    static let eventFPS: ClosedRange<Double> = 4...12
    static let eventDuration: ClosedRange<TimeInterval> = 1.5...8
    static let eventMaxFrames = 8
    /// The highest above the floor an event goes, in beads.
    static let eventMaxLift = 120
    /// The farthest from its start an event goes sideways, in beads.
    static let eventMaxDrift = 30
    /// The most one step may move, either way: nothing larger is ever added up.
    static let eventMaxDelta = 120
    /// The roles a prop may paint: never fur, so every colourway of the animal keeps working.
    static let eventPropRoles: Set<Unicode.Scalar> = ["x", "y", "z", "u", "v"]
}

/// One tick of an event: the frame it shows and how far the whole sprite moved since the step
/// before, in whole beads (`dy` negative is up).
struct PetEventStep: Equatable, Sendable {
    let frame: String
    let dx: Int
    let dy: Int
}

/// Where a step puts the sprite relative to where the event began: `x` beads in the drawing's
/// direction, `lift` beads up from the floor.
struct PetEventOffset: Equatable, Sendable {
    let x: Int
    let lift: Int

    static let zero = PetEventOffset(x: 0, lift: 0)
}

/// A hand-drawn event of one animal (§ 3.5, "Owner 2026-10-30 (events)"): its own frames and prop
/// colours, played one step per tick at its own rate, ending where it began. The contract check
/// guarantees at least one step and deltas that sum to zero. Pure.
struct PetEvent: Equatable, Sendable {
    let id: String
    let fps: Double
    let frames: [String: PetCharMap]
    let steps: [PetEventStep]
    /// The prop roles' colours, the same in every colourway.
    let palette: [Unicode.Scalar: PetRGB]
    /// Each step's place; a dip below the floor reads as the floor.
    let offsets: [PetEventOffset]
    /// Some step moves the sprite: cutting it short would look broken.
    let moves: Bool

    init(
        id: String, fps: Double, frames: [String: PetCharMap], steps: [PetEventStep],
        palette: [Unicode.Scalar: PetRGB]
    ) {
        self.id = id
        self.fps = fps
        self.frames = frames
        self.steps = steps
        self.palette = palette
        var x = 0
        var up = 0
        var offsets: [PetEventOffset] = []
        offsets.reserveCapacity(steps.count)
        for step in steps {
            x += step.dx
            up -= step.dy
            offsets.append(PetEventOffset(x: x, lift: max(0, up)))
        }
        self.offsets = offsets
        moves = steps.contains { $0.dx != 0 || $0.dy != 0 }
    }

    var duration: TimeInterval { Double(steps.count) / fps }

    /// This event in a column with `room` beads above the floor: rising stops at the top, a pause
    /// plays there, and the descent starts from there at its steps' rate, ending on the floor. A step
    /// that would only press against the top is not played, unless it also moves sideways or is the
    /// last; so the sprite never sits pinned while its paws climb, and an event that fits is itself.
    func fitted(room: Int) -> PetEvent {
        let room = max(0, room)
        guard offsets.contains(where: { $0.lift > room }) else { return self }
        var kept: [PetEventStep] = []
        var lift = 0
        for (index, step) in steps.enumerated() {
            let next = min(offsets[index].lift, room)
            let pinned = next == lift && step.dy != 0 && step.dx == 0
            if pinned, index < steps.count - 1 { continue }
            kept.append(PetEventStep(frame: step.frame, dx: step.dx, dy: lift - next))
            lift = next
        }
        return PetEvent(id: id, fps: fps, frames: frames, steps: kept, palette: palette)
    }

    /// The step `elapsed` seconds in, at this event's rate, staying on the last.
    func stepIndex(elapsed: TimeInterval) -> Int {
        min(steps.count - 1, max(0, Int((elapsed * fps).rounded(.down))))
    }
}
