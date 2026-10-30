import Foundation
import AVFoundation
import Accelerate

/// Imported audio lives in MacBand's own folder so projects keep working if the original moves.
enum AudioStore {
    static let folder: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacBand/Audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func url(_ name: String) -> URL { folder.appendingPathComponent(name) }
    static func tunedName(for file: String, clipID: UUID) -> String { "\(clipID.uuidString).tuned.caf" }

    struct Imported { var file: String; var duration: Double; var peaks: Data; var sampleRate: Double; var channels: Int }

    enum StoreError: LocalizedError {
        case unreadable(String)
        var errorDescription: String? { if case .unreadable(let m) = self { return m }; return nil }
    }

    /// All stored audio is Float32, stereo, 44.1 kHz, so players, the tuner and offline export share a format.
    static let rate = 44100.0
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!
    /// File settings for Float32 CAF (files are interleaved on disk; in-memory buffers stay non-interleaved).
    static func fileSettings(channels: Int, rate: Double = AudioStore.rate) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
         AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
    }

    /// Copy any audio file into the store (converted to the store format) and measure it.
    static func importFile(_ src: URL) throws -> Imported {
        let input: AVAudioFile
        do { input = try AVAudioFile(forReading: src) } catch { throw StoreError.unreadable("Couldn't read “\(src.lastPathComponent)” as audio.") }
        let inFmt = input.processingFormat
        let name = UUID().uuidString + ".caf"
        let out = try AVAudioFile(forWriting: url(name), settings: fileSettings(channels: 2), commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let conv = AVAudioConverter(from: inFmt, to: format) else { throw StoreError.unreadable("Unsupported audio format.") }
        let inCap: AVAudioFrameCount = 32768
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: inCap) else { throw StoreError.unreadable("Out of memory.") }
        let outCap = AVAudioFrameCount(Double(inCap) * rate / inFmt.sampleRate) + 4096
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outCap) else { throw StoreError.unreadable("Out of memory.") }
        let hop = Int(rate / 100)
        var peaks: [UInt8] = []; var accum: Float = 0, accumN = 0
        var total = 0
        var finished = false
        while !finished {
            outBuf.frameLength = 0
            var err: NSError?
            let status = conv.convert(to: outBuf, error: &err) { _, outStatus in
                do {
                    if input.framePosition >= input.length { outStatus.pointee = .endOfStream; return nil }
                    try input.read(into: inBuf, frameCount: inCap)
                    if inBuf.frameLength == 0 { outStatus.pointee = .endOfStream; return nil }
                    outStatus.pointee = .haveData; return inBuf
                } catch { outStatus.pointee = .endOfStream; return nil }
            }
            if let err { throw err }
            if outBuf.frameLength > 0 {
                try out.write(from: outBuf)
                let ch0 = outBuf.floatChannelData![0]
                for i in 0..<Int(outBuf.frameLength) {
                    accum = max(accum, abs(ch0[i])); accumN += 1
                    if accumN == hop { peaks.append(UInt8(min(255, accum * 255))); accum = 0; accumN = 0 }
                }
                total += Int(outBuf.frameLength)
            }
            if status == .endOfStream || status == .error { finished = true }
        }
        if accumN > 0 { peaks.append(UInt8(min(255, accum * 255))) }
        guard total > 0 else { throw StoreError.unreadable("“\(src.lastPathComponent)” doesn't contain any audio.") }
        return Imported(file: name, duration: Double(total) / rate, peaks: Data(peaks), sampleRate: rate, channels: 2)
    }

    /// Mono Float32 samples at `rate` Hz (linear resampling), for analysis.
    static func loadMono(_ file: String, rate: Double) throws -> [Float] {
        let f = try AVAudioFile(forReading: url(file))
        let fmt = f.processingFormat
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(f.length)) else { return [] }
        try f.read(into: buf)
        let n = Int(buf.frameLength), chs = Int(fmt.channelCount)
        var mono = [Float](repeating: 0, count: n)
        for c in 0..<chs { let p = buf.floatChannelData![c]; vDSP_vadd(mono, 1, p, 1, &mono, 1, vDSP_Length(n)) }
        if chs > 1 { var k = 1 / Float(chs); vDSP_vsmul(mono, 1, &k, &mono, 1, vDSP_Length(n)) }
        if abs(fmt.sampleRate - rate) < 1 { return mono }
        let ratio = fmt.sampleRate / rate
        let m = Int(Double(n) / ratio)
        var out = [Float](repeating: 0, count: m)
        // box-filter then linear interpolation (cheap anti-aliasing for downsampling)
        let taps = max(1, Int(ratio.rounded()))
        for i in 0..<m {
            let pos = Double(i) * ratio
            let i0 = min(n - 1, Int(pos))
            var s: Float = 0, cnt: Float = 0
            let lo = max(0, i0 - taps / 2), hi = min(n - 1, i0 + taps / 2)
            for j in lo...hi { s += mono[j]; cnt += 1 }
            out[i] = s / max(1, cnt)
        }
        return out
    }

    /// Full-resolution channels for retuning.
    static func loadChannels(_ file: String) throws -> (channels: [[Float]], rate: Double) {
        let f = try AVAudioFile(forReading: url(file))
        let fmt = f.processingFormat
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(f.length)) else { return ([], fmt.sampleRate) }
        try f.read(into: buf)
        let n = Int(buf.frameLength)
        return ((0..<Int(fmt.channelCount)).map { Array(UnsafeBufferPointer(start: buf.floatChannelData![$0], count: n)) }, fmt.sampleRate)
    }

    static func write(_ channels: [[Float]], rate: Double, to name: String) throws {
        guard let first = channels.first else { return }
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: AVAudioChannelCount(channels.count), interleaved: false)!
        let out = try AVAudioFile(forWriting: url(name), settings: fileSettings(channels: channels.count, rate: rate), commonFormat: .pcmFormatFloat32, interleaved: false)
        let n = first.count
        var pos = 0
        while pos < n {
            let m = min(65536, n - pos)
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(m))!
            buf.frameLength = AVAudioFrameCount(m)
            for c in 0..<channels.count { channels[c].withUnsafeBufferPointer { memcpy(buf.floatChannelData![c], $0.baseAddress! + pos, m * 4) } }
            try out.write(from: buf)
            pos += m
        }
    }
}
