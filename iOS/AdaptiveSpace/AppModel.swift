import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    enum CommandError: LocalizedError {
        case missingProposal
        case unsupportedAction(String)
        case unavailable(String)
        case invalidArguments(String)

        var errorDescription: String? {
            switch self {
            case .missingProposal:
                "실행할 명령 정보가 없습니다."
            case let .unsupportedAction(action):
                "아직 지원하지 않는 명령입니다: \(action)"
            case let .unavailable(message), let .invalidArguments(message):
                message
            }
        }
    }

    enum Step: Int, CaseIterable {
        case wearable, profile, home, consensus, hotel, complete

        var title: String {
            switch self {
            case .wearable: "웨어러블"
            case .profile: "추천"
            case .home: "집 적용"
            case .consensus: "합의"
            case .hotel: "호텔"
            case .complete: "완료"
            }
        }
    }

    var step = Step.wearable
    var scenario = DemoScenario.recovery
    var consent = Set(ConsentedMetric.allCases)
    var isWearableConnected = false
    var isStreaming = false
    var lastSignalSequence = 0
    var snapshot: WearableSnapshot?
    var recentSnapshots: [WearableSnapshot] = []
    var recommendation: RecommendationResponse?
    var editedBrightness = 35.0
    var homeRoom = RoomState.homeDefault
    var hotelRoom = RoomState.hotelDefault
    var hasSavedAdjustment = false
    var space: SpaceSpec?
    var session: SpaceSession?
    var companionPreferences: [ComfortPreference] = []
    var companionConsensus: CompanionConsensus?
    private(set) var registeredTools: [RegisteredTool] = []
    var statusMessage = "더미 데이터만 사용합니다."
    var isLoading = false
    var errorMessage: String?

    private let wearable: any WearableProvider
    private let client: any AdaptiveSpaceAPI
    private let commandRouter: (any CommandRouting)?
    private var streamTask: Task<Void, Never>?
    private var homeBeforeApply = RoomState.homeDefault
    private var brightnessDelta: Int
    private var didLoadRegisteredTools = false

    init(
        wearable: any WearableProvider = DemoWearableProvider(),
        client: any AdaptiveSpaceAPI = APIClient(),
        commandRouter: (any CommandRouting)? = nil
    ) {
        self.wearable = wearable
        self.client = client
        self.commandRouter = commandRouter
        self.brightnessDelta = UserDefaults.standard.integer(forKey: "recoveryBrightnessDelta")
        if let rawScenario = UserDefaults.standard.string(forKey: "demoScenario"),
           let demoScenario = DemoScenario(rawValue: rawScenario) {
            self.scenario = demoScenario
        }
    }

    func toggleConsent(_ metric: ConsentedMetric) {
        if consent.contains(metric) { consent.remove(metric) } else { consent.insert(metric) }
        recentSnapshots = recentSnapshots.map { $0.filtered(by: consent) }
        snapshot = snapshot?.filtered(by: consent)
    }

    func connectAndSync() async {
        await perform {
            try await wearable.connect()
            isWearableConnected = true
            recentSnapshots = []
            snapshot = nil
            lastSignalSequence = 0
            isStreaming = true
            statusMessage = "Demo data 연결됨"
        }

        guard isWearableConnected else { return }
        streamTask?.cancel()
        let selectedScenario = scenario
        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await signal in wearable.signalStream(for: selectedScenario) {
                    try Task.checkCancellation()
                    let filtered = signal.snapshot.filtered(by: consent)
                    recentSnapshots.append(filtered)
                    if recentSnapshots.count > 12 {
                        recentSnapshots.removeFirst(recentSnapshots.count - 12)
                    }
                    snapshot = filtered
                    lastSignalSequence = signal.sequence
                    statusMessage = "Demo data LIVE · \(signal.sequence)"
                }
            } catch is CancellationError {
                return
            } catch {
                isStreaming = false
                errorMessage = error.localizedDescription
            }
        }
    }

    func requestRecommendation() async {
        guard let snapshot else { return }
        await perform {
            let response = try await client.recommendation(
                RecommendationRequest(
                    snapshot: snapshot,
                    recentSnapshots: recentSnapshots,
                    consentedFields: consent.sorted { $0.rawValue < $1.rawValue },
                    adjustment: Adjustment(
                        brightnessDelta: scenario == .recovery ? brightnessDelta : 0,
                        temperatureDeltaC: 0,
                        soundPreset: nil
                    )
                )
            )
            recommendation = response
            editedBrightness = Double(response.profile.lighting.brightnessPercent)
            statusMessage = response.generatedBy == "agents_sdk" ? "Agents SDK 추천" : "규칙 기반 오프라인 추천"
            step = .profile
        }
    }

    func approveProfile() {
        step = .home
        statusMessage = "적용 전 값을 확인하세요."
    }

    func applyHome() {
        guard let recommendation else { return }
        homeBeforeApply = homeRoom
        homeRoom = RoomState(
            brightness: recommendation.profile.lighting.brightnessPercent,
            temperature: recommendation.profile.temperatureC,
            sound: recommendation.profile.soundPreset,
            isApplied: true
        )
        hasSavedAdjustment = false
        statusMessage = "집 환경 적용 완료 · 조명/온도/사운드 성공"
    }

    func stopHome() {
        homeRoom = homeBeforeApply
        statusMessage = "즉시 중지 · 적용 직전 상태 복원"
    }

    func restoreHome() {
        homeRoom = .homeDefault
        statusMessage = "집 기본값으로 복원했습니다."
    }

    func saveAdjustment() async {
        guard scenario == .recovery, let recommendation else { return }
        let base = recommendation.profile.lighting.brightnessPercent - brightnessDelta
        brightnessDelta = Int(editedBrightness.rounded()) - base
        UserDefaults.standard.set(brightnessDelta, forKey: "recoveryBrightnessDelta")
        await requestRecommendation()
        if homeRoom.isApplied, let updatedRecommendation = self.recommendation {
            homeRoom.brightness = updatedRecommendation.profile.lighting.brightnessPercent
        }
        step = .home
        hasSavedAdjustment = true
        statusMessage = "사용자 보정 저장 · 같은 조건의 다음 추천에 반영"
    }

    func checkIn() async {
        guard let recommendation else { return }
        await perform {
            let checkedInSpace = try await client.space()
            space = checkedInSpace
            companionPreferences = makeCompanionPreferences(
                profile: recommendation.profile,
                space: checkedInSpace
            )
            companionConsensus = CompanionConsensusEngine.resolve(
                companionPreferences,
                preferred: recommendation.profile
            )
            step = .consensus
            statusMessage = "호텔 체크인 · 동반자 2명 연결"
        }
    }

    func approveCompanionConsensus() async {
        guard let recommendation,
              let profile = companionConsensus?.profile(basedOn: recommendation.profile) else { return }
        await createHotelSession(profile: profile)
    }

    func chooseCompanionPreference(_ id: String) async {
        guard let recommendation,
              let preference = companionPreferences.first(where: { $0.id == id }) else { return }
        let profile = CompanionConsensusEngine.profile(
            for: preference,
            preferred: recommendation.profile
        )
        await createHotelSession(profile: profile)
    }

    func applyHotel() async { await hotelCommand("apply_recommendation") }
    func stopHotel() async { await hotelCommand("stop_environment") }
    func restoreHotel() async { await hotelCommand("restore_environment") }
    func checkout() async { await hotelCommand("checkout_space") }

    func routeCommand(
        text: String,
        scope: String?,
        messages: [AgentChatTurn] = []
    ) async throws -> CommandRouteResponse {
        let context = recommendation.map {
            AgentChatContext(
                context: $0.context,
                confidence: $0.confidence,
                profile: $0.profile,
                reason: $0.reason
            )
        }
        let request = CommandRouteRequest(
            text: text,
            scope: scope,
            sessionId: scope == "hotel" ? session?.sessionId : nil,
            deviceIds: nil,
            messages: Array(messages.suffix(12)),
            context: context
        )

        if commandRouter != nil, !didLoadRegisteredTools {
            do {
                try await loadRegisteredTools()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Cached dynamic tools are optional; server routing below remains authoritative.
            }
        }

        if let localResult = try await localProposal(for: request) {
            return localResult
        }

        return try await client.routeCommand(request)
    }

    func validateBuiltInProposal(
        _ proposal: CommandProposal,
        scope preferredScope: String?
    ) throws {
        guard proposal.requiresConfirmation else {
            throw CommandError.invalidArguments("사용자 확인이 필요한 명령만 실행할 수 있습니다.")
        }
        guard let rawAction = proposal.commandName else { throw CommandError.missingProposal }
        let action = normalizedCommand(rawAction)
        let scope = proposal.arguments["scope"]?.stringValue
            ?? proposal.scope
            ?? preferredScope
            ?? "home"

        if scope == "hotel", proposal.proposalId != nil {
            guard let activeSession = session,
                  proposal.sessionId == activeSession.sessionId else {
                throw CommandError.invalidArguments("호텔 명령이 현재 세션에 바인딩되지 않았습니다.")
            }
        }

        switch action {
        case "apply", "apply_environment", "apply_recommendation", "apply_home", "apply_hotel":
            if action == "apply_hotel" || scope == "hotel" {
                guard session != nil else {
                    throw CommandError.unavailable("먼저 호텔 체크인과 동반자 합의를 완료해 주세요.")
                }
            } else if recommendation == nil {
                throw CommandError.unavailable("먼저 Live에서 환경 추천을 만들어 주세요.")
            }
        case "stop", "stop_environment", "stop_home", "stop_hotel",
             "restore", "restore_environment", "restore_home", "restore_hotel":
            if action.hasSuffix("_hotel") || scope == "hotel" {
                guard session != nil else {
                    throw CommandError.unavailable("활성 호텔 세션이 없습니다.")
                }
            }
        case "checkout", "checkout_space", "checkout_hotel":
            guard scope == "hotel", session != nil else {
                throw CommandError.unavailable("체크아웃할 호텔 세션이 없습니다.")
            }
        case "adjust", "adjust_environment", "adjust_home":
            guard scope != "hotel" else {
                throw CommandError.unavailable("호텔의 세부 조절은 연결된 기기 도구로 실행해 주세요.")
            }
            _ = try validatedHomeAdjustment(proposal.arguments)
        default:
            throw CommandError.unsupportedAction(rawAction)
        }
    }

    @discardableResult
    func confirmBuiltIn(
        _ proposal: CommandProposal,
        scope preferredScope: String?
    ) async throws -> String {
        try validateBuiltInProposal(proposal, scope: preferredScope)
        guard let proposalId = proposal.proposalId else { throw CommandError.missingProposal }
        let scope = proposal.arguments["scope"]?.stringValue
            ?? proposal.scope
            ?? preferredScope
            ?? "home"

        if scope == "hotel" {
            guard let activeSession = session else {
                throw CommandError.unavailable("활성 호텔 세션이 없습니다.")
            }
            guard proposal.sessionId == activeSession.sessionId else {
                throw CommandError.invalidArguments("호텔 명령이 현재 세션에 바인딩되지 않았습니다.")
            }
            let updated = try await client.command(
                sessionId: activeSession.sessionId,
                proposalId: proposalId
            )
            updateHotelState(from: updated)
            return statusMessage
        }

        let confirmation = try await client.confirmProposal(id: proposalId)
        guard confirmation.toolKind == "builtin" else {
            throw CommandError.invalidArguments("서버 확인 결과가 내장 명령과 일치하지 않습니다.")
        }
        let confirmed = CommandProposal(
            proposalId: confirmation.proposalId,
            toolName: confirmation.action,
            action: confirmation.action,
            arguments: confirmation.arguments,
            requiresConfirmation: true,
            source: proposal.source,
            toolKind: "builtin",
            scope: confirmation.scope
        )
        try validateBuiltInProposal(confirmed, scope: preferredScope)
        return try await executeBuiltIn(confirmed, scope: preferredScope)
    }

    @discardableResult
    func executeBuiltIn(_ proposal: CommandProposal, scope preferredScope: String?) async throws -> String {
        errorMessage = nil
        try validateBuiltInProposal(proposal, scope: preferredScope)
        guard let rawAction = proposal.commandName else { throw CommandError.missingProposal }
        let action = normalizedCommand(rawAction)
        let scope = proposal.arguments["scope"]?.stringValue
            ?? proposal.scope
            ?? preferredScope
            ?? "home"

        switch action {
        case "apply", "apply_environment", "apply_recommendation", "apply_home", "apply_hotel":
            if action == "apply_hotel" || scope == "hotel" {
                guard session != nil else {
                    throw CommandError.unavailable("먼저 호텔 체크인과 동반자 합의를 완료해 주세요.")
                }
                await applyHotel()
            } else {
                guard recommendation != nil else {
                    throw CommandError.unavailable("먼저 Live에서 환경 추천을 만들어 주세요.")
                }
                applyHome()
            }

        case "stop", "stop_environment", "stop_home", "stop_hotel":
            if action == "stop_hotel" || scope == "hotel" {
                guard session != nil else { throw CommandError.unavailable("활성 호텔 세션이 없습니다.") }
                await stopHotel()
            } else {
                stopHome()
            }

        case "restore", "restore_environment", "restore_home", "restore_hotel":
            if action == "restore_hotel" || scope == "hotel" {
                guard session != nil else { throw CommandError.unavailable("활성 호텔 세션이 없습니다.") }
                await restoreHotel()
            } else {
                restoreHome()
            }

        case "checkout", "checkout_space", "checkout_hotel":
            guard session != nil else { throw CommandError.unavailable("체크아웃할 호텔 세션이 없습니다.") }
            await checkout()

        case "adjust", "adjust_environment", "adjust_home":
            guard scope != "hotel" else {
                throw CommandError.unavailable("호텔의 세부 조절은 연결된 기기 도구로 실행해 주세요.")
            }
            try adjustHome(using: proposal.arguments)

        default:
            throw CommandError.unsupportedAction(rawAction)
        }

        if let errorMessage { throw CommandError.unavailable(errorMessage) }
        return statusMessage
    }

    func approveToolDraft(
        proposal: CommandProposal?,
        draft: ToolDraft?
    ) async throws -> CommandRouteResponse {
        try await performCommand {
            guard let draft, let proposalId = proposal?.proposalId else {
                throw CommandError.missingProposal
            }
            let approval = try await client.approveToolDraft(
                id: draft.draftId,
                proposalId: proposalId
            )
            cache(approval.tool)
            didLoadRegisteredTools = true
            await commandRouter?.updateTools(registeredTools)
            guard let executionProposal = approval.executionProposal else {
                throw CommandError.unavailable("승인된 도구의 실행 제안을 받지 못했습니다.")
            }
            statusMessage = "새 도구를 등록했습니다. 실행 내용을 한 번 더 확인해 주세요."
            return CommandRouteResponse(
                kind: .dynamicProposal,
                proposal: executionProposal,
                message: statusMessage,
                routedBy: proposal?.source ?? "gpt"
            )
        }
    }

    @discardableResult
    func confirmDynamic(_ proposal: CommandProposal) async throws -> String {
        try await performCommand {
            guard proposal.toolKind == "dynamic",
                  let proposalId = proposal.proposalId else {
                throw CommandError.missingProposal
            }
            let confirmation = try await client.confirmProposal(id: proposalId)
            guard confirmation.toolKind == "dynamic", confirmation.status == "executed" else {
                throw CommandError.invalidArguments("서버가 동적 도구 실행을 확인하지 않았습니다.")
            }
            let name = proposal.toolName ?? "연결 기기 도구"
            let message = "\(name) 실행을 완료했습니다."
            statusMessage = message
            return message
        }
    }

    func rejectToolDraft(_ draft: ToolDraft, proposal: CommandProposal?) async throws {
        try await performCommand {
            guard let proposalId = proposal?.proposalId else { throw CommandError.missingProposal }
            try await client.rejectToolDraft(id: draft.draftId, proposalId: proposalId)
            statusMessage = "새 도구 생성을 취소했습니다."
        }
    }

    func refreshRegisteredTools() async {
        await perform {
            try await loadRegisteredTools()
        }
    }

    func resetDemo() {
        streamTask?.cancel()
        streamTask = nil
        step = .wearable
        isWearableConnected = false
        isStreaming = false
        lastSignalSequence = 0
        snapshot = nil
        recentSnapshots = []
        recommendation = nil
        space = nil
        session = nil
        companionPreferences = []
        companionConsensus = nil
        homeRoom = .homeDefault
        hotelRoom = .hotelDefault
        hasSavedAdjustment = false
        statusMessage = "더미 데이터만 사용합니다."
        errorMessage = nil
    }

    private func hotelCommand(_ action: String) async {
        guard let activeSession = session else { return }
        await perform {
            let proposal = try await client.proposeBuiltIn(
                action: action,
                arguments: [:],
                scope: "hotel",
                sessionId: activeSession.sessionId
            )
            guard let proposalId = proposal.proposalId,
                  proposal.sessionId == activeSession.sessionId else {
                throw CommandError.invalidArguments("호텔 명령이 현재 세션에 바인딩되지 않았습니다.")
            }
            let updated = try await client.command(
                sessionId: activeSession.sessionId,
                proposalId: proposalId
            )
            updateHotelState(from: updated)
        }
    }

    private func updateHotelState(from updated: SpaceSession) {
        session = updated
        switch updated.status {
        case "active":
            if let execution = updated.execution {
                hotelRoom = RoomState(
                    brightness: execution.lighting.brightnessPercent,
                    temperature: execution.temperatureC,
                    sound: "미지원",
                    isApplied: true
                )
            }
            statusMessage = "호텔 적용 · 범주별 결과 확인"
        case "stopped":
            hotelRoom.isApplied = false
            statusMessage = "호텔 중지 · 범주별 결과 확인"
        case "restored":
            hotelRoom = .hotelDefault
            statusMessage = "호텔 복원 · 범주별 결과 확인"
        case "expired":
            hotelRoom = .hotelDefault
            step = .complete
            statusMessage = "체크아웃 · 기본값 복원 · 세션 만료"
        default:
            statusMessage = "호텔 세션 상태 · \(updated.status)"
        }
    }

    private func createHotelSession(profile: EnvironmentProfile) async {
        await perform {
            session = try await client.createSession(profile: profile)
            step = .hotel
            statusMessage = "동반자 합의 완료 · 호텔 승인 전"
        }
    }

    private func adjustHome(using arguments: [String: JSONValue]) throws {
        let (brightnessDelta, temperatureDelta, soundPreset) = try validatedHomeAdjustment(arguments)

        if !homeRoom.isApplied { homeBeforeApply = homeRoom }
        homeRoom.brightness = min(100, max(10, homeRoom.brightness + brightnessDelta))
        homeRoom.temperature = min(30, max(16, homeRoom.temperature + temperatureDelta))
        if let soundPreset { homeRoom.sound = soundPreset }
        homeRoom.isApplied = true
        statusMessage = "집 환경 조절 완료 · \(homeRoom.brightness)% · \(homeRoom.temperature.formatted())°"
    }

    private func validatedHomeAdjustment(
        _ arguments: [String: JSONValue]
    ) throws -> (brightness: Int, temperature: Double, sound: String?) {
        let brightnessDelta = arguments["brightness_delta"]?.intValue ?? 0
        let temperatureDelta = arguments["temperature_delta_c"]?.doubleValue ?? 0
        let soundPreset = arguments["sound_preset"]?.stringValue
        guard (-30...30).contains(brightnessDelta) else {
            throw CommandError.invalidArguments("밝기 조절 범위는 한 번에 ±30%입니다.")
        }
        guard (-3.0...3.0).contains(temperatureDelta) else {
            throw CommandError.invalidArguments("온도 조절 범위는 한 번에 ±3°C입니다.")
        }
        if let soundPreset, !["calm", "focus", "silence"].contains(soundPreset) {
            throw CommandError.invalidArguments("지원하지 않는 사운드 프리셋입니다.")
        }
        guard brightnessDelta != 0 || temperatureDelta != 0 || soundPreset != nil else {
            throw CommandError.invalidArguments("변경할 밝기, 온도 또는 사운드 값이 없습니다.")
        }
        return (brightnessDelta, temperatureDelta, soundPreset)
    }

    private func normalizedCommand(_ action: String) -> String {
        action
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    private func cache(_ tool: RegisteredTool) {
        registeredTools.removeAll { $0.id == tool.id }
        registeredTools.append(tool)
        registeredTools.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func localProposal(for request: CommandRouteRequest) async throws -> CommandRouteResponse? {
        guard let commandRouter else { return nil }
        do {
            guard let result = try await commandRouter.route(request), result.kind != .chat else {
                return nil
            }
            guard let proposal = result.proposal else { return nil }
            let serverProposal: CommandProposal
            switch result.kind {
            case .builtinProposal:
                try validateBuiltInProposal(proposal, scope: request.scope)
                guard let action = proposal.commandName else { throw CommandError.missingProposal }
                serverProposal = try await client.proposeBuiltIn(
                    action: action,
                    arguments: proposal.arguments,
                    scope: request.scope,
                    sessionId: request.sessionId
                )
            case .dynamicProposal:
                guard let toolId = proposal.toolId else { throw CommandError.missingProposal }
                serverProposal = try await client.proposeTool(
                    id: toolId,
                    arguments: proposal.arguments,
                    scope: request.scope
                )
            case .toolDraft, .chat:
                return nil
            }
            return CommandRouteResponse(
                kind: result.kind,
                proposal: serverProposal,
                message: result.message,
                routedBy: "needle",
                fallbackReason: result.fallbackReason
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    private func loadRegisteredTools() async throws {
        registeredTools = try await client.tools()
        didLoadRegisteredTools = true
        await commandRouter?.updateTools(registeredTools)
    }

    private func makeCompanionPreferences(
        profile: EnvironmentProfile,
        space: SpaceSpec
    ) -> [ComfortPreference] {
        let brightnessBounds = (space.lighting.brightnessRange.first ?? 20)...(space.lighting.brightnessRange.last ?? 100)
        let temperatureBounds = (space.temperature.rangeC.first ?? 20)...(space.temperature.rangeC.last ?? 24)

        let myBrightness = clampedRange(
            (profile.lighting.brightnessPercent - 10)...(profile.lighting.brightnessPercent + 10),
            to: brightnessBounds
        )
        let myTemperature = clampedRange(
            (profile.temperatureC - 1)...(profile.temperatureC + 1),
            to: temperatureBounds
        )
        let companionBrightness = clampedRange(40...60, to: brightnessBounds)
        let companionTemperature = clampedRange(
            21.5...23.5,
            to: temperatureBounds
        )

        return [
            ComfortPreference(
                id: "me",
                name: "나",
                symbol: "person.fill",
                brightnessRange: myBrightness,
                temperatureRange: myTemperature
            ),
            ComfortPreference(
                id: "companion",
                name: "동반자",
                symbol: "person.fill",
                brightnessRange: companionBrightness,
                temperatureRange: companionTemperature
            )
        ]
    }

    private func clampedRange<T: Comparable>(
        _ proposed: ClosedRange<T>,
        to bounds: ClosedRange<T>
    ) -> ClosedRange<T> {
        let lower = min(max(proposed.lowerBound, bounds.lowerBound), bounds.upperBound)
        let upper = min(max(proposed.upperBound, bounds.lowerBound), bounds.upperBound)
        return lower...upper
    }

    private func perform(_ operation: () async throws -> Void) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await operation()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func performCommand<Value>(_ operation: () async throws -> Value) async throws -> Value {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            return try await operation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }
}
