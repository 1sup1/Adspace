import SwiftUI

struct FlowView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
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
                }
                .padding()
            }
            .background(
                LinearGradient(
                    colors: [Color.indigo.opacity(0.16), Color.mint.opacity(0.10), Color(.systemBackground)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ).ignoresSafeArea()
            )
            .navigationBarHidden(true)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("ADAPTIVE SPACE")
                .font(.caption.weight(.bold))
                .tracking(2)
                .foregroundStyle(.indigo)
            Text("나의 환경이 공간을 따라옵니다")
                .font(.largeTitle.bold())
            Text("더미 웨어러블 · 안전한 실행 프로필 · 일회성 호텔 세션")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var progress: some View {
        HStack(spacing: 7) {
            ForEach(AppModel.Step.allCases, id: \.rawValue) { step in
                VStack(spacing: 5) {
                    Capsule()
                        .fill(step.rawValue <= model.step.rawValue ? Color.indigo : Color.secondary.opacity(0.18))
                        .frame(height: 5)
                    Text(step.title)
                        .font(.caption2)
                        .foregroundStyle(step == model.step ? .primary : .secondary)
                }
            }
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(model.statusMessage, systemImage: model.errorMessage == nil ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(model.errorMessage == nil ? .green : .red)
            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .font(.subheadline.weight(.medium))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var wearableStep: some View {
        VStack(spacing: 16) {
            card("1. 더미 웨어러블", symbol: "applewatch") {
                Picker("시나리오", selection: $model.scenario) {
                    ForEach(DemoScenario.allCases) { scenario in
                        Label(scenario.title, systemImage: scenario.symbol).tag(scenario)
                    }
                }
                .pickerStyle(.segmented)

                Text("추천에 사용할 항목")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(ConsentedMetric.allCases) { metric in
                    Button { model.toggleConsent(metric) } label: {
                        HStack {
                            Image(systemName: model.consent.contains(metric) ? "checkmark.circle.fill" : "circle")
                            Text(metric.title)
                            Spacer()
                            Text("Demo data").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("consent_\(metric.rawValue)")
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
        card("2. 컨디션 브리핑", symbol: "sparkles") {
            if let recommendation = model.recommendation {
                Label(recommendation.context.title, systemImage: recommendation.context.symbol)
                    .font(.title2.bold())
                Text(recommendation.reason)
                    .font(.body)
                HStack {
                    tag("신뢰도 \(Int(recommendation.confidence * 100))%")
                    tag(recommendation.generatedBy == "agents_sdk" ? "GPT-5.6 Luna" : "규칙 fallback")
                    tag("Demo data")
                }
                profileValues(recommendation.profile)
                Text("의료·감정 진단이 아닌 웰니스 환경 제안입니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                actionButton("값을 확인하고 계속", icon: "checkmark.circle.fill") {
                    model.approveProfile()
                }
                .accessibilityIdentifier("approveProfile")
            }
        }
    }

    private var homeStep: some View {
        VStack(spacing: 16) {
            roomPreview(title: "집 시뮬레이터", room: model.homeRoom)
            card("3. 적용 · 보정 · 복원", symbol: "house.fill") {
                if let recommendation = model.recommendation {
                    profileValues(recommendation.profile)
                    HStack {
                        Button("적용") { model.applyHome() }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("applyHome")
                        Button("즉시 중지") { model.stopHome() }.buttonStyle(.bordered)
                        Button("기본값 복원") { model.restoreHome() }.buttonStyle(.bordered)
                    }

                    Text("밝기 보정: \(Int(model.editedBrightness))%")
                        .font(.headline)
                    Slider(value: $model.editedBrightness, in: 10...100, step: 1)
                        .accessibilityIdentifier("brightnessSlider")
                    actionButton("보정 저장 후 다시 추천", icon: "arrow.clockwise") {
                        await model.saveAdjustment()
                    }
                    .accessibilityIdentifier("saveAdjustment")
                }
            }
            actionButton("호텔 데모 QR 체크인", icon: "qrcode.viewfinder") {
                await model.checkIn()
            }
            .accessibilityIdentifier("checkInHotel")
        }
    }

    private var hotelStep: some View {
        VStack(spacing: 16) {
            roomPreview(title: "호텔 데모 룸", room: model.hotelRoom)
            card("4. 공간 호환성", symbol: "building.2.fill") {
                HStack {
                    Label("공유된 생체정보: \(model.session?.sharedBiometricCount ?? 0)건", systemImage: "lock.shield.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                    Spacer()
                }
                if let home = model.recommendation?.profile, let execution = model.session?.execution {
                    comparison("밝기", home: "\(home.lighting.brightnessPercent)%", hotel: "\(execution.lighting.brightnessPercent)%")
                    comparison("색온도", home: "\(home.lighting.colorTemperatureK)K", hotel: "미지원")
                    comparison("온도", home: "\(home.temperatureC.formatted())°C", hotel: "\(execution.temperatureC.formatted())°C")
                    comparison("사운드", home: home.soundPreset, hotel: "미지원")
                }
                if let excluded = model.session?.excluded {
                    Text("제외: \(excluded.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("호텔 전달값: session_id · space_id · execution · expires_at")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("승인·적용") { Task { await model.applyHotel() } }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("applyHotel")
                    Button("즉시 중지") { Task { await model.stopHotel() } }.buttonStyle(.bordered)
                    Button("복원") { Task { await model.restoreHotel() } }.buttonStyle(.bordered)
                }
                actionButton("체크아웃 및 세션 만료", icon: "door.left.hand.open") {
                    await model.checkout()
                }
                .accessibilityIdentifier("checkout")
            }
        }
    }

    private var completeStep: some View {
        card("5. 안전하게 종료됨", symbol: "checkmark.seal.fill") {
            Label("호텔 기본값 복원", systemImage: "arrow.uturn.backward.circle.fill")
            Label("일회성 권한 만료", systemImage: "timer")
            Label("외부 공간 프로필 사본 삭제", systemImage: "trash.slash.fill")
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

    private func card<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: symbol).font(.title3.bold())
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22))
    }

    private func actionButton(_ title: String, icon: String, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            HStack {
                if model.isLoading { ProgressView().tint(.white) }
                Label(title, systemImage: icon)
                Spacer()
            }
            .font(.headline)
            .padding()
            .foregroundStyle(.white)
            .background(Color.indigo, in: RoundedRectangle(cornerRadius: 15))
        }
        .buttonStyle(.plain)
        .disabled(model.isLoading)
    }

    private func roomPreview(title: String, room: RoomState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                tag(room.isApplied ? "적용 중" : "기본/중지")
            }
            RoundedRectangle(cornerRadius: 20)
                .fill(roomColor(brightness: room.brightness))
                .frame(height: 150)
                .overlay {
                    VStack(spacing: 8) {
                        Image(systemName: "bed.double.fill").font(.system(size: 44))
                        Text("\(room.brightness)% · \(room.temperature.formatted())°C · \(room.sound)")
                            .font(.headline)
                    }
                    .foregroundStyle(room.brightness < 45 ? .white : .primary)
                }
        }
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22))
    }

    private func metricGrid(_ snapshot: WearableSnapshot) -> some View {
        HStack {
            metric("수면", snapshot.sleepScore.map(String.init) ?? "제외")
            metric("걸음", snapshot.activitySteps.map(String.init) ?? "제외")
            metric("심박", snapshot.heartRateBPM.map(String.init) ?? "제외")
            metric("HRV", snapshot.hrvMS.map(String.init) ?? "제외")
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.headline)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func profileValues(_ profile: EnvironmentProfile) -> some View {
        HStack {
            metric("밝기", "\(profile.lighting.brightnessPercent)%")
            metric("색온도", "\(profile.lighting.colorTemperatureK)K")
            metric("온도", "\(profile.temperatureC.formatted())°")
            metric("사운드", profile.soundPreset)
        }
    }

    private func comparison(_ label: String, home: String, hotel: String) -> some View {
        HStack {
            Text(label).font(.subheadline.weight(.medium))
            Spacer()
            Text(home).foregroundStyle(.secondary)
            Image(systemName: "arrow.right")
            Text(hotel).fontWeight(.semibold)
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.indigo.opacity(0.12), in: Capsule())
    }

    private func roomColor(brightness: Int) -> Color {
        Color(red: 1.0, green: 0.72, blue: 0.36)
            .opacity(0.25 + Double(brightness) / 140)
    }
}

#Preview {
    FlowView(model: AppModel())
}
