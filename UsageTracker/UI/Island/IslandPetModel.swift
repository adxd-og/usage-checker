import Combine
import Foundation

/// What the island tells its pet (notch-island spec 2026-10-29 § 3.5 "Animate only when", § 3.8,
/// "Jump from the island"): the gate's conditions the island knows — its transition open, the
/// habitat on screen, its window on screen, the display awake, the screen unlocked, Reduce
/// Motion off — and the jumps that may close it. Owned by `IslandController` for the app's life;
/// only the habitat observes it, so a gate edge redraws the habitat, never the right column. It
/// publishes only a change, and every change of the gate pauses or resumes the app's pet runtime
/// at that moment, whether or not any view draws (Codex review 4).
@MainActor
final class IslandPetModel: ObservableObject {
    /// The island's transition is `open` (`PetAnimationGate.islandOpen`).
    @Published private(set) var islandOpen = false
    /// The habitat is in the island's content: the screen is wide enough and the pet is on.
    @Published private(set) var habitatShown = false
    @Published private(set) var windowVisible = false
    @Published private(set) var displayAwake = true
    @Published private(set) var screenLocked = false
    @Published private(set) var reduceMotion = false

    /// The app's one pet runtime: its visible clock starts and stops here.
    let keeper: PetKeeper
    /// Closes the island with its motion: the controller's; nothing in previews.
    var closeIsland: @MainActor () -> Void = {}

    private let clock: @MainActor () -> Date
    /// A jump from the island: the open it started in and its number.
    private struct JumpTicket: Equatable, Sendable {
        let open: Int
        let jump: Int
    }
    private var opens = 0
    private var jumps = 0
    private var latestJump: JumpTicket?

    init(keeper: PetKeeper, clock: @escaping @MainActor () -> Date = { Date() }, choice: PetChoice = .standard) {
        self.keeper = keeper
        self.clock = clock
        self.choice = choice
    }

    /// The gate's conditions: the surface is the island open with its habitat drawn.
    var conditions: PetAnimationGate.Conditions {
        PetAnimationGate.Conditions(
            surfaceOpen: islandOpen && habitatShown,
            windowVisible: windowVisible,
            displayAwake: displayAwake,
            screenLocked: screenLocked,
            reduceMotion: reduceMotion
        )
    }

    var animates: Bool { PetAnimationGate.animates(conditions) }

    // MARK: - The pet shown

    /// The user's choice as stored (Settings › Pet, § 3.7), stale or not: `shown(in:)` makes it real.
    @Published private(set) var choice: PetChoice

    /// The pet shown changed: the head and the ear tips follow. Nothing without a controller.
    var onPetChange: @MainActor () -> Void = {}

    /// Settings › Pet chose. The old pet's events are not this one's, so they end here. In Debug the
    /// menu's animal gives way: the latest word wins (plan ruling R2).
    func setChoice(_ next: PetChoice) {
        #if DEBUG
        let overridden = debugAnimal != nil
        if overridden { debugAnimal = nil }
        #else
        let overridden = false
        #endif
        guard overridden || choice != next else { return }
        choice = next
        keeper.dropEvents()
        onPetChange()
    }

    #if DEBUG
    /// The animal Debug's menu chose; in memory only.
    @Published private(set) var debugAnimal: String?

    /// Debug's menu: another animal. The old one's events are not this one's, so they end here.
    func showDebugAnimal(_ id: String) {
        guard animal != id else { return }
        debugAnimal = id
        keeper.dropEvents()
        onPetChange()
    }
    #endif

    /// The animal asked for, before the library has its say.
    var animal: String {
        #if DEBUG
        return debugAnimal ?? choice.animal
        #else
        return choice.animal
        #endif
    }

    /// The animal and palette to draw out of `library`, always a pair it has; nil with no pets.
    func shown(in library: PetLibrary) -> PetChoice? {
        #if DEBUG
        if let debugAnimal, let manifest = library.manifests[debugAnimal] {
            return PetChoice(animal: debugAnimal, palette: PetDebugMenuRules.palette(of: manifest))
        }
        #endif
        return PetChoiceRules.resolved(choice, in: library)
    }

    // MARK: - The gate

    /// The island's transition phase, on every frame of a motion and at its end.
    func show(phase: IslandTransition.Phase) {
        let open = PetAnimationGate.islandOpen(phase)
        guard islandOpen != open else { return }
        islandOpen = open
        gateMoved()
    }

    func setHabitatShown(_ shown: Bool) {
        guard habitatShown != shown else { return }
        habitatShown = shown
        gateMoved()
    }

    func setWindowVisible(_ visible: Bool) {
        guard windowVisible != visible else { return }
        windowVisible = visible
        gateMoved()
    }

    func setDisplayAwake(_ awake: Bool) {
        guard displayAwake != awake else { return }
        displayAwake = awake
        gateMoved()
    }

    func setScreenLocked(_ locked: Bool) {
        guard screenLocked != locked else { return }
        screenLocked = locked
        gateMoved()
    }

    func setReduceMotion(_ reduced: Bool) {
        guard reduceMotion != reduced else { return }
        reduceMotion = reduced
        gateMoved()
    }

    /// A condition changed: the runtime's visible clock follows the gate now (`setAnimating` does
    /// nothing when the gate did not turn).
    private func gateMoved() {
        keeper.setAnimating(animates, at: clock())
    }

    // MARK: - Jumps (§ 3.5, Jump from the island; Codex review 3)

    /// The island opened, a turned-around close included: a jump started before can no longer
    /// close it.
    func islandOpened() {
        opens += 1
        latestJump = nil
    }

    /// The island started closing.
    func islandClosed() {
        latestJump = nil
    }

    /// A jump from the island starts. Call the returned action once it landed: it closes the island
    /// only if no newer jump started and the island has not closed or reopened since.
    func jumpStarted() -> @MainActor @Sendable () -> Void {
        jumps += 1
        let ticket = JumpTicket(open: opens, jump: jumps)
        latestJump = ticket
        return { [weak self] in
            self?.landed(ticket)
        }
    }

    private func landed(_ ticket: JumpTicket) {
        guard latestJump == ticket, ticket.open == opens else { return }
        latestJump = nil
        closeIsland()
    }
}
