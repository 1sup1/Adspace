import XCTest
@testable import AdaptiveSpace

final class AdaptiveSpaceTests: XCTestCase {
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
