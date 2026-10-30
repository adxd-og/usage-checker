import Combine
import Foundation

/// The pets' manifests and their images, owned by the app for its whole life (notch-island spec
/// 2026-10-29 § 3.5 Rendering: "a cache owned by the app (not the panel)"). The island's window
/// and views come and go; the library and the images stay. `PetAssetStore` holds the app's one.
final class PetAssets: Sendable {
    let library: PetLibrary
    let sprites: PetSpriteCache

    init(library: PetLibrary) {
        self.library = library
        sprites = PetSpriteCache(library: library)
    }
}

/// The app's one `PetAssets`, read once off the main thread (Codex's P5d plan review 5): with forty
/// events the manifests are too large to parse during the island's opening motion, and a singleton
/// read in the background would still make an early open initialize it or wait for it. So there is
/// no synchronous way to it: `assets` is nil until the read is done, and the habitat shows a bare
/// column until then. Only the habitat observes this store.
@MainActor
final class PetAssetStore: ObservableObject {
    static let shared = PetAssetStore()

    /// Nil until loaded.
    @Published private(set) var assets: PetAssets?

    private let read: @Sendable () -> PetAssets
    private var loading: Task<Void, Never>?

    init(read: @escaping @Sendable () -> PetAssets = { PetAssets(library: .bundled()) }) {
        self.read = read
    }

    /// Starts the read, once; later calls return the same task. `IslandController` calls it at launch.
    @discardableResult
    func load() -> Task<Void, Never> {
        if let loading { return loading }
        let read = self.read
        let task = Task { [weak self] in
            let assets = await Task.detached(priority: .utility) { read() }.value
            self?.assets = assets
        }
        loading = task
        return task
    }
}
