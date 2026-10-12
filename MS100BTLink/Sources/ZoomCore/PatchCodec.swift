import Foundation

extension PatchDump {
    /// Inverse of `unpack7`: groups of 7 data bytes → [msbs, d0…d6] with bit 6-k = top bit of dk.
    public static func pack7(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i < data.count {
            let group = data[i..<min(i + 7, data.count)]
            var msbs: UInt8 = 0
            for (k, b) in group.enumerated() where b & 0x80 != 0 { msbs |= 1 << (6 - k) }
            out.append(msbs)
            out.append(contentsOf: group.map { $0 & 0x7F })
            i += 7
        }
        return out
    }

    /// Writes `value` into a little-endian bit field (inverse of `bits(_:from:width:)`).
    public static func setBits(_ bytes: inout [UInt8], from start: Int, width: Int, value: Int) {
        for j in 0..<width {
            let n = start + j
            guard n / 8 < bytes.count else { return }
            let mask = UInt8(1) << UInt8(n % 8)
            if (value >> j) & 1 == 1 { bytes[n / 8] |= mask } else { bytes[n / 8] &= ~mask }
        }
    }

    /// Why this patch must not be sent to the pedal, or nil if it looks sane:
    /// every effect known to the catalog and every parameter inside its range.
    public var validationProblem: String? {
        guard lengthMatchesMS50G, unpacked.count == 122 else { return "unexpected length \(raw.count)" }
        guard let name, !name.contains("?") else { return "name has unsupported characters" }
        for e in effects where !e.isEmpty {
            guard EffectCatalog.effect(for: e.effectID) != nil || EffectCatalog.installed[e.effectID] != nil else {
                return String(format: "FX%d has unknown effect ID %08X", e.index + 1, e.effectID)
            }
            if let bad = e.parameters.first(where: { $0.display == nil }) {
                return "FX\(e.index + 1) \(bad.name) = \(bad.raw) is out of range"
            }
        }
        return nil
    }
}

/// Editable copy of a patch. Every mutation works on the unpacked bytes, so anything the
/// decoder doesn't understand (unknown bits, cab byte, edit focus) is carried over unchanged.
public struct PatchEdit: Equatable, Sendable {
    public private(set) var unpacked: [UInt8]
    public let deviceID: UInt8

    public init(_ dump: PatchDump) {
        unpacked = dump.unpacked
        deviceID = dump.deviceID
    }

    public static let nameCharacters = CharacterSet(charactersIn: Unicode.Scalar(0x20)...Unicode.Scalar(0x7E))
    public static let tempoRange = 40...250

    /// Re-encoded `F0 52 00 <id> 28 … F7` frame.
    public var frame: [UInt8] {
        [0xF0, 0x52, 0x00, deviceID, 0x28] + PatchDump.pack7(unpacked) + [0xF7]
    }

    public var decoded: PatchDump? { PatchDump.decode(frame) }

    private func blockStart(_ slot: Int) -> Int { slot * PatchDump.effectBlockSize }

    public mutating func setName(_ name: String) {
        let ascii = name.unicodeScalars.filter { PatchEdit.nameCharacters.contains($0) }.map { UInt8($0.value) }
        let padded = Array(ascii.prefix(10)) + Array(repeating: 0x20, count: max(0, 10 - ascii.count))
        unpacked.replaceSubrange(PatchDump.nameRange, with: padded)
    }

    public mutating func setTempo(_ bpm: Int) {
        let t = min(max(bpm, PatchEdit.tempoRange.lowerBound), PatchEdit.tempoRange.upperBound)
        // header byte 109 bits 5–7 = tempo bits 0–2; byte 110 bits 0–4 = tempo bits 3–7
        unpacked[109] = (unpacked[109] & 0x1F) | UInt8((t & 0x07) << 5)
        unpacked[110] = (unpacked[110] & 0xE0) | UInt8((t >> 3) & 0x1F)
    }

    /// Which effect the pedal's screen shows (0…5).
    public mutating func setEditSlot(_ slot: Int) {
        let lr = 5 - min(max(slot, 0), 5)
        unpacked[108] = (unpacked[108] & 0b0011_1111) | UInt8((lr & 0b011) << 6)
        unpacked[109] = (unpacked[109] & 0b1111_1110) | UInt8((lr & 0b100) >> 2)
    }

    public mutating func setOn(slot: Int, _ on: Bool) {
        var block = Array(unpacked[blockStart(slot)..<blockStart(slot) + PatchDump.effectBlockSize])
        PatchDump.setBits(&block, from: 0, width: 1, value: on ? 1 : 0)
        unpacked.replaceSubrange(blockStart(slot)..<blockStart(slot) + PatchDump.effectBlockSize, with: block)
    }

    public mutating func setParameter(slot: Int, index: Int, raw: Int) {
        guard index < PatchDump.parameterFields.count else { return }
        let f = PatchDump.parameterFields[index]
        var block = Array(unpacked[blockStart(slot)..<blockStart(slot) + PatchDump.effectBlockSize])
        PatchDump.setBits(&block, from: f.start, width: f.width, value: raw)
        unpacked.replaceSubrange(blockStart(slot)..<blockStart(slot) + PatchDump.effectBlockSize, with: block)
    }

    /// Puts effect `id` in `slot` with factory-default parameters, or empties the slot (id 0).
    /// Replacing an effect keeps the slot's unknown bits; filling an empty slot starts from zeros.
    public mutating func setEffect(slot: Int, id: UInt32, on: Bool = true) {
        let range = blockStart(slot)..<blockStart(slot) + PatchDump.effectBlockSize
        var block = Array(unpacked[range])
        let wasEmpty = (PatchDump.bits(block, from: 1, width: 28) == 0)
        if id == 0 || wasEmpty {
            block = Array(repeating: 0, count: PatchDump.effectBlockSize)
        }
        if id == 0 {
            block[0] = 0x01 // empty slot as the pedal writes it
        } else {
            PatchDump.setBits(&block, from: 0, width: 1, value: on ? 1 : 0)
            PatchDump.setBits(&block, from: 1, width: 28, value: Int(id))
            let params = EffectCatalog.effect(for: id)?.parameters ?? []
            for (i, f) in PatchDump.parameterFields.enumerated() {
                PatchDump.setBits(&block, from: f.start, width: f.width, value: i < params.count ? params[i].defaultRaw : 0)
            }
        }
        unpacked.replaceSubrange(range, with: block)
        updateEffectCount()
    }

    /// Header effect count = last occupied slot + 1 (minimum 1, as the pedal never stores 0).
    private mutating func updateEffectCount() {
        var last = 0
        for s in 0..<PatchDump.effectCount {
            let block = Array(unpacked[blockStart(s)..<blockStart(s) + PatchDump.effectBlockSize])
            if PatchDump.bits(block, from: 1, width: 28) != 0 { last = s + 1 }
        }
        let count = max(last, 1)
        unpacked[109] = (unpacked[109] & ~0b0001_1100) | UInt8((count & 0x07) << 2)
    }
}
