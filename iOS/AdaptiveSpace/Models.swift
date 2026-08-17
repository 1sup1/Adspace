import Foundation

enum DemoScenario: String, CaseIterable, Codable, Identifiable, Sendable {
    case recovery
    case focus
    case calm

    var id: Self { self }

    var title: String {
        switch self {
        case .recovery: "회복 필요"
        case .focus: "집중 필요"
        case .calm: "안정 필요"
        }
    }

    var symbol: String {
        switch self {
        case .recovery: "moon.stars.fill"
        case .focus: "scope"
        case .calm: "wind"
        }
    }
}

enum ConsentedMetric: String, CaseIterable, Codable, Identifiable, Sendable {
    case sleepScore = "sleep_score"
    case activitySteps = "activity_steps"
    case heartRateBPM = "heart_rate_bpm"
    case hrvMS = "hrv_ms"

    var id: Self { self }

    var title: String {
        switch self {
        case .sleepScore: "수면 점수"
        case .activitySteps: "활동량"
        case .heartRateBPM: "심박"
        case .hrvMS: "HRV"
        }
    }
}

struct WearableSnapshot: Codable, Sendable {
    let id: String
    let source: String
    let capturedAt: String
    let sleepScore: Int?
    let activitySteps: Int?
    let heartRateBPM: Int?
    let hrvMS: Int?
    let timeOfDay: String

    enum CodingKeys: String, CodingKey {
        case id, source
        case capturedAt = "captured_at"
        case sleepScore = "sleep_score"
        case activitySteps = "activity_steps"
        case heartRateBPM = "heart_rate_bpm"
        case hrvMS = "hrv_ms"
        case timeOfDay = "time_of_day"
    }

    func filtered(by consent: Set<ConsentedMetric>) -> Self {
        Self(
            id: id,
            source: source,
            capturedAt: capturedAt,
            sleepScore: consent.contains(.sleepScore) ? sleepScore : nil,
            activitySteps: consent.contains(.activitySteps) ? activitySteps : nil,
            heartRateBPM: consent.contains(.heartRateBPM) ? heartRateBPM : nil,
            hrvMS: consent.contains(.hrvMS) ? hrvMS : nil,
            timeOfDay: timeOfDay
        )
    }
}

struct Adjustment: Codable, Sendable {
    let brightnessDelta: Int
    let temperatureDeltaC: Double
    let soundPreset: String?

    enum CodingKeys: String, CodingKey {
        case brightnessDelta = "brightness_delta"
        case temperatureDeltaC = "temperature_delta_c"
        case soundPreset = "sound_preset"
    }
}

struct RecommendationRequest: Codable, Sendable {
    let snapshot: WearableSnapshot
    let recentSnapshots: [WearableSnapshot]
    let consentedFields: [ConsentedMetric]
    let adjustment: Adjustment

    enum CodingKeys: String, CodingKey {
        case snapshot, adjustment
        case recentSnapshots = "recent_snapshots"
        case consentedFields = "consented_fields"
    }
}

struct LightingProfile: Codable, Equatable, Sendable {
    let brightnessPercent: Int
    let colorTemperatureK: Int

    enum CodingKeys: String, CodingKey {
        case brightnessPercent = "brightness_percent"
        case colorTemperatureK = "color_temperature_k"
    }
}

struct EnvironmentProfile: Codable, Equatable, Sendable {
    let lighting: LightingProfile
    let temperatureC: Double
    let soundPreset: String

    enum CodingKeys: String, CodingKey {
        case lighting
        case temperatureC = "temperature_c"
        case soundPreset = "sound_preset"
    }
}

struct RecommendationResponse: Codable, Sendable {
    let profileId: String
    let context: DemoScenario
    let confidence: Double
    let profile: EnvironmentProfile
    let reason: String
    let requiresConfirmation: Bool
    let inputSource: String
    let generatedBy: String
    let observedSampleCount: Int
    let evidence: [String]
    let comparison: DecisionComparison

    enum CodingKeys: String, CodingKey {
        case context, confidence, profile, reason, comparison
        case profileId = "profile_id"
        case requiresConfirmation = "requires_confirmation"
        case inputSource = "input_source"
        case generatedBy = "generated_by"
        case observedSampleCount = "observed_sample_count"
        case evidence
    }
}

struct ContextDecision: Codable, Sendable {
    let context: DemoScenario
    let confidence: Double
    let reason: String
    let evidence: [String]
}

struct DecisionComparison: Codable, Sendable {
    let ruleBased: ContextDecision
    let agent: ContextDecision
    let signalEvidence: [String]
    let conflictDetected: Bool
    let selected: String

    enum CodingKeys: String, CodingKey {
        case agent, selected
        case ruleBased = "rule_based"
        case signalEvidence = "signal_evidence"
        case conflictDetected = "conflict_detected"
    }
}

struct AgentChatTurn: Codable, Sendable {
    let role: String
    let content: String
}

struct AgentChatContext: Codable, Sendable {
    let context: DemoScenario
    let confidence: Double
    let profile: EnvironmentProfile
    let reason: String
}

struct AgentChatResponse: Codable, Sendable {
    let message: String
}

enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case integer(Int)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.typeMismatch(
                JSONValue.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unsupported JSON value"
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var intValue: Int? {
        switch self {
        case let .integer(value): value
        case let .number(value): Int(exactly: value)
        default: nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case let .integer(value): Double(value)
        case let .number(value): value
        default: nil
        }
    }

    var displayValue: String {
        switch self {
        case let .string(value): value
        case let .integer(value): value.formatted()
        case let .number(value): value.formatted()
        case let .bool(value): value ? "예" : "아니요"
        case let .object(value): value.keys.sorted().joined(separator: ", ")
        case let .array(value): value.map(\.displayValue).joined(separator: ", ")
        case .null: "없음"
        }
    }
}

enum CommandRouteKind: String, Codable, Sendable {
    case builtinProposal = "builtin_proposal"
    case dynamicProposal = "dynamic_proposal"
    case toolDraft = "tool_draft"
    case chat
}

struct CommandRouteRequest: Encodable, Sendable {
    let text: String
    let scope: String?
    let sessionId: String?
    let deviceIds: [String]?
    let messages: [AgentChatTurn]
    let context: AgentChatContext?

    enum CodingKeys: String, CodingKey {
        case text, scope, messages, context
        case sessionId = "session_id"
        case deviceIds = "device_ids"
    }

    init(
        text: String,
        scope: String? = nil,
        sessionId: String? = nil,
        deviceIds: [String]? = nil,
        messages: [AgentChatTurn] = [],
        context: AgentChatContext? = nil
    ) {
        self.text = text
        self.scope = scope
        self.sessionId = sessionId
        self.deviceIds = deviceIds
        self.messages = messages
        self.context = context
    }
}

struct CommandProposal: Codable, Equatable, Sendable {
    let proposalId: String?
    let toolId: String?
    let toolName: String?
    let action: String?
    let arguments: [String: JSONValue]
    let confidence: Double?
    let requiresConfirmation: Bool
    let source: String?
    let toolKind: String?
    let deviceId: String?
    let capabilityId: String?
    let scope: String?
    let sessionId: String?
    let expiresAt: String?
    let confirmationText: String?

    enum CodingKeys: String, CodingKey {
        case action, arguments, confidence, source, scope
        case proposalId = "proposal_id"
        case toolId = "tool_id"
        case toolName = "tool_name"
        case toolKind = "tool_kind"
        case deviceId = "device_id"
        case capabilityId = "capability_id"
        case sessionId = "session_id"
        case expiresAt = "expires_at"
        case confirmationText = "confirmation_text"
        case requiresConfirmation = "requires_confirmation"
    }

    init(
        proposalId: String? = nil,
        toolId: String? = nil,
        toolName: String? = nil,
        action: String? = nil,
        arguments: [String: JSONValue] = [:],
        confidence: Double? = nil,
        requiresConfirmation: Bool = true,
        source: String? = nil,
        toolKind: String? = nil,
        deviceId: String? = nil,
        capabilityId: String? = nil,
        scope: String? = nil,
        sessionId: String? = nil,
        expiresAt: String? = nil,
        confirmationText: String? = nil
    ) {
        self.proposalId = proposalId
        self.toolId = toolId
        self.toolName = toolName
        self.action = action
        self.arguments = arguments
        self.confidence = confidence
        self.requiresConfirmation = requiresConfirmation
        self.source = source
        self.toolKind = toolKind
        self.deviceId = deviceId
        self.capabilityId = capabilityId
        self.scope = scope
        self.sessionId = sessionId
        self.expiresAt = expiresAt
        self.confirmationText = confirmationText
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        proposalId = try container.decodeIfPresent(String.self, forKey: .proposalId)
        toolId = try container.decodeIfPresent(String.self, forKey: .toolId)
        toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
        action = try container.decodeIfPresent(String.self, forKey: .action)
        arguments = try container.decodeIfPresent([String: JSONValue].self, forKey: .arguments) ?? [:]
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
        requiresConfirmation = try container.decodeIfPresent(Bool.self, forKey: .requiresConfirmation) ?? true
        source = try container.decodeIfPresent(String.self, forKey: .source)
        toolKind = try container.decodeIfPresent(String.self, forKey: .toolKind)
        deviceId = try container.decodeIfPresent(String.self, forKey: .deviceId)
        capabilityId = try container.decodeIfPresent(String.self, forKey: .capabilityId)
        scope = try container.decodeIfPresent(String.self, forKey: .scope)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        expiresAt = try container.decodeIfPresent(String.self, forKey: .expiresAt)
        confirmationText = try container.decodeIfPresent(String.self, forKey: .confirmationText)
    }

    var commandName: String? { action ?? toolName }
    var displayName: String { toolName ?? action ?? "환경 명령" }
}

struct ToolDraft: Codable, Equatable, Identifiable, Sendable {
    let draftId: String
    let name: String
    let description: String
    let deviceId: String?
    let capabilityId: String?
    let parameters: [String: JSONValue]
    let scopes: [String]
    let manifestRevision: String?
    let confirmationText: String?
    let status: String?
    let createdAt: String?
    let reviewedAt: String?

    var id: String { draftId }

    enum CodingKeys: String, CodingKey {
        case name, description, parameters, scopes, status
        case draftId = "draft_id"
        case deviceId = "device_id"
        case capabilityId = "capability_id"
        case confirmationText = "confirmation_text"
        case manifestRevision = "manifest_revision"
        case createdAt = "created_at"
        case reviewedAt = "reviewed_at"
    }

    init(
        draftId: String,
        name: String,
        description: String,
        deviceId: String? = nil,
        capabilityId: String? = nil,
        parameters: [String: JSONValue] = [:],
        scopes: [String] = ["home"],
        manifestRevision: String? = nil,
        confirmationText: String? = nil,
        status: String? = nil,
        createdAt: String? = nil,
        reviewedAt: String? = nil
    ) {
        self.draftId = draftId
        self.name = name
        self.description = description
        self.deviceId = deviceId
        self.capabilityId = capabilityId
        self.parameters = parameters
        self.scopes = scopes
        self.manifestRevision = manifestRevision
        self.confirmationText = confirmationText
        self.status = status
        self.createdAt = createdAt
        self.reviewedAt = reviewedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        draftId = try container.decode(String.self, forKey: .draftId)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        deviceId = try container.decodeIfPresent(String.self, forKey: .deviceId)
        capabilityId = try container.decodeIfPresent(String.self, forKey: .capabilityId)
        parameters = try container.decodeIfPresent([String: JSONValue].self, forKey: .parameters) ?? [:]
        scopes = try container.decodeIfPresent([String].self, forKey: .scopes) ?? ["home"]
        manifestRevision = try container.decodeIfPresent(String.self, forKey: .manifestRevision)
        confirmationText = try container.decodeIfPresent(String.self, forKey: .confirmationText)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        reviewedAt = try container.decodeIfPresent(String.self, forKey: .reviewedAt)
    }
}

struct CommandRouteResponse: Codable, Sendable {
    let kind: CommandRouteKind
    let proposal: CommandProposal?
    let draft: ToolDraft?
    let message: String?
    let routedBy: String?
    let fallbackReason: String?

    enum CodingKeys: String, CodingKey {
        case kind, proposal, draft, message
        case routedBy = "routed_by"
        case fallbackReason = "fallback_reason"
    }

    init(
        kind: CommandRouteKind,
        proposal: CommandProposal? = nil,
        draft: ToolDraft? = nil,
        message: String? = nil,
        routedBy: String? = nil,
        fallbackReason: String? = nil
    ) {
        self.kind = kind
        self.proposal = proposal
        self.draft = draft
        self.message = message
        self.routedBy = routedBy
        self.fallbackReason = fallbackReason
    }
}

struct RegisteredTool: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let description: String?
    let deviceId: String?
    let capabilityId: String?
    let parameters: [String: JSONValue]
    let scopes: [String]
    let manifestRevision: String?
    let draftId: String?
    let confirmationText: String?
    let approvedAt: String?
    let enabled: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, description, parameters, scopes, enabled
        case toolId = "tool_id"
        case draftId = "draft_id"
        case deviceId = "device_id"
        case capabilityId = "capability_id"
        case confirmationText = "confirmation_text"
        case approvedAt = "approved_at"
        case manifestRevision = "manifest_revision"
    }

    init(
        id: String,
        name: String,
        description: String? = nil,
        deviceId: String? = nil,
        capabilityId: String? = nil,
        parameters: [String: JSONValue] = [:],
        scopes: [String] = ["home"],
        manifestRevision: String? = nil,
        draftId: String? = nil,
        confirmationText: String? = nil,
        approvedAt: String? = nil,
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.deviceId = deviceId
        self.capabilityId = capabilityId
        self.parameters = parameters
        self.scopes = scopes
        self.manifestRevision = manifestRevision
        self.draftId = draftId
        self.confirmationText = confirmationText
        self.approvedAt = approvedAt
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
            ?? container.decode(String.self, forKey: .toolId)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        deviceId = try container.decodeIfPresent(String.self, forKey: .deviceId)
        capabilityId = try container.decodeIfPresent(String.self, forKey: .capabilityId)
        parameters = try container.decodeIfPresent([String: JSONValue].self, forKey: .parameters) ?? [:]
        scopes = try container.decodeIfPresent([String].self, forKey: .scopes) ?? ["home"]
        manifestRevision = try container.decodeIfPresent(String.self, forKey: .manifestRevision)
        draftId = try container.decodeIfPresent(String.self, forKey: .draftId)
        confirmationText = try container.decodeIfPresent(String.self, forKey: .confirmationText)
        approvedAt = try container.decodeIfPresent(String.self, forKey: .approvedAt)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(deviceId, forKey: .deviceId)
        try container.encodeIfPresent(capabilityId, forKey: .capabilityId)
        try container.encode(parameters, forKey: .parameters)
        try container.encode(scopes, forKey: .scopes)
        try container.encodeIfPresent(manifestRevision, forKey: .manifestRevision)
        try container.encodeIfPresent(draftId, forKey: .draftId)
        try container.encodeIfPresent(confirmationText, forKey: .confirmationText)
        try container.encodeIfPresent(approvedAt, forKey: .approvedAt)
        try container.encode(enabled, forKey: .enabled)
    }
}

struct ToolApprovalResponse: Decodable, Sendable {
    let tool: RegisteredTool
    let executionProposal: CommandProposal?
    let message: String?

    private enum CodingKeys: String, CodingKey {
        case tool, message
        case executionProposal = "execution_proposal"
    }

    init(
        tool: RegisteredTool,
        executionProposal: CommandProposal? = nil,
        message: String? = nil
    ) {
        self.tool = tool
        self.executionProposal = executionProposal
        self.message = message
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           let wrappedTool = try container.decodeIfPresent(RegisteredTool.self, forKey: .tool) {
            tool = wrappedTool
            executionProposal = try container.decodeIfPresent(
                CommandProposal.self,
                forKey: .executionProposal
            )
            message = try container.decodeIfPresent(String.self, forKey: .message)
        } else {
            tool = try RegisteredTool(from: decoder)
            executionProposal = nil
            message = nil
        }
    }
}

struct ProposalConfirmationResponse: Decodable, Sendable {
    let status: String
    let proposalId: String
    let toolKind: String
    let action: String
    let arguments: [String: JSONValue]
    let scope: String
    let result: JSONValue?

    enum CodingKeys: String, CodingKey {
        case status, action, arguments, scope, result
        case proposalId = "proposal_id"
        case toolKind = "tool_kind"
    }
}

struct ToolExecutionResponse: Decodable, Sendable {
    let status: String?
    let message: String?
    let result: JSONValue?
    let toolId: String?
    let deviceId: String?
    let capabilityId: String?

    private enum CodingKeys: String, CodingKey {
        case status, message, result, applied
        case toolId = "tool_id"
        case deviceId = "device_id"
        case capabilityId = "capability_id"
    }

    init(
        status: String? = nil,
        message: String? = nil,
        result: JSONValue? = nil,
        toolId: String? = nil,
        deviceId: String? = nil,
        capabilityId: String? = nil
    ) {
        self.status = status
        self.message = message
        self.result = result
        self.toolId = toolId
        self.deviceId = deviceId
        self.capabilityId = capabilityId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        result = try container.decodeIfPresent(JSONValue.self, forKey: .result)
            ?? container.decodeIfPresent(JSONValue.self, forKey: .applied)
        toolId = try container.decodeIfPresent(String.self, forKey: .toolId)
        deviceId = try container.decodeIfPresent(String.self, forKey: .deviceId)
        capabilityId = try container.decodeIfPresent(String.self, forKey: .capabilityId)
    }
}

struct RegisteredToolsResponse: Decodable, Sendable {
    let tools: [RegisteredTool]

    private enum CodingKeys: String, CodingKey { case tools }

    init(from decoder: Decoder) throws {
        if let values = try? [RegisteredTool](from: decoder) {
            tools = values
        } else {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tools = try container.decode([RegisteredTool].self, forKey: .tools)
        }
    }
}

struct SpaceSpec: Codable, Sendable {
    struct Lighting: Codable, Sendable {
        let supported: Bool
        let brightnessRange: [Int]
        let colorTemperatureSupported: Bool

        enum CodingKeys: String, CodingKey {
            case supported
            case brightnessRange = "brightness_range"
            case colorTemperatureSupported = "color_temperature_supported"
        }
    }

    struct Temperature: Codable, Sendable {
        let supported: Bool
        let rangeC: [Double]

        enum CodingKeys: String, CodingKey {
            case supported
            case rangeC = "range_c"
        }
    }

    struct Sound: Codable, Sendable { let supported: Bool }
    struct Defaults: Codable, Sendable {
        let brightnessPercent: Int
        let temperatureC: Double

        enum CodingKeys: String, CodingKey {
            case brightnessPercent = "brightness_percent"
            case temperatureC = "temperature_c"
        }
    }

    let spaceId: String
    let lighting: Lighting
    let temperature: Temperature
    let sound: Sound
    let defaults: Defaults

    enum CodingKeys: String, CodingKey {
        case lighting, temperature, sound, defaults
        case spaceId = "space_id"
    }
}

struct SpaceExecution: Codable, Sendable {
    struct Lighting: Codable, Sendable {
        let brightnessPercent: Int
        enum CodingKeys: String, CodingKey { case brightnessPercent = "brightness_percent" }
    }

    let lighting: Lighting
    let temperatureC: Double
    enum CodingKeys: String, CodingKey { case lighting; case temperatureC = "temperature_c" }
}

struct SpaceSession: Codable, Sendable {
    let sessionId: String
    let spaceId: String
    let status: String
    let execution: SpaceExecution?
    let excluded: [String]
    let expiresAt: String
    let sharedBiometricCount: Int
    let profileCopyDeleted: Bool
    let results: [String: String]?

    enum CodingKeys: String, CodingKey {
        case status, execution, excluded, results
        case sessionId = "session_id"
        case spaceId = "space_id"
        case expiresAt = "expires_at"
        case sharedBiometricCount = "shared_biometric_count"
        case profileCopyDeleted = "profile_copy_deleted"
    }
}

struct RoomState: Equatable, Sendable {
    var brightness: Int
    var temperature: Double
    var sound: String
    var isApplied = false

    static let homeDefault = Self(brightness: 70, temperature: 22, sound: "기본")
    static let hotelDefault = Self(brightness: 70, temperature: 22, sound: "미지원")
}
