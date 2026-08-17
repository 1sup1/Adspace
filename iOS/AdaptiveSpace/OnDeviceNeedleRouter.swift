import Foundation

enum NeedleBuiltInToolCatalog {
    static let schemas: [NeedleToolSchema] = [
        NeedleToolSchema(
            name: "apply_recommendation",
            description: "현재 추천된 공간 환경을 적용한다.",
            parameters: objectSchema(properties: ["scope": scopeSchema()])
        ),
        NeedleToolSchema(
            name: "adjust_environment",
            description: "현재 공간의 조명 밝기, 온도 또는 사운드를 상대적으로 조절한다.",
            parameters: objectSchema(properties: [
                "scope": .object([
                    "type": .string("string"),
                    "enum": .array([.string("home")]),
                    "description": .string("집 공간")
                ]),
                "brightness_delta": .object([
                    "type": .string("integer"),
                    "minimum": .integer(-30),
                    "maximum": .integer(30),
                    "description": .string("현재 밝기에서 바꿀 퍼센트포인트")
                ]),
                "temperature_delta_c": .object([
                    "type": .string("number"),
                    "minimum": .integer(-3),
                    "maximum": .integer(3),
                    "description": .string("현재 온도에서 바꿀 섭씨 온도")
                ]),
                "sound_preset": .object([
                    "type": .string("string"),
                    "enum": .array([.string("calm"), .string("focus"), .string("silence")]),
                    "description": .string("적용할 사운드 프리셋")
                ])
            ])
        ),
        NeedleToolSchema(
            name: "stop_environment",
            description: "현재 적용 중인 공간 환경 제어를 멈춘다.",
            parameters: objectSchema(properties: ["scope": scopeSchema()])
        ),
        NeedleToolSchema(
            name: "restore_environment",
            description: "공간 환경을 제어 전 기본값으로 복원한다.",
            parameters: objectSchema(properties: ["scope": scopeSchema()])
        ),
        NeedleToolSchema(
            name: "checkout_space",
            description: "호텔 공간을 체크아웃하고 적용 전 환경으로 복원한다.",
            parameters: objectSchema(properties: [
                "scope": .object([
                    "type": .string("string"),
                    "enum": .array([.string("hotel")])
                ])
            ])
        )
    ]
    static let names = Set(schemas.map(\.name))

    private static func objectSchema(properties: [String: JSONValue]) -> [String: JSONValue] {
        [
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array([]),
            "additionalProperties": .bool(false)
        ]
    }

    private static func scopeSchema() -> JSONValue {
        .object([
            "type": .string("string"),
            "enum": .array([.string("home"), .string("hotel")]),
            "description": .string("명령을 실행할 공간")
        ])
    }
}

struct NeedleCallValidator: Sendable {
    let schemasByName: [String: NeedleToolSchema]
    let confidenceThreshold: Double
    let scopeBoundToolNames: Set<String>

    init(
        schemas: [NeedleToolSchema],
        confidenceThreshold: Double = 0.80,
        scopeBoundToolNames: Set<String> = NeedleBuiltInToolCatalog.names
    ) {
        schemasByName = schemas.reduce(into: [:]) { result, schema in
            result[schema.name] = schema
        }
        self.confidenceThreshold = min(max(confidenceThreshold, 0), 1)
        self.scopeBoundToolNames = scopeBoundToolNames
    }

    func validatedCall(
        from envelope: NeedleCompletionEnvelope,
        requestedScope: String?
    ) -> NeedleFunctionCall? {
        guard envelope.type == "call",
              envelope.success != false,
              envelope.error == nil,
              let confidence = envelope.confidence,
              confidence.isFinite,
              confidence >= confidenceThreshold,
              confidence <= 1,
              envelope.functionCalls.count == 1,
              let call = envelope.functionCalls.first,
              let schema = schemasByName[call.name]
        else {
            return nil
        }

        if let requestedScope, !["home", "hotel"].contains(requestedScope) {
            return nil
        }

        var arguments = call.arguments
        if let requestedScope, scopeBoundToolNames.contains(call.name) {
            if let inferredScope = arguments["scope"]?.stringValue,
               inferredScope != requestedScope {
                return nil
            }
            arguments["scope"] = .string(requestedScope)
        }

        if call.name == "checkout_space",
           (arguments["scope"]?.stringValue ?? "hotel") != "hotel" {
            return nil
        }

        if call.name == "adjust_environment",
           arguments.keys.allSatisfy({ !Self.adjustmentKeys.contains($0) }) {
            return nil
        }

        guard Self.validateObject(arguments, against: schema.parameters) else {
            return nil
        }
        return NeedleFunctionCall(name: call.name, arguments: arguments)
    }

    private static let adjustmentKeys: Set<String> = [
        "brightness_delta",
        "temperature_delta_c",
        "sound_preset"
    ]

    private static func validateObject(
        _ object: [String: JSONValue],
        against schema: [String: JSONValue]
    ) -> Bool {
        guard schema["type"]?.stringValue == "object",
              case let .object(properties)? = schema["properties"]
        else {
            return false
        }

        let required: Set<String>
        if case let .array(requiredValues)? = schema["required"] {
            required = Set(requiredValues.compactMap(\.stringValue))
            guard required.count == requiredValues.count else { return false }
        } else {
            required = []
        }

        guard required.isSubset(of: Set(object.keys)) else { return false }
        if schema["additionalProperties"] == .bool(false),
           object.keys.contains(where: { properties[$0] == nil }) {
            return false
        }

        return object.allSatisfy { key, value in
            guard case let .object(propertySchema)? = properties[key] else {
                return schema["additionalProperties"] != .bool(false)
            }
            return validate(value, against: propertySchema)
        }
    }

    private static func validate(
        _ value: JSONValue,
        against schema: [String: JSONValue]
    ) -> Bool {
        if case let .array(enumValues)? = schema["enum"], !enumValues.contains(value) {
            return false
        }
        if let constant = schema["const"], constant != value {
            return false
        }

        switch schema["type"]?.stringValue {
        case "string":
            guard case let .string(text) = value else { return false }
            if let minimum = schema["minLength"]?.intValue, text.count < minimum { return false }
            if let maximum = schema["maxLength"]?.intValue, text.count > maximum { return false }
        case "integer":
            guard numericValue(value, requiresInteger: true) != nil else { return false }
        case "number":
            guard numericValue(value, requiresInteger: false) != nil else { return false }
        case "boolean":
            guard case .bool = value else { return false }
        case "object":
            guard case let .object(object) = value,
                  validateObject(object, against: schema)
            else { return false }
        case "array":
            guard case let .array(values) = value else { return false }
            if case let .object(itemSchema)? = schema["items"],
               !values.allSatisfy({ validate($0, against: itemSchema) }) {
                return false
            }
        default:
            return false
        }

        if let number = numericValue(value, requiresInteger: false) {
            if let minimum = schema["minimum"]?.doubleValue, number < minimum { return false }
            if let maximum = schema["maximum"]?.doubleValue, number > maximum { return false }
            if let minimum = schema["exclusiveMinimum"]?.doubleValue, number <= minimum { return false }
            if let maximum = schema["exclusiveMaximum"]?.doubleValue, number >= maximum { return false }
            if let multiple = schema["multipleOf"]?.doubleValue {
                guard multiple > 0 else { return false }
                let quotient = number / multiple
                if abs(quotient - quotient.rounded()) > 1e-9 { return false }
            }
        }
        return true
    }

    private static func numericValue(
        _ value: JSONValue,
        requiresInteger: Bool
    ) -> Double? {
        switch value {
        case let .integer(number):
            return Double(number)
        case let .number(number) where number.isFinite && (!requiresInteger || Int(exactly: number) != nil):
            return number
        default:
            return nil
        }
    }
}

extension NeedleFunctionCall {
    init(name: String, arguments: [String: JSONValue]) {
        self.name = name
        self.arguments = arguments
    }
}

actor OnDeviceNeedleRouter: CommandRouting {
    static let confidenceThreshold = 0.80

    private let runtime: any NeedleCommandRouting
    private let builtInSchemas: [NeedleToolSchema]
    private var schemas: [NeedleToolSchema]
    private var validator: NeedleCallValidator
    private var dynamicToolsByName: [String: RegisteredTool] = [:]
    private var isConfigured = false
    private var isRouting = false
    private var pendingTools: [RegisteredTool]?

    init(
        runtime: any NeedleCommandRouting = NeedleRuntime.shared,
        schemas: [NeedleToolSchema] = NeedleBuiltInToolCatalog.schemas,
        confidenceThreshold: Double = OnDeviceNeedleRouter.confidenceThreshold
    ) {
        self.runtime = runtime
        builtInSchemas = schemas
        self.schemas = schemas
        validator = NeedleCallValidator(
            schemas: schemas,
            confidenceThreshold: confidenceThreshold,
            scopeBoundToolNames: Set(schemas.map(\.name))
        )
    }

    func updateTools(_ tools: [RegisteredTool]) async {
        guard !isRouting else {
            pendingTools = tools
            return
        }
        applyTools(tools)
    }

    private func applyTools(_ tools: [RegisteredTool]) {
        let builtInNames = Set(builtInSchemas.map(\.name))
        var approvedByName: [String: RegisteredTool] = [:]
        for tool in tools.sorted(by: { ($0.name, $0.id) < ($1.name, $1.id) })
        where tool.enabled && !builtInNames.contains(tool.name) {
            if approvedByName[tool.name] == nil {
                approvedByName[tool.name] = tool
            }
        }

        let approvedSchemas = approvedByName.values
            .sorted(by: { $0.name < $1.name })
            .map { tool in
                NeedleToolSchema(
                    name: tool.name,
                    description: tool.description ?? "\(tool.name) 기기 기능을 실행한다.",
                    parameters: tool.parameters
                )
            }

        dynamicToolsByName = approvedByName
        schemas = builtInSchemas + approvedSchemas
        validator = NeedleCallValidator(
            schemas: schemas,
            confidenceThreshold: validator.confidenceThreshold,
            scopeBoundToolNames: validator.scopeBoundToolNames
        )
        isConfigured = false
    }

    func route(_ request: CommandRouteRequest) async throws -> CommandRouteResponse? {
        guard !isRouting else { return nil }
        isRouting = true
        defer {
            isRouting = false
            if let pendingTools {
                self.pendingTools = nil
                applyTools(pendingTools)
            }
        }
        do {
            guard await runtime.availability() == .available else { return nil }

            if !isConfigured {
                try await runtime.configure(
                    toolSchemas: schemas,
                    systemFacts: "locale: ko-KR; device: phone; assistant: Adaptive Space"
                )
                isConfigured = true
            }

            await runtime.reset()
            let query = request.scope.map { "\(request.text)\nspace scope: \($0)" } ?? request.text
            let envelope = try await runtime.complete(
                query,
                maxNewTokens: NeedleRuntime.minimumMaxNewTokens
            )
            guard let call = validator.validatedCall(
                from: envelope,
                requestedScope: request.scope
            ) else {
                return nil
            }

            if let tool = dynamicToolsByName[call.name] {
                let scope = request.scope ?? "home"
                guard tool.scopes.contains(scope) else { return nil }
                return CommandRouteResponse(
                    kind: .dynamicProposal,
                    proposal: CommandProposal(
                        toolId: tool.id,
                        toolName: tool.name,
                        arguments: call.arguments,
                        confidence: envelope.confidence,
                        requiresConfirmation: true,
                        source: "needle",
                        toolKind: "dynamic",
                        deviceId: tool.deviceId,
                        capabilityId: tool.capabilityId,
                        scope: scope,
                        confirmationText: tool.confirmationText
                    ),
                    routedBy: "needle"
                )
            }

            return CommandRouteResponse(
                kind: .builtinProposal,
                proposal: CommandProposal(
                    toolName: call.name,
                    action: call.name,
                    arguments: call.arguments,
                    confidence: envelope.confidence,
                    requiresConfirmation: true,
                    source: "needle",
                    toolKind: "builtin",
                    deviceId: "app-model",
                    capabilityId: call.name,
                    scope: request.scope ?? "home"
                ),
                routedBy: "needle"
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            isConfigured = false
            return nil
        }
    }
}
