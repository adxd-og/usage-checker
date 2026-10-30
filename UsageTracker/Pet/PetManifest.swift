import Foundation

/// The contract every pet folder keeps (notch-island spec 2026-10-29 § 3.5, "Manifest
/// contract"): `Pets/<animal>/pet.json` with exactly these keys, 35 × 35 frames, a 16 × 16 ear
/// head (§ 3.6), five required animations at 0.5–12 fps and a still frame per pose, and may carry
/// `events` (`PetEvent`, the owner's note of 2026-10-30). `PetManifestValidator` checks it.
enum PetContract {
    /// The bundle's folder of pets, under Contents/Resources.
    static let folderName = "Pets"
    static let fileName = "pet.json"
    static let keys = ["id", "name", "size", "palettes", "frames", "animations", "still", "ear"]
    /// Keys a manifest may have beside `keys`.
    static let optionalKeys = ["events"]
    /// Beads per side of every frame.
    static let size = 35
    /// Beads per side of the ear head.
    static let earSize = 16
    static let fps: ClosedRange<Double> = 0.5...12
    /// The bead that draws nothing; never a role.
    static let transparent: Unicode.Scalar = "."
}

/// The animations every pet has (§ 3.5). P5b's runtime picks among them.
enum PetAnimationName: String, CaseIterable, Sendable {
    case idle, blink, walk, look, sleep
}

/// The poses a still frame exists for (the poses of § 3.5's mood table). The manifest keys its
/// stills by pose; P5b maps moods to poses.
enum PetPose: String, CaseIterable, Sendable {
    case idle, look, sleep
}

/// One drawable picture of a pet: a named frame, the 16 × 16 ear head, or a frame of an event
/// (each event names its own frames, so two may both have an "a").
enum PetSprite: Hashable, Sendable, CustomStringConvertible {
    case frame(String)
    case ear
    case eventFrame(event: String, frame: String)

    var description: String {
        switch self {
        case .frame(let name): "frame \(name)"
        case .ear: "ear"
        case .eventFrame(let event, let frame): "event \(event) frame \(frame)"
        }
    }
}

/// A palette colour.
struct PetRGB: Hashable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    /// Exactly "#" and six hex digits, either case; nil for anything else.
    init?(hex: String) {
        let bytes = Array(hex.utf8)
        guard bytes.count == 7, bytes[0] == UInt8(ascii: "#") else { return nil }
        var nibbles: [UInt8] = []
        for byte in bytes.dropFirst() {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): nibbles.append(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): nibbles.append(byte - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): nibbles.append(byte - UInt8(ascii: "A") + 10)
            default: return nil
            }
        }
        red = nibbles[0] << 4 | nibbles[1]
        green = nibbles[2] << 4 | nibbles[3]
        blue = nibbles[4] << 4 | nibbles[5]
    }
}

/// A square map of beads (§ 3.5 "frames (char maps)"). A bead is one Unicode scalar, not one
/// `Character`: the art validator counts code points, and Swift would merge "e" + U+0301 into
/// one `Character` and accept a row the validator rejects.
struct PetCharMap: Equatable, Sendable {
    /// Beads per side.
    let side: Int
    /// Row-major, top row first; `side * side` beads.
    let beads: [Unicode.Scalar]

    /// Nil unless `rows` holds `side` strings of `side` Unicode scalars each.
    init?(rows: [String], side: Int) {
        guard side > 0, rows.count == side else { return nil }
        var beads: [Unicode.Scalar] = []
        beads.reserveCapacity(side * side)
        for row in rows {
            let scalars = Array(row.unicodeScalars)
            guard scalars.count == side else { return nil }
            beads.append(contentsOf: scalars)
        }
        self.side = side
        self.beads = beads
    }

    /// The bead at column `x`, row `y` (0, 0 = top left).
    func bead(x: Int, y: Int) -> Unicode.Scalar { beads[y * side + x] }

    /// The roles the map paints: every bead but the transparent one.
    var roles: Set<Unicode.Scalar> { Set(beads).subtracting([PetContract.transparent]) }
}

/// One animation: its frames in order and its rate (§ 3.5: at least one frame, 0.5–12 fps).
struct PetAnimation: Equatable, Sendable {
    let frames: [String]
    let fps: Double
}

/// The five required animations; the contract check guarantees each.
struct PetAnimations: Equatable, Sendable {
    let idle: PetAnimation
    let blink: PetAnimation
    let walk: PetAnimation
    let look: PetAnimation
    let sleep: PetAnimation

    subscript(name: PetAnimationName) -> PetAnimation {
        switch name {
        case .idle: idle
        case .blink: blink
        case .walk: walk
        case .look: look
        case .sleep: sleep
        }
    }
}

/// The still frame per pose (§ 3.5 `still`): what Reduce Motion and a paused pet draw.
struct PetStills: Equatable, Sendable {
    let idle: String
    let look: String
    let sleep: String

    subscript(pose: PetPose) -> String {
        switch pose {
        case .idle: idle
        case .look: look
        case .sleep: sleep
        }
    }
}

/// One pet, as its folder's `pet.json` describes it, once the contract check passed.
struct PetManifest: Equatable, Sendable {
    /// Its folder's name ("cat").
    let id: String
    /// Display name ("Cat").
    let name: String
    /// Beads per side of every frame.
    let size: Int
    /// Palette name → role (one Unicode scalar) → colour. Every palette colours every role the
    /// frames and the ear use.
    let palettes: [String: [Unicode.Scalar: PetRGB]]
    let frames: [String: PetCharMap]
    let animations: PetAnimations
    let still: PetStills
    /// The 16 × 16 head for the left ear (§ 3.6), in the same palettes.
    let ear: PetCharMap
    /// The events that kept the contract, in the manifest's order.
    let events: [PetEvent]

    /// Palette names, alphabetical. Display order and the default palette are Settings' (P6).
    var paletteNames: [String] { palettes.keys.sorted() }

    func event(id: String) -> PetEvent? {
        events.first { $0.id == id }
    }

    /// The map a sprite names; nil for a frame the manifest does not have.
    func map(_ sprite: PetSprite) -> PetCharMap? {
        switch sprite {
        case .frame(let name): frames[name]
        case .ear: ear
        case .eventFrame(let event, let frame): self.event(id: event)?.frames[frame]
        }
    }

    /// The colours a sprite draws in: the named palette, with an event frame's props merged in
    /// (the same in every colourway). Nil for a palette the pet does not have.
    func colours(palette name: String, for sprite: PetSprite) -> [Unicode.Scalar: PetRGB]? {
        guard let colours = palettes[name] else { return nil }
        guard case .eventFrame(let event, _) = sprite, let props = self.event(id: event)?.palette else {
            return colours
        }
        return colours.merging(props) { _, prop in prop }
    }
}
