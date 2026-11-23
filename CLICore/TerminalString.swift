import Foundation

/// A string on its way to a terminal: the rule for what the `brioche` tool and its MCP
/// server may print of a string they did not write (spec 2026-11-23 terminal strings).
///
/// The strings of `status.json` come from a hook's payload, a CLI's log, `~/.claude.json`
/// or a provider's answer. Printed as they are, an escape sequence in one of them reaches
/// the user's terminal: a clipboard write (OSC 52), a repainted screen, text shown in
/// another order (a bidi override). `JSONEncoder` and `JSONSerialization` escape C0 only,
/// so the JSON outputs carried DEL, the C1 controls and the format characters as raw UTF-8.
///
/// Two functions. `clean` is the rule for one string. `cleaningStrings(inJSON:)` applies it
/// to every string of a JSON text, and `StatusFile` runs each read through it, so the
/// decoder, `brioche status --json` and everything printed after them only ever see cleaned
/// strings: a string field added to `StatusSnapshot` later is cleaned without a line here
/// or there. The app's own writer does not come through this, and the file on disk is
/// what it was.
enum TerminalString {
    /// The scalars that go. `Cc` (C0, DEL, C1): an escape would repaint the user's terminal
    /// and a line break would make one line two. `Cf` but the two `joiners`: a bidi override
    /// or isolate prints the line in another order; a zero-width space, a byte-order mark or
    /// a soft hyphen hides inside a name; a subdivision flag's tag characters go too and
    /// leave its black flag. `Zl` and `Zp`: the line and paragraph separators break the line
    /// as a newline does. Letters, marks, digits, punctuation, symbols and the space
    /// separators (Zs) stay; the joiners stay too, but show nothing alone
    /// (`isVisibleOnItsOwn`).
    ///
    /// The one definition: the status line's model name (`StatusLineInput.printable`) and
    /// `clean` both drop exactly these, so the two cannot drift.
    static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator: return true
        case .format: return !joiners.contains(scalar.value)
        default: return false
        }
    }

    /// The zero-width non-joiner and joiner (U+200C, U+200D), the format characters that
    /// stay: they shape Persian and the Indic scripts and join emoji, and they reorder
    /// nothing. They stay where they are in a string that has something else to show, and
    /// a string of them alone, or of them and spaces, shows nothing.
    static let joiners: Set<UInt32> = [0x200C, 0x200D]

    /// A removed scalar that separated two words: the tab and the line breaks (U+0009 to
    /// U+000D, U+0085, U+2028, U+2029). A run of removed scalars holding one of them leaves
    /// a space between the visible characters around it.
    static func isLineBreakOrTab(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x85, 0x2028, 0x2029: return true
        default: return false
        }
    }

    /// What is printed for a string that held something and shows nothing: only removed
    /// scalars, joiners and spaces. An empty label would break the shape of the line it
    /// stands in ("` — working.`"), and the reader should see that a name was there.
    static let unseen = "?"

    /// `text` as a terminal may show it, in one pass over its scalars.
    ///
    /// - Every `isInvisible` scalar goes.
    /// - A run of removed scalars that held a line break or a tab leaves one space where it
    ///   stood between two visible characters, so "fix\nbug" reads "fix bug". Joiners
    ///   beside the run are looked through; next to a space, at the start and at the end
    ///   it leaves nothing. Any other removed scalar leaves nothing.
    /// - Leading and trailing spaces (Zs) are trimmed. Spaces inside are left as they are.
    /// - A string with nothing visible left is `unseen`; an empty one stays empty.
    ///
    /// Scalars are dropped and none is reordered or cut, so a cluster is never split, and
    /// there is no length cap here. Cleaning a cleaned string changes nothing.
    static func clean(_ text: String) -> String {
        var kept = String.UnicodeScalarView()
        // The last scalar kept that is not a joiner shows something (it is not a space).
        var followsVisible = false
        // A line break or a tab went since that scalar.
        var brokeLine = false
        var showsSomething = false
        for scalar in text.unicodeScalars {
            // Printable ASCII is most of every string and needs no property lookup.
            let isPrintableASCII = scalar.value > 0x20 && scalar.value < 0x7F
            if !isPrintableASCII {
                if isInvisible(scalar) {
                    if isLineBreakOrTab(scalar) { brokeLine = true }
                    continue
                }
                if joiners.contains(scalar.value) {
                    kept.append(scalar)
                    continue
                }
                if isSpace(scalar) {
                    followsVisible = false
                    brokeLine = false
                    kept.append(scalar)
                    continue
                }
            }
            if brokeLine, followsVisible { kept.append(" ") }
            followsVisible = true
            brokeLine = false
            showsSomething = true
            kept.append(scalar)
        }
        guard showsSomething else { return text.isEmpty ? "" : unseen }
        guard let first = kept.firstIndex(where: { !isSpace($0) }),
              let last = kept.lastIndex(where: { !isSpace($0) })
        else { return unseen }
        return String(kept[first...last])
    }

    /// A space separator (Zs): U+0020, the no-break space, the ideographic space and the
    /// rest. The only whitespace left once the `isInvisible` scalars are gone.
    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value == 0x20 || scalar.properties.generalCategory == .spaceSeparator
    }

    // MARK: - A JSON text

    /// `data`, a JSON text in UTF-8, with every string in it cleaned: values and keys, at
    /// any depth, whatever they are called. A string `clean` leaves alone keeps its bytes,
    /// so a text with nothing to clean comes back byte for byte; a string it changes is
    /// written again with only `"` and `\` escaped. Everything outside the strings is
    /// copied.
    ///
    /// nil when the bytes are not something the rest can be trusted on: not UTF-8 (a lone
    /// 0x9B is a CSI to an 8-bit terminal), a byte outside a string that JSON's own
    /// punctuation, numbers, literals and whitespace do not use (a byte-order mark, the
    /// NULs of UTF-16), a string that does not end, or one Foundation does not read as a
    /// JSON string (a lone surrogate, a raw control character, an unknown escape). The
    /// app writes none of these.
    ///
    /// The strings are found by their quotes: outside a string a `"` opens one, inside one
    /// a `\` takes the byte after it, and the next `"` closes it. No UTF-8 sequence holds
    /// either byte, so this is the grammar's own boundary. What a string says is read by
    /// `JSONDecoder`, the reader the snapshot is decoded with afterwards, so there is one
    /// reading of every escape. One pass, linear in the size of the text.
    static func cleaningStrings(inJSON data: Data) -> Data? {
        guard String(validating: data, as: UTF8.self) != nil else { return nil }
        let bytes = [UInt8](data)
        var cleaned: [UInt8] = []
        cleaned.reserveCapacity(bytes.count)
        let decoder = JSONDecoder()
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            guard byte == quote else {
                guard isJSONStructure(byte) else { return nil }
                cleaned.append(byte)
                index += 1
                continue
            }
            // A string: `index` is its opening quote, `end` its closing one.
            var end = index + 1
            // Printable ASCII with no escape: what it says is what its bytes say.
            var isPlain = true
            while end < bytes.count, bytes[end] != quote {
                if bytes[end] == backslash {
                    isPlain = false
                    end += 1
                } else if bytes[end] < 0x20 || bytes[end] > 0x7E {
                    isPlain = false
                }
                end += 1
            }
            guard end < bytes.count else { return nil }
            let token = bytes[index...end]
            let needsNoCleaning = isPlain && bytes[index + 1] != space && bytes[end - 1] != space
            if needsNoCleaning {
                cleaned.append(contentsOf: token)
            } else {
                guard let text = try? decoder.decode(String.self, from: Data(token)) else { return nil }
                let shown = clean(text)
                if shown.unicodeScalars.elementsEqual(text.unicodeScalars) {
                    cleaned.append(contentsOf: token)
                } else {
                    cleaned.append(quote)
                    for unit in shown.utf8 {
                        if unit == quote || unit == backslash { cleaned.append(backslash) }
                        cleaned.append(unit)
                    }
                    cleaned.append(quote)
                }
            }
            index = end + 1
        }
        return Data(cleaned)
    }

    private static let quote = UInt8(ascii: "\"")
    private static let backslash = UInt8(ascii: "\\")
    private static let space = UInt8(ascii: " ")

    /// A byte JSON uses outside a string: its punctuation, its four whitespace characters,
    /// and what numbers and `true`, `false` and `null` are written with.
    private static func isJSONStructure(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "{"), UInt8(ascii: "}"), UInt8(ascii: "["), UInt8(ascii: "]"),
             UInt8(ascii: ":"), UInt8(ascii: ","),
             0x20, 0x09, 0x0A, 0x0D,
             UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "-"), UInt8(ascii: "+"), UInt8(ascii: "."),
             UInt8(ascii: "e"), UInt8(ascii: "E"),
             UInt8(ascii: "t"), UInt8(ascii: "r"), UInt8(ascii: "u"),
             UInt8(ascii: "f"), UInt8(ascii: "a"), UInt8(ascii: "l"), UInt8(ascii: "s"),
             UInt8(ascii: "n"):
            return true
        default:
            return false
        }
    }
}
