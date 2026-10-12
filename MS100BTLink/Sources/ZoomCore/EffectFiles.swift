// Effect files on the pedal: CRC/7-bit codecs, the .ZDL header, and the effect menu (FLST_SEQ.ZDT).
// Ported from lopezchau/zoom-ms100bt-bluetooth (MS100BTKit/Codec.swift, ZDL.swift, EffectIndex.swift),
// MIT License, Copyright (c) 2026 lopezchau. Every format here was verified there on an MS-100BT (fw 1.30).
// See THIRD_PARTY_NOTICES.md and docs/effect-library-plan.md.

import Foundation

public enum FSCodec {
    static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    /// Standard CRC-32 (zlib). The pedal transmits `crc32(data) ^ 0xFFFFFFFF`.
    public static func crc32<C: Collection>(_ d: C) -> UInt32 where C.Element == UInt8 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in d { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    /// 32-bit value as five 7-bit bytes, least significant first.
    public static func u7x5(_ v: UInt32) -> [UInt8] { (0..<5).map { UInt8((v >> (7 * UInt32($0))) & 0x7F) } }

    /// Reads five 7-bit bytes (least significant first) at `at`.
    public static func u35(_ m: [UInt8], _ at: Int) -> UInt32? {
        guard at >= 0, m.count >= at + 5 else { return nil }
        var v: UInt32 = 0
        for i in 0..<5 { v |= UInt32(m[at + i] & 0x7F) << (7 * UInt32(i)) }
        return v
    }

    /// Valid file name for the pedal: 1–12 printable characters from a conservative set.
    public static func isValidName(_ n: String) -> Bool {
        let ok = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-.")
        return (1...12).contains(n.utf8.count) && n.unicodeScalars.allSatisfy(ok.contains)
    }

    /// 8.3 name ending in .ZDL. Longer base names have frozen pedals at boot (community finding).
    public static func isSafeEffectName(_ n: String) -> Bool {
        let parts = n.split(separator: ".", omittingEmptySubsequences: false)
        return isValidName(n) && parts.count == 2 && (1...8).contains(parts[0].count) && parts[1].uppercased() == "ZDL"
    }
}

/// Category numbers used by ZDL headers (byte 60) and the effect menu.
public enum ZDLCategory {
    public static let names: [UInt8: String] = [
        0x01: "Dynamics", 0x02: "Filter/EQ", 0x03: "Drive", 0x04: "Amp", 0x05: "Bass Amp",
        0x06: "Modulation", 0x07: "SFX", 0x08: "Delay", 0x09: "Reverb", 0x0B: "Pedal",
        0x0C: "Bass Drive", 0x0D: "Bass Preamp", 0x0F: "Shared library",
        0x14: "Bass Drive (B1Xon)", 0x16: "Bass Preamp (B1Xon)",
    ]
    /// Categories the MS-100BT menu shows (DYN/FLTR, OD/DIST, AMP, MOD/SFX, DLY/REV).
    public static let shownOnMS100BT: Set<UInt8> = [0x01, 0x02, 0x03, 0x04, 0x06, 0x07, 0x08, 0x09]
    /// Stored but never shown by the MS-100BT menu (confirmed on hardware with a bass drive).
    public static let notShownOnMS100BT: Set<UInt8> = [0x05, 0x0B, 0x0C, 0x0D, 0x14, 0x16]
    public static let sharedLibrary: UInt8 = 0x0F
    public static func name(_ c: UInt8) -> String { names[c] ?? String(format: "Category %02X", c) }
}

/// A MultiStomp effect file: `00000000` `SIZE` … `INFO` header (byte 60 category, 61 type, 64–65 effect ID,
/// 68… version), then a TI C6000 ELF at 20 + headerSize. Header size 56 is standard; 312 (`CABI`) is the
/// MS-100BT's own amps; 232 (`BCAB`, bass amps) has never been tried on an MS-100BT.
public struct ZDLInfo: Codable, Hashable, Sendable {
    public let fileName: String
    public let size: Int
    public let headerSize: Int
    public let extendedTag: String
    public let category: UInt8
    public let type: UInt8
    /// Bytes 64–65; unique within a category. Patch effect ID = (category << 24) | effectID.
    public let effectID: UInt16
    public let version: String
    public let truncated: Bool
    public let displayName: String
    public let parameters: [String]
    public let imports: [String]
    public let exports: [String]
    public let crc32: UInt32

    /// The 28-bit ID this effect has inside patch data (checked: LINESEL 02/8 = 0x02000008).
    public var patchEffectID: UInt32 { UInt32(category) << 24 | UInt32(effectID) }
    public var hasSafeName: Bool { FSCodec.isSafeEffectName(fileName) }
    public var isSharedLibrary: Bool { category == ZDLCategory.sharedLibrary }

    /// Largest *custom* (community-built) ZDL known to load; 32,998 bytes froze a pedal. Stock
    /// effects up to 42 KB (DualRev) work.
    public static let customSizeLimit = 32_126

    public static func parse(fileName: String, data d: [UInt8]) -> ZDLInfo? {
        guard d.count > 80, Array(d[4..<8]) == Array("SIZE".utf8), Array(d[20..<24]) == Array("INFO".utf8) else { return nil }
        let headerSize = Int(le32(d, 12)), elfSize = Int(le32(d, 16))
        let elfOff = 20 + headerSize
        let tag = headerSize > 56 && d.count >= 0x50 ? String(bytes: d[0x4C..<0x50], encoding: .ascii) ?? "" : ""
        let version = String(bytes: d[68..<72].prefix { $0 != 0 }, encoding: .ascii) ?? ""
        let truncated = elfSize <= 0 || d.count < elfOff + elfSize
        var imports: [String] = [], exports: [String] = []
        if !truncated, elfOff + 4 <= d.count, Array(d[elfOff..<(elfOff + 4)]) == [0x7F, 0x45, 0x4C, 0x46] {
            (exports, imports) = dynamicSymbols(Array(d[elfOff..<(elfOff + elfSize)]))
        }
        let (name, params) = descriptor(d)
        return ZDLInfo(fileName: fileName, size: d.count, headerSize: headerSize, extendedTag: tag,
                       category: d[60], type: d[61], effectID: UInt16(d[64]) | UInt16(d[65]) << 8, version: version,
                       truncated: truncated,
                       displayName: name ?? fileName.replacingOccurrences(of: ".ZDL", with: "", options: .caseInsensitive),
                       parameters: params, imports: imports.sorted(), exports: exports.sorted(), crc32: FSCodec.crc32(d))
    }

    static func le32(_ d: [UInt8], _ o: Int) -> UInt32 {
        guard o >= 0, o + 4 <= d.count else { return 0 }
        return UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24
    }
    static func le16(_ d: [UInt8], _ o: Int) -> Int { o >= 0 && o + 2 <= d.count ? Int(d[o]) | Int(d[o + 1]) << 8 : 0 }
    static func cstring(_ d: [UInt8], _ o: Int, max: Int) -> String {
        guard o >= 0, o < d.count else { return "" }
        return String(bytes: d[o..<min(o + max, d.count)].prefix { $0 != 0 }, encoding: .isoLatin1) ?? ""
    }

    /// The firmware's descriptor table: 0x30-byte entries starting with "OnOff" (word 3 = 1);
    /// entry 1 is the display name (word 3 = 0xFFFFFFFF), the rest are knob names.
    static func descriptor(_ d: [UInt8]) -> (String?, [String]) {
        let needle = Array("OnOff\0".utf8)
        var off = 0
        while off + 0x60 <= d.count {
            if d[off] == 0x4F, Array(d[off..<(off + 6)]) == needle, le32(d, off + 12) == 1, le32(d, off + 0x30 + 12) == 0xFFFF_FFFF {
                let name = cstring(d, off + 0x30, max: 12)
                var params: [String] = []
                var e = off + 0x60
                while e + 0x30 <= d.count, params.count < 16 {
                    let p = cstring(d, e, max: 12)
                    if p.isEmpty || !(p.first?.isLetter ?? false) || !p.allSatisfy({ $0.isASCII && !$0.isNewline }) { break }
                    params.append(p)
                    e += 0x30
                }
                return (name.isEmpty ? nil : name, params)
            }
            off += 1
        }
        return (nil, [])
    }

    /// Defined and undefined names of the ELF's .dynsym table (dependencies on shared libraries).
    static func dynamicSymbols(_ elf: [UInt8]) -> ([String], [String]) {
        let shoff = Int(le32(elf, 0x20)), shentsize = le16(elf, 0x2E), shnum = le16(elf, 0x30)
        guard shoff > 0, shentsize >= 40, shnum < 1000, shoff + shnum * shentsize <= elf.count else { return ([], []) }
        func sh(_ i: Int, _ field: Int) -> Int { Int(le32(elf, shoff + i * shentsize + field * 4)) }
        var defined = Set<String>(), undefined = Set<String>()
        for i in 0..<shnum where sh(i, 1) == 11 { // SHT_DYNSYM
            let symOff = sh(i, 4), symSize = sh(i, 5), link = sh(i, 6)
            guard link < shnum else { continue }
            let strOff = sh(link, 4)
            var o = symOff
            while o + 16 <= min(symOff + symSize, elf.count) {
                let nameOff = Int(le32(elf, o)), shndx = le16(elf, o + 14)
                if nameOff > 0 {
                    let n = cstring(elf, strOff + nameOff, max: 128)
                    if !n.isEmpty { if shndx == 0 { undefined.insert(n) } else { defined.insert(n) } }
                }
                o += 16
            }
        }
        return (Array(defined), Array(undefined))
    }
}

/// FLST_SEQ.ZDT, the pedal's effect menu: 13-byte records (8.3 name + NUL, zero padded).
/// `>>>\0`+u32 opens a category, `<<<\0`+u32 closes it; zero-padded to a fixed size (4108 on the
/// MS-100BT). No checksum. `build(parse(x)) == x` is required, so an unknown format is refused.
public struct EffectIndex: Codable, Equatable, Sendable {
    public struct Category: Codable, Equatable, Sendable {
        public var id: UInt8
        /// Effect file names in menu order. An empty string is a blank record.
        public var effects: [String]
    }

    public var categories: [Category]
    public var fileSize: Int

    public enum IndexError: Error, CustomStringConvertible {
        case malformed(String), tooBig(Int, Int)
        public var description: String {
            switch self {
            case .malformed(let s): return "Malformed effect menu: \(s)"
            case .tooBig(let n, let max): return "Effect menu too big: \(n) > \(max) bytes"
            }
        }
    }

    public static let fileName = "FLST_SEQ.ZDT"
    static let record = 13

    public init(categories: [Category], fileSize: Int) {
        self.categories = categories
        self.fileSize = fileSize
    }

    public init(data: [UInt8]) throws {
        var cats: [Category] = []
        var cur: Category?
        var end = data.count
        while end > 0 && data[end - 1] == 0 { end -= 1 }
        end += (Self.record - end % Self.record) % Self.record
        var off = 0
        while off + Self.record <= min(end, data.count) {
            let r = Array(data[off..<(off + Self.record)])
            let cat = r[4]
            if Array(r[0..<4]) == [0x3E, 0x3E, 0x3E, 0] {
                guard cur == nil else { throw IndexError.malformed("category not closed at \(off)") }
                cur = Category(id: cat, effects: [])
            } else if Array(r[0..<4]) == [0x3C, 0x3C, 0x3C, 0] {
                guard let c = cur, c.id == cat else { throw IndexError.malformed("unexpected category end at \(off)") }
                cats.append(c); cur = nil
            } else {
                guard cur != nil else { throw IndexError.malformed("effect outside a category at \(off)") }
                cur!.effects.append(String(bytes: r.prefix { $0 != 0 }, encoding: .ascii) ?? "")
            }
            off += Self.record
        }
        guard cur == nil else { throw IndexError.malformed("last category not closed") }
        categories = cats
        fileSize = data.count
        guard try build() == data else { throw IndexError.malformed("does not round-trip; unknown format") }
    }

    public func build() throws -> [UInt8] {
        var out: [UInt8] = []
        func rec(_ prefix: [UInt8]) { out += prefix + [UInt8](repeating: 0, count: Self.record - prefix.count) }
        for c in categories {
            rec([0x3E, 0x3E, 0x3E, 0, c.id, 0, 0, 0])
            for e in c.effects {
                let b = Array(e.utf8)
                guard b.count <= 12 else { throw IndexError.malformed("name too long: \(e)") }
                rec(b)
            }
            rec([0x3C, 0x3C, 0x3C, 0, c.id, 0, 0, 0])
        }
        guard out.count <= fileSize else { throw IndexError.tooBig(out.count, fileSize) }
        return out + [UInt8](repeating: 0, count: fileSize - out.count)
    }

    public var allEffects: [String] { categories.flatMap(\.effects).filter { !$0.isEmpty } }
    public func category(of name: String) -> UInt8? { categories.first { $0.effects.contains(name) }?.id }

    public mutating func remove(_ name: String) {
        for i in categories.indices { categories[i].effects.removeAll { $0 == name } }
    }

    /// Adds `name` at the end of category `cat` (its own header category; anything else froze a pedal).
    public mutating func append(_ name: String, to cat: UInt8) {
        remove(name)
        if let i = categories.firstIndex(where: { $0.id == cat }) {
            categories[i].effects.append(name)
        } else {
            categories.append(Category(id: cat, effects: [name]))
        }
    }
}
