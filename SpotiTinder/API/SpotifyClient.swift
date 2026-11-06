import Foundation

enum SpotifyAPIError: LocalizedError {
    case http(Int, String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .http(let status, let message): "Spotify error \(status): \(message)"
        case .invalidResponse: "Unexpected response from Spotify."
        }
    }
}

/// Authorized Web API requests with token refresh on 401 and backoff on 429/5xx.
@MainActor
final class SpotifyClient {
    static let baseURL = URL(string: "https://api.spotify.com/v1/")!

    private let auth: SpotifyAuth
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()

    init(auth: SpotifyAuth) {
        self.auth = auth
    }

    func url(_ path: String, query: [String: String] = [:]) -> URL {
        var components = URLComponents(url: Self.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url!
    }

    func get<T: Decodable>(_ url: URL) async throws -> T {
        try decoder.decode(T.self, from: try await send("GET", url))
    }

    /// Sends a JSON body and decodes the response.
    func request<Response: Decodable>(_ method: String, _ url: URL, body: some Encodable) async throws -> Response {
        let data = try await send(method, url, jsonBody: try encoder.encode(body))
        return try decoder.decode(Response.self, from: data)
    }

    /// Sends a JSON body and ignores the response.
    func perform(_ method: String, _ url: URL, body: some Encodable) async throws {
        try await send(method, url, jsonBody: try encoder.encode(body))
    }

    @discardableResult
    func send(_ method: String, _ url: URL, jsonBody: Data? = nil) async throws -> Data {
        var forceRefresh = false
        var didRefresh = false
        var attempt = 0

        while true {
            attempt += 1
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("Bearer \(try await auth.validAccessToken(forceRefresh: forceRefresh))", forHTTPHeaderField: "Authorization")
            forceRefresh = false
            if let jsonBody {
                request.httpBody = jsonBody
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw SpotifyAPIError.invalidResponse }

            switch http.statusCode {
            case 200..<300:
                return data
            case 401 where !didRefresh:
                didRefresh = true
                forceRefresh = true
            case 429, 500, 502, 503, 504:
                let wait = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? Double(attempt)
                guard attempt < 6, wait <= 60 else { throw SpotifyAPIError.http(http.statusCode, Self.message(from: data)) }
                try await Task.sleep(for: .seconds(wait))
            default:
                throw SpotifyAPIError.http(http.statusCode, Self.message(from: data))
            }
        }
    }

    private static func message(from data: Data) -> String {
        struct Envelope: Decodable {
            struct Inner: Decodable { let message: String? }
            let error: Inner?
        }
        if let message = (try? JSONDecoder().decode(Envelope.self, from: data))?.error?.message {
            return message
        }
        return String(decoding: data, as: UTF8.self)
    }
}
