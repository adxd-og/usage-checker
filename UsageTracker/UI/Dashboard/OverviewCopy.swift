import SwiftUI

/// The Overview's own words (liquid-glass spec § Screens, "Overview";
/// `Dashboard-Overview(-Light).dc.html`). Each card's lines arrive with the card.
enum OverviewCopy {
    /// The rings card's legend.
    static let legendTitle = "Usage windows"

    /// "Burn rate: idle": `OverviewView.burnValue`'s answer, lower case after the colon.
    static func burnLine(burn: BurnRatePrediction?, retained: Bool) -> String {
        let value = OverviewView.burnValue(burn, retained: retained)
        return "Burn rate: \(value.prefix(1).lowercased())\(value.dropFirst())"
    }

    /// The legend's last line: the burn verdict in its colour when there is one (amber
    /// when the limit will be hit), else the burn line in secondary.
    static func footer(verdict: BurnVerdict?, burn: BurnRatePrediction?, retained: Bool) -> OverviewLine {
        if let verdict {
            return OverviewLine(text: verdict.text, token: OMHero.verdictToken(verdict))
        }
        return OverviewLine(text: burnLine(burn: burn, retained: retained), token: .secondary)
    }
}
