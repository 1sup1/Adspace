import Foundation

protocol WearableProvider: Sendable {
    func connect() async throws
    func signalStream(for scenario: DemoScenario) -> AsyncThrowingStream<WearableSignal, Error>
}

struct WearableSignal: Sendable {
    let sequence: Int
    let snapshot: WearableSnapshot
}

struct DemoWearableProvider: WearableProvider {
    private let connectionDelay: Duration
    private let sampleInterval: Duration

    init(
        connectionDelay: Duration = .milliseconds(250),
        sampleInterval: Duration = .milliseconds(550)
    ) {
        self.connectionDelay = connectionDelay
        self.sampleInterval = sampleInterval
    }

    func connect() async throws {
        try await Task.sleep(for: connectionDelay)
    }

    func signalStream(for scenario: DemoScenario) -> AsyncThrowingStream<WearableSignal, Error> {
        let values: [(Int, Int, Int, Int, String)] = switch scenario {
        case .recovery:
            [(52, 3_160, 72, 36, "evening"), (52, 3_175, 74, 34, "evening"),
             (52, 3_188, 77, 32, "evening"), (52, 3_200, 78, 31, "evening")]
        case .focus:
            [(84, 6_710, 66, 55, "morning"), (84, 6_740, 65, 56, "morning"),
             (84, 6_770, 65, 57, "morning"), (84, 6_800, 64, 58, "morning")]
        case .calm:
            [(74, 4_040, 76, 34, "afternoon"), (74, 4_060, 80, 31, "afternoon"),
             (74, 4_080, 85, 27, "afternoon"), (74, 4_100, 88, 25, "afternoon")]
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

                do {
                    for (index, value) in values.enumerated() {
                        if index > 0 {
                            try await Task.sleep(for: sampleInterval)
                        }
                        try Task.checkCancellation()

                        let snapshot = WearableSnapshot(
                            id: "demo-\(scenario.rawValue)-\(index + 1)",
                            source: "demo",
                            capturedAt: formatter.string(from: .now),
                            sleepScore: value.0,
                            activitySteps: value.1,
                            heartRateBPM: value.2,
                            hrvMS: value.3,
                            timeOfDay: value.4
                        )
                        continuation.yield(WearableSignal(sequence: index + 1, snapshot: snapshot))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
