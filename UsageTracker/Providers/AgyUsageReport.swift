import Foundation

/// Why an `agy -p /usage` run gave no reading. Every case is quiet: the provider logs it
/// and asks the web API instead; the state chip stays the grey "not running" one.
enum AgyUsageError: Error, Equatable {
    /// agy answered, with a `status` other than SUCCESS ("" when it wrote none).
    case status(String)
    /// agy printed no JSON object, or one without a quota group.
    case unreadable(String)
    /// agy could not be started.
    case launchFailed(String)
    /// agy was still running, or its stdout still open, at the deadline.
    case timedOut
    /// agy exited non-zero, or a signal of this number ended it.
    case exitStatus(Int32)
    /// agy printed more than `AgyCommand.outputLimit`; it was stopped there.
    case outputTooLarge
}

/// What `agy -p /usage --output-format json` prints, reduced to the quota. agy prints one
/// JSON object: `status` is "SUCCESS", no model turn runs (`num_turns` 0), and the quota is
/// under `command.data.groups`, one group per pool or per-model limit, named as Antigravity
/// names it ("Claude and GPT models", Argon's own group).
struct AgyUsageReport: Equatable, Sendable {
    /// One quota group under agy's name for it, with the buckets agy reported.
    struct Group: Equatable, Sendable {
        let name: String
        let buckets: [Bucket]
    }

    /// One limit of a group. `window` is agy's cadence, lowercased ("weekly", "5h");
    /// `remainingFraction` is the share left, 0...1, nil when agy reported none.
    struct Bucket: Equatable, Sendable {
        let id: String
        let name: String
        let window: String?
        let remainingFraction: Double?
        let resetTime: Date?
        let disabled: Bool
    }

    let groups: [Group]

    /// agy's stdout as a report. A notice printed before the object is skipped: the object
    /// is read from the first "{" to the last "}". Throws `.status` for any status but
    /// SUCCESS, `.unreadable` when there is no object or no group with a bucket. A bucket
    /// without an id is dropped; one without a name is named by its id.
    static func parse(_ stdout: Data) throws -> AgyUsageReport {
        guard let payload = decode(stdout) else {
            throw AgyUsageError.unreadable("no JSON object in agy's output")
        }
        guard payload.status == "SUCCESS" else {
            throw AgyUsageError.status(payload.status ?? "")
        }
        let groups = (payload.command?.data?.groups ?? []).compactMap { group($0) }
        guard !groups.isEmpty else {
            throw AgyUsageError.unreadable("no quota group in agy's output")
        }
        return AgyUsageReport(groups: groups)
    }

    private static func decode(_ data: Data) -> Payload? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        if let whole = try? decoder.decode(Payload.self, from: data) { return whole }
        guard let open = data.firstIndex(of: UInt8(ascii: "{")),
              let close = data.lastIndex(of: UInt8(ascii: "}")),
              open < close
        else { return nil }
        return try? decoder.decode(Payload.self, from: data[open...close])
    }

    private static func group(_ payload: Payload.Group) -> Group? {
        let buckets = (payload.buckets ?? []).compactMap { bucket($0) }
        guard !buckets.isEmpty else { return nil }
        return Group(
            name: (payload.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            buckets: buckets
        )
    }

    private static func bucket(_ payload: Payload.Bucket) -> Bucket? {
        let id = (payload.id ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        let name = (payload.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return Bucket(
            id: id,
            name: name.isEmpty ? id : name,
            window: payload.window?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            remainingFraction: payload.remainingFraction,
            resetTime: date(payload.resetTime),
            disabled: payload.disabled ?? false
        )
    }

    /// ISO-8601 in UTC as agy writes it ("2026-10-23T07:46:06Z"), fractional seconds
    /// allowed. Anything else is no reset time.
    private static func date(_ text: String?) -> Date? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    /// agy's JSON, only the keys the report reads (snake_case on the wire).
    private struct Payload: Decodable {
        struct Group: Decodable {
            let name: String?
            let buckets: [Bucket]?
        }

        struct Bucket: Decodable {
            let id: String?
            let name: String?
            let window: String?
            let remainingFraction: Double?
            let resetTime: String?
            let disabled: Bool?
        }

        struct Body: Decodable {
            let groups: [Group]?
        }

        struct Command: Decodable {
            let data: Body?
        }

        let status: String?
        let command: Command?
    }
}
