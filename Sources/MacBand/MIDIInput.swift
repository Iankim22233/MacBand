import Foundation
import CoreMIDI

/// Connects every MIDI source (keyboards, controllers) and forwards note events.
final class MIDIInput {
    var onNoteOn: ((Int, Int) -> Void)?
    var onNoteOff: ((Int) -> Void)?
    var onDevices: (([String]) -> Void)?
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()

    func start() {
        MIDIClientCreateWithBlock("MacBand" as CFString, &client) { [weak self] note in
            if note.pointee.messageID == .msgSetupChanged { DispatchQueue.main.async { self?.connectAll() } }
        }
        MIDIInputPortCreateWithProtocol(client, "In" as CFString, ._1_0, &port) { [weak self] list, _ in
            self?.handle(list)
        }
        connectAll()
    }

    private func connectAll() {
        var names: [String] = []
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            MIDIPortConnectSource(port, src, nil)
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(src, kMIDIPropertyDisplayName, &name)
            if let n = name?.takeRetainedValue() as String? { names.append(n) }
        }
        onDevices?(names)
    }

    private func handle(_ list: UnsafePointer<MIDIEventList>) {
        var packet = list.pointee.packet
        for _ in 0..<list.pointee.numPackets {
            let count = Int(packet.wordCount)
            withUnsafePointer(to: &packet.words) { ptr in
                ptr.withMemoryRebound(to: UInt32.self, capacity: max(count, 1)) { words in
                    for i in 0..<count {
                        let w = words[i]
                        // UMP MIDI 1.0 channel voice: type 2
                        guard (w >> 28) & 0xF == 2 else { continue }
                        let status = (w >> 20) & 0xF
                        let d1 = Int((w >> 8) & 0x7F), d2 = Int(w & 0x7F)
                        if status == 0x9 && d2 > 0 { onNoteOn?(d1, d2) }
                        else if status == 0x8 || status == 0x9 { onNoteOff?(d1) }
                    }
                }
            }
            packet = MIDIEventPacketNext(&packet).pointee
        }
    }
}
