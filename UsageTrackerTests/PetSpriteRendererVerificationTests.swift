import CoreGraphics
import XCTest
@testable import Omelette

/// Verification of notch-island spec 2026-10-29 § 3.5 Rendering: a bead is exactly its palette
/// colour over whole device pixels, a transparent bead draws nothing, and the bitmap says what
/// it holds so the system draws it as written. The whole buffer is compared with an
/// independently computed one, at every pixel density a display has.
final class PetSpriteRendererVerificationTests: XCTestCase {
    private func bytes(of image: CGImage) throws -> [UInt8] {
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        return Array(data)
    }

    /// What the buffer of `map` in `palette` at `px` must hold, pixel by pixel.
    private func expected(_ map: PetCharMap, _ palette: [Unicode.Scalar: PetRGB], px: Int) -> [UInt8] {
        var out: [UInt8] = []
        for y in 0..<(map.side * px) {
            for x in 0..<(map.side * px) {
                if let colour = palette[map.bead(x: x / px, y: y / px)] {
                    out += [colour.red, colour.green, colour.blue, 255]
                } else {
                    out += [0, 0, 0, 0]
                }
            }
        }
        return out
    }

    private func scrambled(side: Int) throws -> PetCharMap {
        let alphabet = Array(".o1e.w.")
        var seed: UInt64 = 0x9E3779B97F4A7C15
        let rows = (0..<side).map { _ in
            String((0..<side).map { _ -> Character in
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return alphabet[Int(seed >> 33) % alphabet.count]
            })
        }
        return try XCTUnwrap(PetCharMap(rows: rows, side: side))
    }

    private let palette: [Unicode.Scalar: PetRGB] = [
        "o": PetRGB(hex: "#000000")!, "1": PetRGB(hex: "#FF8000")!, "e": PetRGB(hex: "#0a0B0c")!, "w": PetRGB(hex: "#ffffff")!,
    ]

    func testTheWholeBufferIsTheMapScaledByWholeBeadsAtEveryDensity() throws {
        for side in [16, 35] {
            let map = try scrambled(side: side)
            for px in 1...4 {
                let image = try XCTUnwrap(PetSpriteRenderer.image(map, palette: palette, pixelsPerBead: px))
                XCTAssertEqual(image.width, side * px)
                XCTAssertEqual(image.height, side * px)
                XCTAssertEqual(image.bytesPerRow, side * px * 4, "no padding between rows")
                XCTAssertEqual(try bytes(of: image), expected(map, palette, px: px), "\(side) beads at \(px) px")
            }
        }
    }

    func testABlackRoleIsOpaqueBlackAndATransparentBeadIsAllZero() throws {
        let map = try XCTUnwrap(PetCharMap(rows: ["o.", ".o"], side: 2))
        let image = try XCTUnwrap(PetSpriteRenderer.image(map, palette: palette, pixelsPerBead: 1))
        XCTAssertEqual(try bytes(of: image), [0, 0, 0, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255])
    }

    /// The declared layout must be the actual one: drawn into an sRGB RGBA context by the system,
    /// the image gives back the bytes it was built from, so the channel order and the alpha
    /// convention the CGImage names are the ones the buffer has.
    func testTheSystemDrawsTheBitmapBackAsWritten() throws {
        let map = try scrambled(side: 16)
        let image = try XCTUnwrap(PetSpriteRenderer.image(map, palette: palette, pixelsPerBead: 3))
        let width = image.width
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: width, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: width))
        let drawn = try XCTUnwrap(context.data)
        let read = Array(UnsafeBufferPointer(start: drawn.assumingMemoryBound(to: UInt8.self), count: width * width * 4))
        XCTAssertEqual(read, expected(map, palette, px: 3))
    }

    func testTheImageOutlivesTheMapAndThePaletteItWasBuiltFrom() throws {
        var image: CGImage?
        autoreleasepool {
            let map = PetCharMap(rows: ["o1", "e."], side: 2)!
            let colours = palette
            image = PetSpriteRenderer.image(map, palette: colours, pixelsPerBead: 2)
        }
        for _ in 0..<50 { _ = [UInt8](repeating: 0xAA, count: 1 << 16) }
        let kept = try XCTUnwrap(image)
        XCTAssertEqual(PetFixture.pixel(kept, x: 0, y: 0), [0, 0, 0, 255])
        XCTAssertEqual(PetFixture.pixel(kept, x: 3, y: 0), [0xFF, 0x80, 0, 255])
        XCTAssertEqual(PetFixture.pixel(kept, x: 1, y: 3), [0x0a, 0x0b, 0x0c, 255])
        XCTAssertEqual(PetFixture.pixel(kept, x: 3, y: 3), [0, 0, 0, 0])
    }

    func testEverySpriteOfEveryShippedPetInEveryPaletteIsItsMapInItsColours() throws {
        let library = PetLibrary.bundled()
        var checked = 0
        for (animal, pet) in library.manifests.sorted(by: { $0.key < $1.key }) {
            for paletteName in pet.paletteNames {
                let colours = try XCTUnwrap(pet.palettes[paletteName])
                for sprite in pet.frames.keys.sorted().map(PetSprite.frame) + [.ear] {
                    let map = try XCTUnwrap(pet.map(sprite))
                    let image = try XCTUnwrap(PetSpriteRenderer.image(map, palette: colours, pixelsPerBead: 3), "\(animal) \(paletteName) \(sprite)")
                    XCTAssertEqual(try bytes(of: image), expected(map, colours, px: 3), "\(animal) \(paletteName) \(sprite)")
                    checked += 1
                }
            }
        }
        XCTAssertEqual(checked, 4 * 3 * 11)
    }

    func testAMapWithNoBeadsAtAllIsRefusedAndOneWithNoColoursIsClear() throws {
        let map = try XCTUnwrap(PetCharMap(rows: ["oo", "oo"], side: 2))
        let clear = try XCTUnwrap(PetSpriteRenderer.image(map, palette: [:], pixelsPerBead: 2))
        XCTAssertEqual(try bytes(of: clear), [UInt8](repeating: 0, count: 4 * 4 * 4))
        XCTAssertNil(PetSpriteRenderer.image(map, palette: palette, pixelsPerBead: -1))
    }
}
