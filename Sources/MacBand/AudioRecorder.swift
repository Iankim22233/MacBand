import Foundation
import AVFoundation

/// Records the default microphone to a file using its own engine, so the playback graph is untouched.
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private(set) var url: URL?
    private(set) var isRecording = false

    enum Failure: LocalizedError {
        case denied, noInput
        var errorDescription: String? {
            switch self {
            case .denied: return "MacBand isn't allowed to use the microphone. Turn it on in System Settings ▸ Privacy & Security ▸ Microphone."
            case .noInput: return "No microphone input is available."
            }
        }
    }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start() async throws {
        guard await Self.requestAccess() else { throw Failure.denied }
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.channelCount > 0, fmt.sampleRate > 0 else { throw Failure.noInput }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("macband-rec-\(UUID().uuidString).caf")
        file = try AVAudioFile(forWriting: tmp, settings: fmt.settings)
        url = tmp
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buf, _ in try? self?.file?.write(from: buf) }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    func stop() -> URL? {
        guard isRecording else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil
        isRecording = false
        return url
    }
}
