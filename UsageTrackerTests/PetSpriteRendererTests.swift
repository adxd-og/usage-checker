import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.5 Rendering: one CGImage per frame and palette, drawn
/// without interpolation, each bead a square of whole device pixels in its palette colour
/// (§ 3.9 `PetScaleRules` picks how many); "." draws nothing.
final class PetSpriteRendererTests: XCTestCase {
    private func ginger() throws -> [Unicode.Scalar: PetRGB] {
        let outline = try XCTUnwrap(PetRGB(hex: "#3a1d10"))
        let fur = try XCTUnwrap(PetRGB(hex: "#e8892e"))
        let eye = try XCTUnwrap(PetRGB(hex: "#22110a"))
        return ["o": outline, "1": fur, "e": eye]
    }

    func testEachBeadIsASquareOfWholeDevicePixelsInItsPaletteColour() throws {
        let map = try XCTUnwrap(PetCharMap(rows: ["o1", ".e"], side: 2))
        let palette = try ginger()
        let image = try XCTUnwrap(PetSpriteRenderer.image(map, palette: palette, pixelsPerBead: 3))
        XCTAssertEqual(image.width, 6)
        XCTAssertEqual(image.height, 6)
        for y in 0..<6 {
            for x in 0..<6 {
                let expected: [UInt8] = palette[map.bead(x: x / 3, y: y / 3)].map { [$0.red, $0.green, $0.blue, 255] } ?? [0, 0, 0, 0]
                XCTAssertEqual(PetFixture.pixel(image, x: x, y: y), expected, "pixel (\(x), \(y))")
            }
        }
    }

    func testTheTransparentBeadAndARoleThePaletteLacksDrawNothing() throws {
        let map = try XCTUnwrap(PetCharMap(rows: ["z.", ".o"], side: 2))
        let palette = try ginger()
        let image = try XCTUnwrap(PetSpriteRenderer.image(map, palette: palette, pixelsPerBead: 2))
        XCTAssertEqual(PetFixture.pixel(image, x: 0, y: 0), [0, 0, 0, 0])
        XCTAssertEqual(PetFixture.pixel(image, x: 3, y: 0), [0, 0, 0, 0])
        XCTAssertEqual(PetFixture.pixel(image, x: 3, y: 3), [0x3a, 0x1d, 0x10, 255])
    }

    func testAFullFrameIsItsSideTimesThePixelsPerBead() throws {
        let map = try XCTUnwrap(PetCharMap(rows: PetFixture.frameRows, side: 35))
        let palette = try ginger()
        XCTAssertEqual(PetSpriteRenderer.image(map, palette: palette, pixelsPerBead: 1)?.width, 35)
        let retina = try XCTUnwrap(PetSpriteRenderer.image(map, palette: palette, pixelsPerBead: 3))
        XCTAssertEqual(retina.width, 105)
        XCTAssertEqual(retina.height, 105)
        XCTAssertEqual(PetFixture.pixel(retina, x: 104, y: 104), [0x22, 0x11, 0x0a, 255])
        XCTAssertEqual(PetFixture.pixel(retina, x: 101, y: 101), [0, 0, 0, 0])
    }

    func testTheImageIsSRGBAndNeverInterpolated() throws {
        let map = try XCTUnwrap(PetCharMap(rows: ["o"], side: 1))
        let palette = try ginger()
        let image = try XCTUnwrap(PetSpriteRenderer.image(map, palette: palette, pixelsPerBead: 3))
        XCTAssertFalse(image.shouldInterpolate)
        XCTAssertEqual(image.colorSpace?.name.map { $0 as String }, CGColorSpace.sRGB as String)
        XCTAssertEqual(image.alphaInfo, .premultipliedLast)
        XCTAssertEqual(image.bitsPerComponent, 8)
    }

    func testLessThanOnePixelPerBeadGivesNoImage() throws {
        let map = try XCTUnwrap(PetCharMap(rows: ["o"], side: 1))
        let palette = try ginger()
        XCTAssertNil(PetSpriteRenderer.image(map, palette: palette, pixelsPerBead: 0))
    }
}
