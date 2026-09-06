import Foundation

/// What the argument list asked for. Parsing is separate from doing so the app's test
/// bundle can pin every spelling — a CLI whose flags are only exercised by hand grows
/// a new one every release and loses an old one to a typo.
enum CLICommand: Equatable, Sendable {
    case help
    case version
    case status(json: Bool)
    case statusLine(provider: String)
    case mcp
    /// Bad arguments, with the sentence to print before the usage text.
    case usageError(String)

    /// `arguments` is `CommandLine.arguments.dropFirst()` — the program name is gone.
    ///
    /// No arguments prints the usage text rather than guessing: three commands do
    /// three unrelated things, and one of them is a server that would sit there
    /// holding the terminal.
    static func parse(_ arguments: [String]) -> CLICommand {
        guard let first = arguments.first else { return .help }
        let rest = Array(arguments.dropFirst())
        switch first {
        case "help", "--help", "-h":
            return .help
        case "version", "--version", "-v":
            return .version
        case "status":
            return parseStatus(rest)
        case "statusline":
            return parseStatusLine(rest)
        case "mcp":
            guard rest.isEmpty else { return .usageError("`mcp` takes no options: \(rest[0])") }
            return .mcp
        default:
            return .usageError("Unknown command: \(first)")
        }
    }

    private static func parseStatus(_ arguments: [String]) -> CLICommand {
        var json = false
        for argument in arguments {
            switch argument {
            case "--json": json = true
            default: return .usageError("Unknown option for `status`: \(argument)")
            }
        }
        return .status(json: json)
    }

    private static func parseStatusLine(_ arguments: [String]) -> CLICommand {
        var provider = "claude"
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--provider":
                index += 1
                guard index < arguments.count, !arguments[index].hasPrefix("-") else {
                    return .usageError("`--provider` needs a provider id, for example `--provider codex`")
                }
                provider = arguments[index]
            default:
                return .usageError("Unknown option for `statusline`: \(argument)")
            }
            index += 1
        }
        return .statusLine(provider: provider)
    }
}
