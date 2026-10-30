import Foundation
import AVFoundation
import Speech

struct SpokenWord { var text: String; var start: Double; var end: Double }

/// On-device speech-to-text with word timings, used to put the sung words on the tuned notes.
enum Transcriber {
    enum Failure: LocalizedError {
        case unavailable(String)
        var errorDescription: String? { if case .unavailable(let m) = self { return m }; return nil }
    }

    static func transcribe(fileURL: URL, locale: Locale = .current) async throws -> [SpokenWord] {
        if #available(macOS 26.0, *) {
            do { return try await withAnalyzer(fileURL, locale: locale) }
            catch { NSLog("MacBand: SpeechAnalyzer failed (\(error)); trying the classic recognizer") }
        }
        return try await classic(fileURL, locale: locale)
    }

    // MARK: SpeechAnalyzer (macOS 26+)

    @available(macOS 26.0, *)
    private static func withAnalyzer(_ url: URL, locale: Locale) async throws -> [SpokenWord] {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { throw Failure.unavailable("Speech recognition doesn't support the language “\(locale.identifier)”.") }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        let installed = await SpeechTranscriber.installedLocales
        if !installed.contains(where: { $0.identifier(.bcp47) == supported.identifier(.bcp47) }) {
            if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) { try await req.downloadAndInstall() }
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collect = Task { () -> [SpokenWord] in
            var words: [SpokenWord] = []
            for try await result in transcriber.results {
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let t = String(result.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if t.isEmpty { continue }
                    words.append(SpokenWord(text: t, start: range.start.seconds, end: range.end.seconds))
                }
            }
            return words
        }
        let file = try AVAudioFile(forReading: url)
        if let last = try await analyzer.analyzeSequence(from: file) { try await analyzer.finalizeAndFinish(through: last) }
        else { await analyzer.cancelAndFinishNow() }
        return try await collect.value
    }

    // MARK: SFSpeechRecognizer (older systems / fallback)

    private static func classic(_ url: URL, locale: Locale) async throws -> [SpokenWord] {
        let status = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard status == .authorized else { throw Failure.unavailable("Speech recognition isn't allowed. Turn it on for MacBand in System Settings ▸ Privacy & Security ▸ Speech Recognition.") }
        guard let rec = SFSpeechRecognizer(locale: locale), rec.isAvailable else { throw Failure.unavailable("Speech recognition isn't available right now.") }
        let req = SFSpeechURLRecognitionRequest(url: url)
        req.shouldReportPartialResults = false
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        return try await withCheckedThrowingContinuation { cont in
            var done = false
            rec.recognitionTask(with: req) { result, error in
                if done { return }
                if let result, result.isFinal {
                    done = true
                    cont.resume(returning: result.bestTranscription.segments.map { SpokenWord(text: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration) })
                } else if let error {
                    done = true; cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: words → notes

    /// Put each word on the note it starts in; extra words in one note are joined, and a note that
    /// continues a word (no new word starts in it) stays empty.
    static func assign(_ words: [SpokenWord], to notes: inout [TuneNote]) {
        for i in notes.indices { notes[i].word = "" }
        guard !notes.isEmpty else { return }
        for w in words {
            let mid = (w.start + w.end) / 2
            // prefer the note containing the word's start, otherwise the nearest note to its midpoint
            var best = -1; var bestScore = Double.infinity
            for (i, n) in notes.enumerated() {
                let d: Double = (w.start >= n.start - 0.05 && w.start <= n.end) ? 0 : min(abs(mid - n.start), abs(mid - n.end)) + 0.5
                if d < bestScore { bestScore = d; best = i }
            }
            if best >= 0 && bestScore < 1.5 { notes[best].word = notes[best].word.isEmpty ? w.text : notes[best].word + " " + w.text }
        }
    }
}
