import XCTest
@testable import AdaptiveSpace

final class OnDeviceNeedleRouterTests: XCTestCase {
    func testValidCallReturnsConfirmationProposalAndInjectsScope() async throws {
        let runtime = NeedleRuntimeStub(
            response: try completion(
                confidence: 0.94,
                callsJSON: #"[{"name":"apply_recommendation","arguments":{}}]"#
            )
        )
        let router = OnDeviceNeedleRouter(runtime: runtime)

        let response = try await router.route(
            CommandRouteRequest(text: "추천 환경을 적용해줘", scope: "home")
        )

        XCTAssertEqual(response?.kind, .builtinProposal)
        XCTAssertEqual(response?.proposal?.action, "apply_recommendation")
        XCTAssertEqual(response?.proposal?.arguments["scope"], .string("home"))
        XCTAssertEqual(response?.proposal?.source, "needle")
        XCTAssertEqual(response?.proposal?.requiresConfirmation, true)
        XCTAssertEqual(response?.routedBy, "needle")
    }

    func testConfidenceBelowThresholdFallsBack() async throws {
        let runtime = NeedleRuntimeStub(
            response: try completion(
                confidence: 0.79,
                callsJSON: #"[{"name":"stop_environment","arguments":{}}]"#
            )
        )

        let response = try await OnDeviceNeedleRouter(runtime: runtime).route(
            CommandRouteRequest(text: "멈춰", scope: "home")
        )

        XCTAssertNil(response)
    }

    func testOutOfSchemaArgumentsFallBack() async throws {
        let runtime = NeedleRuntimeStub(
            response: try completion(
                confidence: 0.95,
                callsJSON: #"[{"name":"adjust_environment","arguments":{"brightness_delta":99}}]"#
            )
        )

        let response = try await OnDeviceNeedleRouter(runtime: runtime).route(
            CommandRouteRequest(text: "조명을 훨씬 밝게", scope: "home")
        )

        XCTAssertNil(response)
    }

    func testScopeMismatchFallsBack() async throws {
        let runtime = NeedleRuntimeStub(
            response: try completion(
                confidence: 0.95,
                callsJSON: #"[{"name":"restore_environment","arguments":{"scope":"hotel"}}]"#
            )
        )

        let response = try await OnDeviceNeedleRouter(runtime: runtime).route(
            CommandRouteRequest(text: "복원해줘", scope: "home")
        )

        XCTAssertNil(response)
    }

    func testHotelAdjustmentFallsBackBecauseAdjustmentIsHomeOnly() async throws {
        let runtime = NeedleRuntimeStub(
            response: try completion(
                confidence: 0.95,
                callsJSON: #"[{"name":"adjust_environment","arguments":{"brightness_delta":-10}}]"#
            )
        )

        let response = try await OnDeviceNeedleRouter(runtime: runtime).route(
            CommandRouteRequest(text: "호텔 조명을 낮춰줘", scope: "hotel")
        )

        XCTAssertNil(response)
    }

    func testMultipleCallsFallBack() async throws {
        let runtime = NeedleRuntimeStub(
            response: try completion(
                confidence: 0.98,
                callsJSON: #"[{"name":"stop_environment","arguments":{}},{"name":"restore_environment","arguments":{}}]"#
            )
        )

        let response = try await OnDeviceNeedleRouter(runtime: runtime).route(
            CommandRouteRequest(text: "멈추고 복원해", scope: "home")
        )

        XCTAssertNil(response)
    }

    func testRuntimeFailureFallsBackWithoutThrowing() async throws {
        let runtime = NeedleRuntimeStub(error: .completionFailed(status: -1))

        let response = try await OnDeviceNeedleRouter(runtime: runtime).route(
            CommandRouteRequest(text: "멈춰", scope: "home")
        )

        XCTAssertNil(response)
    }

    func testFullApprovedScalarSchemaConstraintsAreValidatedLocally() throws {
        let schema = NeedleToolSchema(
            name: "set_device_profile",
            description: "기기 프로필을 설정합니다.",
            parameters: [
                "type": .string("object"),
                "properties": .object([
                    "profile": .object([
                        "type": .string("string"),
                        "const": .string("focus"),
                        "minLength": .integer(3),
                        "maxLength": .integer(8)
                    ]),
                    "level": .object([
                        "type": .string("number"),
                        "exclusiveMinimum": .integer(0),
                        "exclusiveMaximum": .integer(1),
                        "multipleOf": .number(0.25)
                    ])
                ]),
                "required": .array([.string("profile"), .string("level")]),
                "additionalProperties": .bool(false)
            ]
        )
        let validator = NeedleCallValidator(
            schemas: [schema],
            scopeBoundToolNames: []
        )
        let invalid = try completion(
            confidence: 0.95,
            callsJSON: #"[{"name":"set_device_profile","arguments":{"profile":"focus","level":0.3}}]"#
        )
        let valid = try completion(
            confidence: 0.95,
            callsJSON: #"[{"name":"set_device_profile","arguments":{"profile":"focus","level":0.5}}]"#
        )

        XCTAssertNil(validator.validatedCall(from: invalid, requestedScope: "home"))
        XCTAssertNotNil(validator.validatedCall(from: valid, requestedScope: "home"))
    }

    func testConcurrentRouteFallsBackInsteadOfResettingActiveCompletion() async throws {
        let runtime = NeedleRuntimeStub(
            response: try completion(
                confidence: 0.94,
                callsJSON: #"[{"name":"stop_environment","arguments":{}}]"#
            ),
            delayNanoseconds: 80_000_000
        )
        let router = OnDeviceNeedleRouter(runtime: runtime)
        let first = Task {
            try await router.route(CommandRouteRequest(text: "멈춰", scope: "home"))
        }
        try await Task.sleep(nanoseconds: 10_000_000)

        let overlapping = try await router.route(
            CommandRouteRequest(text: "복원해", scope: "home")
        )

        XCTAssertNil(overlapping)
        let firstResult = try await first.value
        XCTAssertNotNil(firstResult)
    }

    func testApprovedDynamicToolIsReconfiguredAndReturnedByID() async throws {
        let runtime = NeedleRuntimeStub(
            response: try completion(
                confidence: 0.93,
                callsJSON: #"[{"name":"set_air_purifier","arguments":{"speed":2}}]"#
            )
        )
        let router = OnDeviceNeedleRouter(runtime: runtime)
        await router.updateTools([
            RegisteredTool(
                id: "tool-air-1",
                name: "set_air_purifier",
                description: "공기청정기 풍량을 설정한다.",
                parameters: [
                    "type": .string("object"),
                    "properties": .object([
                        "speed": .object([
                            "type": .string("integer"),
                            "minimum": .integer(1),
                            "maximum": .integer(3)
                        ])
                    ]),
                    "required": .array([.string("speed")]),
                    "additionalProperties": .bool(false)
                ],
                confirmationText: "공기청정기 풍량을 바꿀까요?"
            )
        ])

        let response = try await router.route(
            CommandRouteRequest(text: "공기청정기 2단으로", scope: "home")
        )

        XCTAssertEqual(response?.kind, .dynamicProposal)
        XCTAssertEqual(response?.proposal?.toolId, "tool-air-1")
        XCTAssertEqual(response?.proposal?.toolName, "set_air_purifier")
        XCTAssertEqual(response?.proposal?.arguments["speed"], .integer(2))
        XCTAssertEqual(response?.proposal?.confirmationText, "공기청정기 풍량을 바꿀까요?")
        XCTAssertEqual(response?.proposal?.requiresConfirmation, true)
    }

    private func completion(
        confidence: Double,
        callsJSON: String
    ) throws -> NeedleCompletionEnvelope {
        let json = """
        {"type":"call","success":true,"error":null,"function_calls":\(callsJSON),"confidence":\(confidence)}
        """
        return try NeedleWireCodec.decodeCompletion(Array(json.utf8))
    }
}

private actor NeedleRuntimeStub: NeedleCommandRouting {
    private let response: NeedleCompletionEnvelope?
    private let error: NeedleRuntimeError?
    private let delayNanoseconds: UInt64

    init(
        response: NeedleCompletionEnvelope? = nil,
        error: NeedleRuntimeError? = nil,
        delayNanoseconds: UInt64 = 0
    ) {
        self.response = response
        self.error = error
        self.delayNanoseconds = delayNanoseconds
    }

    func availability() async -> NeedleRuntimeAvailability { .available }

    func configure(
        toolSchemas: [NeedleToolSchema],
        systemFacts: String?,
        toolIndexURL: URL?
    ) async throws {}

    func complete(_ input: String, maxNewTokens: Int) async throws -> NeedleCompletionEnvelope {
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if let error { throw error }
        guard let response else { throw NeedleRuntimeError.emptyOutput }
        return response
    }

    func reset() async {}
}
