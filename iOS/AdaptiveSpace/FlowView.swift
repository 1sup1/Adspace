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
                        progress
                        status
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
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 48)
                }
                .scrollIndicators(.hidden)
            }
            .animation(.snappy(duration: 0.45), value: model.step)
            .tint(AdaptiveDesign.accent)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("ADAPTIVE SPACE", systemImage: "wave.3.right.circle.fill")
                    .font(.caption.weight(.bold))
                    .tracking(1.6)
                    .foregroundStyle(AdaptiveDesign.accent)
                Spacer()
                GlassTag(text: "DEMO", tint: AdaptiveDesign.aqua.opacity(0.2))
            }
            Text("나의 환경이\n공간을 따라옵니다")
                .font(.largeTitle.weight(.bold))
                .tracking(-1.2)
            Text("웨어러블 컨텍스트를 안전한 실행 프로필로 바꾸고, 공간에는 필요한 값만 공유합니다.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var progress: some View {
        glassGroup(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(AppModel.Step.allCases, id: \.rawValue) { step in
                    VStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(step.rawValue <= model.step.rawValue ? AdaptiveDesign.accent : .secondary.opacity(0.16))
                                .frame(width: 28, height: 28)
                            if step.rawValue < model.step.rawValue {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                            } else {
                                Text("\(step.rawValue + 1)")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(step.rawValue <= model.step.rawValue ? .white : .secondary)
                            }
                        }
                        Text(step.title)
                            .font(.caption)
                            .foregroundStyle(step == model.step ? .primary : .secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var status: some View {
        GlassSurface(tint: statusTint) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: model.errorMessage == nil ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(model.errorMessage == nil ? AdaptiveDesign.aqua : .red)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.statusMessage)
                        .font(.headline)
                    if let error = model.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Text("사용자 승인 전에는 어떤 공간도 변경하지 않습니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var wearableStep: some View {
        GlassSurface {
            VStack(alignment: .leading, spacing: 24) {
                sectionTitle("더미 웨어러블", symbol: "applewatch", eyebrow: "STEP 1 · CONNECT")

                Picker("시나리오", selection: $model.scenario) {
                    ForEach(DemoScenario.allCases) { scenario in
                        Text(scenario.title).tag(scenario)
                    }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 8) {
                    Text("추천에 사용할 항목")
                        .font(.headline)
                    Text("필요한 항목만 선택할 수 있고, 모두 데모 데이터입니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 4) {
                    ForEach(ConsentedMetric.allCases) { metric in
                        Button { model.toggleConsent(metric) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: model.consent.contains(metric) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(model.consent.contains(metric) ? AdaptiveDesign.accent : .secondary)
                                Text(metric.title)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text("Demo")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("consent_\(metric.rawValue)")
                    }
                }

                actionButton(model.isWearableConnected ? "다시 동기화" : "연결하고 동기화", icon: "arrow.triangle.2.circlepath") {
                    await model.connectAndSync()
                }
                .accessibilityIdentifier("connectWearable")

                if let snapshot = model.snapshot {
                    metricGrid(snapshot)
                    actionButton("에이전트 추천 받기", icon: "sparkles") {
                        await model.requestRecommendation()
                    }
                    .accessibilityIdentifier("requestRecommendation")
                }
            }
        }
    }

    private var profileStep: some View {
        GlassSurface(tint: AdaptiveDesign.accent.opacity(0.08)) {
            VStack(alignment: .leading, spacing: 24) {
                sectionTitle("컨디션 브리핑", symbol: "sparkles", eyebrow: "STEP 2 · INSIGHT")
                if let recommendation = model.recommendation {
                    HStack(spacing: 12) {
                        Image(systemName: recommendation.context.symbol)
                            .font(.largeTitle)
                            .foregroundStyle(AdaptiveDesign.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(recommendation.context.title)
                                .font(.title3.weight(.bold))
                            Text("지금 공간을 위한 웰니스 제안")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(recommendation.reason)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)

                    glassGroup(spacing: 8) {
                        HStack(spacing: 8) {
                            GlassTag(text: "신뢰도 \(Int(recommendation.confidence * 100))%")
                            GlassTag(text: recommendation.generatedBy == "agents_sdk" ? "GPT-5.6 Luna" : "규칙 fallback")
                            GlassTag(text: "Demo")
                        }
                    }

                    profileValues(recommendation.profile)
                    Label("의료·감정 진단이 아닌 웰니스 환경 제안입니다.", systemImage: "heart.text.clipboard")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    actionButton("값을 확인하고 계속", icon: "checkmark.circle.fill") {
                        model.approveProfile()
                    }
                    .accessibilityIdentifier("approveProfile")
                }
            }
        }
    }

    private var homeStep: some View {
        VStack(spacing: 24) {
            roomPreview(title: "집 시뮬레이터", subtitle: "내 공간", room: model.homeRoom)
            GlassSurface {
                VStack(alignment: .leading, spacing: 24) {
                    sectionTitle("적용 · 보정 · 복원", symbol: "house.fill", eyebrow: "STEP 3 · HOME")
                    if let recommendation = model.recommendation {
                        profileValues(recommendation.profile)
                        secondaryActions {
                            GlassSecondaryButton(title: "적용", icon: "play.fill") { model.applyHome() }
                                .accessibilityIdentifier("applyHome")
                            GlassSecondaryButton(title: "중지", icon: "stop.fill") { model.stopHome() }
                            GlassSecondaryButton(title: "복원", icon: "arrow.uturn.backward") { model.restoreHome() }
                        }

                        brightnessControl

                        actionButton("보정 저장 후 다시 추천", icon: "arrow.clockwise") {
                            await model.saveAdjustment()
                        }
                        .accessibilityIdentifier("saveAdjustment")
                    }
                }
            }

            actionButton("호텔 데모 QR 체크인", icon: "qrcode.viewfinder") {
                await model.checkIn()
            }
            .accessibilityIdentifier("checkInHotel")
        }
    }

    private var brightnessControl: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("밝기 보정")
                        .font(.headline)
                    Text("정확한 1% 단위로 조절합니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Int(model.editedBrightness))%")
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            secondaryActions {
                GlassSecondaryButton(title: "1% 낮춤", icon: "minus") {
                    model.editedBrightness = max(10, model.editedBrightness - 1)
                }
                .accessibilityIdentifier("brightnessDecrease")
                GlassSecondaryButton(title: "1% 높임", icon: "plus") {
                    model.editedBrightness = min(100, model.editedBrightness + 1)
                }
                .accessibilityIdentifier("brightnessIncrease")
            }
        }
    }

    private var hotelStep: some View {
        VStack(spacing: 24) {
            roomPreview(title: "호텔 데모 룸", subtitle: "일회성 공간", room: model.hotelRoom)
            GlassSurface(tint: AdaptiveDesign.aqua.opacity(0.08)) {
                VStack(alignment: .leading, spacing: 24) {
                    sectionTitle("공간 호환성", symbol: "building.2.fill", eyebrow: "STEP 4 · HOTEL")

                    Label("공유된 생체정보: \(model.session?.sharedBiometricCount ?? 0)건", systemImage: "lock.shield.fill")
                        .font(.headline)
                        .foregroundStyle(AdaptiveDesign.aqua)

                    if let home = model.recommendation?.profile, let execution = model.session?.execution {
                        VStack(spacing: 16) {
                            comparison("밝기", home: "\(home.lighting.brightnessPercent)%", hotel: "\(execution.lighting.brightnessPercent)%")
                            comparison("색온도", home: "\(home.lighting.colorTemperatureK)K", hotel: "미지원")
                            comparison("온도", home: "\(home.temperatureC.formatted())°C", hotel: "\(execution.temperatureC.formatted())°C")
                            comparison("사운드", home: home.soundPreset, hotel: "미지원")
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        if let excluded = model.session?.excluded {
                            Text("제외 · \(excluded.joined(separator: ", "))")
                        }
                        Text("전달 · session_id · space_id · execution · expires_at")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    secondaryActions {
                        GlassSecondaryButton(title: "승인·적용", icon: "checkmark") { Task { await model.applyHotel() } }
                            .accessibilityIdentifier("applyHotel")
                        GlassSecondaryButton(title: "중지", icon: "stop.fill") { Task { await model.stopHotel() } }
                        GlassSecondaryButton(title: "복원", icon: "arrow.uturn.backward") { Task { await model.restoreHotel() } }
                    }

                    actionButton("체크아웃 및 세션 만료", icon: "door.left.hand.open") {
                        await model.checkout()
                    }
                    .accessibilityIdentifier("checkout")
                }
            }
        }
    }

    private var completeStep: some View {
        GlassSurface(tint: AdaptiveDesign.aqua.opacity(0.12)) {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 16) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(AdaptiveDesign.aqua)
                        .symbolEffect(.bounce, value: model.step)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("안전하게 종료됨")
                            .font(.title3.weight(.bold))
                        Text("공간도 데이터도 원래 상태로")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 16) {
                    completionRow("호텔 기본값 복원", symbol: "arrow.uturn.backward.circle.fill")
                    completionRow("일회성 권한 만료", symbol: "timer")
                    completionRow("외부 공간 프로필 사본 삭제", symbol: "trash.slash.fill")
                }

                if let session = model.session {
                    Text("세션 \(session.sessionId) · \(session.status)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                actionButton("데모 다시 시작", icon: "arrow.counterclockwise") {
                    model.resetDemo()
                }
                .accessibilityIdentifier("resetDemo")
            }
        }
    }

    private func sectionTitle(_ title: String, symbol: String, eyebrow: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(eyebrow)
                .font(.caption.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(AdaptiveDesign.accent)
            Label(title, systemImage: symbol)
                .font(.title3.weight(.bold))
        }
    }

    private func actionButton(_ title: String, icon: String, action: @escaping () async -> Void) -> some View {
        GlassPrimaryButton(title: title, icon: icon, isLoading: model.isLoading) {
            Task { await action() }
        }
    }

    private func roomPreview(title: String, subtitle: String, room: RoomState) -> some View {
        GlassSurface {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.headline)
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    GlassTag(text: room.isApplied ? "적용 중" : "기본/중지")
                }
                RoundedRectangle(cornerRadius: 24)
                    .fill(
                        LinearGradient(
                            colors: [roomColor(brightness: room.brightness), AdaptiveDesign.accent.opacity(0.22)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(height: 176)
                    .overlay {
                        VStack(spacing: 12) {
                            Image(systemName: "bed.double.fill")
                                .font(.system(size: 44))
                            Text("\(room.brightness)% · \(room.temperature.formatted())°C · \(room.sound)")
                                .font(.headline)
                                .monospacedDigit()
                        }
                        .foregroundStyle(.white)
                        .shadow(color: AdaptiveDesign.accent.opacity(0.26), radius: 18, y: 8)
                    }
            }
        }
    }

    private func metricGrid(_ snapshot: WearableSnapshot) -> some View {
        glassGroup(spacing: 8) {
            HStack(spacing: 8) {
                GlassMetricTile(label: "수면", value: snapshot.sleepScore.map(String.init) ?? "제외")
                GlassMetricTile(label: "걸음", value: snapshot.activitySteps.map(String.init) ?? "제외")
                GlassMetricTile(label: "심박", value: snapshot.heartRateBPM.map(String.init) ?? "제외")
                GlassMetricTile(label: "HRV", value: snapshot.hrvMS.map(String.init) ?? "제외")
            }
        }
    }

    private func profileValues(_ profile: EnvironmentProfile) -> some View {
        glassGroup(spacing: 8) {
            HStack(spacing: 8) {
                GlassMetricTile(label: "밝기", value: "\(profile.lighting.brightnessPercent)%")
                GlassMetricTile(label: "색온도", value: "\(profile.lighting.colorTemperatureK)K")
                GlassMetricTile(label: "온도", value: "\(profile.temperatureC.formatted())°")
                GlassMetricTile(label: "사운드", value: profile.soundPreset)
            }
        }
    }

    private func comparison(_ label: String, home: String, hotel: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.headline)
            Spacer()
            Text(home)
                .foregroundStyle(.secondary)
            Image(systemName: "arrow.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(AdaptiveDesign.accent)
            Text(hotel)
                .font(.headline)
        }
    }

    private func completionRow(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.headline)
            .symbolRenderingMode(.hierarchical)
    }

    @ViewBuilder
    private func secondaryActions<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        glassGroup(spacing: 8) {
            HStack(spacing: 8) {
                content()
            }
        }
    }

    @ViewBuilder
    private func glassGroup<Content: View>(spacing: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
    }

    private var statusTint: Color? {
        model.errorMessage == nil ? AdaptiveDesign.aqua.opacity(0.07) : Color.red.opacity(0.08)
    }

    private func roomColor(brightness: Int) -> Color {
        AdaptiveDesign.warm.opacity(0.42 + Double(brightness) / 180)
    }
}

#Preview {
    FlowView(model: AppModel())
}
