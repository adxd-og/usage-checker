import Foundation

enum HTTPClientError: LocalizedError, Sendable {
    case badStatus(Int, body: String)
    case tooManyRetries
    case invalidResponse
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .badStatus(let code, let body):
            return "HTTP \(code): \(body.prefix(200))"
        case .tooManyRetries:
            return "Too many retries"
        case .invalidResponse:
            return "Invalid response"
        case .decoding(let msg):
            return "Decoding failed: \(msg)"
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
            if (code == 429 || (500..<600).contains(code)) && attempt < maxRetries {
                attempt += 1
                try? await Task.sleep(nanoseconds: delay)
                delay = min(delay * 2, 60_000_000_000)
                continue
            }
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw HTTPClientError.badStatus(code, body: bodyStr)
        }
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
