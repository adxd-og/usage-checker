import Foundation

enum HTTPClientError: LocalizedError, Sendable {
    case badStatus(Int, body: String)
    case rateLimited(retryAfter: TimeInterval?)
    case tooManyRetries
    case invalidResponse
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .badStatus(let code, _):
            // Never the response body: this string reaches the UI as `lastError`,
            // and a 401/403 body from the usage API can carry token detail. The
            // body is logged at the throw site instead, where only the console
            // sees it.
            if let reason = Self.reason(for: code) { return "HTTP \(code) (\(reason))" }
            return "HTTP \(code)"
        case .rateLimited(let retryAfter):
            if let s = retryAfter { return "Rate limited (retry after \(Int(s))s)" }
            return "Rate limited"
        case .tooManyRetries:
            return "Too many retries"
        case .invalidResponse:
            return "Invalid response"
        case .decoding(let msg):
            return "Decoding failed: \(msg)"
        }
    }

    /// A word for the codes a user can act on; anything else stays a bare number
    /// rather than inventing an explanation.
    private static func reason(for code: Int) -> String? {
        switch code {
        case 400: return "bad request"
        case 401: return "unauthorized"
        case 403: return "forbidden"
        case 404: return "not found"
        case 408: return "request timeout"
        case 500: return "server error"
        case 502: return "bad gateway"
        case 503: return "service unavailable"
        case 504: return "gateway timeout"
        default: return nil
        }
    }
}

struct HTTPClient: Sendable {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func get<T: Decodable>(
        _ url: URL,
        headers: [String: String],
        as _: T.Type,
        maxRetries: Int = 3
    ) async throws -> T {
        let data = try await raw(url: url, method: "GET", body: nil, headers: headers, maxRetries: maxRetries)
        do {
            return try JSONDecoder.usageTracker.decode(T.self, from: data)
        } catch {
            throw HTTPClientError.decoding(String(describing: error))
        }
    }

    func getRaw(
        _ url: URL,
        headers: [String: String],
        maxRetries: Int = 3
    ) async throws -> Data {
        try await raw(url: url, method: "GET", body: nil, headers: headers, maxRetries: maxRetries)
    }

    func postJSON<T: Decodable>(
        _ url: URL,
        json: [String: Any],
        headers: [String: String],
        as _: T.Type,
        maxRetries: Int = 2
    ) async throws -> T {
        let body = try JSONSerialization.data(withJSONObject: json, options: [])
        var h = headers
        h["Content-Type"] = "application/json"
        let data = try await raw(url: url, method: "POST", body: body, headers: h, maxRetries: maxRetries)
        do {
            return try JSONDecoder.usageTracker.decode(T.self, from: data)
        } catch {
            throw HTTPClientError.decoding(String(describing: error))
        }
    }

    private func raw(
        url: URL,
        method: String,
        body: Data?,
        headers: [String: String],
        maxRetries: Int
    ) async throws -> Data {
        var attempt = 0
        var delay: UInt64 = 1_000_000_000
        while true {
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.httpBody = body
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            req.timeoutInterval = 15

            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                throw HTTPClientError.invalidResponse
            }

            let code = http.statusCode
            if (200..<300).contains(code) {
                return data
            }
            if code == 429 {
                // Retrying a rate-limit only deepens it. Surface Retry-After and let the
                // caller back off until it clears (the poll loop tries again later).
                throw HTTPClientError.rateLimited(retryAfter: Self.retryAfterSeconds(http))
            }
            if (500..<600).contains(code) && attempt < maxRetries {
                attempt += 1
                try? await Task.sleep(nanoseconds: delay)
                delay = min(delay * 2, 60_000_000_000)
                continue
            }
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            // The only place the body is allowed to surface — debugging a 4xx is
            // impossible without it, and the console is not the UI.
            NSLog("[UT] HTTP %d from %@: %@", code, url.absoluteString,
                  String(bodyStr.prefix(200)).trimmingCharacters(in: .whitespacesAndNewlines))
            throw HTTPClientError.badStatus(code, body: bodyStr)
        }
    }

    /// Parses a `Retry-After` header (delta-seconds or HTTP-date) into seconds from now.
    private static func retryAfterSeconds(_ resp: HTTPURLResponse) -> TimeInterval? {
        guard let raw = resp.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let secs = TimeInterval(raw) { return max(0, secs) }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "GMT")
        fmt.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        if let date = fmt.date(from: raw) { return max(0, date.timeIntervalSinceNow) }
        return nil
    }
}

extension JSONDecoder {
    static let usageTracker: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) {
                if let date = parseFlexibleISODate(s) {
                    return date
                }
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad date: \(s)")
            }
            if let n = try? c.decode(Double.self) {
                return Date(timeIntervalSince1970: n > 10_000_000_000 ? n / 1000 : n)
            }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown date type")
        }
        return d
    }()
}

private let fractionRegex = try! NSRegularExpression(pattern: #"\.(\d{1,9})"#)

func parseFlexibleISODate(_ raw: String) -> Date? {
    let s = normalizeFraction(raw)

    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFraction.date(from: s) { return date }

    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    if let date = plain.date(from: stripFraction(s)) { return date }

    let withColon = ISO8601DateFormatter()
    withColon.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
    if let date = withColon.date(from: stripFraction(s)) { return date }

    return nil
}

private func normalizeFraction(_ s: String) -> String {
    let range = NSRange(s.startIndex..<s.endIndex, in: s)
    guard let match = fractionRegex.firstMatch(in: s, range: range),
          match.numberOfRanges >= 2,
          let digitsRange = Range(match.range(at: 1), in: s)
    else { return s }
    let digits = s[digitsRange]
    let trimmed = String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
    return s.replacingCharacters(in: digitsRange, with: trimmed)
}

private func stripFraction(_ s: String) -> String {
    let range = NSRange(s.startIndex..<s.endIndex, in: s)
    return fractionRegex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
}

extension ISO8601DateFormatter {
    nonisolated(unsafe) static let usageTracker: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
