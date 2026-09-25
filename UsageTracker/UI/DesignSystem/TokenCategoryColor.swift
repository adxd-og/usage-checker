import SwiftUI

/// The four buckets' colours. System colours only, so both themes get a legible
/// set without a second palette to maintain: the accent for fresh input (the
/// thing the user actually typed), orange for what the model wrote, and the two
/// cache colours cool against them so cache reads read as "cheap".
///
/// Lives in the UI target on purpose — `TokenBreakdown.swift` in Core stays free
/// of SwiftUI so the aggregators and their tests never import it.
extension TokenCategory {
    var color: Color {
        switch self {
        case .input: return .accentColor
        case .output: return .orange
        case .cacheRead: return .teal
        case .cacheWrite: return .purple
        }
    }

    /// The 3.0 colour role of each type (liquid-glass spec § Tokens, "tokens"): what
    /// History's stacked bars, legend and open-chat bar and Overview's Tokens today card
    /// draw with.
    /// `color` above stays the 2.x system set until its own surfaces move.
    var token: OMColorToken {
        switch self {
        case .input: return .tokenInput
        case .output: return .tokenOutput
        case .cacheRead: return .tokenCacheRead
        case .cacheWrite: return .tokenCacheWrite
        }
    }
}
