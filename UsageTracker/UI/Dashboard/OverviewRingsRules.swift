import SwiftUI

/// One window as the Overview's rings card draws it: its bucket, and for the first three
/// the series colour its ring and legend dot share.
struct OverviewRingWindow: Equatable, Identifiable {
    let bucket: UsageBucket
    /// nil past the third window, which gets a legend row and no ring.
    let series: OMColorToken?

    var id: String { bucket.id }
}

/// A line of copy and the colour it is set in.
struct OverviewLine: Equatable {
    let text: String
    let token: OMColorToken
}

/// What the Overview's rings card draws (liquid-glass spec § Components, "Overview rings";
/// § Screens, "Overview"). Metrics are `Dashboard-Overview(-Light).dc.html`'s.
enum OverviewRingsRules {
    // MARK: - Metrics

    static let diameter: CGFloat = 232
    static let lineWidth: CGFloat = 16
    /// The arcs' centre lines, outermost first: one ring per window, three at most.
    static let radii: [CGFloat] = [106, 85, 64]
    /// Ring colours by place, outermost first: green, blue, violet. For Claude that is
    /// session, all models, per model, as the tokens are named.
    static let seriesTokens: [OMColorToken] = [.seriesSession, .seriesAllModels, .seriesPerModel]
    /// A ring's track is its own colour at 16 %.
    static let trackOpacity: Double = 0.16
    static let paceDotDiameter: CGFloat = 6
    /// Last-known numbers are dimmed, as everywhere else on the dashboard.
    static let retainedOpacity: Double = 0.55
    static let ringLegendSpacing: CGFloat = 36
    static let centreFigureSize: CGFloat = 34
    static let centreUnitSize: CGFloat = 22
    static let centreLabelSize: CGFloat = 11.5
    /// Inside the innermost ring's 112 pt hole, so a long name wraps rather than running
    /// over the stroke.
    static let centreWidth: CGFloat = 96
    static let legendTitleSize: CGFloat = 15
    static let legendTitleBottomPadding: CGFloat = 4
    static let statusSize: CGFloat = 12.5
    static let rowDotDiameter: CGFloat = 10
    static let rowSpacing: CGFloat = 12
    static let rowVerticalPadding: CGFloat = 12
    static let rowNameSize: CGFloat = 13.5
    static let rowSublineSize: CGFloat = 12
    static let rowFigureSize: CGFloat = 24
    static let rowUnitSize: CGFloat = 16
    static let footerSize: CGFloat = 12
    static let footerTopPadding: CGFloat = 6
    static let cardVerticalPadding: CGFloat = 24
    static let cardHorizontalPadding: CGFloat = 28

    // MARK: - Windows

    /// The windows in nesting order, outermost first: the provider tab's hero
    /// (`WindowRanking.detailHero`: the session when there is one, else the most
    /// constrained window, a spend limit included), then the rest in the provider's own
    /// order, promotional pools last. The first three get a ring and a series colour;
    /// any further window is a legend row only.
    static func windows(for service: ServiceSnapshot) -> [OverviewRingWindow] {
        guard let hero = WindowRanking.detailHero(for: service) else { return [] }
        let rest = service.buckets.filter { $0.id != hero.id }
        let ordered = [hero] + rest.filter { !$0.isPromotional } + rest.filter(\.isPromotional)
        return ordered.enumerated().map { index, bucket in
            OverviewRingWindow(bucket: bucket, series: index < seriesTokens.count ? seriesTokens[index] : nil)
        }
    }

    // MARK: - Centre

    /// What the middle of the rings says.
    struct Centre: Equatable {
        let percent: String
        let name: String
    }

    /// The emphasised window's figure and short name, or the outermost window's when
    /// nothing is emphasised (or the index no longer exists). nil with no window at all.
    static func centre(windows: [OverviewRingWindow], emphasised: Int?, mode: PercentDisplay.Mode) -> Centre? {
        guard !windows.isEmpty else { return nil }
        let index = emphasised.flatMap { windows.indices.contains($0) ? $0 : nil } ?? 0
        let bucket = windows[index].bucket
        return Centre(
            percent: PercentDisplay.percentText(bucket.clampedPercent, mode: mode),
            name: centreName(bucket.label)
        )
    }

    /// The mockup's "session", "all models", "Fable only" under the figure: "Current
    /// session" loses "Current", a label starting "All " its capital; any other label,
    /// a model's name above all, stays as the provider wrote it.
    static func centreName(_ label: String) -> String {
        if label == "Current session" { return "session" }
        if label.hasPrefix("All ") { return "all " + label.dropFirst("All ".count) }
        return label
    }

    // MARK: - Legend

    /// A legend row's grey line: a countdown within the hour ("resets in 15m"), the clock
    /// beyond it ("resets 13:00", "resets Thu 12:59"). The spend-limit window says what is
    /// spent instead. A reset that has passed says "resets now" only while the provider
    /// answers: on last-known numbers it may have passed hours ago. nil with no reset time.
    static func subline(
        for bucket: UsageBucket,
        service: ServiceSnapshot,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String? {
        if bucket.id == WindowRanking.extraUsageBucketID(for: service) {
            return SpendLimitCopy.caption(service.extraUsage, compact: false, locale: locale)
        }
        guard let relative = ResetCopy.relative(resetsAt: bucket.resetsAt, now: now) else { return nil }
        if relative == "now" { return service.isRetained ? nil : "resets now" }
        if bucket.resetsAt.timeIntervalSince(now) <= 3600 { return "resets \(relative)" }
        guard let absolute = ResetCopy.absolute(resetsAt: bucket.resetsAt, now: now, calendar: calendar, locale: locale)
        else { return "resets \(relative)" }
        return "resets \(absolute)"
    }

    /// The legend title's verdict: the worst core window's phrase ("On track") in its
    /// gauge tone, as the provider tab says it. Model-scoped windows and promotional pools
    /// do not drive it. nil on last-known numbers, which describe no present state.
    static func status(for service: ServiceSnapshot) -> OverviewLine? {
        guard !service.isRetained, let worst = WindowRanking.heroBucket(for: service) else { return nil }
        return OverviewLine(
            text: OMHero.statusPhrase(worst.clampedPercent),
            token: OMHero.statusToken(worst.clampedPercent)
        )
    }

    /// The pace dot, as `OMRing` draws it, and never on last-known numbers.
    static func showsPaceDot(pace: Double?, retained: Bool) -> Bool {
        !retained && OMRing.paceMarkerVisible(pace)
    }

    /// What VoiceOver reads for a legend row: the window, its figure in words, its reset.
    static func accessibilityLabel(for bucket: UsageBucket, subline: String?, mode: PercentDisplay.Mode) -> String {
        let head = "\(bucket.label), \(PercentDisplay.spoken(bucket.clampedPercent, mode: mode))"
        guard let subline else { return head }
        return "\(head), \(subline)"
    }
}

// MARK: - Emphasis (spec § Components, "Overview rings": hover or focus)

extension OverviewRingsRules {
    /// A ring or legend row that is not the emphasised one while one is.
    static let dimmedOpacity: Double = 0.22
    /// The mockup's `transition: opacity 0.2s ease`.
    static let emphasisAnimation: Double = 0.2
    /// Each ring answers the pointer across its stroke and half the gap to its
    /// neighbour: 10.5 pt either side of its centre line.
    static var hitHalfWidth: CGFloat { (radii[0] - radii[1]) / 2 }

    /// The window emphasised: the one under the pointer, else the legend row holding
    /// keyboard focus, and that only while the user moves with the keyboard, so a click
    /// never leaves a window stuck in front.
    static func emphasised(hovered: Int?, focused: Int?, keyboardNavigation: Bool) -> Int? {
        hovered ?? (keyboardNavigation ? focused : nil)
    }

    /// One opacity per window, for its ring and its legend row: all 1 at rest; while one
    /// is emphasised it stays 1 and the rest drop to 22 %. An index that no longer exists
    /// (the windows changed under the pointer) is at rest.
    static func emphasis(hovered: Int?, count: Int) -> [Double] {
        let count = max(0, count)
        guard let hovered, (0..<count).contains(hovered) else { return Array(repeating: 1, count: count) }
        return (0..<count).map { $0 == hovered ? 1 : dimmedOpacity }
    }

    /// The ring under `point`, in the rings' own 232 pt frame, among the first `count`
    /// windows; nil in the middle, outside, or on a ring that is not drawn.
    static func ring(at point: CGPoint, count: Int) -> Int? {
        let middle = diameter / 2
        let distance = hypot(point.x - middle, point.y - middle)
        for index in 0..<min(max(0, count), radii.count) where abs(distance - radii[index]) <= hitHalfWidth {
            return index
        }
        return nil
    }

    /// The hovered window after the pointer enters or leaves legend row `row`. Leaving
    /// clears only that row's hover, so a late exit from one row cannot wipe the next.
    static func hover(inside: Bool, row: Int, current: Int?) -> Int? {
        if inside { return row }
        return current == row ? nil : current
    }

    /// A legend row's tooltip: the window, its reset on the clock and what the dot on its
    /// ring marks. The rings carry no "dot = time elapsed" caption (spec § Removals), so
    /// the pointer is where the dot is explained.
    static func help(
        for bucket: UsageBucket,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        var parts = [bucket.label]
        if let absolute = ResetCopy.absolute(resetsAt: bucket.resetsAt, now: now, calendar: calendar, locale: locale) {
            parts.append("resets \(absolute)")
        }
        if let elapsed = bucket.elapsedFraction(now: now), OMRing.paceMarkerVisible(elapsed) {
            parts.append("dot: \(Int((elapsed * 100).rounded()))% of the window elapsed")
        }
        return parts.joined(separator: " · ")
    }
}
