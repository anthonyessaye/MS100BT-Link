import Foundation

/// One complete MIDI message pulled out of the byte stream.
public enum MIDIEvent: Equatable, Sendable {
    /// Complete `F0 … F7` message.
    case sysex([UInt8])
    /// Channel voice message, status byte included (running status expanded).
    case channel([UInt8])
    /// System common message (`F1`–`F6`).
    case common([UInt8])
    /// Real-time byte (`F8`–`FF`).
    case realtime(UInt8)
    /// Bytes that fit no MIDI framing (e.g. a SysEx cut off by a status byte).
    case stray([UInt8])
}

/// Reassembles MIDI messages from an arbitrarily chunked byte stream.
/// RFCOMM delivers bytes in whatever chunks it likes, so state persists across `feed` calls.
public struct SysExFramer {
    public static let maxSysExLength = 64 * 1024

    private var sysex: [UInt8]?
    private var runningStatus: UInt8?
    private var pending: [UInt8] = []
    private var expectedData = 0

    public init() {}

    public mutating func feed(_ bytes: [UInt8]) -> [MIDIEvent] {
        var out: [MIDIEvent] = []
        for b in bytes { feed(byte: b, into: &out) }
        return out
    }

    private mutating func feed(byte b: UInt8, into out: inout [MIDIEvent]) {
        if b >= 0xF8 {
            out.append(.realtime(b))
            return
        }
        if b == 0xF0 {
            if let partial = sysex { out.append(.stray(partial)) }
            sysex = [b]
            runningStatus = nil
            pending = []
            return
        }
        if b == 0xF7 {
            if var s = sysex {
                s.append(b)
                out.append(.sysex(s))
                sysex = nil
            } else {
                out.append(.stray([b]))
            }
            return
        }
        if var s = sysex {
            if b < 0x80 {
                if s.count < Self.maxSysExLength { s.append(b); sysex = s }
                return
            }
            // A status byte inside SysEx terminates it without F7.
            out.append(.stray(s))
            sysex = nil
        }
        if b >= 0x80 {
            pending = [b]
            switch b {
            case 0x80...0xEF:
                runningStatus = b
                expectedData = (b & 0xF0 == 0xC0 || b & 0xF0 == 0xD0) ? 1 : 2
            case 0xF1, 0xF3:
                runningStatus = nil; expectedData = 1
            case 0xF2:
                runningStatus = nil; expectedData = 2
            default: // F4, F5, F6
                runningStatus = nil; expectedData = 0
                out.append(.common([b])); pending = []
            }
            return
        }
        // Data byte outside SysEx.
        if pending.isEmpty {
            guard let rs = runningStatus else { out.append(.stray([b])); return }
            pending = [rs]
        }
        pending.append(b)
        if pending.count == expectedData + 1 {
            let status = pending[0]
            out.append(status >= 0xF0 ? .common(pending) : .channel(pending))
            pending = []
        }
    }
}
