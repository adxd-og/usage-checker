import Foundation

/// The pets' manifests and their images, owned by the app for its whole life (notch-island spec
/// 2026-10-29 § 3.5 Rendering: "a cache owned by the app (not the panel)"). The island's window
/// and views come and go; the library and the images stay. Loaded from the bundle on first
/// use. P5b's runtime reads `library` (animations, fps, stills); P5c's habitat and P6's ears
/// and Settings previews draw from `sprites`.
final class PetAssets: Sendable {
    let library: PetLibrary
    let sprites: PetSpriteCache

    init(library: PetLibrary) {
        self.library = library
        sprites = PetSpriteCache(library: library)
    }

    /// The app's one instance, read from Contents/Resources/Pets.
    static let shared = PetAssets(library: .bundled())
}
