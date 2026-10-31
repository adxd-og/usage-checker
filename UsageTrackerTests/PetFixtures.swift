import CoreGraphics
import Foundation

/// A small pet that keeps the manifest contract (notch-island spec 2026-10-29 § 3.5): the JSON a
/// `Pets/<animal>/pet.json` holds, built in code so a test can break one rule at a time.
/// "mouse": palettes grey and white with roles o, 1, e; five frames that all paint o at (0, 0),
/// 1 at (1, 0) and e at (34, 34); the five animations; a still per pose; a 26 × 26 ear that
/// paints o at (0, 0) and 1 at (15, 15). The shipped pets are tested where they ship
/// (PetBundleTests, PetAssetsTests).
enum PetFixture {
    static let id = "mouse"

    static let frameRows = rows(side: 35, beads: [(0, 0, "o"), (1, 0, "1"), (34, 34, "e")])
    static let earRows = rows(side: 26, beads: [(0, 0, "o"), (25, 25, "1")])

    static func manifest() -> [String: Any] {
        [
            "id": id,
            "name": "Mouse",
            "size": 35,
            "palettes": [
                "grey": ["o": "#101010", "1": "#808080", "e": "#000000"],
                "white": ["o": "#202020", "1": "#f0f0f0", "e": "#0a0b0c"],
            ],
            "frames": [
                "idle_1": frameRows,
                "blink": frameRows,
                "walk_1": frameRows,
                "look": frameRows,
                "sleep_1": frameRows,
            ],
            "animations": [
                "idle": animation(["idle_1"], fps: 2),
                "blink": animation(["blink"], fps: 6),
                "walk": animation(["walk_1", "idle_1"], fps: 8),
                "look": animation(["look"], fps: 1),
                "sleep": animation(["sleep_1"], fps: 1.5),
            ],
            "still": ["idle": "idle_1", "look": "look", "sleep": "sleep_1"],
            "ear": earRows,
        ]
    }

    static func animation(_ frames: [String], fps: Any) -> [String: Any] {
        ["frames": frames, "fps": fps]
    }

    /// A `side` × `side` map of transparent beads with `beads` painted in.
    static func rows(side: Int, beads: [(x: Int, y: Int, role: Character)]) -> [String] {
        var grid = Array(repeating: Array(repeating: Character("."), count: side), count: side)
        for bead in beads { grid[bead.y][bead.x] = bead.role }
        return grid.map { String($0) }
    }

    /// `object` with the value at `path` replaced, nested objects created on the way; nil
    /// removes the key.
    static func setting(_ path: [String], to value: Any?, in object: [String: Any]) -> [String: Any] {
        guard let key = path.first else { return object }
        var copy = object
        if path.count == 1 {
            copy[key] = value
        } else {
            copy[key] = setting(Array(path.dropFirst()), to: value, in: copy[key] as? [String: Any] ?? [:])
        }
        return copy
    }

    /// The JSON bytes of `object`.
    static func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    /// Writes `object` to `<directory>/<folder>/pet.json`.
    static func write(_ object: [String: Any], folder: String, in directory: URL) throws {
        let folderURL = directory.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try data(object).write(to: folderURL.appendingPathComponent("pet.json"))
    }

    /// The RGBA bytes of the device pixel at column `x`, row `y` (0, 0 = top left).
    static func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8]? {
        guard let cfData = image.dataProvider?.data else { return nil }
        let data = cfData as Data
        let offset = y * image.bytesPerRow + x * image.bitsPerPixel / 8
        guard x >= 0, y >= 0, x < image.width, y < image.height, offset + 4 <= data.count else { return nil }
        return Array(data[offset..<offset + 4])
    }
}
