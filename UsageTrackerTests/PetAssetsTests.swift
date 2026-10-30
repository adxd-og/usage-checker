import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.5 Rendering: the image cache is "owned by the app (not the
/// panel)": one library and one cache for the app's life, loaded from the bundle; every
/// bundled pet draws every frame and its ear head in every palette at Retina scale.
final class PetAssetsTests: XCTestCase {
    @MainActor
    func testTheAppHoldsOneLibraryAndCacheLoadedFromItsBundle() async throws {
        await PetAssetStore.shared.load().value
        let assets = try XCTUnwrap(PetAssetStore.shared.assets)
        await PetAssetStore.shared.load().value
        XCTAssertTrue(PetAssetStore.shared.assets === assets)
        XCTAssertEqual(assets.library.animalIDs, ["cat", "dog", "duck", "raccoon"])
    }

    func testEveryBundledPetDrawsEveryFrameAndItsEarInEveryPalette() throws {
        let assets = PetAssets(library: .bundled())
        let scale = PetScaleRules.scale(beads: 35, fitting: CGSize(width: 150, height: 300), backingScale: 2)
        var drawn = 0
        for (animal, manifest) in assets.library.manifests {
            for palette in manifest.paletteNames {
                let sprites = manifest.frames.keys.map(PetSprite.frame) + [.ear]
                for sprite in sprites {
                    let key = PetSpriteCache.Key(animal: animal, palette: palette, sprite: sprite, pixelsPerBead: scale.pixelsPerBead)
                    let image = try XCTUnwrap(assets.sprites.image(key), "\(animal) \(palette) \(sprite)")
                    let side = sprite == .ear ? PetContract.earSize : manifest.size
                    XCTAssertEqual(image.width, side * 3, "\(animal) \(palette) \(sprite)")
                    drawn += 1
                }
            }
        }
        XCTAssertEqual(assets.library.animalIDs.count, 4)
        XCTAssertEqual(assets.sprites.count, drawn, "each sprite kept once")
    }
}
