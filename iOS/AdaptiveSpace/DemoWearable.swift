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
            [(52, 3_160, 70, 40, "evening"), (52, 3_175, 78, 34, "evening"),
             (52, 3_188, 87, 28, "evening"), (52, 3_200, 96, 22, "evening")]
        case .focus:
            [(84, 6_710, 66, 55, "morning"), (84, 6_740, 65, 56, "morning"),
             (84, 6_770, 65, 57, "morning"), (84, 6_800, 64, 58, "morning")]
        case .calm:
            [(74, 4_110, 58, 55, "afternoon"), (74, 4_120, 65, 48, "afternoon"),
             (74, 4_130, 72, 39, "afternoon"), (74, 4_140, 80, 30, "afternoon")]
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

                do {
                    var sequence = 0
                    while !Task.isCancelled {
                        if sequence > 0 {
                            try await Task.sleep(for: sampleInterval)
                        }
                        try Task.checkCancellation()
                        sequence += 1
                        let value = values[(sequence - 1) % values.count]

                        let snapshot = WearableSnapshot(
                            id: "demo-\(scenario.rawValue)-\(sequence)",
                            source: "demo",
                            capturedAt: formatter.string(from: .now),
                            sleepScore: value.0,
                            activitySteps: value.1,
                            heartRateBPM: value.2,
                            hrvMS: value.3,
                            timeOfDay: value.4
                        )
                        continuation.yield(WearableSignal(sequence: sequence, snapshot: snapshot))
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
