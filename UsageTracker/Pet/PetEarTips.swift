import CoreGraphics

/// Which part of a pet's 26 × 26 head peeks out in the notch's breath (notch-island spec 2026-10-29
/// § 3.1, D13): from its first painted row, as many whole beads as `band` points hold. Pure.
struct PetEarTips: Equatable, Sendable {
    /// In the head's image: device pixels, origin at the top left.
    let crop: CGRect
    /// As drawn, in points.
    let size: CGSize

    /// Nil when `band` holds no whole bead or the head paints nothing.
    static func tips(of map: PetCharMap, band: CGFloat, scale: PetScaleRules.Scale) -> PetEarTips? {
        let rows = Int((band / scale.pointsPerBead + 1e-6).rounded(.down))
        guard rows > 0,
              let first = (0..<map.side).first(where: { y in
                  (0..<map.side).contains { x in map.bead(x: x, y: y) != PetContract.transparent }
              })
        else { return nil }
        let shown = min(rows, map.side - first)
        let pixels = scale.pixelsPerBead
        return PetEarTips(
            crop: CGRect(x: 0, y: first * pixels, width: map.side * pixels, height: shown * pixels),
            size: CGSize(width: scale.points(beads: map.side), height: scale.points(beads: shown))
        )
    }

    /// A head built off the main thread is still the one to show when it lands: the pet is on and it
    /// is still this pet. Otherwise a newer call has answered, or will.
    static func stillWanted(builtFor: PetChoice, shownNow: PetChoice?, petOn: Bool) -> Bool {
        petOn && shownNow == builtFor
    }
}
