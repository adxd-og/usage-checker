import Foundation

/// What Claude Code tells us about the session it is drawing a status line for.
///
/// It writes a JSON object to our stdin and closes the pipe. Two fields of it are
/// worth a status line: the model's display name and how full the context window is.
/// Everything else in that object is Claude Code's business.
///
/// The payload is somebody else's format and may change under us, so every shape that
/// is not the one we expect — a missing key, an id where a name belongs, a number
/// written as a string, invalid JSON, an empty pipe — resolves to `nil` rather than to
/// an error. A status line has no place to report a parse failure, and a session spent
/// looking at one would be worse than a session spent looking at nothing.
struct StatusLineInput: Equatable, Sendable {
    /// `model.display_name` — "Fable", "Opus 4.5". Never the id: it is what Claude
    /// Code itself prints, and an id in a status bar is noise.
    let model: String?

    /// `context_window.used_percentage`, clamped to 0…100. **Used**, always: this is
    /// the session's context window filling up, a different quantity from the
    /// rate-limit windows beside it, so `PercentDisplay.Mode` — which flips those
    /// between "used" and "left" — deliberately does not apply to it. A context bar
    /// that inverted with that setting would read as a limit the user does not have.
    let contextUsedPercent: Double?

    /// Nothing was piped in, or nothing in it was ours.
    static let none = StatusLineInput(model: nil, contextUsedPercent: nil)

    static func parse(_ data: Data) -> StatusLineInput {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any]
        else { return .none }
        return StatusLineInput(
            model: name(root["model"]),
            contextUsedPercent: percent((root["context_window"] as? [String: Any])?["used_percentage"])
        )
    }

    private static func name(_ value: Any?) -> String? {
        guard let model = value as? [String: Any],
              let name = model["display_name"] as? String
        else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func percent(_ value: Any?) -> Double? {
        guard let value else { return nil }
        let number: Double?
        if let text = value as? String {
            number = Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
        } else if CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() {
            // `true` bridges to 1.0 and would draw a bar. A boolean here is a payload
            // we do not understand, not a one-percent context window.
            number = nil
        } else {
            number = (value as? NSNumber)?.doubleValue
        }
        guard let number, number.isFinite else { return nil }
        return max(0, min(100, number))
    }
}
