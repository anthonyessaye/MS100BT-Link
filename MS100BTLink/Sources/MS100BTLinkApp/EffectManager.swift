import AppKit
import Foundation
import ZoomCore

/// Effects on the pedal: read its files and menu, back everything up, download library effects,
/// and install/remove effects through a validated, backed-up, read-back-verified change plan.
@MainActor
final class EffectManager: ObservableObject {
    @Published var state: PedalFileState?
    @Published var draft: EffectIndex?
    @Published var pendingAdds: [String: LibraryEffect] = [:]
    @Published var pendingRemovals: Set<String> = []
    @Published var installed: [String: ZDLInfo] = [:]     // headers of the pedal's files (from the latest full backup)
    @Published var lastFullBackup: URL?
    @Published var library: [LibraryEffect] = []
    @Published var busy: String?
    @Published var progress: Double?
    @Published var log: [String] = []
    @Published var alert: String?
    @Published var notice: String?

    weak var link: LinkModel?

    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MS100BTLink")
    }
    static var libraryDir: URL { root.appendingPathComponent("EffectLibrary") }
    static var backupsDir: URL { root.appendingPathComponent("EffectBackups") }

    init() {
        loadLatestBackup()
        scanLibrary()
    }

    var onPedal: Set<String> { Set(state?.files.map(\.name) ?? []) }
    var hasChanges: Bool { !pendingAdds.isEmpty || !pendingRemovals.isEmpty || (draft != nil && draft != state?.index) }
    var filesAfter: Int? {
        guard let s = state else { return nil }
        return Set(s.files.map(\.name)).subtracting(pendingRemovals).union(pendingAdds.keys).count
    }

    // MARK: backups on disk

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    func loadLatestBackup() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: Self.backupsDir, includingPropertiesForKeys: nil)) ?? []
        guard let latest = dirs.filter({ $0.lastPathComponent.hasPrefix("full-") }).max(by: { $0.lastPathComponent < $1.lastPathComponent }),
              FileManager.default.fileExists(atPath: latest.appendingPathComponent("MANIFEST.txt").path) else { return }
        lastFullBackup = latest
        var infos: [String: ZDLInfo] = [:]
        for e in LibraryEffect.scan(folder: latest, source: "Backup", community: false) { infos[e.pedalName] = e.info }
        installed = infos
        EffectCatalog.register(infos.values)
    }

    func scanLibrary() {
        var items: [LibraryEffect] = []
        items += LibraryEffect.scan(folder: Self.libraryDir.appendingPathComponent(EffectSource.stock.key), source: "Stock", community: false)
        for s in EffectSource.community {
            items += LibraryEffect.scan(folder: Self.libraryDir.appendingPathComponent(s.key), source: "Community: \(s.owner)", community: true)
        }
        if let b = lastFullBackup { items += LibraryEffect.scan(folder: b, source: "My pedal backup", community: false) }
        // One entry per pedal file name and content; prefer backups (exact copies of the pedal's own files).
        var seen = Set<String>()
        library = items.filter { seen.insert("\($0.pedalName)#\($0.info.crc32)").inserted }
            .sorted { ($0.info.category, $0.displayName) < ($1.info.category, $1.displayName) }
    }

    // MARK: talking to the pedal

    /// Runs `body` in a file-system session (live updates paused, edit mode left), then hands the pedal back.
    private func withFileSystem(_ title: String, _ body: (PedalFileSystem) async throws -> Void) async {
        guard let link, let session = link.session, link.isOpen, session.deviceID != nil else { alert = "Connect to the pedal first."; return }
        guard busy == nil else { return }
        busy = title
        progress = nil
        link.pauseForFileSystem()
        let fs = PedalFileSystem(session: session)
        fs.log = { [weak self] in self?.log.append($0) }
        await fs.begin()
        do {
            try await body(fs)
        } catch {
            alert = "\(error)"
            log.append("ERROR: \(error)")
        }
        fs.end()
        busy = nil
        progress = nil
        await link.resumeAfterFileSystem()
    }

    func readPedal() async {
        await withFileSystem("Reading the pedal's effects…") { fs in
            let st = try await fs.readState { [weak self] in self?.busy = $0 }
            state = st
            draft = st.index
            pendingAdds = [:]
            pendingRemovals = []
            log.append("Pedal: \(st.files.count)/\(EffectPlanValidator.maxFiles) files, \(st.freeBytes / 1024) KB free")
        }
    }

    /// Copies every file on the pedal to the Mac (about 7 minutes for ~175 files). Read-only.
    func backupAll() async {
        await withFileSystem("Backing up every file on the pedal…") { fs in
            let st: PedalFileState
            if let s = state { st = s } else { st = try await fs.readState(); state = st; draft = st.index }
            let dir = Self.backupsDir.appendingPathComponent("full-" + Self.stamp())
            let infos = try await fs.backup(to: dir, files: st.files) { [weak self] i, n, name in
                self?.busy = "Backing up \(name) (\(i + 1)/\(n))"
                self?.progress = n > 0 ? Double(i) / Double(n) : nil
            }
            lastFullBackup = dir
            installed = infos
            EffectCatalog.register(infos.values)
            scanLibrary()
            notice = "Backed up \(st.files.count) files to \(dir.path)"
        }
    }

    // MARK: library downloads

    /// Downloads every .ZDL from a source's GitHub repository into the library folder (files stay on this Mac).
    func download(_ source: EffectSource) async {
        guard busy == nil else { return }
        busy = "Listing \(source.owner)/\(source.repo)…"
        defer { busy = nil; progress = nil }
        struct Tree: Decodable { struct Entry: Decodable { let path: String; let type: String }; let tree: [Entry] }
        do {
            var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(source.owner)/\(source.repo)/git/trees/HEAD?recursive=1")!)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let files = try JSONDecoder().decode(Tree.self, from: data).tree.filter {
                $0.type == "blob" && $0.path.uppercased().hasSuffix(".ZDL") && (source.folder.isEmpty || $0.path.hasPrefix(source.folder))
                    && (source.community ? !$0.path.contains("stock_zdls/") && !$0.path.contains("firmware/") : true)
            }
            let dest = Self.libraryDir.appendingPathComponent(source.key)
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            for (i, f) in files.enumerated() {
                let name = (f.path as NSString).lastPathComponent
                busy = "Downloading \(name) (\(i + 1)/\(files.count))"
                progress = Double(i) / Double(max(files.count, 1))
                let target = dest.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: target.path) { continue }
                let raw = URL(string: "https://raw.githubusercontent.com/\(source.owner)/\(source.repo)/HEAD/\(f.path)")!
                let (bytes, r) = try await URLSession.shared.data(from: raw)
                guard (r as? HTTPURLResponse)?.statusCode == 200 else { continue }
                try bytes.write(to: target)
            }
            try "Source: \(source.url)\nDownloaded: \(Date())\nNotes: \(source.note)\n"
                .write(to: dest.appendingPathComponent("SOURCE.txt"), atomically: true, encoding: .utf8)
            scanLibrary()
            notice = "Downloaded \(files.count) effects from \(source.label)."
        } catch {
            alert = "Download from \(source.owner)/\(source.repo) failed: \(error.localizedDescription)"
        }
    }

    // MARK: editing the plan

    /// Adds an effect to its own category (the one in its file header; anything else froze a pedal).
    func add(_ item: LibraryEffect) {
        guard var d = draft else { alert = "Read the pedal first."; return }
        let risk = item.risk(onPedal: onPedal)
        if risk.blocksInstall { alert = "\(item.displayName): \(risk.label). It can't be installed."; return }
        if risk == .installed && installed[item.pedalName]?.crc32 == item.info.crc32 { notice = "\(item.displayName) is already on the pedal."; return }
        if !item.info.isSharedLibrary { d.append(item.pedalName, to: item.info.category) }
        draft = d
        pendingRemovals.remove(item.pedalName)
        pendingAdds[item.pedalName] = item
        addDependencies(of: item)
    }

    /// Adds shared libraries (e.g. CMN_BASS.ZDL) that provide symbols the effect needs.
    private func addDependencies(of item: LibraryEffect) {
        let available = Set(installed.filter { onPedal.contains($0.key) && !pendingRemovals.contains($0.key) }.values.flatMap(\.exports))
            .union(pendingAdds.values.flatMap(\.info.exports))
        for sym in item.info.imports where !available.contains(sym) {
            let providers = library.filter { $0.info.isSharedLibrary && $0.info.exports.contains(sym) }
            if let p = providers.first(where: { $0.source == item.source }) ?? providers.first {
                pendingAdds[p.pedalName] = p
                notice = "\(p.pedalName) was added too: \(item.displayName) needs it."
            } else {
                notice = "\(item.displayName) needs \(sym), which no library file provides; it will be refused."
            }
        }
    }

    func remove(_ name: String) {
        guard var d = draft else { return }
        if name.uppercased().hasPrefix("CMN_") { alert = "\(name) is a shared library other effects need; it can't be removed."; return }
        d.remove(name)
        draft = d
        if pendingAdds.removeValue(forKey: name) == nil, onPedal.contains(name) { pendingRemovals.insert(name) }
    }

    func discard() {
        draft = state?.index
        pendingAdds = [:]
        pendingRemovals = []
    }

    func makePlan() throws -> EffectChangePlan {
        guard let s = state, let d = draft else { throw PedalFileSystem.FSError.refused("read the pedal first") }
        let writes = try pendingAdds.values.sorted { $0.pedalName < $1.pedalName }.map {
            EffectChangePlan.Write(name: $0.pedalName, data: [UInt8](try Data(contentsOf: $0.url)), community: $0.community)
        }
        return EffectChangePlan(baseIndexCRC: s.indexCRC, deletes: pendingRemovals.sorted(), writes: writes,
                                newIndex: d == s.index ? nil : try d.build())
    }

    /// Problems found without touching the pedal (shown before the confirmation).
    func planProblems() -> [String] {
        guard let s = state else { return ["Read the pedal first."] }
        do { return EffectPlanValidator.problems(try makePlan(), files: s.files, index: s.index, installed: installed) }
        catch { return ["\(error)"] }
    }

    /// Dry run: re-checks the pedal and validates, sends nothing.
    func dryRun() async {
        await withFileSystem("Checking the change…") { fs in
            try await fs.apply(try makePlan(), installed: installed, backupDir: Self.backupsDir.appendingPathComponent("dry-run"), dryRun: true)
            notice = "Dry run OK: nothing was sent to the pedal."
        }
    }

    /// Applies the plan. Callers must have shown the risk confirmation and unlocked editing.
    func apply() async {
        guard let link, link.editingEnabled else { alert = "Unlock editing first."; return }
        let dir = Self.backupsDir.appendingPathComponent("before-change-" + Self.stamp())
        await withFileSystem("Applying effect changes…") { fs in
            try await fs.apply(try makePlan(), installed: installed, backupDir: dir, dryRun: false) { [weak self] what, step, total in
                self?.busy = what
                self?.progress = total > 0 ? Double(step) / Double(total) : nil
            }
            for item in pendingAdds.values { installed[item.pedalName] = item.info }
            for n in pendingRemovals { installed[n] = nil }
            EffectCatalog.register(installed.values)
            let st = try await fs.readState()
            state = st
            draft = st.index
            pendingAdds = [:]
            pendingRemovals = []
            notice = "All changes applied and verified. Restart the pedal to see them in its menu. Copies of everything changed are in \(dir.path)."
        }
    }

    /// For the assistant: library effects (and what is on the pedal) matching a query.
    func search(_ query: String) -> [[String: Any]] {
        let q = query.lowercased()
        return library.filter {
            q.isEmpty || $0.displayName.lowercased().contains(q) || $0.category.lowercased().contains(q)
                || $0.info.parameters.contains { $0.lowercased().contains(q) }
        }
        .prefix(40)
        .map { e in
            let r = e.risk(onPedal: onPedal)
            return ["name": e.displayName, "file": e.pedalName, "category": e.category, "source": e.source,
                    "knobs": e.info.parameters, "status": r.label, "installable": !r.blocksInstall && r != .installed]
        }
    }
}
