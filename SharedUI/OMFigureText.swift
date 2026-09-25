import SwiftUI

/// A figure and its unit: "57%" → "57" and "%", "11m left" → "11m" and " left". The
/// 3.0 screens set the unit smaller and in secondary (`Main.dc.html`). In SharedUI
/// because the slim `OMRing` draws its centre figure with it.
enum OMFigure {
    /// Units a figure can end in. The unit keeps its leading space.
    static let units = [" left", "%"]

    struct Parts: Equatable, Sendable {
        let value: String
        let unit: String?
    }

    static func split(_ text: String) -> Parts {
        for unit in units where text.count > unit.count && text.hasSuffix(unit) {
            return Parts(value: String(text.dropLast(unit.count)), unit: unit)
        }
        return Parts(value: text, unit: nil)
    }
}

/// A 3.0 figure: SF Pro Rounded tabular digits in `token`, its unit (if any) smaller
/// and in secondary, on one baseline.
struct OMFigureText: View {
    let text: String
    let size: CGFloat
    let unitSize: CGFloat
    var weight: Font.Weight = .semibold
    var unitWeight: Font.Weight = .semibold
    var token: OMColorToken = .text

    var body: some View {
        let parts = OMFigure.split(text)
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(parts.value)
                .font(OMFont.numerals(size: size, weight: weight))
                .foregroundStyle(.om(token))
            if let unit = parts.unit {
                Text(unit)
                    .font(.system(size: unitSize, weight: unitWeight))
                    .foregroundStyle(.om(.secondary))
            }
        }
        .lineLimit(1)
    }
}
