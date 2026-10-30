import CoreGraphics
import Foundation

/// A char map in a palette, as a bitmap (notch-island spec 2026-10-29 § 3.5 Rendering): each
/// bead a `pixelsPerBead` × `pixelsPerBead` block of device pixels in its role's colour; the
/// transparent bead and any role the palette lacks stay fully transparent. The bytes are
/// written directly, with no drawing call: no antialiasing, no colour matching, no
/// interpolation, so a bead is exactly its palette colour. sRGB, 8 bits per channel, RGBA,
/// premultiplied (every colour is opaque or clear, so premultiplying changes nothing). Pure.
enum PetSpriteRenderer {
    static func image(_ map: PetCharMap, palette: [Unicode.Scalar: PetRGB], pixelsPerBead: Int) -> CGImage? {
        guard pixelsPerBead > 0, map.side > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let width = map.side * pixelsPerBead
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * width)
        for y in 0..<map.side {
            for x in 0..<map.side {
                guard let colour = palette[map.bead(x: x, y: y)] else { continue }
                for row in (y * pixelsPerBead)..<((y + 1) * pixelsPerBead) {
                    var offset = row * bytesPerRow + x * pixelsPerBead * 4
                    for _ in 0..<pixelsPerBead {
                        bytes[offset] = colour.red
                        bytes[offset + 1] = colour.green
                        bytes[offset + 2] = colour.blue
                        bytes[offset + 3] = 255
                        offset += 4
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: width,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
