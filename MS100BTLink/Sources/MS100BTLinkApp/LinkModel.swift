import AppKit
import Foundation
import IOBluetooth
import ZoomCore

struct ConsoleLine: Identifiable {
    enum Kind { case tx, rx, info, decoded, blocked }
    let id = UUID()
    let time: Date
    let kind: Kind
    let text: String
    let bytes: [UInt8]
}

@MainActor
final class LinkModel: ObservableObject {
    @Published var devices: [DeviceSummary] = []
    @Published var selectedAddress: String?
    @Published var records: [ServiceRecordInfo] = []
    @Published var sdpDone = false
    @Published var state: PedalSession.State = .idle
    @Published var identity: IdentityReply?
    @Published var program: ProgramInfo?
    @Published var programNoReply = false
    @Published var patch: PatchDump?
    @Published var openedAt: Date?
    @Published var rssi: Int?
    @Published var console: [ConsoleLine] = []
    @Published var busy: String?
    @Published var hint: String?
    @Published var now = Date()
    /// Write lock mirrored into the session. Restored at launch if the user chose to keep it unlocked.
    @Published var editingEnabled = UserDefaults.standard.bool(forKey: "editingUnlocked") {
        didSet {
            session?.writesEnabled = editingEnabled
            UserDefaults.standard.set(editingEnabled && rememberUnlock, forKey: "editingUnlocked")
        }
    }
    /// "Keep editing unlocked when the app restarts" (checkbox in the unlock warning).
    var rememberUnlock: Bool {
        get { UserDefaults.standard.object(forKey: "rememberUnlock") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "rememberUnlock") }
    }
    /// Hold edit mode while connected and keep the patch current (pushes, else 2 s polling).
    @Published var liveUpdates = true
    @Published var library: PatchLibrary? = PatchLibrary.latest()
    /// What the pedal holds per slot, as last read this session (backup or select).
    @Published var slots: [Int: PatchDump] = [:]
    @Published var backupProgress: Int?
    @Published var unsolicitedCount = 0
    /// Patch slot 0…49 that is active on the pedal, when known (selected from here, or
    /// matched against the backup / slots read this session; the pedal never reports it).
    @Published var currentSlot: Int?
    private var pollTimer: Timer?
    private var pendingEdits: [String: Task<Void, Never>] = [:]
    private var verifyTask: Task<Void, Never>?

    private(set) var session: PedalSession?
    private(set) var log: WireLog?
    private var ticker: Timer?

    /// For the app delegate's quit hook.
    static weak var shared: LinkModel?

    init() {
        LinkModel.shared = self
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        refreshDevices()
    }

    var selectedDevice: IOBluetoothDevice? {
        selectedAddress.flatMap { IOBluetoothDevice(addressString: $0) }
    }

    var isOpen: Bool { state == .open }

    var tier: Int {
        if patch != nil { return 4 }
        if identity != nil { return 3 }
        if openedAt != nil { return 2 }
        if selectedAddress != nil && sdpDone { return 1 }
        return 0
    }

    var uptime: String {
        guard let openedAt, isOpen else { return "—" }
        let s = Int(now.timeIntervalSince(openedAt))
        return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }

    private func tick() {
        now = Date()
        if isOpen, let d = selectedDevice, d.isConnected() {
            let r = Int(d.rawRSSI())
            rssi = r == 127 ? nil : r
        }
    }

    // MARK: devices

    func refreshDevices() {
        devices = Discovery.pairedDevices().map(Discovery.summary)
        if selectedAddress == nil || !devices.contains(where: { $0.address == selectedAddress }) {
            selectedAddress = Discovery.pairedDevices().first(where: Discovery.looksLikeZoom)?.addressString
                ?? devices.first?.address
        }
    }

    func scanAndPair() async {
        busy = "Scanning (pedal must be in pairing mode)…"
        defer { busy = nil }
        let found = await Discovery.inquiry(seconds: 15)
        info("Inquiry found \(found.count) device(s): " + found.map { $0.nameOrAddress ?? "?" }.joined(separator: ", "))
        guard let pedal = found.first(where: Discovery.looksLikeZoom) else {
            hint = "No ZOOM / MS-100BT device found. Enter pairing mode on the pedal: knob 1 → MENU → Bluetooth → pairing."
            return
        }
        busy = "Pairing with \(pedal.nameOrAddress ?? "pedal")…"
        let r = await Discovery.pair(pedal)
        if r == kIOReturnSuccess {
            info("Paired with \(pedal.nameOrAddress ?? "?")")
            refreshDevices()
            selectedAddress = pedal.addressString
        } else {
            hint = "Pairing failed (\(ioReturnString(r))). Try pairing once from System Settings → Bluetooth."
        }
    }

    func querySDP() async {
        guard let d = selectedDevice else { return }
        busy = "SDP query…"
        defer { busy = nil }
        let r = await Discovery.sdpQuery(d)
        if r != kIOReturnSuccess { info("SDP query status \(ioReturnString(r)); showing cached records") }
        records = Discovery.serviceRecords(d)
        sdpDone = true
        ensureLog()?.note("SDP: " + records.map(\.summary).joined(separator: " | "))
        info("SDP: \(records.count) record(s)")
        if !records.contains(where: \.isSerialPort) {
            hint = "No Serial Port (0x1101) record — the pedal may only expose iAP. See handoff §7."
        }
        if !isOpen, d.isConnected() { d.closeConnection() }
    }

    // MARK: connection

    @discardableResult
    private func ensureLog() -> WireLog? {
        if log == nil { log = try? WireLog(directory: WireLog.appDirectory, prefix: "app") }
        return log
    }

    func connect() async {
        guard let d = selectedDevice else { return }
        hint = nil
        if !sdpDone || !records.contains(where: \.isSerialPort) { await querySDP() }
        guard records.contains(where: \.isSerialPort) else { return }

        busy = "Opening RFCOMM…"
        defer { busy = nil }
        let s = PedalSession(transport: RFCOMMTransport(device: d), log: ensureLog())
        s.onEvent = { [weak self] e in self?.handle(e) }
        session = s
        s.open()
        guard await s.waitUntilOpen() else {
            hint = "Channel did not open. If this keeps happening, turn Bluetooth off and on (the macOS RFCOMM stack can stall)."
            s.close()
            return
        }
        openedAt = s.openedAt
        s.writesEnabled = editingEnabled
        await refresh()
        if liveUpdates { await startLive() }
    }

    func disconnect() {
        stopPolling()
        let s = session
        session = nil
        rssi = nil
        Task { await s?.closeGracefully() }
    }

    /// Quit path: stop polling, send 0x51 if edit mode is held, close.
    func shutdown() async {
        stopPolling()
        let s = session
        session = nil
        await s?.closeGracefully()
    }

    // MARK: live updates

    func setLiveUpdates(_ on: Bool) async {
        liveUpdates = on
        if on { await startLive() } else {
            stopPolling()
            await session?.leaveEditMode()
        }
    }

    private func startLive() async {
        guard let s = session, isOpen, s.deviceID != nil else { return }
        await s.enterEditMode()
        info("Live updates on: edit mode held; polling every 2 s unless the pedal pushes changes")
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollTick() }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollTick() {
        guard let s = session, isOpen, liveUpdates, busy == nil, backupProgress == nil,
              pendingEdits.isEmpty, verifyTask == nil else { return }
        if let last = s.lastRxAt, Date().timeIntervalSince(last) < 1.5 { return }
        Task {
            if let p = await s.readPatch(timeout: 1.5) { patch = p }
        }
    }

    /// Re-sends only allowlisted reads: identity → program → patch.
    func refresh() async {
        guard let s = session, isOpen else { return }
        busy = "Identity request…"
        defer { busy = nil }
        guard let id = await s.identify() else {
            hint = "No identity reply. Everything received is in the console and log."
            return
        }
        guard id.isKnownMS100BTID else {
            hint = "Device ID \(id.deviceID.hex) is not 5D/5E; Zoom requests are blocked by the allowlist."
            return
        }
        programNoReply = true // 0x33 is never answered by the MS-100BT (session 2)
        busy = "Patch request…"
        if let p = await s.readPatch() { patch = p }
    }

    // MARK: editing (every action needs the Editing lock open)

    var canEdit: Bool { editingEnabled && canInteract }
    /// Controls are live whenever a patch is loaded; while locked, using one asks to unlock.
    var canInteract: Bool { isOpen && patch != nil && session?.deviceID != nil }

    private var unlockPromptOpen = false

    /// The unlock warning. Returns true if the user chose Unlock.
    func confirmUnlock() -> Bool {
        let a = NSAlert()
        a.messageText = "Unlock editing?"
        a.informativeText = """
        Changes you make here are sent to the pedal right away.

        • If the pedal's Auto Save is on, they are saved into the patch immediately.
        • If it's off, they last until you Save or switch patches.
        • Saving to a slot overwrites it (a backup is required first).

        The app never touches the pedal's firmware.
        """
        a.alertStyle = .warning
        a.addButton(withTitle: "Unlock")
        a.addButton(withTitle: "Cancel")
        a.showsSuppressionButton = true
        a.suppressionButton?.title = "Keep editing unlocked when the app restarts"
        a.suppressionButton?.state = rememberUnlock ? .on : .off
        let ok = a.runModal() == .alertFirstButtonReturn
        if ok { rememberUnlock = a.suppressionButton?.state == .on }
        return ok
    }

    /// True if editing is unlocked. Otherwise asks to unlock (once at a time) and, if the
    /// user agrees, runs `retry`, which repeats the action they just tried.
    func requireUnlock(retry: @escaping () -> Void) -> Bool {
        if editingEnabled { return true }
        guard canInteract, !unlockPromptOpen else { return false }
        unlockPromptOpen = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                defer { self.unlockPromptOpen = false }
                if self.confirmUnlock() {
                    self.editingEnabled = true
                    retry()
                }
            }
        }
        return false
    }

    /// Runs a write action and reports failures in the console and banner.
    private func write(_ label: String, _ action: (PedalSession) async throws -> Void) async {
        guard let s = session, isOpen else { hint = "Connect first."; return }
        guard editingEnabled else { hint = "Unlock editing first (Device panel)."; return }
        do {
            try await action(s)
            patch = s.patch
        } catch {
            hint = "\(label) failed: \(error)"
            info("\(label) failed: \(error)")
        }
    }

    func setOn(slot: Int, _ on: Bool) {
        guard requireUnlock(retry: { [weak self] in self?.setOn(slot: slot, on) }) else { return }
        Task { await write("FX\(slot + 1) on/off") { s in try s.liveEdit(slot: slot, param: 0, value: on ? 1 : 0) }; scheduleVerify() }
    }

    /// Parameter change from a slider or picker; coalesced so a drag sends at most ~15 edits/s.
    func setParameter(slot: Int, index: Int, raw: Int) {
        guard requireUnlock(retry: { [weak self] in self?.setParameter(slot: slot, index: index, raw: raw) }) else { return }
        if var e = patch.map(PatchEdit.init) { // optimistic UI
            e.setParameter(slot: slot, index: index, raw: raw)
            patch = e.decoded ?? patch
        }
        let key = "\(slot).\(index)"
        pendingEdits[key]?.cancel()
        pendingEdits[key] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 70_000_000)
            guard !Task.isCancelled, let self else { return }
            self.pendingEdits[key] = nil
            await self.write("FX\(slot + 1) parameter") { s in try s.liveEdit(slot: slot, param: index + 2, value: raw) }
            self.scheduleVerify()
        }
    }

    /// After live edits settle, re-read the patch. If the pedal didn't take an edit
    /// (the MS-50G doc says 0x31 may only work on slots 1–3), resend the whole patch.
    private func scheduleVerify() {
        verifyTask?.cancel()
        let expected = patch
        verifyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled, let self, let s = self.session, let expected else { return }
            defer { self.verifyTask = nil }
            guard self.pendingEdits.isEmpty else { return }
            guard let back = await s.readPatch(timeout: 2) else { return }
            self.patch = back
            if back.unpacked != expected.unpacked {
                self.info("Pedal state differs from the edit; resending the whole patch (0x28)")
                await self.write("Resend patch") { s in try await s.sendPatch(PatchEdit(expected)) }
            }
        }
    }

    func setEffect(slot: Int, id: UInt32) async {
        guard requireUnlock(retry: { [weak self] in Task { await self?.setEffect(slot: slot, id: id) } }) else { return }
        guard var e = patch.map(PatchEdit.init) else { return }
        e.setEffect(slot: slot, id: id, on: patch?.effects[slot].isOn ?? true)
        busy = "Sending patch…"; defer { busy = nil }
        await write("Change effect") { s in try await s.sendPatch(e) }
    }

    func rename(_ name: String) async {
        guard requireUnlock(retry: { [weak self] in Task { await self?.rename(name) } }) else { return }
        guard var e = patch.map(PatchEdit.init) else { return }
        e.setName(name)
        busy = "Renaming…"; defer { busy = nil }
        await write("Rename") { s in try await s.sendPatch(e) }
    }

    func setTempo(_ bpm: Int) async {
        guard requireUnlock(retry: { [weak self] in Task { await self?.setTempo(bpm) } }) else { return }
        guard var e = patch.map(PatchEdit.init) else { return }
        e.setTempo(bpm)
        busy = "Setting tempo…"; defer { busy = nil }
        await write("Tempo") { s in try await s.sendPatch(e) }
    }

    func selectPatch(_ n: Int) async {
        guard requireUnlock(retry: { [weak self] in Task { await self?.selectPatch(n) } }) else { return }
        busy = "Selecting patch \(n + 1)…"; defer { busy = nil }
        await write("Select patch") { s in
            if let p = try await s.selectPatch(n) { self.slots[n] = p }
            self.currentSlot = n
        }
    }

    func stepPatch(_ delta: Int) async {
        guard requireUnlock(retry: { [weak self] in Task { await self?.stepPatch(delta) } }) else { return }
        let n = ((currentSlot ?? inferSlot() ?? 0) + delta + Allowlist.patchSlots) % Allowlist.patchSlots
        await selectPatch(n)
    }

    /// Best guess of the active slot by comparing the current patch with known slots.
    func inferSlot() -> Int? {
        guard let p = patch else { return nil }
        let known = slots.merging(library?.patches ?? [:]) { live, _ in live }
        if let exact = known.first(where: { $0.value.unpacked == p.unpacked })?.key { return exact }
        let byName = known.filter { $0.value.name == p.name }
        return byName.count == 1 ? byName.first?.key : nil
    }

    /// Reads all 50 patches into a new backup folder.
    func backupAll() async {
        guard requireUnlock(retry: { [weak self] in Task { await self?.backupAll() } }) else { return }
        guard confirm("Back up all 50 patches?",
                      "The pedal switches through every patch (about 30 s) and returns to the current one. " +
                      "Unsaved edits on the pedal are lost if its Auto Save is off.") else { return }
        backupProgress = 0
        defer { backupProgress = nil }
        await write("Backup") { s in
            let start = self.currentSlot ?? self.inferSlot()
            let all = try await s.readAllPatches { n, p in
                self.backupProgress = n + 1
                if let p { self.slots[n] = p }
            }
            self.library = try PatchLibrary.save(all)
            self.currentSlot = start ?? self.inferSlot()
            self.info("Backed up \(all.count) patches to \(self.library?.folder.path ?? "?")")
            if all.count < Allowlist.patchSlots { self.hint = "Only \(all.count) of 50 patches were read; the backup is incomplete." }
        }
    }

    /// Stores the active patch into `slot`. Requires a backup that holds that slot.
    func store(slot: Int) async {
        guard requireUnlock(retry: { [weak self] in Task { await self?.store(slot: slot) } }) else { return }
        guard let lib = library, let old = lib.patches[slot] else {
            hint = "Back up all patches first: storing overwrites patch \(slot + 1)."
            return
        }
        let target = slots[slot] ?? old
        guard confirm("Overwrite patch \(slot + 1)?",
                      "Patch \(slot + 1) \"\(target.name ?? "?")\" will be replaced by \"\(patch?.name ?? "?")\". " +
                      "A copy is in the backup from \(lib.date).") else { return }
        busy = "Storing…"; defer { busy = nil }
        await write("Store") { s in
            try await s.storePatch(slot: slot)
            if let p = s.patch { self.slots[slot] = p }
            self.info("Stored \"\(s.patch?.name ?? "?")\" into patch \(slot + 1)")
        }
    }

    func exportPatch() {
        guard let p = patch else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (p.name ?? "patch") + ".syx"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(p.raw).write(to: url) } catch { hint = "Export failed: \(error.localizedDescription)" }
    }

    /// Loads a .syx patch file into the pedal's edit buffer (not stored until you Store it).
    func importPatch() async {
        guard requireUnlock(retry: { [weak self] in Task { await self?.importPatch() } }) else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "syx") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let file = PatchLibrary.readPatchFile(url), let id = session?.deviceID else {
            hint = "Not a valid MS-100BT patch file."; return
        }
        if let problem = file.validationProblem { hint = "Patch file refused: \(problem)"; return }
        var e = PatchEdit(file)
        if file.deviceID != id { e = PatchEdit(PatchDump.decode([0xF0, 0x52, 0x00, id] + file.raw.dropFirst(4))!) }
        busy = "Loading patch…"; defer { busy = nil }
        await write("Load patch file") { s in try await s.sendPatch(e) }
    }

    private func confirm(_ title: String, _ text: String) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.alertStyle = .warning
        a.addButton(withTitle: "Continue")
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    private func handle(_ e: PedalSession.Event) {
        switch e {
        case .state(let st):
            state = st
            if st == .closed { info("Channel closed") }
        case .sent(let b, let label):
            append(.tx, label, b)
        case .received(let b):
            append(.rx, "", b)
        case .decoded(_, let d):
            switch d {
            case .identity(let i): identity = i
            case .patch(let p): if pendingEdits.isEmpty { patch = p }
            case .programChange: program = session?.program
            case .zoom(let z) where z.opcode == 0x31:
                if pendingEdits.isEmpty { patch = session?.patch }
            case .other: return
            default: break
            }
            unsolicitedCount = session?.unsolicitedCount ?? 0
            append(.decoded, d.summary, [])
        case .blocked(let v):
            append(.blocked, v.description, v.frame)
        }
    }

    private func info(_ s: String) { append(.info, s, []) }

    private func append(_ kind: ConsoleLine.Kind, _ text: String, _ bytes: [UInt8]) {
        console.append(ConsoleLine(time: Date(), kind: kind, text: text, bytes: bytes))
        if console.count > 5000 { console.removeFirst(console.count - 5000) }
    }

    // MARK: console actions

    func copyHex() {
        let text = console.filter { !$0.bytes.isEmpty }
            .map { ($0.kind == .tx ? "→ " : "← ") + $0.bytes.hex }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func exportLog() {
        guard let url = log?.url else { hint = "Nothing logged yet."; return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.copyItem(at: url, to: dest) }
        catch { hint = "Export failed: \(error.localizedDescription)" }
    }

    func revealLogs() {
        NSWorkspace.shared.activateFileViewerSelecting([log?.url ?? WireLog.appDirectory])
    }
}
