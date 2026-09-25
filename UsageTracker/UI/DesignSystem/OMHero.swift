import SwiftUI

/// Provider-tab header (`Popover-Claude.dc.html`): the hero window as a large slim ring
/// next to its name, time to reset, the status phrase as coloured text ("On track"),
/// and the burn verdict when there is one.
struct OMHero: View {
    let hero: UsageBucket
    let mode: PercentDisplay.Mode
    var verdict: BurnVerdict? = nil

    /// `View` is @MainActor; the phrase is pure, so it stays callable anywhere.
    nonisolated static func statusPhrase(_ percent: Double) -> String {
        if percent >= 90 { return "Almost at the limit" }
        if percent >= 70 { return "Running hot" }
        if percent >= 50 { return "On track" }
        return "Plenty of headroom"
    }

    /// What VoiceOver reads for the hero ring. The phrase stays on the used value:
    /// "Almost at the limit" is the same warning whichever way the number counts.
    nonisolated static func accessibilityText(for hero: UsageBucket, mode: PercentDisplay.Mode) -> String {
        "\(hero.label), \(PercentDisplay.spoken(hero.clampedPercent, mode: mode)), \(statusPhrase(hero.clampedPercent))"
    }

    /// The phrase's colour: the gauge tone's text token on the used value — green
    /// "On track", amber "Running hot", red "Almost at the limit".
    nonisolated static func statusToken(_ percent: Double) -> OMColorToken {
        OMGaugeTone.forUsed(percent).text
    }

    /// A verdict that says the limit will be hit is amber; one that says it won't is quiet.
    nonisolated static func verdictToken(_ verdict: BurnVerdict) -> OMColorToken {
        verdict.willHit ? .warning : .secondary
    }

    // MARK: - Metrics (`Popover-Claude.dc.html`)

    nonisolated static var ringStyle: OMRing.Style { .slim }
    nonisolated static let ringSpacing: CGFloat = 18
    nonisolated static let lineSpacing: CGFloat = 3
    nonisolated static let titleSize: CGFloat = 16
    nonisolated static let captionSize: CGFloat = 12.5
    nonisolated static let verdictSize: CGFloat = 11.5
    nonisolated static let topInset: CGFloat = 10
    nonisolated static let sideInset: CGFloat = 6
    nonisolated static let bottomInset: CGFloat = 6

    var body: some View {
        let now = Date()
        return HStack(spacing: Self.ringSpacing) {
            OMRing(used: hero.clampedPercent, mode: mode, size: .hero, pace: hero.elapsedFraction(), style: Self.ringStyle)
            VStack(alignment: .leading, spacing: Self.lineSpacing) {
                Text(hero.label)
                    .font(.system(size: Self.titleSize, weight: .semibold))
                    .foregroundStyle(.om(.text))
                if let reset = ResetCopy.both(resetsAt: hero.resetsAt, now: now) {
                    Text(reset)
                        .font(.system(size: Self.captionSize))
                        .foregroundStyle(.om(.secondary))
                        .lineLimit(1)
                        .help(ResetCopy.absolute(resetsAt: hero.resetsAt, now: now).map { "Resets \($0)" } ?? "")
                }
                Text(Self.statusPhrase(hero.clampedPercent))
                    .font(.system(size: Self.captionSize, weight: .semibold))
                    .foregroundStyle(.om(Self.statusToken(hero.clampedPercent)))
                if let verdict {
                    HStack(spacing: 5) {
                        Image(systemName: verdict.willHit ? "flame.fill" : "checkmark.circle")
                            .font(.system(size: Self.verdictSize))
                            .foregroundStyle(.om(Self.verdictToken(verdict)))
                        Text(verdict.text)
                            .font(.system(size: Self.verdictSize))
                            .foregroundStyle(.om(verdict.willHit ? .text : .secondary))
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, Self.topInset)
        .padding(.horizontal, Self.sideInset)
        .padding(.bottom, Self.bottomInset)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityText(for: hero, mode: mode))
    }
}

#Preview("Hero") {
    let session = UsageBucket(id: "five_hour", label: "Current session", utilization: 53, resetsAt: Date().addingTimeInterval(900), kind: .session)
    return OMHero(hero: session, mode: .used, verdict: BurnVerdict(willHit: true, text: "At this pace, limit in ~1h 40m"))
        .padding().frame(width: 360)
}
