import SwiftUI

/// The open shape inside the island's window (notch-island spec 2026-10-29 § 3.1): one path
/// for the drawing and for the click-through hit test, so the two never disagree. Window
/// coordinates with the origin at the top left, as SwiftUI draws, computed from the frame
/// AppKit applied: window origins snap to whole points (P0: 656.5 → 656.0). Pure.
///
/// P1's shape is plain: the island a rectangle hanging from the screen's top with rounded
/// bottom corners, the panel the popover's rounded rectangle. P2 gives the island its
/// concave shoulders and its motion through this same path.
struct IslandGeometry: Equatable, Sendable {
    enum Region: Equatable, Sendable {
        /// Over the notch: a click here on the open island closes it (§ 3.1, Dismissal).
        case notchStrip
        /// Inside the shape.
        case body
        /// The window's transparent rest: clicks go through it.
        case outside
    }

    let kind: IslandDisplayResolver.Kind
    let windowSize: CGSize
    /// The x the body centres on, in the window.
    let anchorMidX: CGFloat
    /// The notch in the window; nil for the panel.
    let notch: CGRect?
    let bodyWidth: CGFloat

    /// The island's bottom corners (§ 3.3, island radius 24).
    static let islandBottomRadius: CGFloat = 24
    /// Under the content inside the island (§ 3.3, padding 14).
    static let islandBottomPadding: CGFloat = 14
    /// The resting notch's bottom corners (D13; the spike's closed radius).
    static let restingBottomRadius: CGFloat = 8

    init(placement: IslandDisplayResolver.Placement, appliedFrame: CGRect) {
        kind = placement.kind
        windowSize = appliedFrame.size
        anchorMidX = placement.anchorMidX - appliedFrame.minX
        notch = placement.notch.map { Self.local($0, in: appliedFrame) }
        bodyWidth = placement.bodyWidth
    }

    /// The notch strip's height: the content starts under it. 0 for the panel.
    var stripHeight: CGFloat { notch?.maxY ?? 0 }

    /// The body around content of `contentSize`: centred on the anchor, kept inside the
    /// window's side margins. The island adds the notch strip above and its padding below.
    func bodyRect(contentSize: CGSize) -> CGRect {
        let margin = IslandDisplayResolver.sideMargin
        let x = min(max(anchorMidX - bodyWidth / 2, margin), max(margin, windowSize.width - margin - bodyWidth))
        switch kind {
        case .island:
            return CGRect(x: x, y: 0, width: bodyWidth, height: stripHeight + contentSize.height + Self.islandBottomPadding)
        case .panel:
            return CGRect(x: x, y: 0, width: bodyWidth, height: contentSize.height)
        }
    }

    /// Where the content's top-left corner goes: centred in the body, under the notch strip.
    func contentOrigin(contentSize: CGSize) -> CGPoint {
        let body = bodyRect(contentSize: contentSize)
        return CGPoint(x: body.midX - contentSize.width / 2, y: stripHeight)
    }

    /// The shape: the island square at the top and rounded at the bottom, the panel the
    /// popover's rounded rectangle (`OMRadius.popover`, the corner the content draws).
    func path(contentSize: CGSize) -> Path {
        let body = bodyRect(contentSize: contentSize)
        switch kind {
        case .island:
            return Path(
                roundedRect: body,
                cornerRadii: RectangleCornerRadii(
                    topLeading: 0,
                    bottomLeading: Self.islandBottomRadius,
                    bottomTrailing: Self.islandBottomRadius,
                    topTrailing: 0
                ),
                style: .continuous
            )
        case .panel:
            return OMCornerShape(.popover).path(in: body)
        }
    }

    /// Where a point in the window lands.
    func region(of point: CGPoint, contentSize: CGSize) -> Region {
        if let notch, notch.contains(point) { return .notchStrip }
        return path(contentSize: contentSize).contains(point) ? .body : .outside
    }

    /// A global point in the coordinates of a window at `windowFrame`.
    static func windowPoint(screenPoint: CGPoint, windowFrame: CGRect) -> CGPoint {
        CGPoint(x: screenPoint.x - windowFrame.minX, y: windowFrame.maxY - screenPoint.y)
    }

    /// A global rect in the coordinates of a window at `frame`.
    static func local(_ rect: CGRect, in frame: CGRect) -> CGRect {
        CGRect(x: rect.minX - frame.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The resting panel's black notch in its own view (top-left origin): the notch, square
    /// at the top, rounded at the bottom; the window's half-point slack stays transparent.
    static func restingPath(notch: CGRect, appliedFrame: CGRect) -> Path {
        Path(
            roundedRect: local(notch, in: appliedFrame),
            cornerRadii: RectangleCornerRadii(
                topLeading: 0,
                bottomLeading: restingBottomRadius,
                bottomTrailing: restingBottomRadius,
                topTrailing: 0
            ),
            style: .continuous
        )
    }
}
