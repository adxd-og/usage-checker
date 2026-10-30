import CoreGraphics
import Foundation

/// The pets' images (notch-island spec 2026-10-29 § 3.5 Rendering): one `CGImage` per animal ×
/// palette × sprite (frame or ear head) × pixels per bead, built from the library in memory on
/// first use and kept, so an animation frame is a lookup (§ 3.8) and a palette change reads no
/// file. Thread-safe: the habitat (P5c) reads it on the main thread every frame and warms it
/// off the main thread when the pet, the palette or the display changes. A view draws an image
/// with `Image(decorative: image, scale: backingScale).interpolation(.none)` at its natural
/// size (`PetScaleRules.Scale.points(beads:)`), at an origin from `PetScaleRules.snapped`.
final class PetSpriteCache: @unchecked Sendable {
    struct Key: Hashable, Sendable {
        let animal: String
        let palette: String
        let sprite: PetSprite
        let pixelsPerBead: Int
    }

    private let library: PetLibrary
    private let lock = NSLock()
    private var images: [Key: CGImage] = [:]

    init(library: PetLibrary) {
        self.library = library
    }

    /// The image for `key`, built on first use. Nil for an animal, palette or frame the library
    /// does not have, or fewer than one pixel per bead; nothing is kept then. Rendering runs
    /// outside the lock; when two threads build the same image, the first one stored wins.
    func image(_ key: Key) -> CGImage? {
        lock.lock()
        let kept = images[key]
        lock.unlock()
        if let kept { return kept }
        guard let manifest = library.manifests[key.animal],
              let palette = manifest.palettes[key.palette],
              let map = manifest.map(key.sprite),
              let built = PetSpriteRenderer.image(map, palette: palette, pixelsPerBead: key.pixelsPerBead)
        else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let raced = images[key] { return raced }
        images[key] = built
        return built
    }

    /// Builds every frame and the ear head of one pet in one palette at one scale: 11 images,
    /// 450,216 bytes at 3 px per bead. Call it off the main thread for the pet on screen, in its
    /// palette, at the current display's pixels per bead, when one of them changes, so no frame
    /// is built while drawing. Never for the whole roster or other scales: one pet shows at a
    /// time, and the rest is built on first use. An unknown pet builds nothing.
    func prewarm(animal: String, palette: String, pixelsPerBead: Int) {
        guard let manifest = library.manifests[animal] else { return }
        for name in manifest.frames.keys {
            _ = image(Key(animal: animal, palette: palette, sprite: .frame(name), pixelsPerBead: pixelsPerBead))
        }
        _ = image(Key(animal: animal, palette: palette, sprite: .ear, pixelsPerBead: pixelsPerBead))
    }

    /// How many images are kept.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return images.count
    }
}
