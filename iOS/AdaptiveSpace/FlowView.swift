import SwiftUI

struct FlowView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationStack {
            ZStack {
                AmbientBackdrop()
                ScrollView {
                    VStack(spacing: 24) {
                        header
                        if let error = model.errorMessage { errorBanner(error) }
                        Group {
                            switch model.step {
                            case .wearable: wearableStep
                            case .profile: profileStep
                            case .home: homeStep
                            case .hotel: hotelStep
                            case .complete: completeStep
                            }
                        }
                        .id(model.step)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 40)
                }
                .scrollIndicators(.hidden)
            }
            .animation(.smooth(duration: 0.45), value: model.step)
            .tint(AdaptiveDesign.accent)
            .toolbar(.hidden, for: .navigationBar)
            .preferredColorScheme(.dark)
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: "wave.3.right")
                .font(.headline.weight(.bold))
                .foregroundStyle(AdaptiveDesign.accent)
            Text("ADAPTIVE")
                .font(.caption.weight(.bold))
                .tracking(2.4)
            Spacer()
            HStack(spacing: 5) {
                ForEach(AppModel.Step.allCases, id: \.rawValue) { step in
                    Capsule()
                        .fill(step.rawValue <= model.step.rawValue ? AdaptiveDesign.accent : .white.opacity(0.14))
                        .frame(width: step == model.step ? 24 : 7, height: 7)
                }
            }
            .animation(.snappy, value: model.step)
        }
        .frame(height: 44)
    }

    private var wearableStep: some View {
        VStack(alignment: .leading, spacing: 24) {
            hero("오늘 필요한 공간은?", detail: "상태를 고르면 공간을 준비해요.")

            scenarioPicker

            GlassSurface {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Label("데모 데이터", systemImage: "lock.fill")
                            .font(.headline)
                        Spacer()
                        Text("\(model.consent.count)/4")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.5))
                    }

                    LazyVGrid(columns: twoColumns, spacing: 12) {
                        ForEach(ConsentedMetric.allCases) { metric in
                            consentButton(metric)
                        }
                    }

                    if let snapshot = model.snapshot {
                        Divider().overlay(.white.opacity(0.12))
                        metricGrid(snapshot)
                    }
                }
            }

            if model.snapshot == nil {
                actionButton("웨어러블 연결", icon: "applewatch") {
                    await model.connectAndSync()
                }
                .accessibilityIdentifier("connectWearable")
            } else {
                actionButton("내 공간 만들기", icon: "sparkles") {
                    await model.requestRecommendation()
                }
                .accessibilityIdentifier("requestRecommendation")
            }
        }
    }

    private var scenarioPicker: some View {
        glassGroup(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(DemoScenario.allCases) { scenario in
                    Button {
                        model.scenario = scenario
                    } label: {
                        VStack(spacing: 10) {
                            Image(systemName: scenario.symbol)
                                .font(.title3)
                            Text(shortScenario(scenario))
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(model.scenario == scenario ? AdaptiveDesign.ink : .white)
                        .frame(maxWidth: .infinity, minHeight: 72)
                    }
                    .buttonStyle(.plain)
                    .modifier(ScenarioGlassModifier(isSelected: model.scenario == scenario))
                }
            }
        }
    }

    private var profileStep: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let recommendation = model.recommendation {
                VStack(alignment: .leading, spacing: 20) {
                    Image(systemName: recommendation.context.symbol)
                        .font(.system(size: 46, weight: .medium))
                        .foregroundStyle(AdaptiveDesign.accent)
                        .symbolEffect(.pulse)
                    hero("\(shortScenario(recommendation.context))을 위한 공간", detail: recommendation.reason)
                }

                GlassSurface(tint: AdaptiveDesign.cobalt.opacity(0.1)) {
                    profileValues(recommendation.profile)
                }

                actionButton("이 설정 사용하기", icon: "checkmark") {
                    model.approveProfile()
                }
                .accessibilityIdentifier("approveProfile")
            }
        }
    }

    private var homeStep: some View {
        VStack(alignment: .leading, spacing: 24) {
            hero("집이 준비됐어요", detail: model.homeRoom.isApplied ? "지금 이 설정으로 편안하게 쉬세요." : "확인 후 내 공간에 적용하세요.")
            roomPreview(title: "Home", room: model.homeRoom)

            if !model.homeRoom.isApplied {
                actionButton("집에 적용", icon: "play.fill") {
                    model.applyHome()
                }
                .accessibilityIdentifier("applyHome")
            } else {
                GlassSurface {
                    VStack(spacing: 20) {
                        if model.scenario == .recovery {
                            brightnessControl
                        }
                        quickRoomActions(isHotel: false)
                    }
                }

                if model.scenario != .recovery || model.hasSavedAdjustment {
                    actionButton("호텔에서 이어가기", icon: "qrcode.viewfinder") {
                        await model.checkIn()
                    }
                    .accessibilityIdentifier("checkInHotel")
                } else {
                    actionButton("이 밝기 기억하기", icon: "heart.fill") {
                        await model.saveAdjustment()
                    }
                    .accessibilityIdentifier("saveAdjustment")
                }
            }
        }
    }

    private var brightnessControl: some View {
        VStack(spacing: 16) {
            HStack(alignment: .lastTextBaseline) {
                Text("밝기")
                    .font(.headline)
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

    private var hotelStep: some View {
        VStack(alignment: .leading, spacing: 24) {
            hero(model.hotelRoom.isApplied ? "호텔도 준비됐어요" : "호텔에서도 그대로", detail: "내 설정만 안전하게 옮겨요.")

            GlassSurface(tint: AdaptiveDesign.accent.opacity(0.07)) {
                VStack(alignment: .leading, spacing: 20) {
                    Label("건강 데이터 공유 안 함", systemImage: "lock.shield.fill")
                        .font(.headline)
                        .foregroundStyle(AdaptiveDesign.accent)
                    Text("공유된 생체정보: \(model.session?.sharedBiometricCount ?? 0)건")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.48))

                    if let execution = model.session?.execution {
                        HStack(spacing: 12) {
                            valueBlock("밝기", "\(execution.lighting.brightnessPercent)%")
                            valueBlock("온도", "\(execution.temperatureC.formatted())°")
                        }
                    }

                    Text("조명 색감과 사운드는 호텔 기본값을 유지해요.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.58))
                }
            }

            roomPreview(title: "Hotel", room: model.hotelRoom)
            quickRoomActions(isHotel: true)

            if model.hotelRoom.isApplied {
                actionButton("체크아웃", icon: "door.left.hand.open") {
                    await model.checkout()
                }
                .accessibilityIdentifier("checkout")
            } else {
                actionButton("호텔에 적용", icon: "checkmark") {
                    await model.applyHotel()
                }
                .accessibilityIdentifier("applyHotel")
            }
        }
    }

    private var completeStep: some View {
        VStack(alignment: .leading, spacing: 32) {
            Spacer(minLength: 36)
            ZStack {
                Circle()
                    .fill(AdaptiveDesign.accent.opacity(0.16))
                    .frame(width: 112, height: 112)
                    .blur(radius: 12)
                Image(systemName: "checkmark")
                    .font(.system(size: 48, weight: .medium))
                    .foregroundStyle(AdaptiveDesign.accent)
                    .symbolEffect(.bounce, value: model.step)
            }
            hero("모든 것이 원래대로", detail: "공간은 복원되고, 일회성 연결은 끝났어요.")

            glassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    GlassTag(text: "공간 복원")
                    GlassTag(text: "일회성 권한 만료")
                }
            }

            actionButton("다시 시작", icon: "arrow.counterclockwise") {
                model.resetDemo()
            }
            .accessibilityIdentifier("resetDemo")
        }
    }

    private func hero(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .tracking(-1)
            Text(detail)
                .font(.body)
                .foregroundStyle(.white.opacity(0.54))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func consentButton(_ metric: ConsentedMetric) -> some View {
        Button { model.toggleConsent(metric) } label: {
            HStack(spacing: 10) {
                Image(systemName: model.consent.contains(metric) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(model.consent.contains(metric) ? AdaptiveDesign.accent : .white.opacity(0.25))
                Text(metric.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("consent_\(metric.rawValue)")
    }

    private func metricGrid(_ snapshot: WearableSnapshot) -> some View {
        LazyVGrid(columns: twoColumns, spacing: 12) {
            GlassMetricTile(label: "수면", value: snapshot.sleepScore.map(String.init) ?? "—")
            GlassMetricTile(label: "걸음", value: snapshot.activitySteps.map(String.init) ?? "—")
            GlassMetricTile(label: "심박", value: snapshot.heartRateBPM.map(String.init) ?? "—")
            GlassMetricTile(label: "HRV", value: snapshot.hrvMS.map(String.init) ?? "—")
        }
    }

    private func profileValues(_ profile: EnvironmentProfile) -> some View {
        LazyVGrid(columns: twoColumns, spacing: 12) {
            GlassMetricTile(label: "밝기", value: "\(profile.lighting.brightnessPercent)%")
            GlassMetricTile(label: "온도", value: "\(profile.temperatureC.formatted())°")
            GlassMetricTile(label: "색온도", value: "\(profile.lighting.colorTemperatureK)K")
            GlassMetricTile(label: "사운드", value: profile.soundPreset.capitalized)
        }
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
            .frame(height: 218)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title.uppercased())
                        .font(.caption.weight(.bold))
                        .tracking(2)
                        .foregroundStyle(.white.opacity(0.55))
                    Spacer()
                    Image(systemName: "bed.double.fill")
                        .font(.system(size: 32))
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

    private var twoColumns: [GridItem] {
        [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    }

    private func shortScenario(_ scenario: DemoScenario) -> String {
        switch scenario {
        case .recovery: "회복"
        case .focus: "집중"
        case .calm: "휴식"
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

#Preview {
    FlowView(model: AppModel())
}
