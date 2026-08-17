import SwiftUI

struct AgentChatView: View {
    private struct Bubble: Identifiable {
        let id = UUID()
        let role: String
        let content: String
    }

    let model: AppModel
    let scope: String?
    var showsCloseButton = true

    @Environment(\.dismiss) private var dismiss
    @StateObject private var voice = VoiceController()
    @State private var messages: [Bubble] = []
    @State private var draft = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showsVoiceMode = false
    @State private var pendingRoute: CommandRouteResponse?
    @State private var requestTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ZStack {
                AmbientBackdrop()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 20) {
                            ForEach(messages) { message in
                                bubble(message)
                                    .id(message.id)
                            }
                            if let pendingRoute {
                                RouteConfirmationCard(
                                    route: pendingRoute,
                                    isLoading: isLoading,
                                    confirm: confirmPendingRoute,
                                    cancel: cancelPendingRoute
                                )
                                .id("pendingRoute")
                            }
                            if isLoading {
                                ProgressView()
                                    .tint(AdaptiveDesign.accent)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if let errorMessage {
                                Text(errorMessage)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                        .padding(20)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: messages.count) {
                        if let id = messages.last?.id {
                            withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                        }
                    }
                    .onChange(of: pendingRoute != nil) {
                        if pendingRoute != nil {
                            withAnimation { proxy.scrollTo("pendingRoute", anchor: .bottom) }
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                composer
                    .padding(.bottom, showsCloseButton ? 0 : 76)
            }
            .navigationTitle("Adaptive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsCloseButton {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("닫기") { dismiss() }
                    }
                }
            }
            .preferredColorScheme(.dark)
            .onDisappear {
                requestTask?.cancel()
                voice.stop()
                voice.stopSpeaking()
            }
            .fullScreenCover(isPresented: $showsVoiceMode) {
                VoiceModeView(
                    voice: voice,
                    isLoading: isLoading,
                    reply: messages.last(where: { $0.role == "assistant" })?.content,
                    send: sendVoice,
                    close: closeVoice
                )
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("메시지", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .padding(.horizontal, 16)
                .frame(minHeight: 48)
                .modifier(ChatInputGlassModifier())
                .submitLabel(.send)
                .onSubmit { send(draft) }
                .disabled(isLoading || pendingRoute != nil)
                .accessibilityIdentifier("agentChatInput")

            Button {
                if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    showsVoiceMode = true
                } else {
                    send(draft)
                }
            } label: {
                Image(systemName: draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "waveform" : "arrow.up")
                    .font(.headline.weight(.bold))
                    .frame(width: 48, height: 48)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .tint(AdaptiveDesign.accent)
            .foregroundStyle(AdaptiveDesign.ink)
            .disabled(isLoading || pendingRoute != nil)
            .accessibilityLabel(draft.isEmpty ? "보이스 모드" : "전송")
            .accessibilityIdentifier(draft.isEmpty ? "openVoiceMode" : "sendAgentChat")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func bubble(_ message: Bubble) -> some View {
        if message.role == "user" {
            Text(message.content)
                .font(.body)
                .foregroundStyle(AdaptiveDesign.ink)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(AdaptiveDesign.accent, in: RoundedRectangle(cornerRadius: 20))
                .frame(maxWidth: 300, alignment: .trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityIdentifier("chatUserMessage")
        } else {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "wave.3.right")
                    .foregroundStyle(AdaptiveDesign.accent)
                    .frame(width: 24, height: 24)
                Text((try? AttributedString(markdown: message.content)) ?? AttributedString(message.content))
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("chatAgentReply")
        }
    }

    private func sendVoice() {
        let content = voice.transcript
        voice.stop()
        guard !content.isEmpty else { return }
        showsVoiceMode = false
        send(content, speakResponse: true)
    }

    private func closeVoice() {
        voice.clear()
        voice.stopSpeaking()
        showsVoiceMode = false
    }

    private func send(_ content: String, speakResponse: Bool = false) {
        let content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, !isLoading, pendingRoute == nil else { return }
        let history = messages.suffix(12).map { AgentChatTurn(role: $0.role, content: $0.content) }
        messages.append(Bubble(role: "user", content: content))
        draft = ""
        errorMessage = nil
        isLoading = true
        requestTask?.cancel()
        requestTask = Task {
            defer { isLoading = false }
            do {
                let response = try await model.routeCommand(
                    text: content,
                    scope: scope,
                    messages: history
                )
                try Task.checkCancellation()
                receive(response, speakResponse: speakResponse)
                voice.clear()
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func receive(_ response: CommandRouteResponse, speakResponse: Bool) {
        switch response.kind {
        case .chat:
            let message = response.message ?? "응답을 만들지 못했습니다. 다시 말씀해 주세요."
            messages.append(Bubble(role: "assistant", content: message))
            if speakResponse { voice.speak(message) }
        case .builtinProposal:
            guard let proposal = response.proposal else {
                errorMessage = "서버가 실행할 명령 정보를 보내지 않았습니다."
                return
            }
            do {
                try model.validateBuiltInProposal(proposal, scope: scope)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            let message = response.message ?? "실행 전에 아래 명령을 확인해 주세요."
            messages.append(Bubble(role: "assistant", content: message))
            pendingRoute = response
            if speakResponse { voice.speak(message) }
        case .dynamicProposal:
            guard response.proposal != nil else {
                errorMessage = "서버가 등록된 도구의 실행 정보를 보내지 않았습니다."
                return
            }
            let message = response.message ?? "등록된 도구로 실행할 내용을 확인해 주세요."
            messages.append(Bubble(role: "assistant", content: message))
            pendingRoute = response
            if speakResponse { voice.speak(message) }
        case .toolDraft:
            guard response.draft != nil, response.proposal != nil else {
                errorMessage = "서버가 새 도구 초안 또는 실행 인자를 보내지 않았습니다."
                return
            }
            let message = response.message ?? "이 기기에 맞는 새 도구를 만들었습니다. 내용을 확인해 주세요."
            messages.append(Bubble(role: "assistant", content: message))
            pendingRoute = response
            if speakResponse { voice.speak(message) }
        }
    }

    private func confirmPendingRoute() {
        guard let route = pendingRoute, !isLoading else { return }
        errorMessage = nil
        isLoading = true
        requestTask?.cancel()
        requestTask = Task {
            defer { isLoading = false }
            do {
                let message: String
                switch route.kind {
                case .builtinProposal:
                    guard let proposal = route.proposal else { throw AppModel.CommandError.missingProposal }
                    message = try await model.confirmBuiltIn(proposal, scope: scope)
                case .dynamicProposal:
                    guard let proposal = route.proposal else { throw AppModel.CommandError.missingProposal }
                    message = try await model.confirmDynamic(proposal)
                case .toolDraft:
                    let nextRoute = try await model.approveToolDraft(
                        proposal: route.proposal,
                        draft: route.draft
                    )
                    try Task.checkCancellation()
                    pendingRoute = nextRoute
                    messages.append(
                        Bubble(
                            role: "assistant",
                            content: nextRoute.message ?? "도구를 등록했습니다. 첫 실행을 확인해 주세요."
                        )
                    )
                    return
                case .chat:
                    throw AppModel.CommandError.missingProposal
                }
                try Task.checkCancellation()
                pendingRoute = nil
                messages.append(Bubble(role: "assistant", content: message))
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func cancelPendingRoute() {
        guard let route = pendingRoute, !isLoading else { return }
        errorMessage = nil

        guard let draft = route.draft else {
            pendingRoute = nil
            messages.append(Bubble(role: "assistant", content: "명령 실행을 취소했습니다."))
            return
        }

        isLoading = true
        requestTask?.cancel()
        requestTask = Task {
            defer { isLoading = false }
            do {
                try await model.rejectToolDraft(draft, proposal: route.proposal)
                try Task.checkCancellation()
                pendingRoute = nil
                messages.append(Bubble(role: "assistant", content: "새 도구 생성을 취소했습니다."))
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct RouteConfirmationCard: View {
    let route: CommandRouteResponse
    let isLoading: Bool
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        GlassSurface(tint: cardTint, padding: 18) {
            VStack(alignment: .leading, spacing: 16) {
                Label(title, systemImage: symbol)
                    .font(.headline)
                    .foregroundStyle(AdaptiveDesign.accent)

                if let draft = route.draft {
                    toolDraftDetails(draft)
                } else if let proposal = route.proposal {
                    proposalDetails(proposal)
                }

                HStack(spacing: 10) {
                    Button("취소", action: cancel)
                        .buttonStyle(.bordered)
                        .tint(.white)
                        .frame(maxWidth: .infinity)
                        .disabled(isLoading)
                        .accessibilityIdentifier(route.draft == nil ? "cancelCommandProposal" : "rejectToolDraft")

                    Button(action: confirm) {
                        if isLoading {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text(confirmTitle).frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AdaptiveDesign.accent)
                    .foregroundStyle(AdaptiveDesign.ink)
                    .disabled(isLoading)
                    .accessibilityIdentifier(route.draft == nil ? "confirmCommandProposal" : "approveToolDraft")
                }
                .controlSize(.large)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityIdentifier(route.draft == nil ? "commandProposalCard" : "toolDraftCard")
    }

    private var title: String { route.draft == nil ? "명령 실행 확인" : "새 도구 확인" }
    private var symbol: String { route.draft == nil ? "checkmark.shield.fill" : "wrench.and.screwdriver.fill" }
    private var confirmTitle: String { route.draft == nil ? "실행" : "도구 만들기" }
    private var cardTint: Color {
        route.draft == nil ? AdaptiveDesign.cobalt.opacity(0.14) : AdaptiveDesign.accent.opacity(0.1)
    }

    private func proposalDetails(_ proposal: CommandProposal) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(commandTitle(proposal.displayName))
                .font(.title3.weight(.semibold))
            if let confirmationText = proposal.confirmationText {
                Text(confirmationText)
                    .font(.subheadline)
            }
            if let source = route.routedBy ?? proposal.source {
                detailRow("라우터", routerTitle(source))
            }
            if let deviceId = proposal.deviceId, deviceId != "app-model" {
                detailRow("기기", deviceId)
            }
            if let capabilityId = proposal.capabilityId,
               proposal.toolKind == "dynamic" {
                detailRow("기능", capabilityId)
            }
            if let scope = proposal.scope { detailRow("공간", scope) }
            if let confidence = proposal.confidence {
                detailRow("신뢰도", confidence.formatted(.percent.precision(.fractionLength(0))))
            }
            ForEach(proposal.arguments.keys.sorted(), id: \.self) { key in
                detailRow(argumentTitle(key), proposal.arguments[key]?.displayValue ?? "없음")
            }
            Text("확인하기 전에는 기기 상태가 바뀌지 않습니다.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.58))
        }
    }

    private func toolDraftDetails(_ draft: ToolDraft) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(draft.name)
                .font(.title3.weight(.semibold))
            Text(draft.description)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.78))
            if let confirmationText = draft.confirmationText {
                Text(confirmationText)
                    .font(.subheadline.weight(.semibold))
            }
            if let deviceId = draft.deviceId { detailRow("기기", deviceId) }
            if let capabilityId = draft.capabilityId { detailRow("기능", capabilityId) }
            if !draft.scopes.isEmpty {
                detailRow("허용 공간", draft.scopes.joined(separator: ", "))
            }
            if let proposal = route.proposal {
                if let scope = proposal.scope {
                    detailRow("이번 실행 공간", scope)
                }
                ForEach(proposal.arguments.keys.sorted(), id: \.self) { key in
                    detailRow(argumentTitle(key), proposal.arguments[key]?.displayValue ?? "없음")
                }
            }
            Text("승인하면 도구만 등록합니다. 첫 실행은 다음 카드에서 다시 확인하며, 이후 재사용할 때도 매번 확인합니다.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.58))
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.white.opacity(0.54))
            Spacer(minLength: 16)
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.caption)
    }

    private func argumentTitle(_ key: String) -> String {
        switch key {
        case "scope": "공간"
        case "brightness_delta": "밝기 변화"
        case "temperature_delta_c": "온도 변화"
        case "sound_preset": "사운드"
        default: key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func commandTitle(_ action: String) -> String {
        switch action {
        case "apply_recommendation": "추천 환경 적용"
        case "adjust_environment": "환경 조절"
        case "stop_environment": "환경 제어 중지"
        case "restore_environment": "기본 환경 복원"
        case "checkout_space": "공간 체크아웃"
        case "execute_dynamic_tool": "연결 기기 제어"
        default: action.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func routerTitle(_ source: String) -> String {
        switch source.lowercased() {
        case "needle": "Needle · 온디바이스"
        case "gpt": "GPT · 서버"
        default: source
        }
    }
}

private struct VoiceModeView: View {
    @ObservedObject var voice: VoiceController
    let isLoading: Bool
    let reply: String?
    let send: () -> Void
    let close: () -> Void

    var body: some View {
        ZStack {
            AmbientBackdrop()
            VStack(spacing: 32) {
                HStack {
                    Text("VOICE")
                        .font(.caption.weight(.bold))
                        .tracking(2.4)
                    Label("STT · TTS 기기 내 처리", systemImage: "lock.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("localVoiceMode")
                    Spacer()
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .tint(.white)
                    .accessibilityIdentifier("closeVoiceMode")
                }

                Spacer()

                ZStack {
                    Circle()
                        .fill(AdaptiveDesign.cobalt.opacity(0.22))
                        .frame(width: 240, height: 240)
                        .blur(radius: 20)
                        .scaleEffect(voice.isListening ? 1.12 : 0.94)
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [AdaptiveDesign.accent, AdaptiveDesign.cobalt],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 156, height: 156)
                        .overlay {
                            Image(systemName: voice.isListening ? "waveform" : "wave.3.right")
                                .font(.system(size: 42, weight: .medium))
                                .foregroundStyle(AdaptiveDesign.ink)
                                .symbolEffect(.variableColor.iterative, isActive: voice.isListening)
                        }
                }
                .animation(
                    voice.isListening
                        ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                        : .easeOut(duration: 0.25),
                    value: voice.isListening
                )

                Text(status)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .frame(maxWidth: 320)

                Text("GPT 응답은 서버를 사용할 수 있습니다")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Spacer()

                voiceControls
            }
            .padding(24)
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var voiceControls: some View {
        let controls = HStack(spacing: 16) {
            Button {
                if voice.isListening {
                    voice.stop()
                } else {
                    Task { await voice.requestAndStart() }
                }
            } label: {
                Image(systemName: voice.isListening ? "pause.fill" : "mic.fill")
                    .font(.title3)
                    .frame(width: 64, height: 64)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .tint(.white)
            .accessibilityIdentifier("voiceMic")

            if !voice.transcript.isEmpty {
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.title3.weight(.bold))
                        .frame(width: 64, height: 64)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .tint(AdaptiveDesign.accent)
                .foregroundStyle(AdaptiveDesign.ink)
                .disabled(isLoading)
                .accessibilityIdentifier("sendVoiceMessage")
            }
        }

        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 16) { controls }
        } else {
            controls
        }
    }

    private var status: String {
        if let error = voice.errorMessage { return error }
        if isLoading { return "처리 중" }
        if voice.isListening { return voice.transcript.isEmpty ? "듣는 중" : voice.transcript }
        if !voice.transcript.isEmpty { return voice.transcript }
        return reply ?? "말해보세요"
    }
}

private struct ChatInputGlassModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
        } else {
            content.background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
        }
    }
}
