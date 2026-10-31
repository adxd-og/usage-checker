import SwiftUI

/// The resting panel's window and what it draws (notch-island spec 2026-10-29 § 3.1 Notch hint, § 3.6,
/// D13): the notch, the ears shown attached to it, as one black shape. The window server hands the
/// panel a click only where it drew, so this shape is also where it takes clicks. View coordinates,
/// origin at the top left, from the frame AppKit applied. Pure.
struct RestingLayout: Equatable, Sendable {
    /// The room the hint takes beside and below the notch, only while it shows (the P0 spike's).
    static let hintSideRoom: CGFloat = 6
    static let hintBottomRoom: CGFloat = 8
    /// Reduce Motion's outline (D13: "a brighter outline only").
    static let outlineWidth: CGFloat = 1.5
    static let outlineOpacity: CGFloat = 0.45

    let notch: CGRect
    let leftEar: CGRect?
    let rightEar: CGRect?

    /// The window in global coordinates, rounded out to whole points as `restingFrame` does.
    static func frame(notch: CGRect, left: Bool, right: Bool, hintRoom: Bool) -> CGRect {
        var rect = notch
        let ear = IslandEarRules.earWidth
        if left {
            rect = rect.union(CGRect(x: notch.minX - ear, y: notch.minY, width: ear, height: notch.height))
        }
        if right {
            rect = rect.union(CGRect(x: notch.maxX, y: notch.minY, width: ear, height: notch.height))
        }
        if hintRoom {
            rect = rect.insetBy(dx: -hintSideRoom, dy: 0)
            rect = rect.union(CGRect(x: rect.minX, y: notch.minY - hintBottomRoom, width: rect.width, height: hintBottomRoom))
        }
        return IslandDisplayResolver.restingFrame(notch: rect)
    }

    /// `notch` in global coordinates; `appliedFrame` is the window as AppKit placed it.
    init(notch: CGRect, left: Bool, right: Bool, appliedFrame: CGRect) {
        let local = IslandGeometry.local(notch, in: appliedFrame)
        let ear = IslandEarRules.earWidth
        self.notch = local
        leftEar = left ? CGRect(x: local.minX - ear, y: local.minY, width: ear, height: local.height) : nil
        rightEar = right ? CGRect(x: local.maxX, y: local.minY, width: ear, height: local.height) : nil
    }

    /// The black: the notch and each ear shown breathe as one, each ear reaching under the notch's
    /// rounded corner so no wedge shows between them (owner, after the first look at P6).
    func shape(_ look: NotchHint.Look = .rest) -> Path {
        let radius = IslandGeometry.restingBottomRadius
        var path = Path(
            roundedRect: CGRect(
                x: notch.minX - look.widen, y: notch.minY,
                width: notch.width + 2 * look.widen, height: notch.height + look.down
            ),
            cornerRadii: RectangleCornerRadii(topLeading: 0, bottomLeading: radius, bottomTrailing: radius, topTrailing: 0),
            style: .continuous
        )
        if let leftEar {
            path.addPath(Path(
                roundedRect: CGRect(
                    x: leftEar.minX - look.widen, y: leftEar.minY,
                    width: leftEar.width + look.widen + radius, height: leftEar.height + look.down
                ),
                cornerRadii: RectangleCornerRadii(topLeading: 0, bottomLeading: radius, bottomTrailing: 0, topTrailing: 0),
                style: .continuous
            ))
        }
        if let rightEar {
            path.addPath(Path(
                roundedRect: CGRect(
                    x: rightEar.minX - radius, y: rightEar.minY,
                    width: rightEar.width + radius + look.widen, height: rightEar.height + look.down
                ),
                cornerRadii: RectangleCornerRadii(topLeading: 0, bottomLeading: 0, bottomTrailing: radius, topTrailing: 0),
                style: .continuous
            ))
        }
        return path
    }

    /// An ear's content at the breath's `look`: it rides down with the shape's lower edge.
    func earFrame(_ ear: CGRect?, look: NotchHint.Look) -> CGRect {
        ear?.offsetBy(dx: 0, dy: look.down) ?? .zero
    }

    /// Reduce Motion's outline: the notch's edge, a point out, where the display has pixels.
    func outline() -> Path {
        let radius = IslandGeometry.restingBottomRadius + 1
        return Path(
            roundedRect: CGRect(x: notch.minX - 1, y: notch.minY, width: notch.width + 2, height: notch.height + 1),
            cornerRadii: RectangleCornerRadii(topLeading: 0, bottomLeading: radius, bottomTrailing: radius, topTrailing: 0),
            style: .continuous
        )
    }

    /// Where the pointer counts as over the notch: the notch, and while the hint is up the grown
    /// shape, so moving into the breath is not a leave (the P0 spike's rule).
    func trackedRect(hintUp: Bool) -> CGRect {
        guard hintUp else { return notch }
        return CGRect(
            x: notch.minX - IslandMotion.hintWiden, y: notch.minY,
            width: notch.width + 2 * IslandMotion.hintWiden, height: notch.height + IslandMotion.hintDown
        )
    }

    /// Where the ear tips draw: centred on the notch, standing on the shape's lower edge (plan R9).
    func tipsRect(size: CGSize, look: NotchHint.Look) -> CGRect {
        CGRect(x: notch.midX - size.width / 2, y: notch.maxY + look.down - size.height, width: size.width, height: size.height)
    }
}
