import Foundation

/// Patch backups on disk: one folder per backup under
/// `~/Library/Application Support/MS100BTLink/Backups/<yyyyMMdd-HHmmss>/`,
/// holding `patch-NN.syx` (the raw 146-byte dump) for each slot read.
public struct PatchLibrary {
    public let folder: URL
    public private(set) var patches: [Int: PatchDump]

    public static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MS100BTLink/Backups")
    }

    /// Writes a new backup folder.
    public static func save(_ patches: [Int: PatchDump]) throws -> PatchLibrary {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        let folder = root.appendingPathComponent(f.string(from: Date()))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (slot, p) in patches {
            try Data(p.raw).write(to: folder.appendingPathComponent(fileName(slot)))
        }
        return PatchLibrary(folder: folder, patches: patches)
    }

    /// Most recent backup, if any.
    public static func latest() -> PatchLibrary? {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        guard let newest = dirs.filter({ $0.hasDirectoryPath }).max(by: { $0.lastPathComponent < $1.lastPathComponent }) else { return nil }
        return load(newest)
    }

    public static func load(_ folder: URL) -> PatchLibrary? {
        var out: [Int: PatchDump] = [:]
        for slot in 0..<Allowlist.patchSlots {
            let url = folder.appendingPathComponent(fileName(slot))
            if let data = try? Data(contentsOf: url), let p = PatchDump.decode([UInt8](data)) { out[slot] = p }
        }
        return out.isEmpty ? nil : PatchLibrary(folder: folder, patches: out)
    }

    /// Reads a single `.syx` patch file (e.g. one exported earlier).
    public static func readPatchFile(_ url: URL) -> PatchDump? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return PatchDump.decode([UInt8](data))
    }

    public var isComplete: Bool { patches.count == Allowlist.patchSlots }
    public var date: String { folder.lastPathComponent }

    static func fileName(_ slot: Int) -> String { String(format: "patch-%02d.syx", slot + 1) }
}
