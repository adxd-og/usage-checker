import Combine

/// The picker's previews under the pet's own gate (notch-island spec 2026-10-29 § 3.7): the surface is
/// the picker on screen in its window, not occluded; display, lock and Reduce Motion as on the island.
/// Publishes only a change.
@MainActor
final class PetPreviewGateModel: ObservableObject {
    @Published private(set) var conditions = PetAnimationGate.Conditions(
        surfaceOpen: false, windowVisible: false, displayAwake: true, screenLocked: false, reduceMotion: false
    )

    var animates: Bool { PetAnimationGate.animates(conditions) }

    func setShown(_ shown: Bool) { update(\.surfaceOpen, shown) }
    func setWindowVisible(_ visible: Bool) { update(\.windowVisible, visible) }
    func setDisplayAwake(_ awake: Bool) { update(\.displayAwake, awake) }
    func setScreenLocked(_ locked: Bool) { update(\.screenLocked, locked) }
    func setReduceMotion(_ reduced: Bool) { update(\.reduceMotion, reduced) }

    private func update(_ key: WritableKeyPath<PetAnimationGate.Conditions, Bool>, _ value: Bool) {
        guard conditions[keyPath: key] != value else { return }
        conditions[keyPath: key] = value
    }
}
