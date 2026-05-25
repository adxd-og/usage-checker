import Foundation

struct OAuthTokenResponse: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?
    let tokenType: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
    }
}

struct OAuthRefreshClient: Sendable {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let tokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!

    let http: HTTPClient

    init(http: HTTPClient = HTTPClient()) {
        self.http = http
    }

    func refresh(refreshToken: String, userAgent: String) async throws -> OAuthTokenResponse {
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID,
        ]
        let headers = [
            "User-Agent": userAgent,
            "Accept": "application/json",
        ]
        return try await http.postJSON(
            Self.tokenURL,
            json: body,
            headers: headers,
            as: OAuthTokenResponse.self,
            maxRetries: 1
        )
    }
}
