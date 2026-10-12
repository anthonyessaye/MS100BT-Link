import Foundation

/// Universal identity reply: `F0 7E <ch> 06 02 52 <id> 00 <mode> 00 <v1> <v2> <v3> <v4> F7`.
/// Byte 6 = device ID and byte 8 = op mode are read exactly as the updater reads them.
public struct IdentityReply: Equatable, Sendable {
    public let deviceID: UInt8
    public let mode: UInt8
    /// ASCII firmware version from bytes 10…, e.g. "1.30".
    public let version: String
    public let raw: [UInt8]

    public static func decode(_ m: [UInt8]) -> IdentityReply? {
        guard m.count >= 11, m.first == 0xF0, m.last == 0xF7,
              m[1] == 0x7E, m[3] == 0x06, m[4] == 0x02, m[5] == 0x52 else { return nil }
        let versionBytes = m[10..<(m.count - 1)].filter { (0x20...0x7E).contains($0) }
        let version = String(decoding: versionBytes, as: UTF8.self)
        return IdentityReply(deviceID: m[6], mode: m[8], version: version, raw: m)
    }

    public var isKnownMS100BTID: Bool { Allowlist.knownDeviceIDs.contains(deviceID) }
}

/// Any Zoom-format SysEx: `F0 52 00 <id> <op> … F7`.
public struct ZoomSysEx: Equatable, Sendable {
    public let deviceID: UInt8
    public let opcode: UInt8
    /// Bytes after the opcode, excluding the trailing F7.
    public let payload: [UInt8]

    public static func decode(_ m: [UInt8]) -> ZoomSysEx? {
        guard m.count >= 6, m[0] == 0xF0, m[1] == 0x52, m[2] == 0x00, m.last == 0xF7 else { return nil }
        return ZoomSysEx(deviceID: m[3], opcode: m[4], payload: Array(m[5..<(m.count - 1)]))
    }
}

/// Current program, assembled from `B0 00 <msb>`, `B0 20 <lsb>`, `C0 <pp>`.
public struct ProgramInfo: Equatable, Sendable {
    public var bankMSB: UInt8?
    public var bankLSB: UInt8?
    public var program: UInt8?

    public init(bankMSB: UInt8? = nil, bankLSB: UInt8? = nil, program: UInt8? = nil) {
        self.bankMSB = bankMSB; self.bankLSB = bankLSB; self.program = program
    }

    /// Applies one channel message. Returns true when it changed the program number.
    @discardableResult
    public mutating func apply(_ msg: [UInt8]) -> Bool {
        guard let status = msg.first else { return false }
        switch status & 0xF0 {
        case 0xB0 where msg.count == 3 && msg[1] == 0x00: bankMSB = msg[2]
        case 0xB0 where msg.count == 3 && msg[1] == 0x20: bankLSB = msg[2]
        case 0xC0 where msg.count == 2: program = msg[1]; return true
        default: break
        }
        return false
    }

    public var displayString: String {
        guard let p = program else { return "—" }
        var s = "Program \(p) (patch \(Int(p) + 1))"
        if bankMSB != nil || bankLSB != nil {
            s += ", bank \(bankMSB.map(String.init) ?? "?")/\(bankLSB.map(String.init) ?? "?")"
        }
        return s
    }
}

/// Current-patch dump (`F0 52 00 <id> 28 … F7`).
///
/// Bytes 5…144 are 7-bit packed: groups of 8 = one MSB byte + 7 data bytes. Bit 6 of the MSB
/// byte is the top bit of the FIRST data byte (bit 6-k → data byte k). The reverse order also
/// decodes names and on/off, but corrupts effect IDs and parameters. Unpacked, a 146-byte dump gives 122 bytes:
///   0…107   six 18-byte effect blocks, each a little-endian bit stream:
///             bit 0 on/off · bits 1–28 effect ID · P0–P2 13 bits each from bit 29 ·
///             P3–P7 8 bits each from bit 68 · P8 8 bits at bit 128 (zoom-explorer `readMSPatch`)
///   108…110 patch header: effect count, tempo, edit focus (zoom-explorer `readMSPatch`)
///   111…120 name, 10 ASCII chars, space padded
/// Verified on the MS-100BT: name "Bourj" matched the screen, and toggling effect 5 changed
/// exactly bit 0 of block 5's first byte (0x60 → 0x61).
public struct PatchDump: Equatable, Sendable {
    public static let expectedLength = 146
    public static let packedStart = 5
    public static let effectBlockSize = 18
    public static let effectCount = 6
    public static let nameRange = 111..<121

    /// Bit positions (start, width) of P0…P8 inside an 18-byte effect block.
    public static let parameterFields: [(start: Int, width: Int)] =
        [(29, 13), (42, 13), (55, 13), (68, 8), (76, 8), (84, 8), (92, 8), (100, 8), (128, 8)]

    public struct ParameterValue: Equatable, Sendable, Identifiable {
        public let index: Int
        public let name: String
        public let raw: Int
        /// Display string from the catalog; nil if `raw` is out of range (layout doubt).
        public let display: String?
        public var id: Int { index }
        public var text: String { display ?? "?\(raw)" }
    }

    public struct EffectSlot: Equatable, Sendable, Identifiable {
        public let index: Int
        /// Bit 0 of the block's first unpacked byte. Verified on the MS-100BT. Nil for empty slots.
        public let isOn: Bool?
        /// Effect ID (`0` = empty slot / THRU). Category is the top byte.
        public let effectID: UInt32
        public var isEmpty: Bool { effectID == 0 }
        /// Name from `EffectCatalog`; nil if the ID is unknown (e.g. an MS-100BT-only effect).
        public var name: String? { isEmpty ? nil : EffectCatalog.name(for: effectID) }
        public var category: String? { isEmpty ? nil : EffectCatalog.category(for: effectID) }
        public var displayName: String {
            if isEmpty { return "—" }
            return name ?? String(format: "unknown %08X", effectID)
        }
        /// Decoded parameters, named from the catalog (empty for unknown IDs and empty slots).
        public var parameters: [ParameterValue] {
            guard !isEmpty, raw.count == PatchDump.effectBlockSize,
                  let def = EffectCatalog.effect(for: effectID) else { return [] }
            return def.parameters.enumerated().compactMap { i, p in
                guard i < PatchDump.parameterFields.count else { return nil }
                let f = PatchDump.parameterFields[i]
                let v = PatchDump.bits(raw, from: f.start, width: f.width)
                return ParameterValue(index: i, name: p.name, raw: v, display: p.display(v))
            }
        }
        /// Unpacked bytes of this slot's 18-byte block (no type decoding in this phase).
        public let raw: [UInt8]
        public var id: Int { index }
    }

    public let deviceID: UInt8
    public let raw: [UInt8]
    public let unpacked: [UInt8]
    public let name: String?
    public let effects: [EffectSlot]
    /// Effect count from the header (can lag right after an on-pedal add/delete, per zoom-explorer).
    public let effectCount: Int?
    public let tempo: Int?
    /// Effect slot (0…5) the pedal's own screen shows / edits. Header bits, per zoom-explorer:
    /// byte 108 bits 6–7 and byte 109 bit 0 hold (5 − slot).
    public let editSlot: Int?

    public var lengthMatchesMS50G: Bool { raw.count == Self.expectedLength }

    /// Little-endian bit field: bit n = bit (n % 8) of byte n / 8.
    public static func bits(_ bytes: [UInt8], from start: Int, width: Int) -> Int {
        var v = 0
        for j in 0..<width {
            let n = start + j
            guard n / 8 < bytes.count else { break }
            v |= Int((bytes[n / 8] >> (n % 8)) & 1) << j
        }
        return v
    }

    /// Zoom 7-bit unpacking: each group is [msbs, d0…d6], bit 6-k of msbs → top bit of dk.
    /// A short final group is allowed.
    public static func unpack7(_ packed: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        var i = packed.startIndex
        while i < packed.endIndex {
            let msbs = packed[i]
            var k = 0
            var j = i + 1
            while j < packed.endIndex && k < 7 {
                out.append(packed[j] | ((msbs >> (6 - k)) & 1) << 7)
                j += 1; k += 1
            }
            i = j
        }
        return out
    }

    public static func decode(_ m: [UInt8]) -> PatchDump? {
        guard let z = ZoomSysEx.decode(m), z.opcode == 0x28 else { return nil }
        let last = m.count - 1 // index of F7
        let u = packedStart < last ? unpack7(m[packedStart..<last]) : []

        var name: String?
        if nameRange.upperBound <= u.count {
            let chars = u[nameRange].map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "?" }
            name = String(chars).trimmingCharacters(in: .whitespaces)
        }

        var effects: [EffectSlot] = []
        for i in 0..<effectCount {
            let lo = i * effectBlockSize
            let hi = min(lo + effectBlockSize, u.count)
            let block = lo < hi ? Array(u[lo..<hi]) : []
            var word: UInt32 = 0
            for (k, b) in block.prefix(4).enumerated() { word |= UInt32(b) << (8 * k) }
            let id = block.count >= 4 ? (word >> 1) & 0x0FFF_FFFF : 0
            let on: Bool? = id == 0 ? nil : block.first.map { $0 & 1 == 1 }
            effects.append(EffectSlot(index: i, isOn: on, effectID: id, raw: block))
        }
        var count: Int?, tempo: Int?, edit: Int?
        if u.count >= 111 {
            let h = u[108..<111].map { Int($0) }
            count = (h[1] & 0b0001_1100) >> 2
            tempo = ((h[1] & 0b1110_0000) >> 5) + ((h[2] & 0b0001_1111) << 3)
            let leftToRight = ((h[0] & 0b1100_0000) >> 6) | ((h[1] & 0b0000_0001) << 2)
            edit = 5 - leftToRight
        }
        return PatchDump(deviceID: z.deviceID, raw: m, unpacked: u, name: name, effects: effects,
                         effectCount: count, tempo: tempo, editSlot: edit)
    }
}

/// Everything the session can recognise in one MIDI event.
public enum DecodedMessage: Equatable, Sendable {
    case identity(IdentityReply)
    case patch(PatchDump)
    /// `F0 52 00 <id> 00 <code> … F7` response/ack.
    case response(deviceID: UInt8, code: UInt8, payload: [UInt8])
    case zoom(ZoomSysEx)
    case programChange(UInt8)
    case controlChange(controller: UInt8, value: UInt8)
    case other

    public static func decode(_ event: MIDIEvent) -> DecodedMessage {
        switch event {
        case .sysex(let m):
            if let id = IdentityReply.decode(m) { return .identity(id) }
            if let p = PatchDump.decode(m) { return .patch(p) }
            if let z = ZoomSysEx.decode(m) {
                if z.opcode == 0x00 {
                    return .response(deviceID: z.deviceID, code: z.payload.first ?? 0, payload: z.payload)
                }
                return .zoom(z)
            }
            return .other
        case .channel(let c):
            if c[0] & 0xF0 == 0xC0, c.count == 2 { return .programChange(c[1]) }
            if c[0] & 0xF0 == 0xB0, c.count == 3 { return .controlChange(controller: c[1], value: c[2]) }
            return .other
        default:
            return .other
        }
    }

    public var summary: String {
        switch self {
        case .identity(let i):
            return "identity reply: device ID \(i.deviceID.hex), mode \(i.mode), firmware \"\(i.version)\""
        case .patch(let p):
            return "patch dump: \(p.raw.count) bytes, name \"\(p.name ?? "?")\"" + (p.lengthMatchesMS50G ? "" : " (length differs from MS-50G 146)")
        case .response(_, let code, let payload):
            return "response code \(code.hex)" + (payload.count > 1 ? " [\(payload.hex)]" : "")
        case .zoom(let z):
            return "zoom opcode \(z.opcode.hex), \(z.payload.count) payload bytes"
        case .programChange(let p):
            return "program change \(p)"
        case .controlChange(let c, let v):
            return "control change \(c) = \(v)"
        case .other:
            return "unrecognised"
        }
    }
}
