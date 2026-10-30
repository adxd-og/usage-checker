import Foundation

/// A bit: a short act between the pose's own frames (notch-island spec 2026-10-29 § 3.5
/// Runtime: the idle loop's "walk, sit, blink, nap", sitting being the idle pose itself, and
/// "one stretch per limit reset").
enum PetBit: Equatable, Sendable {
    /// Walks toward the habitat's farther edge, a bead a frame, at most `PetRuntime.walkBeads`.
    case walk
    /// Blinks once.
    case blink
    /// Naps for `PetRuntime.napCycles` sleep cycles.
    case nap
    /// A limit reset seen in a live poll. The manifests draw no stretch: it plays the look
    /// frame for one cycle (1 s).
    case stretch

    /// The manifest animation it plays.
    var animation: PetAnimationName {
        switch self {
        case .walk: .walk
        case .blink: .blink
        case .nap: .sleep
        case .stretch: .look
        }
    }
}

extension PetPose {
    /// The animation a pose plays while no bit does.
    var animation: PetAnimationName {
        switch self {
        case .idle: .idle
        case .look: .look
        case .sleep: .sleep
        }
    }
}

/// What the user is doing on the island: no bit starts, and a running one stops, while the
/// pointer is over the right column or a field has focus (§ 3.5 Runtime).
struct PetUserActivity: Equatable, Sendable {
    var pointerOverContent = false
    var fieldFocused = false

    var isBusy: Bool { pointerOverContent || fieldFocused }

    static let none = PetUserActivity()
}

/// The habitat at one moment.
struct PetFrame: Equatable, Sendable {
    /// The manifest frame to draw.
    let frame: String
    /// The playing animation's rate: the habitat's `TimelineView` runs at it (§ 3.8).
    let fps: Double
    /// Where the pet stands: beads from the habitat's left edge.
    let xBeads: Int
    /// Drawn mirrored: the last walk went left.
    let facesLeft: Bool
    /// The bit playing; nil while the pose's own animation does.
    let bit: PetBit?
    /// A pat's heart is up.
    let showsHeart: Bool
}

/// The pet's life inside its mood (notch-island spec 2026-10-29 § 3.5 Runtime, § 3.9
/// `PetRuntime`): which frame shows, where on the floor, when the idle loop plays a bit, the
/// stretch after a limit reset and the pat. One per app, so it outlives the panel: the visible
/// open time, the next bit's deadline, where the pet stands, the last reset per window and the
/// pat carry from one open to the next. Time comes in as `now`, chance from an injected
/// `PetRandom`; nothing here starts a timer. `PetKeeper` owns it: it calls `resume` and
/// `pause` when the island's `PetAnimationGate` turns on and off, and `tick` when the habitat
/// pulls a frame from its one `TimelineView` while the gate is on, at the returned frame's
/// `fps`; every poll reaches it through `observe`. Motion never leaves the habitat: the pet stays within `roamBeads` of floor and
/// moves in whole beads. Pure.
struct PetRuntime {
    /// The farthest a walk goes: 16 beads, 2 s at the walk's 8 fps.
    static let walkBeads = 16
    /// A nap in sleep cycles: 2.7 s at two frames and 1.5 fps.
    static let napCycles = 2
    /// How long a pat's heart stays up (§ 3.5: "a pat (♥ 1.2 s)").
    static let patDuration: TimeInterval = 1.2

    private let random: PetRandom
    /// The visible open time and the next bit's deadline.
    private(set) var clock: PetBitClock
    /// Each live window's last reset time, and the resets already stretched for.
    private(set) var resets = PetResetWatch()
    /// Beads from the habitat's left edge, 0 … the floor's `roamBeads`.
    private(set) var xBeads = 0
    /// The last walk went left: the pet is drawn mirrored.
    private(set) var facesLeft = false
    /// When a live poll showed a reset the pet has not stretched for yet. It waits for the next
    /// slot of an open, however long the island stayed closed (owner, 2026-10-30).
    private(set) var stretchSeenAt: Date?
    /// Until when a pat's heart is up.
    private(set) var patUntil: Date?
    /// The pose's own animation and since when; nil after a pause, a bit or a pat, so it starts
    /// again from its first frame.
    private var base: Base?
    private var running: Running?

    private struct Base {
        let pose: PetPose
        let since: Date
    }

    private struct Running {
        let bit: PetBit
        let since: Date
        let until: Date
        /// A walk's start, direction (−1 left, +1 right) and length in beads.
        let fromX: Int
        let step: Int
        let beads: Int
    }

    init(random: PetRandom) {
        self.random = random
        clock = PetBitClock(random: random)
    }

    // MARK: - Visibility

    /// The gate turned on: a visible period starts, its first bit due 2–4 s into it; its first
    /// 1.5 s see no bit.
    mutating func resume(at now: Date) {
        clock.resume(at: now, random: random)
    }

    /// The gate turned off: the period's time is banked, a running bit ends where it is, and
    /// the pose's animation starts from its first frame next time.
    mutating func pause(at now: Date) {
        clock.pause(at: now)
        running = nil
        base = nil
    }

    // MARK: - Polls

    /// Every poll's services (`AppState.snapshot.services`), island open or not: a limit reset
    /// seen in a live poll makes the pet stretch once, the next time it may.
    mutating func observe(_ services: [ServiceSnapshot], now: Date) {
        if !resets.observe(services, now: now).isEmpty { stretchSeenAt = now }
    }

    // MARK: - Pat

    /// A pat (§ 3.5 Mood rule, D11): its heart is up for 1.2 s, a running bit stops, and the next
    /// slot (a waiting stretch's too) is due 7–10 s of visible time later, so nothing starts under
    /// the heart.
    mutating func pat(at now: Date) {
        patUntil = now.addingTimeInterval(Self.patDuration)
        running = nil
        base = nil
        clock.reschedule(at: now, random: random)
    }

    /// The heart is up at `now`: for a still pet too (Reduce Motion), which the habitat draws
    /// without a timeline.
    func showsHeart(at now: Date) -> Bool {
        patUntil.map { now < $0 } ?? false
    }

    // MARK: - Stills

    /// The frame while the gate is off, the entrance included (§ 3.5: "otherwise the still
    /// frame"): the current mood's pose's still, whatever played before, so Reduce Motion never
    /// keeps an old pose.
    static func still(pose: PetPose, stills: PetStills) -> String {
        stills[pose]
    }

    // MARK: - Frames

    /// The frame at `now` for a mood showing `pose`; `loops`: the mood runs the idle loop (Idle,
    /// Agent working: `PetMoodRules.runsIdleLoop`), where bits, the stretch and the pat's heart
    /// play. `activity` is the user's, `animations` the pet's, `roamBeads` the floor beside
    /// the pet in beads (the habitat's width in beads less the pet's).
    mutating func tick(
        at now: Date,
        pose: PetPose,
        loops: Bool,
        activity: PetUserActivity,
        animations: PetAnimations,
        roamBeads: Int
    ) -> PetFrame {
        clock.resume(at: now, random: random)
        let roam = max(0, roamBeads)
        xBeads = min(xBeads, roam)
        if let until = patUntil, now >= until { patUntil = nil }
        let patted = loops && patUntil != nil
        let quiet = activity.isBusy

        if let current = running {
            if quiet || !loops {
                endBit()
            } else if now >= current.until {
                if current.bit == .walk {
                    xBeads = clamped(current.fromX + current.step * current.beads, roam: roam)
                }
                endBit()
            }
        }

        // The next due slot: a waiting stretch takes it, else a walk, a blink or a nap.
        if running == nil, !quiet, loops, clock.isDue(at: now) {
            if stretchSeenAt != nil {
                stretchSeenAt = nil
                start(.stretch, at: now, animations: animations, roam: roam)
            } else {
                let kinds: [PetBit] = roam > 0 ? [.walk, .blink, .nap] : [.blink, .nap]
                start(kinds[random.index(below: kinds.count)], at: now, animations: animations, roam: roam)
            }
        }

        if let current = running {
            let animation = animations[current.bit.animation]
            let elapsed = max(0, now.timeIntervalSince(current.since))
            if current.bit == .walk {
                let steps = min(current.beads, Int((elapsed * animation.fps).rounded(.down)))
                xBeads = clamped(current.fromX + current.step * steps, roam: roam)
            }
            return show(animation, elapsed: elapsed, bit: current.bit, heart: patted)
        }

        if base?.pose != pose { base = Base(pose: pose, since: now) }
        let since = base?.since ?? now
        return show(
            animations[pose.animation], elapsed: max(0, now.timeIntervalSince(since)),
            bit: nil, heart: patted
        )
    }

    // MARK: - Private

    private mutating func start(_ bit: PetBit, at now: Date, animations: PetAnimations, roam: Int) {
        let animation = animations[bit.animation]
        let cycle = Double(animation.frames.count) / animation.fps
        var step = 0
        var beads = 0
        let duration: TimeInterval
        switch bit {
        case .walk:
            step = xBeads * 2 > roam ? -1 : 1
            beads = min(Self.walkBeads, step < 0 ? xBeads : roam - xBeads)
            facesLeft = step < 0
            duration = Double(beads) / animation.fps
        case .blink, .stretch:
            duration = cycle
        case .nap:
            duration = Double(Self.napCycles) * cycle
        }
        running = Running(
            bit: bit, since: now, until: now.addingTimeInterval(duration),
            fromX: xBeads, step: step, beads: beads
        )
        base = nil
        clock.reschedule(at: now, random: random)
    }

    private mutating func endBit() {
        running = nil
        base = nil
    }

    private func show(
        _ animation: PetAnimation,
        elapsed: TimeInterval,
        bit: PetBit?,
        heart: Bool
    ) -> PetFrame {
        let index = Int((elapsed * animation.fps).rounded(.down)) % animation.frames.count
        return PetFrame(
            frame: animation.frames[index], fps: animation.fps, xBeads: xBeads,
            facesLeft: facesLeft, bit: bit, showsHeart: heart
        )
    }

    private func clamped(_ x: Int, roam: Int) -> Int {
        min(roam, max(0, x))
    }
}
