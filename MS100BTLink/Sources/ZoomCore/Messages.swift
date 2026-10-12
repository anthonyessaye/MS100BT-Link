import Foundation

/// Every message this app is able to build. See docs/updater-findings.md for the evidence.
/// Reads are always allowed; writes (`isWrite`) also need `PedalSession.writesEnabled`.
/// Nothing here can touch firmware or the pedal's file system.
public enum Message: Equatable, Sendable {
    /// `F0 7E 00 06 01 F7` — the exact first message Zoom's own updater sends.
    case identityRequest
    /// `F0 7E 7F 06 01 F7` — standard broadcast form, fallback only.
    case identityRequestBroadcast
    /// `F0 52 00 <id> 33 F7` — never answered by the MS-100BT.
    case requestCurrentProgram(deviceID: UInt8)
    /// `F0 52 00 <id> 29 F7` — reply is a `28` patch dump (needs edit mode on the MS-100BT).
    case requestCurrentPatch(deviceID: UInt8)
    /// `F0 52 00 <id> 50 F7` — edit mode on (no storage write).
    case editModeOn(deviceID: UInt8)
    /// `F0 52 00 <id> 51 F7` — edit mode off.
    case editModeOff(deviceID: UInt8)

    // MARK: writes

    /// `C0 <pp>` — select patch 0…49. Changes the live patch, writes nothing.
    case selectPatch(Int)
    /// `F0 52 00 <id> 31 <slot> <param> <lsb> <msb> F7` — live edit of the active patch.
    /// param 0 = on/off (value 0/1), 2…10 = P0…P8. Not stored unless saved / Auto Save.
    case parameterEdit(deviceID: UInt8, slot: Int, param: Int, value: Int)
    /// Full 146-byte `F0 52 00 <id> 28 … F7` frame replacing the active patch (edit buffer).
    case sendPatch(frame: [UInt8])
    /// `F0 52 00 <id> 32 01 00 00 <pp> 00 00 00 00 00 F7` — store the active patch into slot pp.
    case storePatch(deviceID: UInt8, slot: Int)
    /// `F0 52 00 <id> 60 <body…> F7` — pedal file system (effect files and menu). Only the exact
    /// shapes in `Allowlist.validateFileSystem` pass, and the session gates reads and writes separately.
    case fileSystem(deviceID: UInt8, body: [UInt8])

    public var isWrite: Bool {
        switch self {
        case .selectPatch, .parameterEdit, .sendPatch, .storePatch: return true
        default: return false
        }
    }

    public var bytes: [UInt8] {
        switch self {
        case .identityRequest: return [0xF0, 0x7E, 0x00, 0x06, 0x01, 0xF7]
        case .identityRequestBroadcast: return [0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7]
        case .requestCurrentProgram(let id): return Self.zoom(id, 0x33)
        case .requestCurrentPatch(let id): return Self.zoom(id, 0x29)
        case .editModeOn(let id): return Self.zoom(id, 0x50)
        case .editModeOff(let id): return Self.zoom(id, 0x51)
        case .selectPatch(let n): return [0xC0, UInt8(clamping: n)]
        case .parameterEdit(let id, let slot, let param, let value):
            return [0xF0, 0x52, 0x00, id, 0x31, UInt8(clamping: slot), UInt8(clamping: param),
                    UInt8(clamping: value & 0x7F), UInt8(clamping: (value >> 7) & 0x7F), 0xF7]
        case .sendPatch(let frame): return frame
        case .storePatch(let id, let slot):
            return [0xF0, 0x52, 0x00, id, 0x32, 0x01, 0x00, 0x00, UInt8(clamping: slot),
                    0x00, 0x00, 0x00, 0x00, 0x00, 0xF7]
        case .fileSystem(let id, let body):
            return [0xF0, 0x52, 0x00, id, 0x60] + body + [0xF7]
        }
    }

    public var label: String {
        switch self {
        case .identityRequest: return "identity request"
        case .identityRequestBroadcast: return "identity request (broadcast)"
        case .requestCurrentProgram: return "request current program (0x33)"
        case .requestCurrentPatch: return "request current patch (0x29)"
        case .editModeOn: return "edit mode on (0x50)"
        case .editModeOff: return "edit mode off (0x51)"
        case .selectPatch(let n): return "select patch \(n + 1) (C0)"
        case .parameterEdit(_, let slot, let param, let value):
            return param == 0 ? "FX\(slot + 1) \(value == 1 ? "on" : "off") (0x31)"
                              : "FX\(slot + 1) P\(param - 2) = \(value) (0x31)"
        case .sendPatch: return "send patch (0x28)"
        case .storePatch(_, let slot): return "STORE to patch \(slot + 1) (0x32)"
        case .fileSystem(_, let body): return String(format: "file system 60 %02X", body.first ?? 0)
        }
    }

    private static func zoom(_ id: UInt8, _ op: UInt8) -> [UInt8] {
        [0xF0, 0x52, 0x00, id, op, 0xF7]
    }
}

public struct AllowlistViolation: Error, CustomStringConvertible {
    public let frame: [UInt8]
    public let reason: String
    public var description: String { "Blocked outbound frame [\(frame.hex)]: \(reason)" }
}

/// Hard gate applied by every transport before any byte leaves the Mac.
/// Exact shapes only: anything not recognised here is refused.
public enum Allowlist {
    public static let patchSlots = 50
    /// Device IDs the official updater accepts (docs/updater-findings.md).
    public static let knownDeviceIDs: Set<UInt8> = [0x5D, 0x5E]
    /// Six-byte Zoom requests we may send.
    public static let readOpcodes: Set<UInt8> = [0x29, 0x33, 0x50, 0x51]
    /// Opcodes that are never sent: firmware/filesystem path or unknown.
    public static let forbiddenOpcodes: [UInt8: String] = [
        0x01: "flash write begin (firmware updater)",
        0x04: "flash write end (firmware updater)",
        0x05: "unknown, firmware template",
        0x17: "unknown, firmware template",
        0x20: "unknown, firmware template",
        0x21: "unknown, firmware template",
        0x61: "Bluetooth-module function (updater)",
    ]

    private static let identityForms: [[UInt8]] = [
        Message.identityRequest.bytes,
        Message.identityRequestBroadcast.bytes,
    ]

    public static func validate(_ f: [UInt8]) throws {
        func refuse(_ why: String) -> AllowlistViolation { AllowlistViolation(frame: f, reason: why) }
        if identityForms.contains(f) { return }

        // Patch select: C0 on channel 1 only.
        if f.count == 2, f[0] == 0xC0 {
            guard Int(f[1]) < patchSlots else { throw refuse("patch number \(f[1]) out of range") }
            return
        }

        guard f.count >= 6, f[0] == 0xF0, f[1] == 0x52, f[2] == 0x00, f.last == 0xF7 else {
            throw refuse("not an allowlisted message shape")
        }
        let id = f[3], op = f[4]
        if let why = forbiddenOpcodes[op] { throw refuse("opcode \(op.hex) is forbidden: \(why)") }
        guard knownDeviceIDs.contains(id) else { throw refuse("device ID \(id.hex) is not a known MS-100BT ID") }
        guard f.dropFirst().dropLast().allSatisfy({ $0 < 0x80 }) else { throw refuse("data byte ≥ 0x80") }

        switch op {
        case _ where readOpcodes.contains(op):
            guard f.count == 6 else { throw refuse("read request must be 6 bytes") }
        case 0x31:
            guard f.count == 10 else { throw refuse("parameter edit must be 10 bytes") }
            guard f[5] < 6 else { throw refuse("effect slot \(f[5]) out of range") }
            guard f[6] == 0 || (2...10).contains(f[6]) else { throw refuse("parameter number \(f[6]) not allowed") }
            if f[6] == 0 { guard f[7] <= 1, f[8] == 0 else { throw refuse("on/off value must be 0 or 1") } }
        case 0x28:
            guard f.count == PatchDump.expectedLength else { throw refuse("patch must be \(PatchDump.expectedLength) bytes") }
            guard let p = PatchDump.decode(f) else { throw refuse("patch does not decode") }
            if let problem = p.validationProblem { throw refuse("patch failed validation: \(problem)") }
        case 0x60:
            try validateFileSystem(f)
        case 0x32:
            let template: [UInt8] = [0xF0, 0x52, 0x00, id, 0x32, 0x01, 0x00, 0x00, f.count > 8 ? f[8] : 0,
                                     0x00, 0x00, 0x00, 0x00, 0x00, 0xF7]
            guard f == template else { throw refuse("store must match the documented 15-byte form") }
            guard Int(f[8]) < patchSlots else { throw refuse("patch slot \(f[8]) out of range") }
        default:
            throw refuse("opcode \(op.hex) is not allowlisted")
        }
    }

    public static func isAllowed(_ frame: [UInt8]) -> Bool {
        (try? validate(frame)) != nil
    }

    // MARK: file system

    public enum FileSystemAccess { case read, write }

    /// Files never written or deleted (Bluetooth pairing data).
    public static let protectedFiles: Set<String> = ["PAIR.DAT"]
    /// Largest write/read block (the pedal's maxFFSWriteSize on the MS-100BT).
    public static let maxFileBlock = 4096

    /// nil if `f` is not a file-system message; otherwise whether it reads or changes the pedal's files.
    public static func fileSystemAccess(_ f: [UInt8]) -> FileSystemAccess? {
        guard f.count >= 7, f[0] == 0xF0, f[1] == 0x52, f[4] == 0x60 else { return nil }
        switch f[5] {
        case 0x24, 0x23: return .write
        case 0x20: return f.count > 6 && f[6] == 0x01 ? .write : .read
        default: return .read
        }
    }

    /// Exact shapes of the file-system commands verified on an MS-100BT (lopezchau/zoom-ms100bt-bluetooth,
    /// docs/PROTOCOL.md). Everything else in the 0x60 family (e.g. `60 06`, the updater's preparation step)
    /// stays blocked.
    static func validateFileSystem(_ f: [UInt8]) throws {
        func refuse(_ why: String) -> AllowlistViolation { AllowlistViolation(frame: f, reason: "file system: " + why) }
        let body = Array(f[5..<(f.count - 1)])
        guard let sub = body.first else { throw refuse("empty") }

        func name(from i: Int) throws -> String {
            // `<name bytes> 00` must end the body exactly.
            guard body.count > i + 1, body.last == 0 else { throw refuse("missing file name terminator") }
            let raw = Array(body[i..<(body.count - 1)])
            guard let n = String(bytes: raw, encoding: .ascii), FSCodec.isValidName(n) else { throw refuse("invalid file name") }
            return n
        }
        func writable(_ n: String) throws {
            guard !protectedFiles.contains(n.uppercased()) else { throw refuse("\(n) is protected") }
            guard FSCodec.isSafeEffectName(n) || n == EffectIndex.fileName else {
                throw refuse("\(n) is not an 8.3 .ZDL effect or the effect menu")
            }
        }

        switch sub {
        case 0x02, 0x09, 0x27: // FS info, end of session, end of listing
            guard body.count == 1 else { throw refuse("bad length") }
        case 0x05: // ACK
            guard body == [0x05, 0x00] else { throw refuse("bad ACK") }
        case 0x29: // disk usage
            guard body == [0x29, 0, 0, 0, 0, 0] else { throw refuse("bad disk-usage request") }
        case 0x25, 0x26: // find first / next, pattern "*" only
            guard body == [sub, 0, 0, 0x2A, 0] else { throw refuse("bad listing request") }
        case 0x20: // open: mode 02 = read, 01 = write
            guard body.count >= 13, body[1] == 0x01 || body[1] == 0x02, body[2..<11].allSatisfy({ $0 == 0 }) else {
                throw refuse("bad open")
            }
            let n = try name(from: 11)
            if body[1] == 0x01 { try writable(n) }
        case 0x22: // read block: handle(5) size(5)
            guard body.count == 11, let size = FSCodec.u35(body, 6), (1...UInt32(maxFileBlock)).contains(size) else {
                throw refuse("bad read")
            }
        case 0x21: // close: handle(5)
            guard body.count == 6 else { throw refuse("bad close") }
        case 0x24: // delete
            try writable(try name(from: 1))
        case 0x23: // write block: handle(5) size(5) packed data, crc(5)
            guard body.count > 16, let size = FSCodec.u35(body, 6), (1...UInt32(maxFileBlock)).contains(size) else {
                throw refuse("bad write header")
            }
            let n = Int(size)
            let packed = Array(body[11..<(body.count - 5)])
            guard packed.count == n + (n + 6) / 7 else { throw refuse("block length does not match its size") }
            let data = PatchDump.unpack7(packed[...])
            guard data.count == n, let crc = FSCodec.u35(body, body.count - 5),
                  crc ^ 0xFFFF_FFFF == FSCodec.crc32(data) else { throw refuse("block checksum does not match its data") }
        default:
            throw refuse(String(format: "command %02X is not allowlisted", sub))
        }
    }

    /// True for frames that change pedal state (patch select, edits, send, store).
    public static func isWrite(_ f: [UInt8]) -> Bool {
        if f.count == 2, f[0] == 0xC0 { return true }
        return f.count > 4 && f[0] == 0xF0 && [0x28, 0x31, 0x32].contains(f[4])
    }
}

extension UInt8 {
    public var hex: String { String(format: "%02X", self) }
}

extension Sequence where Element == UInt8 {
    public var hex: String { map { $0.hex }.joined(separator: " ") }
}
