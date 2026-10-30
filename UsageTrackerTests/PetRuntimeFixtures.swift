import Foundation
@testable import Omelette

/// The shipped cat's animations and stills as the art package drew them (Pets/cat/pet.json):
/// idle two frames at 2 fps, blink one at 6, walk four at 8, look one at 1, sleep two at 1.5;
/// stills idle_1, look, sleep_1. `PetRuntimeTests` checks the bundle still says so.
enum PetRuntimeFixture {
    static let animations = PetAnimations(
        idle: PetAnimation(frames: ["idle_1", "idle_2"], fps: 2),
        blink: PetAnimation(frames: ["blink"], fps: 6),
        walk: PetAnimation(frames: ["walk_1", "walk_2", "walk_3", "walk_4"], fps: 8),
        look: PetAnimation(frames: ["look"], fps: 1),
        sleep: PetAnimation(frames: ["sleep_1", "sleep_2"], fps: 1.5)
    )
    static let stills = PetStills(idle: "idle_1", look: "look", sleep: "sleep_1")

    /// Monday 2026-10-26 13:48 UTC.
    static let t0 = Date(timeIntervalSince1970: 1_793_022_480)

    /// The floor beside a 35-bead pet in the 150 pt habitat at 1.5 pt a bead: 100 − 35 beads.
    static let roam = 65
}
