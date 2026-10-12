import Foundation
@testable import ZoomCore

/// In-memory MS-100BT for tests: answers identity and the file-system protocol byte-for-byte as documented
/// from hardware (lopezchau/zoom-ms100bt-bluetooth docs/PROTOCOL.md), with failure injection.
/// Every outbound frame is checked by the real allowlist, like the real transports do.
@MainActor
final class SimulatedPedal: Transport {
    weak var delegate: TransportDelegate?
    var displayName = "simulated MS-100BT"
    var isOpen = true

    var files: [String: [UInt8]] = [:]
    var maxFiles = 200
    var totalBytes = 4_143_170
    var sent: [[UInt8]] = []

    // Failure injection
    var corruptNextReadCRC = false
    var failWritesFor: [String: Int] = [:]     // name → number of upcoming opens whose blocks are rejected
    var silent = false                           // stop answering (lost connection)

    private enum Handle { case read(String, Int), write(String, [UInt8], Bool) }
    private var handles: [[UInt8]: Handle] = [:]
    private var pendingData: [UInt8]?
    private var listing: [String] = []
    private var lastHandle: [UInt8] = [0, 0, 0, 0, 0]

    func open() throws { delegate?.transportDidOpen(self) }
    func close() { isOpen = false }

    func send(_ f: [UInt8]) throws {
        try Allowlist.validate(f)
        sent.append(f)
        guard !silent else { return }
        if f == [0xF0, 0x7E, 0x00, 0x06, 0x01, 0xF7] {
            reply([0xF0, 0x7E, 0x00, 0x06, 0x02, 0x52, 0x5E, 0x00, 0x01, 0x00, 0x31, 0x2E, 0x33, 0x30, 0xF7])
            return
        }
        guard f.count >= 7, f[4] == 0x60 else { return }
        handleFS(Array(f[5..<(f.count - 1)]))
    }

    /// Writes sent to the pedal (file-system writes only).
    var fileWrites: [[UInt8]] { sent.filter { Allowlist.fileSystemAccess($0) == .write } }

    // MARK: protocol

    private func reply(_ m: [UInt8]) { delegate?.transport(self, didReceive: m) }
    private func status(_ v: UInt32) { reply([0xF0, 0x52, 0x00, 0x5E, 0x60, 0x03] + FSCodec.u7x5(v) + [0xF7]) }
    private static let notFound: UInt32 = 0xFFFF_FFFA

    private func name(_ b: ArraySlice<UInt8>) -> String { String(bytes: b.prefix { $0 != 0 }, encoding: .ascii) ?? "" }

    private func handleFS(_ b: [UInt8]) {
        switch b[0] {
        case 0x02:
            reply([0xF0, 0x52, 0x00, 0x5E, 0x60, 0x04, 0x02] + [UInt8](repeating: 0, count: 13) + FSCodec.u7x5(4096) + [0xF7])
        case 0x05:
            if let d = pendingData { pendingData = nil; reply(d) } else { status(0) }
        case 0x09:
            reply([0xF0, 0x52, 0x00, 0x5E, 0x60, 0x05, 0x00, 0xF7])
        case 0x29:
            let used = files.values.reduce(0) { $0 + $1.count }
            reply([0xF0, 0x52, 0x00, 0x5E, 0x60, 0x04, 0x29, 0, 0, 0, 0] + FSCodec.u7x5(UInt32(totalBytes))
                  + FSCodec.u7x5(UInt32(totalBytes - used)) + [0xF7])
        case 0x25, 0x26:
            if b[0] == 0x25 { listing = files.keys.sorted() }
            guard !listing.isEmpty else { status(Self.notFound); return }
            let n = listing.removeFirst()
            let nameField = Array(n.utf8.prefix(12)) + [UInt8](repeating: 0, count: 12 - min(12, n.utf8.count))
            reply([0xF0, 0x52, 0x00, 0x5E, 0x60, 0x04, b[0]] + [UInt8](repeating: 0, count: 8) + nameField
                  + [0, 0, 0] + FSCodec.u7x5(UInt32(files[n]!.count)) + [0, 0xF7])
        case 0x27:
            status(0)
        case 0x20:
            let n = name(b[11...])
            let h: [UInt8] = n == EffectIndex.fileName ? [0x54, 0x26, 0x46, 0x28, 0x0E] : [0, 0, 0, 0, 0]
            if b[1] == 0x02 {
                guard files[n] != nil else { status(Self.notFound); return }
                handles[h] = .read(n, 0)
            } else {
                let full = files[n] == nil && files.count >= maxFiles
                var failing = false
                if let k = failWritesFor[n], k > 0 { failWritesFor[n] = k - 1; failing = true }
                handles[h] = .write(n, [], full || failing)
            }
            lastHandle = h
            reply([0xF0, 0x52, 0x00, 0x5E, 0x60, 0x04, 0x20, 0, 0, 4, 0] + h + [0, 0xF7])
        case 0x22:
            let h = Array(b[1..<6]), want = Int(FSCodec.u35(b, 6) ?? 0)
            guard case .read(let n, let pos)? = handles[h], let data = files[n] else { status(Self.notFound); return }
            let block = Array(data[pos..<min(pos + want, data.count)])
            handles[h] = .read(n, pos + block.count)
            var crc = FSCodec.crc32(block) ^ 0xFFFF_FFFF
            if corruptNextReadCRC { corruptNextReadCRC = false; crc ^= 1 }
            reply([0xF0, 0x52, 0x00, 0x5E, 0x60, 0x04, 0x22, 0x00, 0xF7]) // short acknowledgement
            pendingData = [0xF0, 0x52, 0x00, 0x5E, 0x60, 0x04, 0x22, 0x01, 0x00, UInt8(block.count & 0x7F), UInt8(block.count >> 7)]
                + PatchDump.pack7(block) + FSCodec.u7x5(crc) + [0xF7]
        case 0x23:
            let h = Array(b[1..<6]), size = Int(FSCodec.u35(b, 6)!)
            guard case .write(let n, var buf, let failing)? = handles[h] else { status(Self.notFound); return }
            if failing { status(0xFFFF_FFFF); return } // e.g. the 201st file: open works, first block refused
            buf += PatchDump.unpack7(b[11..<(b.count - 5)])
            handles[h] = .write(n, buf, failing)
            reply([0xF0, 0x52, 0x00, 0x5E, 0x60, 0x04, 0x23, 0, 0, 4, 0] + FSCodec.u7x5(UInt32(size)) + [0xF7])
        case 0x21:
            let h = Array(b[1..<6])
            if case .write(let n, let buf, let failing)? = handles[h], !failing { files[n] = buf }
            handles[h] = nil
            status(0)
        case 0x24:
            let n = name(b[1...])
            if files.removeValue(forKey: n) == nil { status(Self.notFound) } else { status(0) }
        default:
            status(0xFFFF_FFFF)
        }
    }
}

/// Builds a minimal but well-formed ZDL: standard 56-byte header, an ELF stub, and the firmware's
/// descriptor table (OnOff, display name, knobs).
func makeZDL(category: UInt8, id: UInt16, name: String, knobs: [String] = ["Gain", "Tone", "Level"], padTo size: Int = 0) -> [UInt8] {
    func le32(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
    func entry(_ s: String, _ word3: UInt32) -> [UInt8] {
        var e = Array(s.utf8.prefix(12)) + [UInt8](repeating: 0, count: 12 - min(12, s.utf8.count))
        e += [UInt8(word3 & 0xFF), UInt8((word3 >> 8) & 0xFF), UInt8((word3 >> 16) & 0xFF), UInt8(word3 >> 24)]
        return e + [UInt8](repeating: 0, count: 0x30 - e.count)
    }
    var elf: [UInt8] = [0x7F, 0x45, 0x4C, 0x46] + [UInt8](repeating: 0, count: 60)
    elf += entry("OnOff", 1) + entry(name, 0xFFFF_FFFF) + knobs.flatMap { entry($0, 2) } + [UInt8](repeating: 0, count: 0x30)
    if size > 76 + elf.count { elf += [UInt8](repeating: 0x11, count: size - 76 - elf.count) }
    var h: [UInt8] = [0, 0, 0, 0] + Array("SIZE".utf8) + le32(8) + le32(56) + le32(elf.count) + Array("INFO".utf8)
    h += [UInt8](repeating: 0, count: 76 - h.count)
    h[60] = category; h[61] = 1; h[64] = UInt8(id & 0xFF); h[65] = UInt8(id >> 8)
    h.replaceSubrange(68..<72, with: Array("1.00".utf8))
    return h + elf
}

/// A stock-like effect menu with the given categories.
func makeIndex(_ cats: [(UInt8, [String])], size: Int = 4108) -> [UInt8] {
    try! EffectIndex(categories: cats.map { EffectIndex.Category(id: $0.0, effects: $0.1) }, fileSize: size).build()
}
