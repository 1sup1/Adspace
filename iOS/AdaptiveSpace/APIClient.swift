import Foundation

struct APIClient: Sendable {
    enum ClientError: LocalizedError {
        case invalidResponse
        case server(Int, String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse: "서버 응답을 확인할 수 없습니다."
            case let .server(code, message): "서버 오류 \(code): \(message)"
            }
        }
    }

    private let baseURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(baseURL: URL = URL(string: ProcessInfo.processInfo.environment["ADSPACE_SERVER_URL"] ?? "http://127.0.0.1:8000")!) {
        self.baseURL = baseURL
    }

    func recommendation(_ request: RecommendationRequest) async throws -> RecommendationResponse {
        try await send("v1/recommendations", method: "POST", body: request)
    }

    func space() async throws -> SpaceSpec {
        try await send("v1/spaces/hotel-demo-room", method: "GET", body: Optional<Int>.none)
    }

    func createSession(profile: EnvironmentProfile) async throws -> SpaceSession {
        struct Body: Encodable {
            let profile: EnvironmentProfile
            let ttlSeconds = 900
            enum CodingKeys: String, CodingKey { case profile; case ttlSeconds = "ttl_seconds" }
        }
        return try await send("v1/spaces/hotel-demo-room/sessions", method: "POST", body: Body(profile: profile))
    }

    func command(sessionId: String, action: String) async throws -> SpaceSession {
        struct Body: Encodable { let action: String }
        return try await send("v1/sessions/\(sessionId)/commands", method: "POST", body: Body(action: action))
    }

    private func send<Response: Decodable, Body: Encodable>(
        _ path: String,
        method: String,
        body: Body?
    ) async throws -> Response {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try encoder.encode(body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard 200..<300 ~= http.statusCode else {
            throw ClientError.server(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        return try decoder.decode(Response.self, from: data)
    }
}
