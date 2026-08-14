import XCTest
@testable import AdaptiveSpace

final class AdaptiveSpaceTests: XCTestCase {
    func testDemoWearableEmitsOrderedSignals() async throws {
        let provider = DemoWearableProvider(connectionDelay: .zero, sampleInterval: .zero)
        var signals: [WearableSignal] = []

        for try await signal in provider.signalStream(for: .recovery) {
            signals.append(signal)
        }

        XCTAssertEqual(signals.map(\.sequence), [1, 2, 3, 4])
        XCTAssertEqual(signals.map(\.snapshot.id), [
            "demo-recovery-1", "demo-recovery-2", "demo-recovery-3", "demo-recovery-4"
        ])
        XCTAssertEqual(signals.last?.snapshot.heartRateBPM, 78)
    }

    func testConsentRemovesUnapprovedMetric() {
        let snapshot = WearableSnapshot(
            id: "demo",
            source: "demo",
            capturedAt: "2026-08-14T00:00:00Z",
            sleepScore: 52,
            activitySteps: 3_200,
            heartRateBPM: 78,
            hrvMS: 31,
            timeOfDay: "evening"
        )
        let filtered = snapshot.filtered(by: [.sleepScore])
        XCTAssertEqual(filtered.sleepScore, 52)
        XCTAssertNil(filtered.activitySteps)
        XCTAssertNil(filtered.heartRateBPM)
        XCTAssertNil(filtered.hrvMS)
    }
}
