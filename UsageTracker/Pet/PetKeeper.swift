import Combine
import Foundation

/// The app's one pet runtime, outside every view (notch-island spec 2026-10-29 § 3.5 Runtime:
/// "owned by the app, survives panel re-creation"). It reads every snapshot the app publishes
/// from launch, island open or not, so a limit reset seen in a live poll makes the pet stretch
/// once and a relaunch never does (`PetResetWatch`); it starts and banks the visible open time
/// when the gate turns on and off (`IslandPetModel` turns it, the moment a condition changes);
/// and it hands the habitat the frame of each moment while, and only while, the gate is on:
/// `PetRuntime.tick` resumes the visible clock, so a paused runtime is never ticked. Not
/// observable: the habitat pulls `frame` from its `TimelineView` content, which mutates the
/// runtime, and nothing published may change while a view draws.
@MainActor
final class PetKeeper {
    private(set) var runtime: PetRuntime
    /// The gate is on (`PetAnimationGate`): the visible clock runs and frames tick it.
    private(set) var isAnimating = false
    /// What the user is doing on the island, read at each frame (`IslandController`): the pointer
    /// over the right column, a field being edited. Nothing, without a controller.
    var activity: @MainActor () -> PetUserActivity = { .none }
    /// The time a poll is read at.
    private let clock: @MainActor () -> Date
    private var polls: AnyCancellable?

    init(random: PetRandom, clock: @escaping @MainActor () -> Date = { Date() }) {
        runtime = PetRuntime(random: random)
        self.clock = clock
    }

    /// Every snapshot's services from launch on (`AppState.$snapshot`). Only live readings count
    /// (`PetResetWatch`), so the launch seed and a retained provider bring no stretch.
    /// `@Published` sends on the main actor: `AppState` is `@MainActor`.
    func watch<P: Publisher>(_ services: P) where P.Output == [ServiceSnapshot], P.Failure == Never {
        polls = services.sink { [weak self] services in
            guard let keeper = self else { return }
            MainActor.assumeIsolated {
                keeper.runtime.observe(services, now: keeper.clock())
            }
        }
    }

    /// The gate turned on or off: a visible period starts, or ends with its time banked and a
    /// running bit dropped. The same state again does nothing.
    func setAnimating(_ on: Bool, at now: Date) {
        guard on != isAnimating else { return }
        isAnimating = on
        if on {
            runtime.resume(at: now)
        } else {
            runtime.pause(at: now)
        }
    }

    /// The frame at `now` for the mood's pose and loop while the gate is on; nil while it is off.
    func frame(
        at now: Date, presentation: PetMoodPresentation, animations: PetAnimations, roamBeads: Int,
        events: [PetEvent] = [], liftRoom: Int = PetContract.eventMaxLift
    ) -> PetFrame? {
        guard isAnimating else { return nil }
        return runtime.tick(
            at: now, pose: presentation.pose, loops: presentation.loops,
            activity: activity(), animations: animations, roamBeads: roamBeads,
            events: events, liftRoom: liftRoom
        )
    }

    /// A pat (§ 3.5 Mood rule, rows 5 and 7): its heart for 1.2 s.
    func pat(at now: Date) {
        runtime.pat(at: now)
    }

    #if DEBUG
    /// Debug's menu: plays this event from the next frame; false, and nothing asked, while the gate
    /// is off (Reduce Motion among others).
    @discardableResult
    func play(eventID: String) -> Bool {
        playAll(eventIDs: [eventID])
    }

    /// Debug's menu: plays these in order from the next frame; a gate-off drops the rest.
    @discardableResult
    func playAll(eventIDs: [String]) -> Bool {
        guard isAnimating else { return false }
        runtime.play(eventIDs)
        return true
    }

    /// Debug's menu: the animal changed, and its events are not this one's.
    func dropEvents() {
        runtime.dropEvents()
    }
    #endif

    /// The heart is up at `now`, for a still pet too.
    func showsHeart(at now: Date) -> Bool {
        runtime.showsHeart(at: now)
    }
}
