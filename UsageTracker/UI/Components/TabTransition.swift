import SwiftUI

/// A tab switch's motion: how long the cross-fade takes and how far the incoming page
/// slides while it fades in.
struct OMTabTransition: Equatable, Sendable {
    let duration: Double
    let offset: CGFloat
}

/// Tab switches on the dashboard, in Settings and in the popover: the pages cross-fade and
/// the incoming one slides a few points in from the side it comes from, easing out. With
/// no known side it only fades; under Reduce Motion the switch is instant.
enum OMTransitionRules {
    static func tab(reduceMotion: Bool) -> OMTabTransition? {
        reduceMotion ? nil : OMTabTransition(duration: 0.18, offset: 8)
    }

    /// +1 when `next` comes after `previous` in `order` (down a sidebar, right along a
    /// segmented control), −1 when before, 0 when they are the same or either is not in
    /// `order`.
    static func direction<T: Equatable>(from previous: T?, to next: T, in order: [T]) -> Int {
        guard
            let previous,
            let from = order.firstIndex(of: previous),
            let to = order.firstIndex(of: next),
            from != to
        else { return 0 }
        return to > from ? 1 : -1
    }

    /// Where the incoming page starts, along the tabs' axis: the transition's offset toward
    /// the side it comes from (positive: below or to the right), 0 for a plain fade.
    static func insertionOffset<T: Equatable>(
        from previous: T?,
        to next: T,
        in order: [T],
        transition: OMTabTransition?
    ) -> CGFloat {
        guard let transition else { return 0 }
        return CGFloat(direction(from: previous, to: next, in: order)) * transition.offset
    }
}

/// Wraps a tab's page so a new selection cross-fades in (`OMTransitionRules`). Both pages
/// overlap in a `ZStack` while they fade; the outgoing one only fades, because a removed
/// view keeps the transition it was last drawn with. `shown` still holds the previous tab
/// while the new page is inserted, which is what gives the slide its direction.
struct OMTabTransitionContainer<Selection: Hashable, Content: View>: View {
    let selection: Selection
    let order: [Selection]
    let axis: Axis
    let alignment: Alignment
    let content: Content

    @State private var shown: Selection?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let motion = OMTransitionRules.tab(reduceMotion: reduceMotion)
        let offset = OMTransitionRules.insertionOffset(from: shown, to: selection, in: order, transition: motion)
        ZStack(alignment: alignment) {
            content
                .id(selection)
                .transition(Self.transition(motion: motion, offset: offset, axis: axis))
        }
        .animation(motion.map { .easeOut(duration: $0.duration) }, value: selection)
        .onAppear { shown = selection }
        .onChange(of: selection) { _, new in shown = new }
    }

    private static func transition(motion: OMTabTransition?, offset: CGFloat, axis: Axis) -> AnyTransition {
        guard motion != nil else { return .identity }
        let shift = axis == .vertical ? CGSize(width: 0, height: offset) : CGSize(width: offset, height: 0)
        return .asymmetric(insertion: .opacity.combined(with: .offset(shift)), removal: .opacity)
    }
}

extension View {
    /// This tab page, cross-fading to the next when `selection` changes. `order` is the
    /// tabs' order on screen, `axis` the direction they run in.
    func omTabTransition<Selection: Hashable>(
        selection: Selection,
        order: [Selection],
        axis: Axis,
        alignment: Alignment = .topLeading
    ) -> some View {
        OMTabTransitionContainer(selection: selection, order: order, axis: axis, alignment: alignment, content: self)
    }
}
