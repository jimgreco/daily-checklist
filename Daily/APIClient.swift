import Foundation

struct APIClient {
    enum APIError: Error {
        case invalidURL
        case badResponse(Int)
    }

    private let baseURL: URL

    init() {
        let configured = Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as? String
        self.baseURL = URL(string: configured ?? "http://127.0.0.1:8787")!
    }

    func signInWithGoogle(idToken: String) async throws -> AuthResponse {
        try await post(path: "auth/google", body: ["idToken": idToken])
    }

    func signInWithApple(identityToken: String, fullName: PersonNameComponents?) async throws -> AuthResponse {
        struct Name: Codable { var givenName: String?; var familyName: String? }
        struct Body: Codable { var identityToken: String; var fullName: Name? }
        return try await post(
            path: "auth/apple",
            body: Body(
                identityToken: identityToken,
                fullName: fullName.map { Name(givenName: $0.givenName, familyName: $0.familyName) }
            )
        )
    }

    func refresh(refreshToken: String) async throws -> AuthResponse {
        try await post(path: "auth/refresh", body: ["refreshToken": refreshToken])
    }

    #if DEBUG
    func devSignIn() async throws -> AuthResponse {
        try await post(path: "auth/dev", body: ["email": "dev@daily.local", "name": "Local Dev"])
    }
    #endif

    func currentUser(token: String) async throws -> AppUser {
        try await request(path: "auth/me", method: "GET", token: token, body: nil)
    }

    func sync(_ requestBody: SyncRequest, token: String) async throws -> SyncResponse {
        try await request(path: "api/sync", method: "POST", token: token, body: encoder.encode(requestBody))
    }

    private func post<T: Decodable, Body: Encodable>(path: String, body: Body) async throws -> T {
        try await request(path: path, method: "POST", token: nil, body: encoder.encode(body))
    }

    private func request<T: Decodable>(
        path: String,
        method: String,
        token: String?,
        body: Data?
    ) async throws -> T {
        let url = baseURL.appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse(0) }
        guard (200..<300).contains(http.statusCode) else { throw APIError.badResponse(http.statusCode) }
        return try decoder.decode(T.self, from: data)
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
