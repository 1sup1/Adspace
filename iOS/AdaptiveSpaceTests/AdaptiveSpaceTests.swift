import XCTest
@testable import AdaptiveSpace

final class AdaptiveSpaceTests: XCTestCase {
    func testCompanionConsensusUsesSharedRangeAndPreservesPreferredValue() {
        let preferred = EnvironmentProfile(
            lighting: LightingProfile(brightnessPercent: 42, colorTemperatureK: 2_700),
            temperatureC: 23,
            soundPreset: "calm"
        )
        let preferences = [
            ComfortPreference(
                id: "me",
                name: "나",
                symbol: "person.fill",
                brightnessRange: 32...52,
                temperatureRange: 22.0...24.0
            ),
            ComfortPreference(
                id: "companion",
                name: "동반자",
                symbol: "person.fill",
                brightnessRange: 40...60,
                temperatureRange: 21.5...23.5
            )
        ]

        let consensus = CompanionConsensusEngine.resolve(preferences, preferred: preferred)

        XCTAssertTrue(consensus.canApply)
        XCTAssertEqual(consensus.brightnessRange, 40...52)
        XCTAssertEqual(consensus.temperatureRange, 22.0...23.5)
        XCTAssertEqual(consensus.brightnessPercent, 42)
        XCTAssertEqual(consensus.temperatureC, 23)
        XCTAssertEqual(consensus.profile(basedOn: preferred)?.lighting.brightnessPercent, 42)
    }

    func testCompanionConsensusRequiresExplicitChoiceWhenRangesDoNotOverlap() {
        let preferred = EnvironmentProfile(
            lighting: LightingProfile(brightnessPercent: 42, colorTemperatureK: 2_700),
            temperatureC: 23,
            soundPreset: "calm"
        )
        let preferences = [
            ComfortPreference(
                id: "me",
                name: "나",
                symbol: "person.fill",
                brightnessRange: 20...30,
                temperatureRange: 20.0...21.0
            ),
            ComfortPreference(
                id: "companion",
                name: "동반자",
                symbol: "person.fill",
                brightnessRange: 60...70,
                temperatureRange: 23.0...24.0
            )
        ]

        let consensus = CompanionConsensusEngine.resolve(preferences, preferred: preferred)

        XCTAssertFalse(consensus.canApply)
        XCTAssertNil(consensus.profile(basedOn: preferred))
    }

    func testCompanionConsensusRoundingNeverLeavesSharedRange() {
        let preferred = EnvironmentProfile(
            lighting: LightingProfile(brightnessPercent: 42, colorTemperatureK: 2_700),
            temperatureC: 23.4,
            soundPreset: "calm"
        )
        let preference = ComfortPreference(
            id: "me",
            name: "나",
            symbol: "person.fill",
            brightnessRange: 40...50,
            temperatureRange: 22.1...23.4
        )

        let consensus = CompanionConsensusEngine.resolve([preference], preferred: preferred)

        XCTAssertEqual(consensus.temperatureC, 23.4)
        XCTAssertTrue(preference.temperatureRange.contains(consensus.temperatureC ?? 0))
    }

    func testDemoWearableEmitsOrderedSignals() async throws {
        let provider = DemoWearableProvider(connectionDelay: .zero, sampleInterval: .zero)
        var signals: [WearableSignal] = []

        for try await signal in provider.signalStream(for: .recovery) {
            signals.append(signal)
            if signals.count == 6 { break }
        }

        XCTAssertEqual(signals.map(\.sequence), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(signals.map(\.snapshot.id), [
            "demo-recovery-1", "demo-recovery-2", "demo-recovery-3",
            "demo-recovery-4", "demo-recovery-5", "demo-recovery-6"
        ])
        XCTAssertEqual(signals[3].snapshot.heartRateBPM, 96)
        XCTAssertEqual(signals[4].snapshot.heartRateBPM, 70)
    }

    func testConsentRemovesUnapprovedMetric() {
        let snapshot = WearableSnapshot(
            id: "demo",
            source: "demo",
            capturedAt: "2026-08-14T00:00:00Z",
            sleepScore: 52,
            activitySteps: 3_200,
            heartRateBPM: 78,
            hrvMS: 31,
            timeOfDay: "evening"
        )
        let filtered = snapshot.filtered(by: [.sleepScore])
        XCTAssertEqual(filtered.sleepScore, 52)
        XCTAssertNil(filtered.activitySteps)
        XCTAssertNil(filtered.heartRateBPM)
        XCTAssertNil(filtered.hrvMS)
    }

    func testCommandRouteContractsDecodeBuiltinDraftAndExecution() throws {
        let decoder = JSONDecoder()
        let builtin = try decoder.decode(CommandRouteResponse.self, from: Data(#"""
        {
          "kind": "builtin_proposal",
          "routed_by": "needle",
          "proposal": {
            "proposal_id": "11111111111111111111111111111111",
            "action": "adjust_environment",
            "tool_name": "adjust_environment",
            "arguments": {"scope": "home", "brightness_delta": -10},
            "requires_confirmation": true,
            "source": "needle",
            "confidence": 0.62,
            "tool_kind": "builtin",
            "tool_id": null,
            "device_id": "app-model",
            "capability_id": "adjust_environment",
            "scope": "home",
            "expires_at": "2026-08-17T00:02:00Z",
            "confirmation_text": "환경을 조절할까요?"
          },
          "draft": null,
          "message": null,
          "fallback_reason": null
        }
        """#.utf8))

        XCTAssertEqual(builtin.kind, .builtinProposal)
        XCTAssertEqual(builtin.proposal?.action, "adjust_environment")
        XCTAssertEqual(builtin.proposal?.proposalId, "11111111111111111111111111111111")
        XCTAssertEqual(builtin.proposal?.arguments["brightness_delta"], .integer(-10))
        XCTAssertEqual(builtin.proposal?.toolKind, "builtin")

        let sessionBound = try decoder.decode(CommandProposal.self, from: Data(#"""
        {
          "proposal_id": "99999999999999999999999999999999",
          "action": "stop_environment",
          "arguments": {"scope": "hotel"},
          "requires_confirmation": true,
          "scope": "hotel",
          "session_id": "session-test"
        }
        """#.utf8))
        XCTAssertEqual(sessionBound.sessionId, "session-test")

        let draft = try decoder.decode(CommandRouteResponse.self, from: Data(#"""
        {
          "kind": "tool_draft",
          "routed_by": "gpt",
          "proposal": {
            "proposal_id": "22222222222222222222222222222222",
            "action": "execute_dynamic_tool",
            "tool_name": "set_desk_light",
            "arguments": {"brightness_percent": 35},
            "requires_confirmation": true,
            "source": "gpt",
            "confidence": null,
            "tool_kind": "dynamic",
            "tool_id": null,
            "device_id": "desk-light",
            "capability_id": "set_brightness",
            "scope": "home",
            "expires_at": "2026-08-17T00:02:00Z",
            "confirmation_text": "책상 조명을 35%로 바꿀까요?"
          },
          "draft": {
            "draft_id": "draft-1",
            "name": "set_desk_light",
            "description": "책상 조명의 밝기를 설정합니다.",
            "device_id": "desk-light",
            "capability_id": "set_brightness",
            "confirmation_text": "책상 조명을 바꿀까요?",
            "scopes": ["home"],
            "manifest_revision": "manifest-1",
            "parameters": {
              "type": "object",
              "properties": {"brightness_percent": {"type": "integer"}},
              "required": ["brightness_percent"],
              "additionalProperties": false
            },
            "status": "pending",
            "created_at": "2026-08-17T00:00:00Z",
            "reviewed_at": null
          },
          "message": "새 도구를 검토해 주세요.",
          "fallback_reason": "low_confidence"
        }
        """#.utf8))

        XCTAssertEqual(draft.kind, .toolDraft)
        XCTAssertEqual(draft.draft?.draftId, "draft-1")
        XCTAssertEqual(draft.proposal?.proposalId, "22222222222222222222222222222222")
        XCTAssertEqual(draft.proposal?.arguments["brightness_percent"], .integer(35))
        XCTAssertEqual(draft.fallbackReason, "low_confidence")

        let approval = try decoder.decode(ToolApprovalResponse.self, from: Data(#"""
        {
          "tool": {
            "tool_id": "tool-1",
            "draft_id": "draft-1",
            "name": "set_desk_light",
            "description": "책상 조명의 밝기를 설정합니다.",
            "device_id": "desk-light",
            "capability_id": "set_brightness",
            "parameters": {"type": "object", "properties": {}, "required": [], "additionalProperties": false},
            "scopes": ["home"],
            "manifest_revision": "manifest-1",
            "confirmation_text": "책상 조명을 바꿀까요?",
            "approved_at": "2026-08-17T00:01:00Z",
            "enabled": true
          },
          "execution_proposal": {
            "proposal_id": "33333333333333333333333333333333",
            "action": "execute_dynamic_tool",
            "tool_name": "set_desk_light",
            "arguments": {"brightness_percent": 35},
            "requires_confirmation": true,
            "source": "gpt",
            "confidence": null,
            "tool_kind": "dynamic",
            "tool_id": "tool-1",
            "device_id": "desk-light",
            "capability_id": "set_brightness",
            "scope": "home",
            "expires_at": "2026-08-17T00:03:00Z",
            "confirmation_text": "책상 조명을 바꿀까요?"
          }
        }
        """#.utf8))
        XCTAssertEqual(approval.tool.id, "tool-1")
        XCTAssertTrue(approval.tool.enabled)
        XCTAssertEqual(approval.executionProposal?.proposalId, "33333333333333333333333333333333")

        let confirmation = try decoder.decode(ProposalConfirmationResponse.self, from: Data(#"""
        {
          "status": "executed",
          "proposal_id": "33333333333333333333333333333333",
          "tool_kind": "dynamic",
          "action": "execute_dynamic_tool",
          "arguments": {"brightness_percent": 35},
          "scope": "home",
          "result": {"applied": {"brightness_percent": 35}}
        }
        """#.utf8))
        XCTAssertEqual(confirmation.status, "executed")
        XCTAssertEqual(confirmation.proposalId, "33333333333333333333333333333333")
        XCTAssertEqual(confirmation.arguments["brightness_percent"], .integer(35))
    }

    func testCommandRouteRequestPreservesHistoryAndRecommendationContext() throws {
        let context = AgentChatContext(
            context: .focus,
            confidence: 0.8,
            profile: EnvironmentProfile(
                lighting: LightingProfile(brightnessPercent: 70, colorTemperatureK: 4_500),
                temperatureC: 21,
                soundPreset: "focus"
            ),
            reason: "최근 신호가 집중 환경과 맞습니다."
        )
        let request = CommandRouteRequest(
            text: "조명을 낮춰줘",
            scope: "hotel",
            sessionId: "session-test",
            deviceIds: nil,
            messages: [AgentChatTurn(role: "assistant", content: "무엇을 도와드릴까요?")],
            context: context
        )

        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["text"] as? String, "조명을 낮춰줘")
        XCTAssertEqual(object["session_id"] as? String, "session-test")
        XCTAssertEqual((object["messages"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((object["context"] as? [String: Any])?["context"] as? String, "focus")
        XCTAssertNil(object["device_ids"])
    }

    @MainActor
    func testBuiltInProposalDispatchesThroughExistingAppActions() async throws {
        let client = StubAdaptiveSpaceAPI()
        let model = AppModel(client: client)
        model.recommendation = recommendationFixture()

        let serverProposal = try await client.proposeBuiltIn(
            action: "apply_recommendation",
            arguments: ["scope": .string("home")],
            scope: "home",
            sessionId: nil
        )
        let applied = try await model.confirmBuiltIn(
            serverProposal,
            scope: "home"
        )
        let confirmationCalls = await client.recordedCalls()

        XCTAssertTrue(model.homeRoom.isApplied)
        XCTAssertEqual(model.homeRoom.brightness, 42)
        XCTAssertEqual(applied, model.statusMessage)
        XCTAssertEqual(
            confirmationCalls.confirmedProposalIds,
            ["11111111111111111111111111111111"]
        )

        _ = try await model.executeBuiltIn(
            CommandProposal(
                action: "adjust_environment",
                arguments: ["brightness_delta": .integer(-7)],
                source: "gpt",
                toolKind: "builtin"
            ),
            scope: "home"
        )
        XCTAssertEqual(model.homeRoom.brightness, 35)
    }

    @MainActor
    func testToolDraftApprovalRequiresSeparateExecutionConfirmation() async throws {
        let client = StubAdaptiveSpaceAPI()
        let model = AppModel(client: client)
        let draft = ToolDraft(
            draftId: "draft-1",
            name: "set_desk_light",
            description: "책상 조명의 밝기를 설정합니다.",
            deviceId: "desk-light",
            capabilityId: "set_brightness",
            parameters: ["type": .string("object")],
            scopes: ["home"],
            manifestRevision: "manifest-1",
            confirmationText: "책상 조명을 바꿀까요?"
        )
        let draftProposal = CommandProposal(
            proposalId: "22222222222222222222222222222222",
            action: "execute_dynamic_tool",
            arguments: ["brightness_percent": .integer(35)],
            source: "gpt",
            toolKind: "dynamic",
            deviceId: "desk-light",
            capabilityId: "set_brightness",
            scope: "home"
        )

        let approval = try await model.approveToolDraft(proposal: draftProposal, draft: draft)
        let approvalCalls = await client.recordedCalls()

        XCTAssertEqual(approvalCalls.approvedDrafts.map(\.draftId), ["draft-1"])
        XCTAssertEqual(
            approvalCalls.approvedDrafts.map(\.proposalId),
            ["22222222222222222222222222222222"]
        )
        XCTAssertTrue(approvalCalls.confirmedProposalIds.isEmpty)
        XCTAssertEqual(model.registeredTools.map(\.id), ["tool-1"])
        XCTAssertEqual(approval.kind, .dynamicProposal)
        XCTAssertEqual(
            approval.proposal?.proposalId,
            "33333333333333333333333333333333"
        )

        let executionProposal = try XCTUnwrap(approval.proposal)
        let message = try await model.confirmDynamic(executionProposal)
        let confirmedCalls = await client.recordedCalls()

        XCTAssertEqual(
            confirmedCalls.confirmedProposalIds,
            ["33333333333333333333333333333333"]
        )
        XCTAssertEqual(message, "set_desk_light 실행을 완료했습니다.")
    }

    @MainActor
    func testLocalCommandRouterGetsFirstChanceBeforeServer() async throws {
        let localResponse = CommandRouteResponse(
            kind: .builtinProposal,
            proposal: CommandProposal(
                action: "stop_environment",
                arguments: ["scope": .string("home")],
                source: "needle",
                toolKind: "builtin"
            ),
            routedBy: "needle"
        )
        let client = StubAdaptiveSpaceAPI()
        let model = AppModel(
            client: client,
            commandRouter: StubCommandRouter(response: localResponse)
        )

        let response = try await model.routeCommand(text: "지금 멈춰", scope: "home")
        let calls = await client.recordedCalls()

        XCTAssertEqual(response.kind, .builtinProposal)
        XCTAssertEqual(response.proposal?.proposalId, "11111111111111111111111111111111")
        XCTAssertEqual(calls.builtInProposals.map(\.action), ["stop_environment"])
        XCTAssertEqual(calls.builtInProposals.first?.arguments["scope"], .string("home"))
        XCTAssertEqual(calls.builtInProposals.first?.scope, "home")
        XCTAssertEqual(calls.routeCount, 0)
    }

    @MainActor
    func testLocalDynamicRouterGetsServerProposalTokenBeforeReturn() async throws {
        let localResponse = CommandRouteResponse(
            kind: .dynamicProposal,
            proposal: CommandProposal(
                toolId: "tool-1",
                toolName: "set_desk_light",
                arguments: ["brightness_percent": .integer(35)],
                source: "needle",
                toolKind: "dynamic"
            ),
            routedBy: "needle"
        )
        let client = StubAdaptiveSpaceAPI()
        let model = AppModel(
            client: client,
            commandRouter: StubCommandRouter(response: localResponse)
        )

        let response = try await model.routeCommand(text: "책상 조명을 35%로", scope: "home")
        let calls = await client.recordedCalls()

        XCTAssertEqual(response.kind, .dynamicProposal)
        XCTAssertEqual(response.proposal?.proposalId, "44444444444444444444444444444444")
        XCTAssertEqual(calls.toolProposals.map(\.toolId), ["tool-1"])
        XCTAssertEqual(
            calls.toolProposals.first?.arguments["brightness_percent"],
            .integer(35)
        )
        XCTAssertEqual(calls.toolProposals.first?.scope, "home")
        XCTAssertEqual(calls.routeCount, 0)
    }

    @MainActor
    func testLocalHotelProposalIsBoundToCurrentSessionBeforeReturn() async throws {
        let localResponse = CommandRouteResponse(
            kind: .builtinProposal,
            proposal: CommandProposal(
                action: "stop_environment",
                arguments: ["scope": .string("hotel")],
                source: "needle",
                toolKind: "builtin"
            ),
            routedBy: "needle"
        )
        let client = StubAdaptiveSpaceAPI()
        let model = AppModel(
            client: client,
            commandRouter: StubCommandRouter(response: localResponse)
        )
        model.session = hotelSessionFixture(status: "active")

        let response = try await model.routeCommand(text: "호텔 제어를 멈춰", scope: "hotel")
        let calls = await client.recordedCalls()

        XCTAssertEqual(response.proposal?.sessionId, "session-test")
        XCTAssertEqual(calls.builtInProposals.first?.sessionId, "session-test")
        XCTAssertEqual(calls.builtInProposals.first?.scope, "hotel")
        XCTAssertEqual(calls.routeCount, 0)
    }

    @MainActor
    func testHotelProposalPreflightRejectsAnotherSessionBinding() {
        let model = AppModel(client: StubAdaptiveSpaceAPI())
        model.session = hotelSessionFixture(status: "active")
        let stale = CommandProposal(
            proposalId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            action: "stop_environment",
            arguments: ["scope": .string("hotel")],
            requiresConfirmation: true,
            source: "gpt",
            toolKind: "builtin",
            scope: "hotel",
            sessionId: "session-other"
        )

        XCTAssertThrowsError(try model.validateBuiltInProposal(stale, scope: "hotel"))
    }

    @MainActor
    func testHotelConfirmationUsesSessionEndpointInsteadOfGeneralConfirm() async throws {
        let client = StubAdaptiveSpaceAPI()
        let model = AppModel(client: client)
        model.session = hotelSessionFixture(status: "active")
        model.hotelRoom = RoomState(
            brightness: 42,
            temperature: 23,
            sound: "미지원",
            isApplied: true
        )
        let proposal = try await client.proposeBuiltIn(
            action: "stop_environment",
            arguments: [:],
            scope: "hotel",
            sessionId: "session-test"
        )

        let message = try await model.confirmBuiltIn(proposal, scope: "hotel")
        let calls = await client.recordedCalls()

        XCTAssertEqual(calls.sessionCommands.map(\.sessionId), ["session-test"])
        XCTAssertEqual(calls.sessionCommands.first?.proposalId, proposal.proposalId)
        XCTAssertTrue(calls.confirmedProposalIds.isEmpty)
        XCTAssertEqual(model.session?.status, "stopped")
        XCTAssertFalse(model.hotelRoom.isApplied)
        XCTAssertEqual(message, "호텔 중지 · 범주별 결과 확인")
    }

    @MainActor
    func testHotelButtonsIssueBoundProposalsAndNeverSendDirectActions() async {
        let client = StubAdaptiveSpaceAPI()
        let model = AppModel(client: client)
        model.session = hotelSessionFixture(status: "pending_approval")

        await model.applyHotel()
        XCTAssertEqual(model.session?.status, "active")
        XCTAssertTrue(model.hotelRoom.isApplied)

        await model.stopHotel()
        XCTAssertEqual(model.session?.status, "stopped")
        XCTAssertFalse(model.hotelRoom.isApplied)

        await model.restoreHotel()
        XCTAssertEqual(model.session?.status, "restored")
        XCTAssertEqual(model.hotelRoom, .hotelDefault)

        await model.checkout()
        let calls = await client.recordedCalls()

        XCTAssertEqual(calls.builtInProposals.map(\.action), [
            "apply_recommendation",
            "stop_environment",
            "restore_environment",
            "checkout_space"
        ])
        XCTAssertEqual(
            Set(calls.builtInProposals.compactMap(\.sessionId)),
            Set(["session-test"])
        )
        XCTAssertEqual(
            calls.sessionCommands.map(\.proposalId),
            calls.builtInProposals.map(\.proposalId)
        )
        XCTAssertTrue(calls.confirmedProposalIds.isEmpty)
        XCTAssertEqual(model.session?.status, "expired")
        XCTAssertEqual(model.step, .complete)
        XCTAssertEqual(model.hotelRoom, .hotelDefault)
    }

    private func recommendationFixture() -> RecommendationResponse {
        let decision = ContextDecision(
            context: .recovery,
            confidence: 0.8,
            reason: "테스트",
            evidence: ["테스트 신호"]
        )
        return RecommendationResponse(
            profileId: "profile-1",
            context: .recovery,
            confidence: 0.8,
            profile: EnvironmentProfile(
                lighting: LightingProfile(brightnessPercent: 42, colorTemperatureK: 2_700),
                temperatureC: 23,
                soundPreset: "calm"
            ),
            reason: "테스트 추천",
            requiresConfirmation: true,
            inputSource: "test",
            generatedBy: "test",
            observedSampleCount: 1,
            evidence: ["테스트 신호"],
            comparison: DecisionComparison(
                ruleBased: decision,
                agent: decision,
                signalEvidence: ["테스트 신호"],
                conflictDetected: false,
                selected: "agent"
            )
        )
    }

    private func hotelSessionFixture(status: String) -> SpaceSession {
        SpaceSession(
            sessionId: "session-test",
            spaceId: "hotel-demo-room",
            status: status,
            execution: SpaceExecution(
                lighting: SpaceExecution.Lighting(brightnessPercent: 42),
                temperatureC: 23
            ),
            excluded: ["sound_preset"],
            expiresAt: "2026-08-17T01:00:00Z",
            sharedBiometricCount: 0,
            profileCopyDeleted: false,
            results: nil
        )
    }
}

private struct StubCommandRouter: CommandRouting {
    let response: CommandRouteResponse?

    func route(_ request: CommandRouteRequest) async throws -> CommandRouteResponse? {
        response
    }
}

private actor StubAdaptiveSpaceAPI: AdaptiveSpaceAPI {
    struct BuiltInProposalCall: Sendable {
        let proposalId: String
        let action: String
        let arguments: [String: JSONValue]
        let scope: String?
        let sessionId: String?
    }

    struct ToolProposalCall: Sendable {
        let toolId: String
        let arguments: [String: JSONValue]
        let scope: String?
    }

    struct DraftReviewCall: Sendable {
        let draftId: String
        let proposalId: String
    }

    struct SessionCommandCall: Sendable {
        let sessionId: String
        let proposalId: String
    }

    struct Calls: Sendable {
        let routeCount: Int
        let builtInProposals: [BuiltInProposalCall]
        let toolProposals: [ToolProposalCall]
        let approvedDrafts: [DraftReviewCall]
        let rejectedDrafts: [DraftReviewCall]
        let confirmedProposalIds: [String]
        let sessionCommands: [SessionCommandCall]
    }

    private var routeCount = 0
    private var builtInProposals: [BuiltInProposalCall] = []
    private var toolProposals: [ToolProposalCall] = []
    private var approvedDrafts: [DraftReviewCall] = []
    private var rejectedDrafts: [DraftReviewCall] = []
    private var confirmedProposalIds: [String] = []
    private var sessionCommands: [SessionCommandCall] = []

    func recommendation(_ request: RecommendationRequest) async throws -> RecommendationResponse {
        throw StubError.unimplemented
    }

    func chat(messages: [AgentChatTurn], recommendation: RecommendationResponse?) async throws -> AgentChatResponse {
        throw StubError.unimplemented
    }

    func space() async throws -> SpaceSpec { throw StubError.unimplemented }
    func createSession(profile: EnvironmentProfile) async throws -> SpaceSession { throw StubError.unimplemented }
    func command(sessionId: String, proposalId: String) async throws -> SpaceSession {
        sessionCommands.append(
            SessionCommandCall(sessionId: sessionId, proposalId: proposalId)
        )
        guard let proposal = builtInProposals.last(where: { $0.proposalId == proposalId }) else {
            throw StubError.unimplemented
        }
        switch proposal.action {
        case "apply_recommendation":
            return hotelSession(status: "active", sessionId: sessionId)
        case "stop_environment":
            return hotelSession(status: "stopped", sessionId: sessionId)
        case "restore_environment":
            return hotelSession(status: "restored", sessionId: sessionId)
        case "checkout_space":
            return hotelSession(
                status: "expired",
                sessionId: sessionId,
                execution: nil,
                profileCopyDeleted: true
            )
        default:
            throw StubError.unimplemented
        }
    }

    func routeCommand(_ request: CommandRouteRequest) async throws -> CommandRouteResponse {
        routeCount += 1
        return CommandRouteResponse(kind: .chat, message: "서버 응답", routedBy: "gpt")
    }

    func tools() async throws -> [RegisteredTool] { [approvedTool] }

    func proposeBuiltIn(
        action: String,
        arguments: [String: JSONValue],
        scope: String?,
        sessionId: String?
    ) async throws -> CommandProposal {
        let proposalId = String(repeating: String((builtInProposals.count + 1) % 10), count: 32)
        var normalizedArguments = arguments
        if let scope { normalizedArguments["scope"] = .string(scope) }
        builtInProposals.append(
            BuiltInProposalCall(
                proposalId: proposalId,
                action: action,
                arguments: normalizedArguments,
                scope: scope,
                sessionId: sessionId
            )
        )
        return CommandProposal(
            proposalId: proposalId,
            toolName: action,
            action: action,
            arguments: normalizedArguments,
            requiresConfirmation: true,
            source: "needle",
            toolKind: "builtin",
            deviceId: "app-model",
            capabilityId: action,
            scope: scope ?? "home",
            sessionId: sessionId,
            expiresAt: "2026-08-17T00:02:00Z",
            confirmationText: "\(action) 명령을 실행할까요?"
        )
    }

    func proposeTool(
        id: String,
        arguments: [String: JSONValue],
        scope: String?
    ) async throws -> CommandProposal {
        toolProposals.append(
            ToolProposalCall(toolId: id, arguments: arguments, scope: scope)
        )
        return CommandProposal(
            proposalId: "44444444444444444444444444444444",
            toolId: id,
            toolName: approvedTool.name,
            action: "execute_dynamic_tool",
            arguments: arguments,
            requiresConfirmation: true,
            source: "needle",
            toolKind: "dynamic",
            deviceId: approvedTool.deviceId,
            capabilityId: approvedTool.capabilityId,
            scope: scope ?? "home",
            expiresAt: "2026-08-17T00:02:00Z",
            confirmationText: approvedTool.confirmationText
        )
    }

    func approveToolDraft(id: String, proposalId: String) async throws -> ToolApprovalResponse {
        approvedDrafts.append(DraftReviewCall(draftId: id, proposalId: proposalId))
        return ToolApprovalResponse(
            tool: approvedTool,
            executionProposal: executionProposal
        )
    }

    func rejectToolDraft(id: String, proposalId: String) async throws {
        rejectedDrafts.append(DraftReviewCall(draftId: id, proposalId: proposalId))
    }

    func confirmProposal(id: String) async throws -> ProposalConfirmationResponse {
        confirmedProposalIds.append(id)
        if id == executionProposal.proposalId {
            return ProposalConfirmationResponse(
                status: "executed",
                proposalId: id,
                toolKind: "dynamic",
                action: "execute_dynamic_tool",
                arguments: executionProposal.arguments,
                scope: "home",
                result: .object(["applied": .object(executionProposal.arguments)])
            )
        }

        let call = builtInProposals.last
        return ProposalConfirmationResponse(
            status: "confirmed",
            proposalId: id,
            toolKind: "builtin",
            action: call?.action ?? "stop_environment",
            arguments: call?.arguments ?? ["scope": .string("home")],
            scope: call?.scope ?? "home",
            result: nil
        )
    }

    func recordedCalls() -> Calls {
        Calls(
            routeCount: routeCount,
            builtInProposals: builtInProposals,
            toolProposals: toolProposals,
            approvedDrafts: approvedDrafts,
            rejectedDrafts: rejectedDrafts,
            confirmedProposalIds: confirmedProposalIds,
            sessionCommands: sessionCommands
        )
    }

    private func hotelSession(
        status: String,
        sessionId: String,
        execution: SpaceExecution? = SpaceExecution(
            lighting: SpaceExecution.Lighting(brightnessPercent: 42),
            temperatureC: 23
        ),
        profileCopyDeleted: Bool = false
    ) -> SpaceSession {
        SpaceSession(
            sessionId: sessionId,
            spaceId: "hotel-demo-room",
            status: status,
            execution: execution,
            excluded: ["sound_preset"],
            expiresAt: "2026-08-17T01:00:00Z",
            sharedBiometricCount: 0,
            profileCopyDeleted: profileCopyDeleted,
            results: ["lighting": status]
        )
    }

    private var approvedTool: RegisteredTool {
        RegisteredTool(
            id: "tool-1",
            name: "set_desk_light",
            description: "책상 조명의 밝기를 설정합니다.",
            deviceId: "desk-light",
            capabilityId: "set_brightness",
            parameters: ["type": .string("object")],
            scopes: ["home"],
            manifestRevision: "manifest-1",
            draftId: "draft-1",
            confirmationText: "책상 조명을 바꿀까요?",
            approvedAt: "2026-08-17T00:01:00Z",
            enabled: true
        )
    }

    private var executionProposal: CommandProposal {
        CommandProposal(
            proposalId: "33333333333333333333333333333333",
            toolId: approvedTool.id,
            toolName: approvedTool.name,
            action: "execute_dynamic_tool",
            arguments: ["brightness_percent": .integer(35)],
            requiresConfirmation: true,
            source: "gpt",
            toolKind: "dynamic",
            deviceId: approvedTool.deviceId,
            capabilityId: approvedTool.capabilityId,
            scope: "home",
            expiresAt: "2026-08-17T00:03:00Z",
            confirmationText: approvedTool.confirmationText
        )
    }

    private enum StubError: Error { case unimplemented }
}
