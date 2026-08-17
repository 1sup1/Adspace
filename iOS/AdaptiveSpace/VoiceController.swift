@preconcurrency import AVFoundation
import Combine
@preconcurrency import Speech

@MainActor
final class VoiceController: ObservableObject {
    enum LocalRecognitionError: LocalizedError, Equatable {
        case unsupported
        case temporarilyUnavailable

        var errorDescription: String? {
            switch self {
            case .unsupported:
                "이 기기에서는 한국어 온디바이스 음성 인식을 지원하지 않습니다. 텍스트로 입력해 주세요."
            case .temporarilyUnavailable:
                "한국어 온디바이스 음성 인식을 지금 사용할 수 없습니다. 잠시 후 다시 시도해 주세요."
            }
        }
    }

    static let localeIdentifier = "ko-KR"

    @Published private(set) var transcript = ""
    @Published private(set) var isListening = false
    @Published private(set) var errorMessage: String?

    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
    private let synthesizer = AVSpeechSynthesizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var hasInputTap = false
    private var pendingStartID: UUID?

    func requestAndStart() async {
        stopSpeaking()
        let startID = UUID()
        pendingStartID = startID
        defer {
            if pendingStartID == startID { pendingStartID = nil }
        }

        let speechAllowed = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization {
                continuation.resume(returning: $0 == .authorized)
            }
        }
        guard pendingStartID == startID, !Task.isCancelled else { return }
        guard speechAllowed else {
            errorMessage = "음성 인식 권한이 필요합니다."
            return
        }

        let microphoneAllowed = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission {
                continuation.resume(returning: $0)
            }
        }
        guard pendingStartID == startID, !Task.isCancelled else { return }
        guard microphoneAllowed else {
            errorMessage = "마이크 권한이 필요합니다."
            return
        }
        start()
    }

    func stop() {
        pendingStartID = nil
        if audioEngine.isRunning { audioEngine.stop() }
        if hasInputTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInputTap = false
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isListening = false
    }

    func clear() {
        stop()
        transcript = ""
        errorMessage = nil
    }

    func speak(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(Self.makeSystemUtterance(text))
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func start() {
        clear()
        guard let recognizer else {
            errorMessage = "음성 인식을 사용할 수 없습니다."
            return
        }
        let request: SFSpeechAudioBufferRecognitionRequest
        do {
            request = try Self.makeOnDeviceRecognitionRequest(
                recognizerAvailable: recognizer.isAvailable,
                supportsOnDeviceRecognition: recognizer.supportsOnDeviceRecognition
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.defaultToSpeaker, .allowBluetoothHFP]
            )
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            self.request = request

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            hasInputTap = true
            audioEngine.prepare()
            try audioEngine.start()
            isListening = true

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let failed = error != nil
                let finished = result?.isFinal == true || failed
                Task { @MainActor [weak self] in
                    guard let self, self.request === request else { return }
                    if let text { self.transcript = text }
                    if failed, self.isListening, self.transcript.isEmpty {
                        self.errorMessage = "기기에서 음성을 인식하지 못했습니다. 다시 시도해 주세요."
                    }
                    if finished { self.stop() }
                }
            }
        } catch {
            stop()
            errorMessage = "마이크 연결을 확인해 주세요."
        }
    }

    static func makeOnDeviceRecognitionRequest(
        recognizerAvailable: Bool,
        supportsOnDeviceRecognition: Bool
    ) throws -> SFSpeechAudioBufferRecognitionRequest {
        guard supportsOnDeviceRecognition else { throw LocalRecognitionError.unsupported }
        guard recognizerAvailable else { throw LocalRecognitionError.temporarilyUnavailable }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        return request
    }

    static func makeSystemUtterance(_ text: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: localeIdentifier)
        utterance.rate = 0.48
        return utterance
    }
}
