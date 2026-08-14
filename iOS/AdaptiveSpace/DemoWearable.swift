import Foundation

protocol WearableProvider: Sendable {
    func connect() async throws
    func snapshot(for scenario: DemoScenario) async throws -> WearableSnapshot
}

struct DemoWearableProvider: WearableProvider {
    func connect() async throws {
        try await Task.sleep(for: .milliseconds(250))
    }

    func snapshot(for scenario: DemoScenario) async throws -> WearableSnapshot {
        try await Task.sleep(for: .milliseconds(250))
        let values: (Int, Int, Int, Int, String) = switch scenario {
        case .recovery: (52, 3_200, 78, 31, "evening")
        case .focus: (84, 6_800, 64, 58, "morning")
        case .calm: (74, 4_100, 88, 25, "afternoon")
        }
        return WearableSnapshot(
            id: "demo-\(scenario.rawValue)-001",
            source: "demo",
            capturedAt: ISO8601DateFormatter().string(from: .now),
            sleepScore: values.0,
            activitySteps: values.1,
            heartRateBPM: values.2,
            hrvMS: values.3,
            timeOfDay: values.4
        )
    }
}
