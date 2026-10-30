import CoreGraphics

/// How big a pet sprite is drawn and where (notch-island spec 2026-10-29 § 3.5 Rendering,
/// § 3.9 `PetScaleRules`). A bead is a whole number of device pixels: the most that keeps a
/// bead at 1.5 pt or less (35 beads → 52.5 pt, the pet's design size) and the sprite inside
/// the box it is drawn in, never fewer than one. 3 px at 2× gives 52.5 pt; at 1× two pixels
/// would make 70 pt, so one, 35 pt. The origin sits on the device-pixel grid and animation
/// offsets are whole beads, so every bead edge lands on a pixel edge. Pure.
enum PetScaleRules {
    struct Scale: Equatable, Sendable {
        /// Device pixels per bead side; the sprite cache renders at this size.
        let pixelsPerBead: Int
        /// Device pixels per point of the display drawn on (1 when it was not a positive number).
        let backingScale: CGFloat

        /// Points per bead: 1.5 with 3 px at 2×, 1 with 1 px at 1×.
        var pointsPerBead: CGFloat { CGFloat(pixelsPerBead) / backingScale }

        /// `beads` beads in points: a sprite's side, or an animation offset (whole beads only).
        func points(beads: Int) -> CGFloat { CGFloat(beads) * pointsPerBead }
    }

    /// The pet's design size per bead (spec § 3.5: 35 beads drawn at 52.5 pt).
    static let maxPointsPerBead: CGFloat = 1.5

    /// Absorbs float error so 52.5 pt × 2 / 35 counts as the 3 it is.
    private static let tolerance: CGFloat = 1e-6

    /// The scale for a sprite `beads` wide drawn in `box` (points) on a display at
    /// `backingScale`. A box that is not a finite number (not measured yet) limits nothing; a
    /// box too small for one pixel per bead still gets one.
    static func scale(beads: Int, fitting box: CGSize, backingScale: CGFloat) -> Scale {
        let scale = usable(backingScale)
        let byDesign = (maxPointsPerBead * scale + tolerance).rounded(.down)
        let side = min(box.width, box.height)
        let byBox = beads > 0 && side.isFinite
            ? (side * scale / CGFloat(beads) + tolerance).rounded(.down)
            : byDesign
        return Scale(pixelsPerBead: Int(max(1, min(byDesign, byBox))), backingScale: scale)
    }

    /// `point` moved to the nearest device pixel. Pass it in the window's coordinates, so the
    /// grid is the window's.
    static func snapped(_ point: CGPoint, backingScale: CGFloat) -> CGPoint {
        let scale = usable(backingScale)
        return CGPoint(x: (point.x * scale).rounded() / scale, y: (point.y * scale).rounded() / scale)
    }

    private static func usable(_ backingScale: CGFloat) -> CGFloat {
        backingScale.isFinite && backingScale > 0 ? backingScale : 1
    }
}
