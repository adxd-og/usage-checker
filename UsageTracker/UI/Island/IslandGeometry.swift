import SwiftUI

/// The open shape inside the island's window (notch-island spec 2026-10-29 § 3.1): one path
/// for the drawing and for the click-through hit test, so the two never disagree. Window
/// coordinates with the origin at the top left, as SwiftUI draws, computed from the frame
/// AppKit applied: window origins snap to whole points (P0: 656.5 → 656.0). Pure.
///
/// The island's shape moves (§ 3.2): at progress 0 it is the notch with the resting notch's
/// corners, at 1 the open body with concave shoulders where its top edge meets the sides,
/// past 1 while the open spring overshoots, always inside the window. The panel's shape is
/// the popover's rounded rectangle and does not move.
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
    /// The open island's shoulders: concave fillets where the top edge meets the sides
    /// (§ 3.2; the spike's open value). At the notch they are 0, so the shape there is the
    /// resting notch exactly.
    static let openShoulder: CGFloat = 12

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

    /// The island's body at `progress`: from the notch (0) to `bodyRect` (1), past it while
    /// the open spring overshoots, kept inside the window. Shoulders not included. The panel's
    /// is `bodyRect` at any progress.
    func shapeRect(contentSize: CGSize, progress: Double) -> CGRect {
        let open = bodyRect(contentSize: contentSize)
        guard kind == .island, let notch else { return open }
        let p = CGFloat(max(progress, 0))
        let minX = max(notch.minX + (open.minX - notch.minX) * p, 0)
        let maxX = min(notch.maxX + (open.maxX - notch.maxX) * p, windowSize.width)
        let maxY = min(notch.maxY + (open.maxY - notch.maxY) * p, windowSize.height)
        return CGRect(x: minX, y: 0, width: max(maxX - minX, 0), height: max(maxY, 0))
    }

    /// The shape at `progress` (1 when omitted: the island open). The island: square at the
    /// top, rounded at the bottom from the resting notch's 8 pt to 24, with concave shoulders
    /// growing from 0 to `openShoulder`, never wider than the room the window leaves beside the
    /// body. The panel: the popover's rounded rectangle (`OMRadius.popover`, the corner the
    /// content draws).
    func path(contentSize: CGSize, progress: Double = 1) -> Path {
        switch kind {
        case .panel:
            return OMCornerShape(.popover).path(in: bodyRect(contentSize: contentSize))
        case .island:
            let body = shapeRect(contentSize: contentSize, progress: progress)
            let p = CGFloat(min(max(progress, 0), 1))
            let radius = Self.restingBottomRadius + (Self.islandBottomRadius - Self.restingBottomRadius) * p
            var path = Path(
                roundedRect: body,
                cornerRadii: RectangleCornerRadii(
                    topLeading: 0,
                    bottomLeading: radius,
                    bottomTrailing: radius,
                    topTrailing: 0
                ),
                style: .continuous
            )
            let shoulder = min(Self.openShoulder * p, body.minX, windowSize.width - body.maxX, body.height)
            if shoulder > 0 {
                // Each shoulder: the corner between the top edge and the side, less a quarter
                // circle (a quadratic, as the spike drew it), so the black flows into the side.
                for (side, outward) in [(body.minX, -shoulder), (body.maxX, shoulder)] {
                    path.move(to: CGPoint(x: side + outward, y: 0))
                    path.addLine(to: CGPoint(x: side, y: 0))
                    path.addLine(to: CGPoint(x: side, y: shoulder))
                    path.addQuadCurve(to: CGPoint(x: side + outward, y: 0), control: CGPoint(x: side, y: 0))
                    path.closeSubpath()
                }
            }
            return path
        }
    }

    /// Where a point in the window lands while the shape is at `progress` (1 when omitted).
    /// Only what is drawn counts: the notch strip is the part of the drawn shape over the
    /// notch, so a point in the notch's rect but outside a rounded corner is outside.
    func region(of point: CGPoint, contentSize: CGSize, progress: Double = 1) -> Region {
        guard path(contentSize: contentSize, progress: progress).contains(point) else { return .outside }
        if let notch, notch.contains(point) { return .notchStrip }
        return .body
    }

    /// A global point in the coordinates of a window at `windowFrame`.
    static func windowPoint(screenPoint: CGPoint, windowFrame: CGRect) -> CGPoint {
        CGPoint(x: screenPoint.x - windowFrame.minX, y: windowFrame.maxY - screenPoint.y)
    }

    /// A global rect in the coordinates of a window at `frame`.
    static func local(_ rect: CGRect, in frame: CGRect) -> CGRect {
        CGRect(x: rect.minX - frame.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    /// A rect in the coordinates of a window at `frame`, in global ones: `local`'s inverse.
    static func global(_ rect: CGRect, in frame: CGRect) -> CGRect {
        CGRect(x: rect.minX + frame.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
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
