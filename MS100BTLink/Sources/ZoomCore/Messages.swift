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
        0x60: "filesystem access (updater ZDL upload)",
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
