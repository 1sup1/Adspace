import Foundation

enum DemoScenario: String, CaseIterable, Codable, Identifiable, Sendable {
    case recovery
    case focus
    case calm

    var id: Self { self }

    var title: String {
        switch self {
        case .recovery: "회복 필요"
        case .focus: "집중 필요"
        case .calm: "안정 필요"
        }
    }

    var symbol: String {
        switch self {
        case .recovery: "moon.stars.fill"
        case .focus: "scope"
        case .calm: "wind"
        }
    }
}

enum ConsentedMetric: String, CaseIterable, Codable, Identifiable, Sendable {
    case sleepScore = "sleep_score"
    case activitySteps = "activity_steps"
    case heartRateBPM = "heart_rate_bpm"
    case hrvMS = "hrv_ms"

    var id: Self { self }

    var title: String {
        switch self {
        case .sleepScore: "수면 점수"
        case .activitySteps: "활동량"
        case .heartRateBPM: "심박"
        case .hrvMS: "HRV"
        }
    }
}

struct WearableSnapshot: Codable, Sendable {
    let id: String
    let source: String
    let capturedAt: String
    let sleepScore: Int?
    let activitySteps: Int?
    let heartRateBPM: Int?
    let hrvMS: Int?
    let timeOfDay: String

    enum CodingKeys: String, CodingKey {
        case id, source
        case capturedAt = "captured_at"
        case sleepScore = "sleep_score"
        case activitySteps = "activity_steps"
        case heartRateBPM = "heart_rate_bpm"
        case hrvMS = "hrv_ms"
        case timeOfDay = "time_of_day"
    }

    func filtered(by consent: Set<ConsentedMetric>) -> Self {
        Self(
            id: id,
            source: source,
            capturedAt: capturedAt,
            sleepScore: consent.contains(.sleepScore) ? sleepScore : nil,
            activitySteps: consent.contains(.activitySteps) ? activitySteps : nil,
            heartRateBPM: consent.contains(.heartRateBPM) ? heartRateBPM : nil,
            hrvMS: consent.contains(.hrvMS) ? hrvMS : nil,
            timeOfDay: timeOfDay
        )
    }
}

struct Adjustment: Codable, Sendable {
    let brightnessDelta: Int
    let temperatureDeltaC: Double
    let soundPreset: String?

    enum CodingKeys: String, CodingKey {
        case brightnessDelta = "brightness_delta"
        case temperatureDeltaC = "temperature_delta_c"
        case soundPreset = "sound_preset"
    }
}

struct RecommendationRequest: Codable, Sendable {
    let snapshot: WearableSnapshot
    let recentSnapshots: [WearableSnapshot]
    let consentedFields: [ConsentedMetric]
    let adjustment: Adjustment

    enum CodingKeys: String, CodingKey {
        case snapshot, adjustment
        case recentSnapshots = "recent_snapshots"
        case consentedFields = "consented_fields"
    }
}

struct LightingProfile: Codable, Equatable, Sendable {
    let brightnessPercent: Int
    let colorTemperatureK: Int

    enum CodingKeys: String, CodingKey {
        case brightnessPercent = "brightness_percent"
        case colorTemperatureK = "color_temperature_k"
    }
}

struct EnvironmentProfile: Codable, Equatable, Sendable {
    let lighting: LightingProfile
    let temperatureC: Double
    let soundPreset: String

    enum CodingKeys: String, CodingKey {
        case lighting
        case temperatureC = "temperature_c"
        case soundPreset = "sound_preset"
    }
}

struct RecommendationResponse: Codable, Sendable {
    let profileId: String
    let context: DemoScenario
    let confidence: Double
    let profile: EnvironmentProfile
    let reason: String
    let requiresConfirmation: Bool
    let inputSource: String
    let generatedBy: String
    let observedSampleCount: Int
    let evidence: [String]

    enum CodingKeys: String, CodingKey {
        case context, confidence, profile, reason
        case profileId = "profile_id"
        case requiresConfirmation = "requires_confirmation"
        case inputSource = "input_source"
        case generatedBy = "generated_by"
        case observedSampleCount = "observed_sample_count"
        case evidence
    }
}

struct SpaceSpec: Codable, Sendable {
    struct Lighting: Codable, Sendable {
        let supported: Bool
        let brightnessRange: [Int]
        let colorTemperatureSupported: Bool

        enum CodingKeys: String, CodingKey {
            case supported
            case brightnessRange = "brightness_range"
            case colorTemperatureSupported = "color_temperature_supported"
        }
    }

    struct Temperature: Codable, Sendable {
        let supported: Bool
        let rangeC: [Double]

        enum CodingKeys: String, CodingKey {
            case supported
            case rangeC = "range_c"
        }
    }

    struct Sound: Codable, Sendable { let supported: Bool }
    struct Defaults: Codable, Sendable {
        let brightnessPercent: Int
        let temperatureC: Double

        enum CodingKeys: String, CodingKey {
            case brightnessPercent = "brightness_percent"
            case temperatureC = "temperature_c"
        }
    }

    let spaceId: String
    let lighting: Lighting
    let temperature: Temperature
    let sound: Sound
    let defaults: Defaults

    enum CodingKeys: String, CodingKey {
        case lighting, temperature, sound, defaults
        case spaceId = "space_id"
    }
}

struct SpaceExecution: Codable, Sendable {
    struct Lighting: Codable, Sendable {
        let brightnessPercent: Int
        enum CodingKeys: String, CodingKey { case brightnessPercent = "brightness_percent" }
    }

    let lighting: Lighting
    let temperatureC: Double
    enum CodingKeys: String, CodingKey { case lighting; case temperatureC = "temperature_c" }
}

struct SpaceSession: Codable, Sendable {
    let sessionId: String
    let spaceId: String
    let status: String
    let execution: SpaceExecution?
    let excluded: [String]
    let expiresAt: String
    let sharedBiometricCount: Int
    let profileCopyDeleted: Bool
    let results: [String: String]?

    enum CodingKeys: String, CodingKey {
        case status, execution, excluded, results
        case sessionId = "session_id"
        case spaceId = "space_id"
        case expiresAt = "expires_at"
        case sharedBiometricCount = "shared_biometric_count"
        case profileCopyDeleted = "profile_copy_deleted"
    }
}

struct RoomState: Equatable, Sendable {
    var brightness: Int
    var temperature: Double
    var sound: String
    var isApplied = false

    static let homeDefault = Self(brightness: 70, temperature: 22, sound: "기본")
    static let hotelDefault = Self(brightness: 70, temperature: 22, sound: "미지원")
}
