import SwiftUI

/// How the content draws a moment of a page move (notch-island spec 2026-10-29 § 3.2,
/// Drill-down; prototype v9's numbers). The reveal: the page shows only inside a rect that
/// grows from its tile's frame to the whole page, its corner going from the tile's 18 to 0, over
/// the tile's own surface, which fades as it grows; the page's words fade in and rise late; All
/// fades out early and shrinks a little toward the tile, whose own copy is not drawn while the
/// page stands in its place. Back is the same backwards. Without a tile the pages cross-fade,
/// the outgoing one sinking and the incoming one rising 8 pt; Reduce Motion only cross-fades.
/// Every layer's look depends only on how far the move is between its two pages, and the layer
/// order only on the pages, so a reversal (§ 3.2, Interrupt) changes nothing on screen. The page
/// more than half in is the one shown: it takes the clicks and VoiceOver, and the strip and the
/// meta line follow it. The lower row shows the destination from the first frame; it and the
/// stage each go from one page's height to the other's, so the column never jumps, and the
/// height rules are told both as drawn (`moveHeights`). Pure.
enum IslandDrillLook {
    typealias Page = IslandNavigation.Page

    /// One page's layer at one moment.
    struct Layer: Equatable, Sendable {
        /// The whole layer.
        var opacity: Double = 1
        /// The page's words and numbers, apart from the growing tile's surface.
        var contentOpacity: Double = 1
        /// How far below its place the content is; it rises as it comes in.
        var contentOffsetY: CGFloat = 0
        /// All shrinks a little toward the tile a page grows out of.
        var scale: CGFloat = 1
        var anchor: UnitPoint = .center
        /// The reveal: only this rect of the layer shows, in `clipRadius` corners; nil: all of it.
        var clip: CGRect?
        var clipRadius: CGFloat = 0
        /// The tile's surface behind a page growing out of it.
        var surfaceOpacity: Double = 0
        /// Takes clicks and is read by VoiceOver: the page shown.
        var interactive = true

        /// A page at rest.
        static let whole = Layer()
    }

    // MARK: Numbers (prototype v9)

    /// All is gone by 1 / 1.8 of the way in.
    static let allFadeRate: Double = 1.8
    /// How much All shrinks toward the tile by the end of a reveal.
    static let allShrink: CGFloat = 0.03
    /// The page's words come in from a quarter of the way, over half of it ...
    static let contentInStart: Double = 0.25
    static let contentInSpan: Double = 0.5
    /// ... rising this far.
    static let contentRise: CGFloat = 6
    /// The source tile is not drawn once its page has grown this far out of it.
    static let tileHiddenDepth: Double = 0.02
    /// The strip's "‹ All" and logos come in from 0.3 of the way, over half of it.
    static let navigationFadeStart: Double = 0.3
    static let navigationFadeSpan: Double = 0.5

    private static let hidden = Layer(opacity: 0, interactive: false)

    // MARK: Which page

    /// The page shown: the one moved to once the move is half done, the one left before.
    static func shownPage(_ frame: IslandDrill.Frame) -> Page {
        guard frame.isMoving else { return frame.to }
        return frame.progress >= 0.5 ? frame.to : frame.from
    }

    /// The provider whose tile a reveal grows from or goes back into; nil for any other move.
    static func revealedProvider(_ frame: IslandDrill.Frame) -> String? {
        guard frame.isMoving, frame.motion == .reveal else { return nil }
        switch (frame.from, frame.to) {
        case (.all, .provider(let id)), (.provider(let id), .all): return id
        default: return nil
        }
    }

    /// How far a reveal's page is in: the progress toward it, or away from it on Back.
    static func depth(_ frame: IslandDrill.Frame) -> Double {
        frame.to == .all ? 1 - frame.progress : frame.progress
    }

    /// The tile not drawn on All while its page grows out of it or goes back into it.
    static func hiddenTile(_ frame: IslandDrill.Frame) -> String? {
        guard let id = revealedProvider(frame), depth(frame) > tileHiddenDepth else { return nil }
        return id
    }

    /// The layers to draw, bottom first: the page at rest; during a move both, All under any
    /// page (a page grows over All and goes back into it), two pages in id order — never by
    /// direction, so a reversal keeps the order.
    static func layers(_ frame: IslandDrill.Frame) -> [Page] {
        guard frame.isMoving else { return [frame.to] }
        return [frame.from, frame.to].sorted(by: drawnBelow)
    }

    private static func drawnBelow(_ a: Page, _ b: Page) -> Bool {
        switch (a, b) {
        case (.all, _): return true
        case (_, .all): return false
        case (.provider(let x), .provider(let y)): return x < y
        }
    }

    /// The page the lower row shows: the destination, from the move's first frame, so it switches
    /// once, at the start, inside a frame whose height moves with the page (`height`).
    static func lowerRowPage(_ frame: IslandDrill.Frame) -> Page {
        frame.to
    }

    // MARK: The layers

    /// `page`'s layer in `frame`. `tile`: the revealed provider's tile in the layer's
    /// coordinates; `size`: the layer's own size.
    static func layer(_ page: Page, in frame: IslandDrill.Frame, tile: CGRect?, size: CGSize) -> Layer {
        guard frame.isMoving else { return page == frame.to ? .whole : hidden }
        guard page == frame.from || page == frame.to else { return hidden }
        let shown = page == shownPage(frame)
        if frame.motion == .reveal, revealedProvider(frame) != nil {
            return revealLayer(page, depth: depth(frame), tile: tile, size: size, shown: shown)
        }
        let p = clamp(frame.progress)
        var layer = Layer()
        layer.interactive = shown
        // Each layer's offset follows its own opacity (the outgoing page sinks as the incoming one
        // rises), so a reversal, which swaps the two ends, moves neither.
        layer.opacity = page == frame.to ? p : 1 - p
        if frame.motion == .slide {
            layer.contentOffsetY = IslandMotion.drillSlide * CGFloat(1 - layer.opacity)
        }
        return layer
    }

    private static func revealLayer(_ page: Page, depth d: Double, tile: CGRect?, size: CGSize, shown: Bool) -> Layer {
        let q = clamp(d)
        var layer = Layer()
        layer.interactive = shown
        if page == .all {
            layer.opacity = clamp(1 - allFadeRate * d)
            layer.scale = 1 - allShrink * CGFloat(q)
            if let tile, size.width > 0, size.height > 0 {
                layer.anchor = UnitPoint(x: tile.midX / size.width, y: tile.midY / size.height)
            }
            return layer
        }
        guard let tile else {
            // No tile measured yet: the page fades in where it is.
            layer.opacity = q
            return layer
        }
        layer.clip = lerp(tile, CGRect(origin: .zero, size: size), CGFloat(q))
        layer.clipRadius = OMRadius.popoverTile * CGFloat(1 - q)
        layer.surfaceOpacity = 1 - q
        let words = clamp((d - contentInStart) / contentInSpan)
        layer.contentOpacity = words
        layer.contentOffsetY = contentRise * CGFloat(1 - words)
        return layer
    }

    // MARK: Height and strip

    /// The height of the stage, or of the lower row, in `frame`, from the two pages' own: nil at
    /// rest (its own); during a move from the page left's to the destination's with the
    /// progress, never past either. A page not measured yet stands in at the other's height.
    static func height(_ frame: IslandDrill.Frame, from: CGFloat?, to: CGFloat?) -> CGFloat? {
        guard frame.isMoving, let start = from ?? to else { return nil }
        let end = to ?? start
        return start + (end - start) * CGFloat(clamp(frame.progress))
    }

    /// What the height rules need of a move (`IslandHeightRules.MoveHeights`, read by
    /// `IslandLayoutModel`): the stage and the lower row as drawn in this frame (`height`), and the
    /// destination's stage at rest (the page left's while the destination is not measured yet).
    /// nil at rest, and while either has no height to draw at.
    static func moveHeights(
        _ frame: IslandDrill.Frame, stage: (from: CGFloat?, to: CGFloat?), lowerRow: (from: CGFloat?, to: CGFloat?)
    ) -> IslandHeightRules.MoveHeights? {
        guard let stageDrawn = height(frame, from: stage.from, to: stage.to),
              let lowerRowDrawn = height(frame, from: lowerRow.from, to: lowerRow.to)
        else { return nil }
        return IslandHeightRules.MoveHeights(
            stageDrawn: stageDrawn, stageAtRest: stage.to ?? stageDrawn, lowerRowDrawn: lowerRowDrawn
        )
    }

    /// How much the strip shows "‹ All" and the logos rather than "Omelette" and the meta line:
    /// 1 in a page with siblings, 0 at All and at the only provider's page; during a move
    /// between the two it comes in from 0.3 of the way to 0.8.
    static func navigationOpacity(_ frame: IslandDrill.Frame, providers: [String]) -> Double {
        func level(_ page: Page) -> Double { IslandNavigation.isDrilledIn(page, providers: providers) ? 1 : 0 }
        let p = frame.isMoving ? clamp(frame.progress) : 1
        let mix = level(frame.from) + (level(frame.to) - level(frame.from)) * p
        return clamp((mix - navigationFadeStart) / navigationFadeSpan)
    }

    private static func clamp(_ x: Double) -> Double {
        min(max(x, 0), 1)
    }

    private static func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(
            x: a.minX + (b.minX - a.minX) * t,
            y: a.minY + (b.minY - a.minY) * t,
            width: a.width + (b.width - a.width) * t,
            height: a.height + (b.height - a.height) * t
        )
    }
}
