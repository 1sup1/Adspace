import Foundation

#if canImport(CNeedle)
import CNeedle
#endif

struct NeedleToolSchema: Codable, Equatable, Sendable {
    let name: String
    let description: String
    let parameters: [String: JSONValue]

    init(
        name: String,
        description: String,
        parameters: [String: JSONValue]
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

struct NeedleFunctionCall: Decodable, Equatable, Sendable {
    let name: String
    let arguments: [String: JSONValue]

    private enum CodingKeys: String, CodingKey {
        case name, arguments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        arguments = try container.decodeIfPresent([String: JSONValue].self, forKey: .arguments) ?? [:]
    }
}

struct NeedleCompletionEnvelope: Decodable, Equatable, Sendable {
    let type: String
    let success: Bool?
    let error: String?
    let errorCode: String?
    let functionCalls: [NeedleFunctionCall]
    let reasoning: String?
    let confidence: Double?
    let prefillTokensPerSecond: Double?
    let decodeTokensPerSecond: Double?
    let peakRAMMegabytes: Double?

    private enum CodingKeys: String, CodingKey {
        case type, success, error, reasoning, confidence
        case errorCode = "error_code"
        case functionCalls = "function_calls"
        case prefillTokensPerSecond = "prefill_tps"
        case decodeTokensPerSecond = "decode_tps"
        case peakRAMMegabytes = "peak_ram_mb"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        success = try container.decodeIfPresent(Bool.self, forKey: .success)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        errorCode = try container.decodeIfPresent(String.self, forKey: .errorCode)
        functionCalls = try container.decodeIfPresent([NeedleFunctionCall].self, forKey: .functionCalls) ?? []
        reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning)
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
        prefillTokensPerSecond = try container.decodeIfPresent(Double.self, forKey: .prefillTokensPerSecond)
        decodeTokensPerSecond = try container.decodeIfPresent(Double.self, forKey: .decodeTokensPerSecond)
        peakRAMMegabytes = try container.decodeIfPresent(Double.self, forKey: .peakRAMMegabytes)
    }
}

enum NeedleRuntimeUnavailableReason: Equatable, Sendable {
    case nativeLibraryMissing
    case unsupportedOS(required: String)

    var message: String {
        switch self {
        case .nativeLibraryMissing:
            "Needle 네이티브 라이브러리가 이 빌드에 포함되지 않았습니다."
        case let .unsupportedOS(required):
            "공식 Needle 네이티브 라이브러리는 iOS \(required) 이상이 필요합니다. 서버 GPT로 전환합니다."
        }
    }
}

enum NeedleRuntimeAvailability: Equatable, Sendable {
    case available
    case unavailable(NeedleRuntimeUnavailableReason)
}

enum NeedleRuntimeError: LocalizedError, Equatable, Sendable {
    case unavailable(NeedleRuntimeUnavailableReason)
    case initializationFailed(status: Int32)
    case completionFailed(status: Int32)
    case notConfigured
    case emptyInput
    case emptyOutput
    case outputBufferTooSmall
    case invalidUTF8
    case invalidJSON(String)

    var errorDescription: String? {
        switch self {
        case let .unavailable(reason):
            reason.message
        case let .initializationFailed(status):
            "Needle 도구 스키마 초기화에 실패했습니다(상태 코드: \(status))."
        case let .completionFailed(status):
            "Needle 명령 해석에 실패했습니다(상태 코드: \(status))."
        case .notConfigured:
            "Needle을 사용하기 전에 도구 스키마를 구성해야 합니다."
        case .emptyInput:
            "해석할 명령이 비어 있습니다."
        case .emptyOutput:
            "Needle이 빈 응답을 반환했습니다."
        case .outputBufferTooSmall:
            "Needle 응답이 출력 버퍼보다 큽니다."
        case .invalidUTF8:
            "Needle 응답이 올바른 UTF-8이 아닙니다."
        case let .invalidJSON(message):
            "Needle 응답 JSON을 해석할 수 없습니다: \(message)"
        }
    }
}

protocol NeedleCommandRouting: Sendable {
    func availability() async -> NeedleRuntimeAvailability
    func configure(
        toolSchemas: [NeedleToolSchema],
        systemFacts: String?,
        toolIndexURL: URL?
    ) async throws
    func complete(_ input: String, maxNewTokens: Int) async throws -> NeedleCompletionEnvelope
    func reset() async
}

extension NeedleCommandRouting {
    func configure(
        toolSchemas: [NeedleToolSchema],
        systemFacts: String? = nil
    ) async throws {
        try await configure(toolSchemas: toolSchemas, systemFacts: systemFacts, toolIndexURL: nil)
    }

    func complete(_ input: String) async throws -> NeedleCompletionEnvelope {
        try await complete(input, maxNewTokens: NeedleRuntime.minimumMaxNewTokens)
    }
}

enum NeedleWireCodec {
    static func encodeTools(_ tools: [NeedleToolSchema]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(tools)
        guard let json = String(data: data, encoding: .utf8) else {
            throw NeedleRuntimeError.invalidUTF8
        }
        return json
    }

    static func decodeCompletion(_ bytes: [UInt8]) throws -> NeedleCompletionEnvelope {
        guard !bytes.isEmpty else {
            throw NeedleRuntimeError.emptyOutput
        }
        guard String(bytes: bytes, encoding: .utf8) != nil else {
            throw NeedleRuntimeError.invalidUTF8
        }

        do {
            return try JSONDecoder().decode(NeedleCompletionEnvelope.self, from: Data(bytes))
        } catch {
            throw NeedleRuntimeError.invalidJSON(String(describing: error))
        }
    }
}

actor NeedleRuntime: NeedleCommandRouting {
    static let shared = NeedleRuntime()
    static let minimumMaxNewTokens = 128
    static let outputBufferCapacity = 256 * 1_024

    private var isConfigured = false

    private init() {}

    func availability() async -> NeedleRuntimeAvailability {
#if canImport(CNeedle)
        guard Self.isOperatingSystemSupported else {
            return .unavailable(.unsupportedOS(required: Self.minimumOperatingSystem))
        }
        return .available
#else
        return .unavailable(.nativeLibraryMissing)
#endif
    }

    func configure(
        toolSchemas: [NeedleToolSchema],
        systemFacts: String?,
        toolIndexURL: URL?
    ) async throws {
        try Self.requireOperatingSystemSupport()
        let toolsJSON = try NeedleWireCodec.encodeTools(toolSchemas)

#if canImport(CNeedle)
        if isConfigured {
            needle_reset()
        }

        let system = systemFacts ?? ""
        let indexPath = toolIndexURL?.path
        let status = system.withCString { systemPointer in
            toolsJSON.withCString { toolsPointer in
                if let indexPath {
                    return indexPath.withCString { indexPointer in
                        needle_init(systemPointer, toolsPointer, indexPointer)
                    }
                }
                return needle_init(systemPointer, toolsPointer, nil)
            }
        }

        guard status >= 0 else {
            isConfigured = false
            throw NeedleRuntimeError.initializationFailed(status: status)
        }
        isConfigured = true
#else
        throw NeedleRuntimeError.unavailable(.nativeLibraryMissing)
#endif
    }

    func complete(
        _ input: String,
        maxNewTokens: Int = NeedleRuntime.minimumMaxNewTokens
    ) async throws -> NeedleCompletionEnvelope {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NeedleRuntimeError.emptyInput
        }
        guard isConfigured else {
            throw NeedleRuntimeError.notConfigured
        }

#if canImport(CNeedle)
        let requestedTokens = max(Self.minimumMaxNewTokens, maxNewTokens)
        let nativeTokenCount = Int32(clamping: requestedTokens)
        var output = [CChar](repeating: 0, count: Self.outputBufferCapacity)

        let status = input.withCString { inputPointer in
            output.withUnsafeMutableBufferPointer { outputPointer in
                needle_complete(
                    inputPointer,
                    nativeTokenCount,
                    outputPointer.baseAddress,
                    Int32(outputPointer.count)
                )
            }
        }

        guard status >= 0 else {
            throw NeedleRuntimeError.completionFailed(status: status)
        }
        guard let terminator = output.firstIndex(of: 0) else {
            throw NeedleRuntimeError.outputBufferTooSmall
        }

        let bytes = output[..<terminator].map { UInt8(bitPattern: $0) }
        return try NeedleWireCodec.decodeCompletion(bytes)
#else
        throw NeedleRuntimeError.unavailable(.nativeLibraryMissing)
#endif
    }

    func reset() async {
        guard isConfigured else { return }
#if canImport(CNeedle)
        needle_reset()
#endif
    }

    private static let minimumOperatingSystem = "26.5"

    private static var isOperatingSystemSupported: Bool {
        if #available(iOS 26.5, *) { true } else { false }
    }

    private static func requireOperatingSystemSupport() throws {
        guard isOperatingSystemSupported else {
            throw NeedleRuntimeError.unavailable(
                .unsupportedOS(required: minimumOperatingSystem)
            )
        }
    }
}
