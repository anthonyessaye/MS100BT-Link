// The pedal's file system (effects and effect menu) over SysEx 0x60.
// Protocol and engine logic ported from lopezchau/zoom-ms100bt-bluetooth (MS100BTKit/Pedal.swift, Engine.swift),
// MIT License, Copyright (c) 2026 lopezchau; every operation was verified there on an MS-100BT, firmware 1.30.
// Firmware commands (ROM erase/write, 01/04) and the updater's 60 06 / 61 xx steps are NOT implemented and stay
// blocked by the allowlist.

import Foundation

public struct PedalFile: Codable, Hashable, Sendable {
    public let name: String
    public let size: Int
    public init(name: String, size: Int) { self.name = name; self.size = size }
}

/// Snapshot of the pedal's file system.
public struct PedalFileState: Sendable {
    public let maxWriteSize: Int
    public let totalBytes: Int
    public let freeBytes: Int
    public let files: [PedalFile]
    public let index: EffectIndex
    public let indexRaw: [UInt8]
    public var indexCRC: UInt32 { FSCodec.crc32(indexRaw) }
}

/// A change computed by the app: delete some effects, write some, and (usually) a new effect menu.
public struct EffectChangePlan: Sendable {
    public struct Write: Sendable {
        public let name: String
        public let data: [UInt8]
        /// Community-built effect (stricter size limit).
        public let community: Bool
        public init(name: String, data: [UInt8], community: Bool) { self.name = name; self.data = data; self.community = community }
    }
    /// CRC of the menu the plan was computed from; apply aborts if the pedal's menu changed since.
    public let baseIndexCRC: UInt32
    public let deletes: [String]
    public let writes: [Write]
    public let newIndex: [UInt8]?
    public init(baseIndexCRC: UInt32, deletes: [String], writes: [Write], newIndex: [UInt8]?) {
        self.baseIndexCRC = baseIndexCRC; self.deletes = deletes; self.writes = writes; self.newIndex = newIndex
    }
}

/// Every safety rule for effect changes, as a pure function (tested without a pedal).
/// Rules from lopezchau's hardware findings plus our own extra checks.
public enum EffectPlanValidator {
    public static let maxFiles = 200

    /// - Parameters:
    ///   - files: the pedal's current file list.
    ///   - index: the pedal's current menu.
    ///   - installed: header info of the pedal's effect files (from a full backup); required.
    /// - Returns: problems; empty means the plan may run.
    public static func problems(_ plan: EffectChangePlan, files: [PedalFile], index: EffectIndex,
                                installed: [String: ZDLInfo]?) -> [String] {
        var p: [String] = []
        let names = Set(files.map(\.name))
        guard let installed, !installed.isEmpty else {
            return ["Back up every file on the pedal first: the backup is the safety net, and it is needed to check effect IDs and shared libraries."]
        }

        // Names
        for n in plan.deletes + plan.writes.map(\.name) {
            if Allowlist.protectedFiles.contains(n.uppercased()) { p.append("\(n) is protected and is never changed.") }
            if n == EffectIndex.fileName { p.append("The effect menu is only changed through the plan's new menu.") }
        }
        for w in plan.writes where !FSCodec.isSafeEffectName(w.name) {
            p.append("\(w.name): only 8.3 .ZDL names are allowed (longer names have frozen pedals at boot).")
        }
        for d in plan.deletes where d.uppercased().hasPrefix("CMN_") {
            p.append("\(d) is a shared library other effects need; it is never deleted.")
        }
        if Set(plan.writes.map(\.name)).count != plan.writes.count { p.append("The plan writes the same file twice.") }

        // Each new effect file
        var writeInfos: [String: ZDLInfo] = [:]
        for w in plan.writes {
            guard let z = ZDLInfo.parse(fileName: w.name, data: w.data) else { p.append("\(w.name) is not a valid effect file."); continue }
            writeInfos[w.name] = z
            if z.truncated { p.append("\(w.name) is truncated.") }
            if z.category == 0x0B { p.append("\(z.displayName) needs an expression pedal, which the MS-100BT does not have.") }
            if z.extendedTag == "BCAB" { p.append("\(z.displayName) uses the BCAB header, never tried on an MS-100BT.") }
            if !z.isSharedLibrary && !ZDLCategory.shownOnMS100BT.contains(z.category) {
                p.append("\(z.displayName) is a \(ZDLCategory.name(z.category)) effect, which the MS-100BT menu never shows.")
            }
            if w.community && z.size > ZDLInfo.customSizeLimit {
                p.append("\(z.displayName) is \(z.size) bytes; custom effects above \(ZDLInfo.customSizeLimit) bytes have frozen pedals.")
            }
        }

        // File count
        let after = names.subtracting(plan.deletes).union(plan.writes.map(\.name))
        if after.count > maxFiles { p.append("The pedal holds at most \(maxFiles) files; this change needs \(after.count).") }

        // Effect-ID clashes and shared-library dependencies, against what stays on the pedal.
        let staying = installed.filter { after.contains($0.key) && writeInfos[$0.key] == nil }
        for (n, z) in writeInfos where !z.isSharedLibrary && z.effectID != 0 {
            if let clash = staying.first(where: { $0.value.category == z.category && $0.value.effectID == z.effectID && !$0.value.isSharedLibrary }) {
                p.append("\(z.displayName) (\(n)) uses effect ID \(z.effectID) in \(ZDLCategory.name(z.category)), already used by \(clash.value.displayName) (\(clash.key)).")
            }
            if let other = writeInfos.first(where: { $0.key != n && $0.value.category == z.category && $0.value.effectID == z.effectID && !$0.value.isSharedLibrary }) {
                p.append("\(n) and \(other.key) use the same effect ID.")
            }
        }
        let exports = Set(staying.values.flatMap(\.exports)).union(writeInfos.values.flatMap(\.exports))
        for (n, z) in writeInfos {
            let missing = z.imports.filter { !exports.contains($0) }
            if !missing.isEmpty { p.append("\(n) needs \(missing.joined(separator: ", ")), which no file on the pedal or in this change provides.") }
        }

        // The new menu
        if let raw = plan.newIndex {
            do {
                let idx = try EffectIndex(data: raw)
                if idx.fileSize != index.fileSize { p.append("The new menu has a different size from the pedal's.") }
                let listed = idx.allEffects
                if Set(listed).count != listed.count { p.append("The new menu lists an effect twice.") }
                for n in listed where !after.contains(n) {
                    p.append("The new menu lists \(n), which would not be on the pedal.")
                }
                for c in idx.categories {
                    for n in c.effects where !n.isEmpty {
                        guard let z = writeInfos[n] ?? installed[n] else { continue }
                        if z.isSharedLibrary { p.append("\(n) is a shared library and must not be listed in the menu.") }
                        else if z.category != c.id {
                            p.append(String(format: "%@ is a category %02X effect but would be listed under %02X; that froze an MS-100BT.", n, z.category, c.id))
                        }
                    }
                }
            } catch {
                p.append("The new menu is invalid: \(error)")
            }
        } else if !plan.deletes.filter({ index.allEffects.contains($0) }).isEmpty {
            p.append("Deleting a listed effect needs a new menu without it.")
        }
        return p
    }
}

/// File-system operations on a connected pedal. Main-actor, async, everything through `PedalSession.send`
/// (so through the allowlist and the session's file-system gates).
@MainActor
public final class PedalFileSystem {
    public enum FSError: Error, CustomStringConvertible {
        case noReply(String), rejected(String, [UInt8]), verifyMismatch(String), refused(String), noDevice
        public var description: String {
            switch self {
            case .noReply(let w): return "No reply from the pedal: \(w)."
            case .rejected(let w, let m): return "The pedal rejected \(w): \(m.prefix(16).hex)."
            case .verifyMismatch(let n): return "Verification failed for \(n): what was read back differs from what was written."
            case .refused(let why): return "Refused: \(why)"
            case .noDevice: return "No device ID yet (identify first)."
            }
        }
    }

    public let session: PedalSession
    public var log: (String) -> Void = { _ in }
    /// 0xFFFFFFFA: "not found / end of list".
    static let notFound: UInt32 = 0xFFFF_FFFA

    public init(session: PedalSession) { self.session = session }

    // MARK: session

    /// Opens a file-system session: leaves edit mode (file operations run in normal mode, as verified).
    public func begin() async {
        await session.leaveEditMode()
        session.fileSystemEnabled = true
    }

    public func end() {
        session.fileSystemWritesEnabled = false
        session.fileSystemEnabled = false
    }

    // MARK: low level

    static func isFS(_ m: [UInt8], sub: UInt8, fn: UInt8? = nil) -> Bool {
        m.count >= 7 && m[4] == 0x60 && m[5] == sub && (fn == nil || m[6] == fn!)
    }
    static func isStatus(_ m: [UInt8]) -> Bool { isFS(m, sub: 0x03) }
    static func statusValue(_ m: [UInt8]) -> UInt32? { isStatus(m) ? FSCodec.u35(m, 6) : nil }

    @discardableResult
    func transact(_ body: [UInt8], timeout: TimeInterval = 4, until: @escaping ([UInt8]) -> Bool) async throws -> [[UInt8]] {
        guard let id = session.deviceID else { throw FSError.noDevice }
        session.fileSystemInbox.removeAll()
        try session.send(.fileSystem(deviceID: id, body: body))
        let got: [[UInt8]]? = await session.waitFor(timeout) { [session] in
            session.fileSystemInbox.contains(where: until) ? session.fileSystemInbox : nil
        }
        return got ?? session.fileSystemInbox
    }

    func ack() async throws {
        let r = try await transact([0x05, 0x00], until: Self.isStatus)
        guard r.contains(where: Self.isStatus) else { throw FSError.noReply("ACK") }
    }

    func close(_ handle: [UInt8]) async {
        _ = try? await transact([0x21] + handle, timeout: 3, until: Self.isStatus)
        _ = try? await transact([0x09], timeout: 2) { _ in true }
    }

    // MARK: reads

    public func maxWriteSize() async throws -> Int {
        let r = try await transact([0x02]) { Self.isFS($0, sub: 0x04, fn: 0x02) || Self.isStatus($0) }
        try await ack()
        guard let m = r.first(where: { Self.isFS($0, sub: 0x04, fn: 0x02) }), let v = FSCodec.u35(m, 20), v > 0 else { return 4096 }
        return min(Int(v), Allowlist.maxFileBlock)
    }

    public func diskUsage() async throws -> (total: Int, free: Int) {
        let r = try await transact([0x29, 0, 0, 0, 0, 0]) { Self.isFS($0, sub: 0x04) || Self.isStatus($0) }
        guard let m = r.first(where: { Self.isFS($0, sub: 0x04) }), let t = FSCodec.u35(m, 11), let f = FSCodec.u35(m, 16) else {
            throw FSError.noReply("disk usage")
        }
        return (Int(t), Int(f))
    }

    public func listFiles(progress: (Int) -> Void = { _ in }) async throws -> [PedalFile] {
        var files: [PedalFile] = []
        var op: UInt8 = 0x25
        var retries = 0
        while files.count < EffectPlanValidator.maxFiles + 20 {
            let r = try await transact([op, 0x00, 0x00, 0x2A, 0x00], timeout: 3) { Self.isFS($0, sub: 0x04) || Self.isStatus($0) }
            guard let m = r.first(where: { Self.isFS($0, sub: 0x04) && $0.count > 35 }) else {
                // Only an explicit "end of list" ends the listing; a truncated list would defeat the
                // file-limit check and the pre-delete backup, so a missing reply is retried, then fails.
                if r.contains(where: { Self.statusValue($0) == Self.notFound }) { break }
                retries += 1
                if retries > 3 { throw FSError.noReply("file listing after \(files.count) files") }
                continue
            }
            op = 0x26
            retries = 0
            let name = String(bytes: m[15..<27].prefix { $0 != 0 }, encoding: .ascii) ?? "" // 12-byte field
            if name.isEmpty || files.contains(where: { $0.name == name }) { break }
            files.append(PedalFile(name: name, size: Int(FSCodec.u35(m, 30) ?? 0)))
            progress(files.count)
        }
        try await transact([0x27], timeout: 2, until: Self.isStatus)
        return files
    }

    public func readFile(_ name: String, expectedSize: Int? = nil, chunk: Int = 4096) async throws -> [UInt8] {
        let open: [UInt8] = [0x20, 0x02] + [UInt8](repeating: 0, count: 9) + Array(name.utf8) + [0x00]
        let r = try await transact(open) { Self.isFS($0, sub: 0x04, fn: 0x20) || Self.isStatus($0) }
        guard let om = r.first(where: { Self.isFS($0, sub: 0x04, fn: 0x20) && $0.count > 16 }) else {
            throw FSError.noReply("open \(name) for reading")
        }
        let handle = Array(om[11..<16])
        try await ack()

        // Observed: read → short reply; ACK → data message (byte 7 = 01); ACK → status.
        let isData: ([UInt8]) -> Bool = { Self.isFS($0, sub: 0x04, fn: 0x22) && $0.count >= 17 && $0[7] == 0x01 }
        var data: [UInt8] = []
        do {
            for _ in 0..<10_000 {
                let r1 = try await transact([0x22] + handle + FSCodec.u7x5(UInt32(chunk))) { Self.isFS($0, sub: 0x04, fn: 0x22) || Self.isStatus($0) }
                var m = r1.first(where: isData)
                if m == nil { m = try await transact([0x05, 0x00]) { isData($0) || Self.isStatus($0) }.first(where: isData) }
                guard let m else {
                    if data.isEmpty || (expectedSize.map { data.count < $0 } ?? false) { throw FSError.noReply("read \(name) at \(data.count)") }
                    break
                }
                let length = Int(m[9]) | (Int(m[10]) << 7)
                try await ack()
                if length == 0 { break }
                let block = Array(PatchDump.unpack7(m[11..<(m.count - 6)]).prefix(length))
                guard block.count == length, (FSCodec.u35(m, m.count - 6) ?? 0) ^ 0xFFFF_FFFF == FSCodec.crc32(block) else {
                    throw FSError.rejected("block checksum of \(name)", Array(m.prefix(16)))
                }
                data += block
                if let e = expectedSize, data.count >= e { break }
                if length < chunk { break }
            }
        } catch {
            await close(handle)
            throw error
        }
        await close(handle)
        if let e = expectedSize, data.count != e { throw FSError.verifyMismatch("\(name) (\(data.count) of \(e) bytes)") }
        return data
    }

    // MARK: writes (need session.fileSystemWritesEnabled and session.writesEnabled)

    /// Deletes a file. Returns false if it did not exist.
    @discardableResult
    public func deleteFile(_ name: String) async throws -> Bool {
        let r = try await transact([0x24] + Array(name.utf8) + [0x00], until: Self.isStatus)
        guard let m = r.first(where: Self.isStatus), let v = Self.statusValue(m) else { throw FSError.noReply("delete \(name)") }
        if v == Self.notFound { return false }
        guard v == 0 else { throw FSError.rejected("delete \(name)", m) }
        return true
    }

    /// delete → open for writing → [write block → ACK]… → close → read back and compare.
    public func writeFile(_ name: String, _ data: [UInt8], chunk: Int = 4096,
                          progress: (Int, Int) -> Void = { _, _ in }) async throws {
        let ok: ([UInt8]) -> Bool = { Self.statusValue($0) == 0 }
        _ = try await deleteFile(name)
        let open: [UInt8] = [0x20, 0x01] + [UInt8](repeating: 0, count: 9) + Array(name.utf8) + [0x00]
        let r1 = try await transact(open) { Self.isFS($0, sub: 0x04, fn: 0x20) || Self.isStatus($0) }
        guard let om = r1.first(where: { Self.isFS($0, sub: 0x04, fn: 0x20) && $0.count > 16 }) else {
            throw FSError.noReply("open \(name) for writing")
        }
        let handle = Array(om[11..<16]) // not always 00×5: use what the pedal returns
        try await ack()
        do {
            var off = 0
            while off < data.count {
                let n = min(chunk, data.count - off)
                let block = Array(data[off..<(off + n)])
                let body = [0x23] + handle + FSCodec.u7x5(UInt32(n)) + PatchDump.pack7(block) + FSCodec.u7x5(FSCodec.crc32(block) ^ 0xFFFF_FFFF)
                let rw = try await transact(body, timeout: 6) { Self.isFS($0, sub: 0x04, fn: 0x23) || Self.isStatus($0) || Self.isFS($0, sub: 0x05) }
                if rw.isEmpty { throw FSError.noReply("write block at \(off) of \(name)") }
                if let e = rw.first(where: { Self.isStatus($0) && !ok($0) }) { throw FSError.rejected("write of \(name) at \(off)", e) }
                let ra = try await transact([0x05, 0x00]) { Self.isStatus($0) || Self.isFS($0, sub: 0x04, fn: 0x23) }
                if let e = ra.first(where: { Self.isStatus($0) && !ok($0) }) { throw FSError.rejected("ACK of \(name) at \(off)", e) }
                off += n
                progress(off, data.count)
            }
        } catch {
            await close(handle)
            throw error
        }
        await close(handle)
        let back = try await readFile(name, expectedSize: data.count)
        guard back == data else { throw FSError.verifyMismatch(name) }
    }

    // MARK: high level

    public func readState(progress: (String) -> Void = { _ in }) async throws -> PedalFileState {
        progress("Reading file-system info")
        let maxWrite = try await maxWriteSize()
        let usage = try await diskUsage()
        progress("Listing files")
        let files = try await listFiles { progress("Listing files (\($0))") }
        progress("Reading the effect menu")
        let size = files.first { $0.name == EffectIndex.fileName }?.size
        let raw = try await readFile(EffectIndex.fileName, expectedSize: size)
        return PedalFileState(maxWriteSize: maxWrite, totalBytes: usage.total, freeBytes: usage.free, files: files,
                              index: try EffectIndex(data: raw), indexRaw: raw)
    }

    /// Read-only copy of every file into `dir`, with MANIFEST.txt (name size crc32). Returns effect headers.
    @discardableResult
    public func backup(to dir: URL, files: [PedalFile], progress: (Int, Int, String) -> Void = { _, _, _ in }) async throws -> [String: ZDLInfo] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var manifest = "# name size crc32\n"
        var infos: [String: ZDLInfo] = [:]
        for (i, f) in files.enumerated() {
            progress(i, files.count, f.name)
            let d = try await readFile(f.name, expectedSize: f.size > 0 ? f.size : nil)
            try Data(d).write(to: dir.appendingPathComponent(f.name))
            manifest += String(format: "%@ %d %08x\n", f.name, d.count, FSCodec.crc32(d))
            if let z = ZDLInfo.parse(fileName: f.name, data: d) { infos[f.name] = z }
        }
        try manifest.write(to: dir.appendingPathComponent("MANIFEST.txt"), atomically: true, encoding: .utf8)
        progress(files.count, files.count, "done")
        return infos
    }

    /// Re-checks the pedal, validates the plan, saves copies of everything it will change, then deletes,
    /// writes (each read back) and writes the new menu (read back). If the menu write fails, the old menu
    /// is written back. `installed` = headers of the pedal's effect files from a full backup.
    public func apply(_ plan: EffectChangePlan, installed: [String: ZDLInfo]?, backupDir: URL, dryRun: Bool,
                      progress: (String, Int, Int) -> Void = { _, _, _ in }) async throws {
        let files = try await listFiles()
        let indexSize = files.first { $0.name == EffectIndex.fileName }?.size
        let oldIndex = try await readFile(EffectIndex.fileName, expectedSize: indexSize)
        guard FSCodec.crc32(oldIndex) == plan.baseIndexCRC else {
            throw FSError.refused("the pedal's effect menu changed since it was read; read the pedal again")
        }
        let problems = EffectPlanValidator.problems(plan, files: files, index: try EffectIndex(data: oldIndex), installed: installed)
        guard problems.isEmpty else { throw FSError.refused(problems.joined(separator: " ")) }
        log("Plan OK: delete \(plan.deletes.count), write \(plan.writes.count), menu \(plan.newIndex == nil ? "unchanged" : "updated")")
        if dryRun { log("Dry run: nothing was sent."); return }

        // Safety copies: the old menu and every file that will be deleted or overwritten. Never delete without a copy.
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        try Data(oldIndex).write(to: backupDir.appendingPathComponent(EffectIndex.fileName))
        let names = Set(files.map(\.name))
        for n in Set(plan.deletes).union(Set(plan.writes.map(\.name)).intersection(names)).sorted() {
            let d = try await readFile(n, expectedSize: files.first { $0.name == n }?.size)
            try Data(d).write(to: backupDir.appendingPathComponent(n))
        }

        session.fileSystemWritesEnabled = true
        defer { session.fileSystemWritesEnabled = false }
        let steps = plan.deletes.count + plan.writes.count + (plan.newIndex == nil ? 0 : 1)
        var step = 0
        for n in plan.deletes {
            step += 1; progress("Deleting \(n)", step, steps)
            try await deleteFile(n)
        }
        for w in plan.writes {
            step += 1; progress("Writing \(w.name)", step, steps)
            try await writeFile(w.name, w.data)
            log(String(format: "Verified %@ (%d bytes, CRC32 %08x)", w.name, w.data.count, FSCodec.crc32(w.data)))
        }
        if let newIndex = plan.newIndex {
            step += 1; progress("Writing the effect menu", step, steps)
            do {
                try await writeFile(EffectIndex.fileName, newIndex)
            } catch {
                log("Menu write failed (\(error)); restoring the previous menu")
                var restored = false
                for _ in 0..<3 where !restored {
                    restored = (try? await writeFile(EffectIndex.fileName, oldIndex)) != nil
                }
                throw FSError.refused("writing the new menu failed (\(error)); " +
                                      (restored ? "the previous menu was restored." : "restoring the previous menu ALSO failed: keep the pedal on and retry, the copy is in \(backupDir.path)."))
            }
        }
        progress("All changes applied and verified", steps, steps)
    }
}
