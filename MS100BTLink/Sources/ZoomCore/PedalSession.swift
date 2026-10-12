import Foundation

/// One connection to the pedal: owns the transport, reassembles and decodes inbound
/// MIDI, logs both directions, and keeps the latest decoded state.
/// Main-thread only (IOBluetooth delivers callbacks on the main run loop).
@MainActor
public final class PedalSession: TransportDelegate {
    public enum State: Equatable {
        case idle, opening, open, closed
        case failed(String)

        public var label: String {
            switch self {
            case .idle: return "Idle"
            case .opening: return "Opening…"
            case .open: return "Open"
            case .closed: return "Closed"
            case .failed(let why): return "Failed: \(why)"
            }
        }
    }

    public enum Event {
        case state(State)
        case sent([UInt8], label: String)
        case received([UInt8])
        case decoded(MIDIEvent, DecodedMessage)
        case blocked(AllowlistViolation)
    }

    public let transport: Transport
    public let log: WireLog?
    public var onEvent: ((Event) -> Void)?

    public private(set) var state: State = .idle
    public private(set) var openedAt: Date?
    public private(set) var bytesIn = 0
    public private(set) var bytesOut = 0

    public private(set) var identity: IdentityReply?
    public private(set) var identityAt: Date?
    public private(set) var program = ProgramInfo()
    public private(set) var programAt: Date?
    public private(set) var patch: PatchDump?
    public private(set) var patchAt: Date?
    public private(set) var lastResponse: DecodedMessage?
    public private(set) var lastResponseAt: Date?
    public private(set) var lastRxAt: Date?
    /// Set once a plain 0x29 went unanswered but the edit-mode-bracketed one worked
    /// (true for the MS-100BT, session 1). Later reads skip the plain attempt.
    public private(set) var patchNeedsEditMode = false
    /// Edit mode (0x50) currently held open; 0x51 is sent before the channel closes.
    public private(set) var editModeActive = false
    /// Write lock. Writes (patch select, edits, send, store) are refused while false.
    public var writesEnabled = false
    /// File-system reads (listing, backup) are refused unless a file-system session is open.
    public var fileSystemEnabled = false
    /// File writes/deletes additionally need this (set only while an approved change plan runs)
    /// and `writesEnabled`.
    public var fileSystemWritesEnabled = false
    /// Replies to file-system commands, collected for `PedalFileSystem`.
    public var fileSystemInbox: [[UInt8]] = []
    /// Inbound Zoom messages that arrived without a matching request (pedal pushes).
    public private(set) var unsolicitedCount = 0
    private var patchRequestedAt: Date?

    private var framer = SysExFramer()

    public init(transport: Transport, log: WireLog?) {
        self.transport = transport
        self.log = log
        transport.delegate = self
    }

    /// Device ID learned from the identity reply. Never guessed.
    public var deviceID: UInt8? { identity?.deviceID }

    public func open() {
        setState(.opening)
        log?.note("opening \(transport.displayName)")
        do {
            try transport.open()
        } catch {
            log?.note("open failed: \(error)")
            setState(.failed("\(error)"))
        }
    }

    public func close() {
        transport.close()
        editModeActive = false
        if state != .closed { setState(.closed) }
    }

    /// Leaves edit mode (0x51) if it is held, gives the write a moment to go out, then closes.
    public func closeGracefully() async {
        if editModeActive { await leaveEditMode() }
        close()
    }

    public struct WriteLocked: Error, CustomStringConvertible {
        public let label: String
        public var description: String { "Write refused (editing is locked): \(label)" }
    }

    public func send(_ message: Message) throws {
        let bytes = message.bytes
        if message.isWrite && !writesEnabled {
            log?.note("write refused (locked): \(message.label)")
            throw WriteLocked(label: message.label)
        }
        switch Allowlist.fileSystemAccess(bytes) {
        case .read? where !fileSystemEnabled:
            log?.note("file-system access refused (not in a file-system session): \(message.label)")
            throw WriteLocked(label: message.label + " (file-system session closed)")
        case .write? where !(fileSystemWritesEnabled && writesEnabled):
            log?.note("file write refused (locked): \(message.label)")
            throw WriteLocked(label: message.label + " (file writes locked)")
        default: break
        }
        if case .requestCurrentPatch = message { patchRequestedAt = Date() }
        do {
            try transport.send(bytes)
        } catch let v as AllowlistViolation {
            log?.note(v.description)
            onEvent?(.blocked(v))
            throw v
        }
        bytesOut += bytes.count
        log?.record(.tx, bytes, note: message.label)
        onEvent?(.sent(bytes, label: message.label))
    }

    private func setState(_ s: State) {
        state = s
        onEvent?(.state(s))
    }

    // MARK: TransportDelegate

    public func transportDidOpen(_ transport: Transport) {
        openedAt = Date()
        log?.note("channel open: \(transport.displayName)")
        setState(.open)
    }

    public func transport(_ transport: Transport, didFailToOpen error: Error) {
        log?.note("open failed: \(error)")
        setState(.failed("\(error)"))
    }

    public func transport(_ transport: Transport, didReceive bytes: [UInt8]) {
        bytesIn += bytes.count
        lastRxAt = Date()
        log?.record(.rx, bytes)
        onEvent?(.received(bytes))
        for event in framer.feed(bytes) {
            let decoded = DecodedMessage.decode(event)
            apply(event, decoded)
            if decoded != .other { log?.note("decoded: \(decoded.summary)") }
            onEvent?(.decoded(event, decoded))
        }
    }

    public func transportDidClose(_ transport: Transport) {
        log?.note("channel closed")
        setState(.closed)
    }

    private func apply(_ event: MIDIEvent, _ decoded: DecodedMessage) {
        let now = Date()
        switch decoded {
        case .identity(let i): identity = i; identityAt = now
        case .patch(let p):
            if patchRequestedAt.map({ now.timeIntervalSince($0) > 4 }) ?? true { noteUnsolicited("patch dump") }
            patchRequestedAt = nil
            patch = p; patchAt = now
        case .response: lastResponse = decoded; lastResponseAt = now
        case .zoom(let z) where z.opcode == 0x31 && z.payload.count >= 4:
            // The pedal reporting a knob/switch change: mirror it into the local patch.
            noteUnsolicited("parameter change")
            if let current = patch {
                var e = PatchEdit(current)
                let slot = Int(z.payload[0]), param = Int(z.payload[1])
                let value = Int(z.payload[2]) | Int(z.payload[3]) << 7
                if slot < PatchDump.effectCount {
                    if param == 0 { e.setOn(slot: slot, value == 1) }
                    else if param >= 2 { e.setParameter(slot: slot, index: param - 2, raw: value) }
                    if let d = e.decoded { patch = d; patchAt = now }
                }
            }
        case .zoom(let z) where z.opcode == 0x60:
            if case .sysex(let m) = event { fileSystemInbox.append(m) }
        case .zoom, .programChange, .controlChange:
            noteUnsolicited(decoded.summary)
        default: break
        }
        if case .channel(let c) = event, program.apply(c) { programAt = now }
    }
}

// MARK: - Probe sequences (allowlisted reads only)

extension PedalSession {
    /// Polls `get` every 50 ms until it returns non-nil or `timeout` passes.
    /// Sleeping on the main actor lets the run loop deliver Bluetooth callbacks.
    public func waitFor<T>(_ timeout: TimeInterval, _ get: () -> T?) async -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let v = get() { return v }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return get()
    }

    public func sleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    public func waitUntilOpen(timeout: TimeInterval = 15) async -> Bool {
        let s: State? = await waitFor(timeout) {
            switch state {
            case .open, .failed, .closed: return state
            default: return nil
            }
        }
        return s == .open
    }

    private func noteUnsolicited(_ what: String) {
        unsolicitedCount += 1
        log?.note("unsolicited from pedal: \(what)")
    }

    private func fresh<T>(_ value: T?, at: Date?, after t: Date) -> T? {
        guard let value, let at, at >= t else { return nil }
        return value
    }

    /// Identity request (updater form), then the broadcast form if nothing came back.
    public func identify(timeout: TimeInterval = 2) async -> IdentityReply? {
        for m in [Message.identityRequest, .identityRequestBroadcast] {
            let t = Date()
            guard (try? send(m)) != nil else { return nil }
            if let r = await waitFor(timeout, { fresh(identity, at: identityAt, after: t) }) { return r }
        }
        return nil
    }

    /// `0x33`. Needs the device ID from `identify()`.
    public func readProgram(timeout: TimeInterval = 2) async -> ProgramInfo? {
        guard let id = deviceID else { log?.note("readProgram skipped: no device ID yet"); return nil }
        let t = Date()
        guard (try? send(.requestCurrentProgram(deviceID: id))) != nil else { return nil }
        return await waitFor(timeout) { fresh(program, at: programAt, after: t) }
    }

    /// Holds edit mode open (0x50) until `leaveEditMode` or `closeGracefully`.
    public func enterEditMode() async {
        guard let id = deviceID, !editModeActive else { return }
        guard (try? send(.editModeOn(deviceID: id))) != nil else { return }
        editModeActive = true
        await sleep(0.3)
    }

    public func leaveEditMode() async {
        guard let id = deviceID, editModeActive else { return }
        try? send(.editModeOff(deviceID: id))
        editModeActive = false
        await sleep(0.2) // let the write complete before anything closes the channel
    }

    /// `0x29`; if silent and `allowEditMode`, retry bracketed by `0x50`/`0x51` (0x51 always sent).
    /// While edit mode is held, a single `0x29` is sent.
    public func readPatch(timeout: TimeInterval = 3, allowEditMode: Bool = true) async -> PatchDump? {
        guard let id = deviceID else { log?.note("readPatch skipped: no device ID yet"); return nil }
        var t = Date()
        if editModeActive {
            guard (try? send(.requestCurrentPatch(deviceID: id))) != nil else { return nil }
            return await waitFor(timeout) { fresh(patch, at: patchAt, after: t) }
        }
        if !(patchNeedsEditMode && allowEditMode) {
            guard (try? send(.requestCurrentPatch(deviceID: id))) != nil else { return nil }
            if let p = await waitFor(timeout, { fresh(patch, at: patchAt, after: t) }) { return p }
            guard allowEditMode else { return nil }
            log?.note("no 0x28 reply; retrying inside edit mode")
        }

        guard (try? send(.editModeOn(deviceID: id))) != nil else { return nil }
        defer { try? send(.editModeOff(deviceID: id)) }
        await sleep(0.3)
        t = Date()
        guard (try? send(.requestCurrentPatch(deviceID: id))) != nil else { return nil }
        let p = await waitFor(timeout) { fresh(patch, at: patchAt, after: t) }
        if p != nil { patchNeedsEditMode = true }
        return p
    }

    // MARK: writes (each needs writesEnabled; every frame still passes the allowlist)

    public enum WriteError: Error, CustomStringConvertible {
        case noDevice, noPatch, invalid(String), notConfirmed(String)
        public var description: String {
            switch self {
            case .noDevice: return "No device ID yet (identify first)."
            case .noPatch: return "No current patch read yet."
            case .invalid(let why): return "Refused: \(why)"
            case .notConfirmed(let why): return "Pedal did not confirm: \(why)"
            }
        }
    }

    /// Live edit (0x31) of the active patch; the local copy is updated immediately.
    public func liveEdit(slot: Int, param: Int, value: Int) throws {
        guard let id = deviceID else { throw WriteError.noDevice }
        try send(.parameterEdit(deviceID: id, slot: slot, param: param, value: value))
        if let current = patch {
            var e = PatchEdit(current)
            if param == 0 { e.setOn(slot: slot, value == 1) } else { e.setParameter(slot: slot, index: param - 2, raw: value) }
            if let d = e.decoded { patch = d }
        }
    }

    /// Sends a whole edited patch (0x28) to the edit buffer, then re-reads it to confirm.
    @discardableResult
    public func sendPatch(_ edit: PatchEdit) async throws -> PatchDump {
        guard deviceID != nil else { throw WriteError.noDevice }
        guard let d = edit.decoded else { throw WriteError.invalid("patch does not decode") }
        if let problem = d.validationProblem { throw WriteError.invalid(problem) }
        try send(.sendPatch(frame: edit.frame))
        await sleep(0.3)
        guard let back = await readPatch() else { throw WriteError.notConfirmed("no patch dump after send") }
        guard back.unpacked == d.unpacked else {
            log?.note("send-patch mismatch: sent \(edit.frame.hex) got \(back.raw.hex)")
            throw WriteError.notConfirmed("read-back differs from what was sent")
        }
        return back
    }

    /// Selects patch 0…49 (C0) and reads it.
    public func selectPatch(_ n: Int) async throws -> PatchDump? {
        try send(.selectPatch(n))
        await sleep(0.3)
        return await readPatch()
    }

    /// Stores the active patch into slot 0…49 (0x32). Callers must confirm with the user first.
    public func storePatch(slot: Int) async throws {
        guard let id = deviceID else { throw WriteError.noDevice }
        try send(.storePatch(deviceID: id, slot: slot))
        await sleep(1.0) // pedal shows "Storing…"
    }

    /// Reads all 50 patches by selecting each one, then reselects the patch that was active.
    /// Switching patches discards unsaved edits on the pedal (if Auto Save is off).
    public func readAllPatches(progress: (Int, PatchDump?) -> Void) async throws -> [Int: PatchDump] {
        guard writesEnabled else { throw WriteLocked(label: "patch select for backup") }
        let original = patch
        var out: [Int: PatchDump] = [:]
        for n in 0..<Allowlist.patchSlots {
            let p = try await selectPatch(n)
            if let p { out[n] = p }
            progress(n, p)
        }
        if let original, let back = out.first(where: { $0.value.unpacked == original.unpacked })?.key {
            _ = try await selectPatch(back)
        } else if let original, let byName = out.first(where: { $0.value.name == original.name })?.key {
            _ = try await selectPatch(byName)
        }
        return out
    }

    /// Highest tier reached in this session (Tier 1 = device + SDP is decided by the caller).
    public var tierReached: Int {
        if patch != nil { return 4 }
        if identity != nil { return 3 }
        if openedAt != nil { return 2 }
        return 1
    }
}
