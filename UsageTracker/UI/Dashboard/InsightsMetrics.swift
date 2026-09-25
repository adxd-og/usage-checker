import SwiftUI

/// The Insights tab's measures and colours, from `Dashboard-Insights(-Light).dc.html`.
/// The mockup's weight 650 is `.semibold`.
enum InsightsMetrics {
    // MARK: - Session window: split by model

    /// The split bar: 10 pt high, rounded 5, 2 pt between models.
    static let splitBarHeight: CGFloat = 10
    static let splitBarRadius: CGFloat = 5
    static let splitBarGap: CGFloat = 2
    /// The legend under it: 22 pt between models, 7 between dot, name and dollars.
    static let legendSpacing: CGFloat = 22
    static let legendItemSpacing: CGFloat = 7
    static let legendDotSize: CGFloat = 8
    static let legendTextSize: CGFloat = 12.5

    /// The models' colours in order: the mockup's blue, violet and teal, which are the
    /// input, cache-write and cache-read token colours in both themes.
    static let modelSplitTokens: [OMColorToken] = [.tokenInput, .tokenCacheWrite, .tokenCacheRead]

    /// The colour of the model at `index`. A fourth would repeat the first, though
    /// `InsightsRules.modelSplitLimit` never asks for one.
    static func modelSplitToken(at index: Int) -> OMColorToken {
        modelSplitTokens[index % modelSplitTokens.count]
    }

    /// The "Other" slice: many models and none in particular, so the muted mark.
    static let otherModelsToken: OMColorToken = .muted

    /// A slice's colour in the bar and the legend: the palette's by position, or
    /// `otherModelsToken` for "Other".
    static func splitToken(for share: InsightsModelShare, at index: Int) -> OMColorToken {
        share.isOther ? otherModelsToken : modelSplitToken(at: index)
    }
}
