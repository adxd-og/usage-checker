import Foundation

/// The two requests that put a cmux tab in front, as newline-delimited JSON-RPC.
///
/// cmux (github.com/manaflow-ai/cmux) exposes no AppleScript and no tty addressing:
/// its socket takes `workspace.select` then `surface.focus`, in that order — focusing
/// a surface in a workspace that is not selected does nothing.
///
/// The lines are built by hand rather than through `JSONSerialization` so the exact
/// bytes are pinned by a test: this is a protocol, and key order is part of reading a
/// wire log. The ids come out of a shell environment variable, so they are escaped.
enum CmuxRPC {
    static func requests(workspace: String, surface: String) -> [String] {
        [
            #"{"id":1,"method":"workspace.select","params":{"workspace":"\#(escape(workspace))"}}"#,
            #"{"id":2,"method":"surface.focus","params":{"surface":"\#(escape(surface))"}}"#,
        ]
    }

    /// One JSON string literal's worth of escaping. A quote must not close the string,
    /// a newline must not split one message into two, and a control character must not
    /// make the whole line unparseable at the other end.
    static func escape(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.unicodeScalars.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }
}
