import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    enum Step: Int, CaseIterable {
        case wearable, profile, home, hotel, complete

        var title: String {
            switch self {
            case .wearable: "웨어러블"
            case .profile: "추천"
            case .home: "집 적용"
            case .hotel: "호텔"
            case .complete: "완료"
            }
        }
    }

    var step = Step.wearable
    var scenario = DemoScenario.recovery
    var consent = Set(ConsentedMetric.allCases)
    var isWearableConnected = false
    var snapshot: WearableSnapshot?
    var recommendation: RecommendationResponse?
    var editedBrightness = 35.0
    var homeRoom = RoomState.homeDefault
    var hotelRoom = RoomState.hotelDefault
    var hasSavedAdjustment = false
    var space: SpaceSpec?
    var session: SpaceSession?
    var statusMessage = "더미 데이터만 사용합니다."
    var isLoading = false
    var errorMessage: String?

    private let wearable: any WearableProvider
    private let client: APIClient
    private var homeBeforeApply = RoomState.homeDefault
    private var brightnessDelta: Int

    init(wearable: any WearableProvider = DemoWearableProvider(), client: APIClient = APIClient()) {
        self.wearable = wearable
        self.client = client
        self.brightnessDelta = UserDefaults.standard.integer(forKey: "recoveryBrightnessDelta")
    }

    func toggleConsent(_ metric: ConsentedMetric) {
        if consent.contains(metric) { consent.remove(metric) } else { consent.insert(metric) }
    }

    func connectAndSync() async {
        await perform {
            try await wearable.connect()
            isWearableConnected = true
            let raw = try await wearable.snapshot(for: scenario)
            snapshot = raw.filtered(by: consent)
            statusMessage = "Demo data 동기화 완료 · 동의 \(consent.count)개"
        }
    }

    func requestRecommendation() async {
        guard let snapshot else { return }
        await perform {
            let response = try await client.recommendation(
                RecommendationRequest(
                    snapshot: snapshot,
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
            async let spaceRequest = client.space()
            async let sessionRequest = client.createSession(profile: recommendation.profile)
            space = try await spaceRequest
            session = try await sessionRequest
            step = .hotel
            statusMessage = "호텔 데모 QR 체크인 · 승인 전"
        }
    }

    func applyHotel() async { await hotelCommand("apply") }
    func stopHotel() async { await hotelCommand("stop") }
    func restoreHotel() async { await hotelCommand("restore") }

    func checkout() async {
        guard let id = session?.sessionId else { return }
        await perform {
            session = try await client.command(sessionId: id, action: "checkout")
            hotelRoom = .hotelDefault
            step = .complete
            statusMessage = "체크아웃 · 기본값 복원 · 세션 만료"
        }
    }

    func resetDemo() {
        step = .wearable
        isWearableConnected = false
        snapshot = nil
        recommendation = nil
        space = nil
        session = nil
        homeRoom = .homeDefault
        hotelRoom = .hotelDefault
        hasSavedAdjustment = false
        statusMessage = "더미 데이터만 사용합니다."
        errorMessage = nil
    }

    private func hotelCommand(_ action: String) async {
        guard let id = session?.sessionId else { return }
        await perform {
            let updated = try await client.command(sessionId: id, action: action)
            session = updated
            if action == "apply", let execution = updated.execution {
                hotelRoom = RoomState(
                    brightness: execution.lighting.brightnessPercent,
                    temperature: execution.temperatureC,
                    sound: "미지원",
                    isApplied: true
                )
            } else if action == "restore" {
                hotelRoom = .hotelDefault
            } else if action == "stop" {
                hotelRoom.isApplied = false
            }
            statusMessage = "호텔 \(action) · 범주별 결과 확인"
        }
    }

    private func perform(_ operation: () async throws -> Void) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do { try await operation() } catch { errorMessage = error.localizedDescription }
    }
}
