import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.5, "Owner 2026-10-30 (events)", over the built app bundle:
/// whatever events ship keep the contract and draw in every colourway. With no art yet, every test
/// passes on nothing; the session's art commit, which brings all four animals at once, makes them
/// bite, and then every animal must have an event.
final class PetBundleEventTests: XCTestCase {
    func testNoShippedEventWasDropped() {
        for (animal, check) in PetLibrary.bundled().checks {
            let dropped = check.notes.filter(\.isDroppedEvent).map(\.description)
            XCTAssertEqual(dropped, [], animal)
        }
    }

    func testEveryShippedEventKeepsItsLimits() {
        for (animal, manifest) in PetLibrary.bundled().manifests {
            XCTAssertEqual(Set(manifest.events.map(\.id)).count, manifest.events.count, "\(animal): ids")
            for event in manifest.events {
                let name = "\(animal) \(event.id)"
                XCTAssertTrue(PetContract.eventFPS.contains(event.fps), name)
                XCTAssertTrue(PetContract.eventDuration.contains(event.duration), name)
                XCTAssertLessThanOrEqual(event.frames.count, PetContract.eventMaxFrames, name)
                XCTAssertEqual(event.offsets.last, .zero, "\(name) ends where it began")
                XCTAssertLessThanOrEqual(event.offsets.map(\.lift).max() ?? 0, PetContract.eventMaxLift, name)
                XCTAssertLessThanOrEqual(event.offsets.map { abs($0.x) }.max() ?? 0, PetContract.eventMaxDrift, name)
                for step in event.steps {
                    XCTAssertNotNil(event.frames[step.frame], "\(name) step \(step.frame)")
                }
            }
        }
    }

    func testEveryShippedEventDrawsInEveryColourway() {
        let library = PetLibrary.bundled()
        let cache = PetSpriteCache(library: library)
        for (animal, manifest) in library.manifests {
            for palette in manifest.paletteNames {
                for event in manifest.events {
                    for (name, map) in event.frames {
                        let sprite = PetSprite.eventFrame(event: event.id, frame: name)
                        let colours = manifest.colours(palette: palette, for: sprite) ?? [:]
                        XCTAssertTrue(map.roles.isSubset(of: Set(colours.keys)), "\(animal) \(palette) \(sprite)")
                        let key = PetSpriteCache.Key(animal: animal, palette: palette, sprite: sprite, pixelsPerBead: 1)
                        XCTAssertEqual(cache.image(key)?.width, PetContract.size, "\(animal) \(palette) \(sprite)")
                    }
                }
            }
        }
    }

    /// Passes on nothing before the art commit. The art lands for all four animals in one commit.
    func testOnceArtHasLandedEveryAnimalHasAnEvent() {
        let manifests = PetLibrary.bundled().manifests
        guard manifests.values.contains(where: { !$0.events.isEmpty }) else { return }
        for (animal, manifest) in manifests {
            XCTAssertFalse(manifest.events.isEmpty, animal)
        }
    }
}
