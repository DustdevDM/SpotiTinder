import CryptoKit
import Foundation
import Observation

struct SpotifyToken: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    /// Space-separated scopes Spotify granted. Nil for tokens saved before this was tracked.
    var scope: String?
}

struct AuthorizationRequest: Sendable {
    let url: URL
    let verifier: String
    let state: String
}

enum AuthError: LocalizedError {
    case denied(String)
    case stateMismatch
    case missingCode
    case notLoggedIn
    case tokenRequestFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .denied(let reason): "Spotify login was denied (\(reason))."
        case .stateMismatch: "Login response didn't match the request. Please try again."
        case .missingCode: "Spotify didn't return an authorization code."
        case .notLoggedIn: "You're logged out. Please log in again."
        case .tokenRequestFailed(let status, let body): "Token request failed (\(status)): \(body)"
        }
    }
}

/// Spotify login using Authorization Code + PKCE, so no client secret ships in the app.
@MainActor @Observable
final class SpotifyAuth {
    private(set) var token: SpotifyToken?
    var isLoggedIn: Bool { token != nil }

    /// False when the saved login predates a scope the app now asks for, so you need to log in again.
    func hasScope(_ scope: String) -> Bool {
        token?.scope?.split(separator: " ").contains { $0 == scope } ?? false
    }

    @ObservationIgnored private var refreshTask: Task<SpotifyToken, Error>?
    private static let keychainKey = "spotify.token"

    init() {
        if let data = Keychain.load(Self.keychainKey) {
            token = try? JSONDecoder().decode(SpotifyToken.self, from: data)
        }
    }

    func makeAuthorizationRequest() -> AuthorizationRequest {
        let verifier = Self.randomString(length: 64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
        let state = Self.randomString(length: 16)

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Config.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Config.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: Config.scopes.joined(separator: " ")),
        ]
        return AuthorizationRequest(url: components.url!, verifier: verifier, state: state)
    }

    func completeLogin(callbackURL: URL, request: AuthorizationRequest) async throws {
        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        if let error = value("error") { throw AuthError.denied(error) }
        guard value("state") == request.state else { throw AuthError.stateMismatch }
        guard let code = value("code") else { throw AuthError.missingCode }

        let response = try await requestToken([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Config.redirectURI,
            "client_id": Config.clientID,
            "code_verifier": request.verifier,
        ])
        store(SpotifyToken(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? "",
            expiresAt: Date().addingTimeInterval(response.expiresIn),
            scope: response.scope
        ))
    }

    /// Returns a usable access token, refreshing it first if it expires within a minute.
    func validAccessToken(forceRefresh: Bool = false) async throws -> String {
        guard let token else { throw AuthError.notLoggedIn }
        if !forceRefresh, token.expiresAt.timeIntervalSinceNow > 60 { return token.accessToken }
        if let refreshTask { return try await refreshTask.value.accessToken }

        let task = Task { try await self.refresh(using: token.refreshToken) }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value.accessToken
    }

    func logout() {
        token = nil
        Keychain.delete(Self.keychainKey)
    }

    private func refresh(using refreshToken: String) async throws -> SpotifyToken {
        do {
            let response = try await requestToken([
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "client_id": Config.clientID,
            ])
            let newToken = SpotifyToken(
                accessToken: response.accessToken,
                refreshToken: response.refreshToken ?? refreshToken,
                expiresAt: Date().addingTimeInterval(response.expiresIn),
                scope: response.scope ?? token?.scope
            )
            store(newToken)
            return newToken
        } catch AuthError.tokenRequestFailed(400, _) {
            // Refresh token revoked or expired: force a fresh login.
            logout()
            throw AuthError.notLoggedIn
        }
    }

    private func store(_ token: SpotifyToken) {
        self.token = token
        if let data = try? JSONEncoder().encode(token) {
            Keychain.save(data, for: Self.keychainKey)
        }
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: TimeInterval
        let scope: String?
    }

    private func requestToken(_ form: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form
            .map { "\($0.key)=\($0.value.formEncoded)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw AuthError.tokenRequestFailed(status, String(decoding: data, as: UTF8.self))
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(TokenResponse.self, from: data)
    }

    private static func randomString(length: Int) -> String {
        let characters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<length).map { _ in characters.randomElement()! })
    }
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension String {
    var formEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
