import Foundation
import AVFoundation
import AudioToolbox
import CVST3Host

/// VST3 plugins are hosted by `MBVST3AudioUnit` (Objective-C++), which presents each plugin as an
/// Audio Unit so it slots into the same engine graph as every other instrument and effect.
enum VST3Support {
    private static var registered: [String: UInt32] = [:]
    private static var nextSubtype: UInt32 = 0x4D420001      // 'MB' + counter
    private static let lock = NSLock()

    static func instantiate(_ spec: PluginSpec) async throws -> AVAudioUnit {
        let key = spec.key
        let subtype: UInt32 = {
            lock.lock(); defer { lock.unlock() }
            if let s = registered[key] { return s }
            let s = nextSubtype; nextSubtype += 1
            registered[key] = s
            MBVST3AudioUnit.registerPlugin(atPath: spec.vst3Path, classID: spec.vst3ClassID, name: spec.name,
                                           instrument: spec.isInstrument, subtype: s)
            return s
        }()
        let desc = AudioComponentDescription(
            componentType: spec.isInstrument ? kAudioUnitType_MusicDevice : kAudioUnitType_Effect,
            componentSubType: subtype, componentManufacturer: PluginHost.fourCC("MBnd"),
            componentFlags: 0, componentFlagsMask: 0)
        guard FileManager.default.fileExists(atPath: spec.vst3Path) else {
            throw EngineError.message("\(spec.name) isn't installed at \(spec.vst3Path).")
        }
        do { return try await AVAudioUnit.instantiate(with: desc, options: []) }
        catch { throw EngineError.message("\(spec.name) (VST3) failed to load: \(error.localizedDescription)") }
    }

    /// Child-process scan of one bundle; prints JSON for the parent.
    static func scanBundleJSON(path: String) -> String {
        let items = MBVST3AudioUnit.scanBundle(atPath: path)
        guard let data = try? JSONSerialization.data(withJSONObject: items), let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }
}
