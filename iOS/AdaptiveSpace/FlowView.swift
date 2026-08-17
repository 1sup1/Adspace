import SwiftUI

struct FlowView: View {
    private enum Hub: String, CaseIterable {
        case live, spaces, agent

        var title: String {
            switch self {
            case .live: "Live"
            case .spaces: "Spaces"
            case .agent: "Agent"
            }
        }

        var symbol: String {
            switch self {
            case .live: "waveform.path.ecg"
            case .spaces: "square.grid.2x2.fill"
            case .agent: "sparkles"
            }
        }
    }

    private enum Space: String, CaseIterable {
        case home, hotel

        var title: String { self == .home ? "Home" : "Hotel" }
        var symbol: String { self == .home ? "house.fill" : "building.2.fill" }
    }

    @Bindable var model: AppModel
    @State private var selectedHub = Hub.live
    @State private var selectedSpace = Space.home

    var body: some View {
        ZStack {
            AmbientBackdrop()
            Group {
                switch selectedHub {
                case .live: liveHub
                case .spaces: spacesHub
                case .agent:
                    AgentChatView(
                        model: model,
                        scope: selectedSpace.rawValue,
                        showsCloseButton: false
                    )
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.985)))
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { hubDock }
        .animation(.smooth(duration: 0.35), value: selectedHub)
        .tint(AdaptiveDesign.accent)
        .preferredColorScheme(.dark)
    }

    private var liveHub: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hubHeader(title: "ADAPTIVE", symbol: "wave.3.right", badge: liveBadge)
                if let error = model.errorMessage { errorBanner(error) }
                liveSignalCard
                consentStrip

                if model.snapshot == nil {
                    actionButton("웨어러블 연결", icon: "applewatch") {
                        await model.connectAndSync()
                    }
                    .accessibilityIdentifier("connectWearable")
                } else {
                    actionButton(model.recommendation == nil ? "환경 판단" : "다시 판단", icon: "sparkles") {
                        await model.requestRecommendation()
                    }
                    .accessibilityIdentifier("requestRecommendation")
                }

                if let recommendation = model.recommendation {
                    HStack {
                        Text("DECISION")
                            .font(.caption.weight(.bold))
                            .tracking(2)
                            .foregroundStyle(.white.opacity(0.48))
                        Spacer()
                        GlassTag(text: "\(recommendation.observedSampleCount) SIGNALS")
                    }
                    DecisionComparisonView(
                        comparison: recommendation.comparison,
                        profile: recommendation.profile
                    )
                    actionButton("공간에 적용", icon: "arrow.right") {
                        model.approveProfile()
                        selectedSpace = .home
                        selectedHub = .spaces
                    }
                    .accessibilityIdentifier("approveProfile")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
    }

    private var liveSignalCard: some View {
        GlassSurface(tint: AdaptiveDesign.cobalt.opacity(0.1)) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("HEART RATE")
                            .font(.caption2.weight(.bold))
                            .tracking(1.8)
                            .foregroundStyle(.white.opacity(0.46))
                        HStack(alignment: .lastTextBaseline, spacing: 6) {
                            Text(model.snapshot?.heartRateBPM.map(String.init) ?? "—")
                                .font(.system(size: 54, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                            Text("BPM")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white.opacity(0.48))
                        }
                    }
                    Spacer()
                    Image(systemName: model.isStreaming ? "dot.radiowaves.left.and.right" : "heart.fill")
                        .font(.title2)
                        .foregroundStyle(AdaptiveDesign.accent)
                        .symbolEffect(.variableColor.iterative, isActive: model.isStreaming)
                }

                signalTrace

                HStack(spacing: 0) {
                    compactMetric("수면 점수", model.snapshot?.sleepScore)
                    compactMetric("걸음", model.snapshot?.activitySteps)
                    compactMetric("HRV", model.snapshot?.hrvMS)
                }
            }
        }
    }

    private var signalTrace: some View {
        GeometryReader { proxy in
            let values = model.recentSnapshots.compactMap(\.heartRateBPM)
            Path { path in
                guard let minimum = values.min(), let maximum = values.max(), !values.isEmpty else { return }
                let span = max(1, maximum - minimum)
                for (index, value) in values.enumerated() {
                    let x = values.count == 1 ? 0 : proxy.size.width * CGFloat(index) / CGFloat(values.count - 1)
                    let ratio = CGFloat(value - minimum) / CGFloat(span)
                    let y = proxy.size.height - ratio * (proxy.size.height - 8) - 4
                    if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(
                LinearGradient(colors: [AdaptiveDesign.accent.opacity(0.25), AdaptiveDesign.accent], startPoint: .leading, endPoint: .trailing),
                style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
            )
            .animation(.smooth, value: model.lastSignalSequence)
        }
        .frame(height: 70)
        .accessibilityHidden(true)
    }

    private var consentStrip: some View {
        GlassSurface(padding: 12) {
            HStack(spacing: 4) {
                ForEach(ConsentedMetric.allCases) { metric in
                    Button { model.toggleConsent(metric) } label: {
                        VStack(spacing: 6) {
                            Image(systemName: model.consent.contains(metric) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(model.consent.contains(metric) ? AdaptiveDesign.accent : .white.opacity(0.25))
                            Text(metric.title)
                                .font(.caption2.weight(.medium))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("consent_\(metric.rawValue)")
                }
            }
        }
    }

    private var spacesHub: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hubHeader(title: "SPACES", symbol: "square.grid.2x2.fill", badge: nil)
                spacePicker
                if let error = model.errorMessage { errorBanner(error) }

                switch selectedSpace {
                case .home: homeSpace
                case .hotel: hotelSpace
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
    }

    private var spacePicker: some View {
        glassGroup(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(Space.allCases, id: \.self) { space in
                    Button {
                        selectedSpace = space
                    } label: {
                        Label(space.title, systemImage: space.symbol)
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .foregroundStyle(selectedSpace == space ? AdaptiveDesign.ink : .white)
                    }
                    .buttonStyle(.plain)
                    .modifier(ScenarioGlassModifier(isSelected: selectedSpace == space))
                }
            }
        }
    }

    private var homeSpace: some View {
        VStack(alignment: .leading, spacing: 20) {
            roomPreview(title: "Home", room: model.homeRoom)

            if model.recommendation == nil {
                actionButton("Live에서 환경 판단", icon: "waveform.path.ecg") {
                    selectedHub = .live
                }
            } else if !model.homeRoom.isApplied {
                actionButton("적용", icon: "play.fill") { model.applyHome() }
                    .accessibilityIdentifier("applyHome")
            } else {
                GlassSurface {
                    VStack(spacing: 20) {
                        if model.scenario == .recovery { brightnessControl }
                        quickRoomActions(isHotel: false)
                    }
                }

                if model.scenario == .recovery && !model.hasSavedAdjustment {
                    actionButton("저장", icon: "checkmark") { await model.saveAdjustment() }
                        .accessibilityIdentifier("saveAdjustment")
                } else {
                    actionButton("호텔로 가져가기", icon: "arrow.up.right") {
                        await model.checkIn()
                        selectedSpace = .hotel
                    }
                    .accessibilityIdentifier("checkInHotel")
                }
            }
        }
    }

    @ViewBuilder
    private var hotelSpace: some View {
        switch model.step {
        case .consensus:
            if let consensus = model.companionConsensus {
                CompanionConsensusView(
                    preferences: model.companionPreferences,
                    consensus: consensus,
                    isLoading: model.isLoading,
                    approve: { await model.approveCompanionConsensus() },
                    choose: { await model.chooseCompanionPreference($0) }
                )
            }
        case .hotel:
            hotelControls
        case .complete:
            completeState
        default:
            VStack(alignment: .leading, spacing: 20) {
                roomPreview(title: "Hotel", room: model.hotelRoom)
                if model.recommendation == nil {
                    actionButton("Live에서 환경 판단", icon: "waveform.path.ecg") { selectedHub = .live }
                } else {
                    actionButton("체크인", icon: "qrcode.viewfinder") {
                        await model.checkIn()
                    }
                    .accessibilityIdentifier("checkInHotel")
                }
            }
        }
    }

    private var hotelControls: some View {
        VStack(alignment: .leading, spacing: 20) {
            GlassSurface(tint: AdaptiveDesign.accent.opacity(0.07)) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Label("0 BIOMETRICS", systemImage: "lock.shield.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AdaptiveDesign.accent)
                        Spacer()
                        GlassTag(text: "PRIVATE")
                    }
                    if let execution = model.session?.execution {
                        HStack(spacing: 12) {
                            valueBlock("밝기", "\(execution.lighting.brightnessPercent)%")
                            valueBlock("온도", "\(execution.temperatureC.formatted())°")
                        }
                    }
                }
            }
            roomPreview(title: "Hotel", room: model.hotelRoom)
            quickRoomActions(isHotel: true)

            if model.hotelRoom.isApplied {
                actionButton("체크아웃", icon: "door.left.hand.open") { await model.checkout() }
                    .accessibilityIdentifier("checkout")
            } else {
                actionButton("적용", icon: "checkmark") { await model.applyHotel() }
                    .accessibilityIdentifier("applyHotel")
            }
        }
    }

    private var completeState: some View {
        VStack(alignment: .leading, spacing: 24) {
            roomPreview(title: "Hotel", room: model.hotelRoom)
            HStack(spacing: 8) {
                GlassTag(text: "공간 복원")
                GlassTag(text: "일회성 권한 만료")
            }
            actionButton("새 세션", icon: "arrow.counterclockwise") {
                model.resetDemo()
                selectedSpace = .home
                selectedHub = .live
            }
            .accessibilityIdentifier("resetDemo")
        }
    }

    private var brightnessControl: some View {
        VStack(spacing: 16) {
            HStack(alignment: .lastTextBaseline) {
                Text("밝기").font(.headline)
                Spacer()
                Text("\(Int(model.editedBrightness))%")
                    .font(.system(size: 38, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            HStack(spacing: 12) {
                adjustmentButton("minus", identifier: "brightnessDecrease") {
                    model.editedBrightness = max(10, model.editedBrightness - 1)
                }
                Capsule()
                    .fill(.white.opacity(0.12))
                    .frame(height: 5)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(AdaptiveDesign.accent)
                            .frame(width: max(12, CGFloat(model.editedBrightness / 100) * 170), height: 5)
                    }
                adjustmentButton("plus", identifier: "brightnessIncrease") {
                    model.editedBrightness = min(100, model.editedBrightness + 1)
                }
            }
        }
    }

    private var hubDock: some View {
        glassGroup(spacing: 12) {
            HStack(spacing: 8) {
                ForEach(Hub.allCases, id: \.self) { hub in
                    Button {
                        selectedHub = hub
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: hub.symbol)
                                .font(.system(size: 17, weight: .semibold))
                            Text(hub.title)
                                .font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(selectedHub == hub ? AdaptiveDesign.ink : .white.opacity(0.62))
                        .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.plain)
                    .modifier(DockGlassModifier(isSelected: selectedHub == hub))
                    .accessibilityIdentifier(hub == .agent ? "openAgentChat" : "hub_\(hub.rawValue)")
                }
            }
            .padding(8)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func hubHeader(title: String, symbol: String, badge: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.headline.weight(.bold))
                .foregroundStyle(AdaptiveDesign.accent)
            Text(title)
                .font(.caption.weight(.bold))
                .tracking(2.4)
            Spacer()
            if let badge { GlassTag(text: badge) }
        }
        .frame(height: 44)
    }

    private var liveBadge: String {
        model.isStreaming ? "LIVE · \(model.lastSignalSequence)" : "OFFLINE"
    }

    private func compactMetric(_ label: String, _ value: Int?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value.map(String.init) ?? "—")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.46))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func roomPreview(title: String, room: RoomState) -> some View {
        RoundedRectangle(cornerRadius: AdaptiveDesign.radius)
            .fill(
                LinearGradient(
                    colors: room.isApplied
                        ? [roomColor(brightness: room.brightness), AdaptiveDesign.cobalt.opacity(0.5)]
                        : [.white.opacity(0.1), .white.opacity(0.035)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(height: 230)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(title.uppercased())
                            .font(.caption.weight(.bold))
                            .tracking(2)
                            .foregroundStyle(.white.opacity(0.55))
                        Spacer()
                        Circle()
                            .fill(room.isApplied ? AdaptiveDesign.accent : .white.opacity(0.2))
                            .frame(width: 8, height: 8)
                    }
                    Spacer()
                    Image(systemName: title == "Hotel" ? "building.2.fill" : "house.fill")
                        .font(.system(size: 30))
                    Text("\(room.brightness)%  ·  \(room.temperature.formatted())°")
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                    Text(room.sound)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.56))
                }
                .padding(24)
            }
            .overlay {
                RoundedRectangle(cornerRadius: AdaptiveDesign.radius)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            }
    }

    private func quickRoomActions(isHotel: Bool) -> some View {
        glassGroup(spacing: 8) {
            HStack(spacing: 8) {
                GlassSecondaryButton(title: "중지", icon: "stop.fill") {
                    if isHotel { Task { await model.stopHotel() } } else { model.stopHome() }
                }
                GlassSecondaryButton(title: "복원", icon: "arrow.uturn.backward") {
                    if isHotel { Task { await model.restoreHotel() } } else { model.restoreHome() }
                }
            }
        }
    }

    private func valueBlock(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.48))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func adjustmentButton(_ symbol: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.headline)
                .frame(width: 48, height: 48)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .tint(.white)
        .accessibilityIdentifier(identifier)
    }

    private func errorBanner(_ message: String) -> some View {
        GlassSurface(tint: Color.red.opacity(0.14), padding: 16) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(.red)
        }
    }

    private func actionButton(_ title: String, icon: String, action: @escaping () async -> Void) -> some View {
        GlassPrimaryButton(title: title, icon: icon, isLoading: model.isLoading) {
            Task { await action() }
        }
    }

    @ViewBuilder
    private func glassGroup<Content: View>(spacing: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }

    private func roomColor(brightness: Int) -> Color {
        AdaptiveDesign.warm.opacity(0.28 + Double(brightness) / 190)
    }
}

private struct ScenarioGlassModifier: ViewModifier {
    let isSelected: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(
                .regular.tint(isSelected ? AdaptiveDesign.accent : .white.opacity(0.04)).interactive(),
                in: .rect(cornerRadius: 22)
            )
        } else {
            content.background(isSelected ? AdaptiveDesign.accent : .white.opacity(0.08), in: RoundedRectangle(cornerRadius: 22))
        }
    }
}

private struct DockGlassModifier: ViewModifier {
    let isSelected: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(
                .regular.tint(isSelected ? AdaptiveDesign.accent : .clear).interactive(),
                in: .rect(cornerRadius: 20)
            )
        } else {
            content.background(isSelected ? AdaptiveDesign.accent : .clear, in: RoundedRectangle(cornerRadius: 20))
        }
    }
}

#Preview {
    FlowView(model: AppModel())
}
