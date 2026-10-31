import Combine
import CoreGraphics
import Foundation

/// The ear's head on its way to the habitat pet as the island opens (notch-island spec 2026-10-29
/// § 3.6): about 180 ms, in the island's window coordinates, eased out, opaque until the content
/// starts to come in (`IslandMotion.contentDelay`), then gone. Pure.
struct IslandEarMorph: Equatable, Sendable {
    static let duration: TimeInterval = 0.18

    let start: TimeInterval
    let from: CGRect
    let to: CGRect

    struct Frame: Equatable, Sendable {
        let rect: CGRect
        let opacity: Double
    }

    /// Nil from its end on; the first frame before its start.
    func frame(at now: TimeInterval) -> Frame? {
        let elapsed = max(now - start, 0)
        guard elapsed < Self.duration else { return nil }
        let progress = elapsed / Self.duration
        let eased = CGFloat(1 - pow(1 - progress, 3))
        let fadeFrom = IslandMotion.contentDelay / Self.duration
        return Frame(
            rect: CGRect(
                x: from.minX + (to.minX - from.minX) * eased,
                y: from.minY + (to.minY - from.minY) * eased,
                width: from.width + (to.width - from.width) * eased,
                height: from.height + (to.height - from.height) * eased
            ),
            opacity: progress <= fadeFrom ? 1 : 1 - (progress - fadeFrom) / (1 - fadeFrom)
        )
    }

    /// Only from a head (pet on), with a habitat to land in, and motion allowed.
    static func eligible(mark: IslandEars.LeftMark?, morphEligible: Bool, reduceMotion: Bool) -> Bool {
        mark == .head && morphEligible && !reduceMotion
    }

    /// The pet's place on the floor in the island's window (plan R7); nil before the column is
    /// measured. The habitat starts at the content's padding and the island's top inset.
    static func target(
        contentOrigin: CGPoint, columnHeight: CGFloat?, xBeads: Int, scale: PetScaleRules.Scale
    ) -> CGRect? {
        guard let columnHeight, columnHeight > 0 else { return nil }
        let beads = PetContract.size
        let side = scale.points(beads: beads)
        let origin = PetHabitatRules.origin(
            xBeads: xBeads,
            footY: PetHabitatRules.floorY(height: columnHeight, petSide: side),
            petBeads: beads,
            roamBeads: PetHabitatRules.roamBeads(petBeads: beads, scale: scale),
            scale: scale
        )
        return CGRect(
            x: contentOrigin.x + ProviderGridRules.padding + origin.x,
            y: contentOrigin.y + IslandHeightRules.islandTopInset + origin.y,
            width: side, height: side
        )
    }
}

/// The morph as drawn. Only its layer observes it, so its frames redraw the head, never the content.
@MainActor
final class IslandEarMorphModel: ObservableObject {
    @Published private(set) var frame: IslandEarMorph.Frame?
    private(set) var image: CGImage?
    private(set) var backingScale: CGFloat = 2
    private var morph: IslandEarMorph?

    func start(_ morph: IslandEarMorph, image: CGImage?, backingScale: CGFloat) {
        self.morph = morph
        self.image = image
        self.backingScale = backingScale
        frame = morph.frame(at: morph.start)
    }

    /// One frame of the island's clock; false once it is over.
    @discardableResult
    func advance(to now: TimeInterval) -> Bool {
        guard let morph else { return false }
        let next = morph.frame(at: now)
        if next != frame { frame = next }
        if next == nil { stop() }
        return next != nil
    }

    func stop() {
        morph = nil
        image = nil
        if frame != nil { frame = nil }
    }
}
