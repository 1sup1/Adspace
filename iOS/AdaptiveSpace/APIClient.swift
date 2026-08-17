import Foundation

protocol CommandRouting: Sendable {
    func route(_ request: CommandRouteRequest) async throws -> CommandRouteResponse?
    func updateTools(_ tools: [RegisteredTool]) async
}

extension CommandRouting {
    func updateTools(_ tools: [RegisteredTool]) async {}
}

protocol AdaptiveSpaceAPI: Sendable {
    func recommendation(_ request: RecommendationRequest) async throws -> RecommendationResponse
    func chat(messages: [AgentChatTurn], recommendation: RecommendationResponse?) async throws -> AgentChatResponse
    func space() async throws -> SpaceSpec
    func createSession(profile: EnvironmentProfile) async throws -> SpaceSession
    func command(sessionId: String, proposalId: String) async throws -> SpaceSession
    func routeCommand(_ request: CommandRouteRequest) async throws -> CommandRouteResponse
    func tools() async throws -> [RegisteredTool]
    func proposeBuiltIn(
        action: String,
        arguments: [String: JSONValue],
        scope: String?,
        sessionId: String?
    ) async throws -> CommandProposal
    func proposeTool(id: String, arguments: [String: JSONValue], scope: String?) async throws -> CommandProposal
    func approveToolDraft(id: String, proposalId: String) async throws -> ToolApprovalResponse
    func rejectToolDraft(id: String, proposalId: String) async throws
    func confirmProposal(id: String) async throws -> ProposalConfirmationResponse
}

struct APIClient: AdaptiveSpaceAPI, Sendable {
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

    func chat(messages: [AgentChatTurn], recommendation: RecommendationResponse?) async throws -> AgentChatResponse {
        struct Body: Encodable {
            let messages: [AgentChatTurn]
            let context: AgentChatContext?
        }
        let context = recommendation.map {
            AgentChatContext(
                context: $0.context,
                confidence: $0.confidence,
                profile: $0.profile,
                reason: $0.reason
            )
        }
        return try await send("v1/chat", method: "POST", body: Body(messages: messages, context: context))
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

    func command(sessionId: String, proposalId: String) async throws -> SpaceSession {
        struct Body: Encodable {
            let proposalId: String
            enum CodingKeys: String, CodingKey { case proposalId = "proposal_id" }
        }
        return try await send(
            "v1/sessions/\(sessionId)/commands",
            method: "POST",
            body: Body(proposalId: proposalId)
        )
    }

    func routeCommand(_ request: CommandRouteRequest) async throws -> CommandRouteResponse {
        try await send("v1/commands/route", method: "POST", body: request)
    }

    func tools() async throws -> [RegisteredTool] {
        let response: RegisteredToolsResponse = try await send(
            "v1/tools",
            method: "GET",
            body: Optional<Int>.none
        )
        return response.tools
    }

    func proposeBuiltIn(
        action: String,
        arguments: [String: JSONValue],
        scope: String?,
        sessionId: String?
    ) async throws -> CommandProposal {
        struct Body: Encodable {
            let arguments: [String: JSONValue]
            let scope: String?
            let sessionId: String?

            enum CodingKeys: String, CodingKey {
                case arguments, scope
                case sessionId = "session_id"
            }
        }
        return try await send(
            "v1/builtin-tools/\(action)/proposals",
            method: "POST",
            body: Body(arguments: arguments, scope: scope, sessionId: sessionId)
        )
    }

    func proposeTool(
        id: String,
        arguments: [String: JSONValue],
        scope: String?
    ) async throws -> CommandProposal {
        struct Body: Encodable {
            let arguments: [String: JSONValue]
            let scope: String?
        }
        return try await send(
            "v1/tools/\(id)/proposals",
            method: "POST",
            body: Body(arguments: arguments, scope: scope)
        )
    }

    func approveToolDraft(id: String, proposalId: String) async throws -> ToolApprovalResponse {
        struct Body: Encodable {
            let proposalId: String
            enum CodingKeys: String, CodingKey { case proposalId = "proposal_id" }
        }
        return try await send(
            "v1/tool-drafts/\(id)/approve",
            method: "POST",
            body: Body(proposalId: proposalId)
        )
    }

    func rejectToolDraft(id: String, proposalId: String) async throws {
        struct Body: Encodable {
            let proposalId: String
            enum CodingKeys: String, CodingKey { case proposalId = "proposal_id" }
        }
        try await sendWithoutResponse(
            "v1/tool-drafts/\(id)/reject",
            method: "POST",
            body: Body(proposalId: proposalId)
        )
    }

    func confirmProposal(id: String) async throws -> ProposalConfirmationResponse {
        try await send(
            "v1/command-proposals/\(id)/confirm",
            method: "POST",
            body: Optional<Int>.none
        )
    }

    private func send<Response: Decodable, Body: Encodable>(
        _ path: String,
        method: String,
        body: Body?
    ) async throws -> Response {
        let data = try await responseData(path, method: method, body: body)
        return try decoder.decode(Response.self, from: data)
    }

    private func sendWithoutResponse<Body: Encodable>(
        _ path: String,
        method: String,
        body: Body?
    ) async throws {
        _ = try await responseData(path, method: method, body: body)
    }

    private func responseData<Body: Encodable>(
        _ path: String,
        method: String,
        body: Body?
    ) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try encoder.encode(body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard 200..<300 ~= http.statusCode else {
            throw ClientError.server(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        return data
    }
}
