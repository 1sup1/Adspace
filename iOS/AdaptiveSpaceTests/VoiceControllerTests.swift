@preconcurrency import AVFoundation
@preconcurrency import Speech
import XCTest
@testable import AdaptiveSpace

@MainActor
final class VoiceControllerTests: XCTestCase {
    func testSupportedRecognitionCreatesLocalOnlyRequest() throws {
        let request = try VoiceController.makeOnDeviceRecognitionRequest(
            recognizerAvailable: true,
            supportsOnDeviceRecognition: true
        )

        XCTAssertTrue(request.requiresOnDeviceRecognition)
        XCTAssertTrue(request.shouldReportPartialResults)
    }

    func testRecognitionFailsClosedWhenOnDeviceProcessingIsUnsupported() {
        XCTAssertThrowsError(
            try VoiceController.makeOnDeviceRecognitionRequest(
                recognizerAvailable: true,
                supportsOnDeviceRecognition: false
            )
        ) { error in
            XCTAssertEqual(error as? VoiceController.LocalRecognitionError, .unsupported)
        }
    }

    func testRecognitionReportsTemporaryUnavailability() {
        XCTAssertThrowsError(
            try VoiceController.makeOnDeviceRecognitionRequest(
                recognizerAvailable: false,
                supportsOnDeviceRecognition: true
            )
        ) { error in
            XCTAssertEqual(error as? VoiceController.LocalRecognitionError, .temporarilyUnavailable)
        }
    }

    func testSystemUtteranceUsesKoreanVoiceConfiguration() {
        let utterance = VoiceController.makeSystemUtterance("안녕하세요")

        XCTAssertEqual(utterance.speechString, "안녕하세요")
        XCTAssertEqual(utterance.voice?.language, VoiceController.localeIdentifier)
        XCTAssertEqual(utterance.rate, 0.48, accuracy: 0.001)
    }
}
