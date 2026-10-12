import AppKit
import CoreAudioKit
import CoreMIDI
import Foundation
import ZoomCore

/// One incoming MIDI 1.0 channel message.
struct MIDIInputMessage: Equatable {
    enum Kind: String, Codable { case cc, note, program }
    let kind: Kind
    let channel: Int      // 1…16
    let number: Int       // CC#, note#, or program#
    let value: Int        // CC value / velocity; 127 for program change

    /// Footswitch press: CC ≥ 64, note-on with velocity, or any program change.
    var isPress: Bool { value >= 64 || (kind == .note && value > 0) || kind == .program }

    var label: String {
        switch kind {
        case .cc: return "CC \(number) = \(value) · ch \(channel)"
        case .note: return "Note \(number) vel \(value) · ch \(channel)"
        case .program: return "Program \(number) · ch \(channel)"
        }
    }
}

struct MIDITrigger: Codable, Hashable {
    var kind: MIDIInputMessage.Kind
    var channel: Int
    var number: Int

    func matches(_ m: MIDIInputMessage) -> Bool { m.kind == kind && m.channel == channel && m.number == number }

    var label: String {
        switch kind {
        case .cc: return "CC \(number) · ch \(channel)"
        case .note: return "Note \(number) · ch \(channel)"
        case .program: return "PC \(number) · ch \(channel)"
        }
    }
}

enum MIDIAction: Codable, Hashable {
    case toggleEffect(slot: Int)
    case nextPatch
    case previousPatch
    case selectPatch(Int)
    case parameter(slot: Int, index: Int)
    case switchMode
    case nothing

    var isContinuous: Bool { if case .parameter = self { return true }; return false }

    var label: String {
        switch self {
        case .toggleEffect(let s): return "Toggle FX \(s + 1)"
        case .nextPatch: return "Next patch"
        case .previousPatch: return "Previous patch"
        case .selectPatch(let n): return "Load patch \(n + 1)"
        case .parameter(let s, let i): return "FX \(s + 1) knob \(i + 1)"
        case .switchMode: return "Switch Stomp/Patch mode"
        case .nothing: return "Nothing"
        }
    }
}

/// How a switch reports presses. Detected once (on the first press after Learn) and saved.
enum SwitchBehavior: String, Codable, CaseIterable {
    /// Not stored: means "detect on the next press".
    case auto
    /// Momentary: high value = press, low value = release (ignored).
    case momentary
    /// Latching: every message (high or low) is a press.
    case latching

    var label: String {
        switch self {
        case .auto: return "Detect on next press"
        case .momentary: return "Momentary (press/release)"
        case .latching: return "Latching (alternates on/off)"
        }
    }
}

enum ControlMode: String, Codable, CaseIterable {
    case stomp, patch
    var label: String { self == .stomp ? "Stomp" : "Patch" }
}

struct MIDIMapping: Codable, Identifiable, Hashable {
    var id = UUID()
    var trigger: MIDITrigger?
    /// What the switch does in Stomp mode.
    var action: MIDIAction
    /// What it does in Patch mode; nil = same as Stomp mode.
    var patchAction: MIDIAction?
    /// nil = auto.
    var behavior: SwitchBehavior?

    func action(in mode: ControlMode) -> MIDIAction {
        mode == .patch ? (patchAction ?? action) : action
    }
}

/// Listens to every MIDI source and turns mapped messages into pedal actions.
@MainActor
final class MIDIControl: ObservableObject {
    @Published var sources: [String] = []
    @Published var mappings: [MIDIMapping] { didSet { save() } }
    /// Program Change n (1-based on the controller: 0…49) loads patch n+1 directly.
    @Published var programChangeLoadsPatch: Bool { didSet { UserDefaults.standard.set(programChangeLoadsPatch, forKey: "midiPCLoadsPatch") } }
    @Published var learning: UUID?
    @Published var lastMessage: String?
    @Published var lastMessageAt: Date?
    @Published var status: String?
    @Published var mode: ControlMode { didSet { UserDefaults.standard.set(mode.rawValue, forKey: "midiMode") } }
    /// Mappings whose switch type is being detected: time of the first press.
    /// A release within `detectWindow` → momentary; none → latching. Then saved for good.
    private var detecting: [UUID: Date] = [:]
    private let detectWindow: TimeInterval = 0.4

    weak var model: LinkModel?
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()

    /// Six switches: FX 1–6 in Stomp mode, patches 01–06 in Patch mode; plus previous/next.
    static let defaultMappings: [MIDIMapping] =
        (0..<6).map { MIDIMapping(action: .toggleEffect(slot: $0), patchAction: .selectPatch($0)) } +
        [MIDIMapping(action: .previousPatch), MIDIMapping(action: .nextPatch)]

    init() {
        if let data = UserDefaults.standard.data(forKey: "midiMappings"),
           let saved = try? JSONDecoder().decode([MIDIMapping].self, from: data) {
            mappings = saved
        } else {
            mappings = Self.defaultMappings
        }
        programChangeLoadsPatch = UserDefaults.standard.object(forKey: "midiPCLoadsPatch") as? Bool ?? true
        mode = ControlMode(rawValue: UserDefaults.standard.string(forKey: "midiMode") ?? "") ?? .stomp
        // v2: give pre-existing "Toggle FX n" switches a Patch-mode default (load patch n).
        if !UserDefaults.standard.bool(forKey: "midiMappingsV2") {
            for i in mappings.indices where mappings[i].patchAction == nil {
                if case .toggleEffect(let slot) = mappings[i].action { mappings[i].patchAction = .selectPatch(slot) }
            }
            UserDefaults.standard.set(true, forKey: "midiMappingsV2")
        }
        start()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(mappings) { UserDefaults.standard.set(data, forKey: "midiMappings") }
    }

    // MARK: CoreMIDI

    private func start() {
        let s = MIDIClientCreateWithBlock("MS-100BT Link" as CFString, &client) { [weak self] note in
            guard note.pointee.messageID == .msgSetupChanged else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.connectSources() } }
        }
        guard s == noErr else { status = "CoreMIDI unavailable (\(s))"; return }
        let p = MIDIInputPortCreateWithProtocol(client, "input" as CFString, ._1_0, &port) { [weak self] list, _ in
            let messages = MIDIControl.parse(list)
            guard !messages.isEmpty else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { messages.forEach { self?.receive($0) } } }
        }
        guard p == noErr else { status = "Could not open MIDI input (\(p))"; return }
        connectSources()
    }

    func connectSources() {
        var names: [String] = []
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            MIDIPortConnectSource(port, src, nil) // reconnecting an already connected source is harmless
            var name: Unmanaged<CFString>?
            if MIDIObjectGetStringProperty(src, kMIDIPropertyDisplayName, &name) == noErr, let n = name?.takeRetainedValue() {
                names.append(n as String)
            }
        }
        sources = names
    }

    /// MIDI 1.0 channel-voice messages from a UMP event list (message type 0x2).
    nonisolated static func parse(_ list: UnsafePointer<MIDIEventList>) -> [MIDIInputMessage] {
        var out: [MIDIInputMessage] = []
        for packet in list.unsafeSequence() {
            let count = Int(packet.pointee.wordCount)
            withUnsafeBytes(of: packet.pointee.words) { raw in
                let words = raw.bindMemory(to: UInt32.self)
                for w in words.prefix(count) where w >> 28 == 0x2 {
                    let status = Int((w >> 16) & 0xFF), d1 = Int((w >> 8) & 0x7F), d2 = Int(w & 0x7F)
                    let ch = (status & 0x0F) + 1
                    switch status & 0xF0 {
                    case 0xB0: out.append(MIDIInputMessage(kind: .cc, channel: ch, number: d1, value: d2))
                    case 0x90: out.append(MIDIInputMessage(kind: .note, channel: ch, number: d1, value: d2))
                    case 0x80: out.append(MIDIInputMessage(kind: .note, channel: ch, number: d1, value: 0))
                    case 0xC0: out.append(MIDIInputMessage(kind: .program, channel: ch, number: d1, value: 127))
                    default: break
                    }
                }
            }
        }
        return out
    }

    // MARK: mapping

    private func receive(_ m: MIDIInputMessage) {
        lastMessage = m.label
        lastMessageAt = Date()

        if let id = learning {
            guard m.isPress || m.kind == .cc else { return } // ignore note-offs while learning
            if let i = mappings.firstIndex(where: { $0.id == id }) {
                mappings[i].trigger = MIDITrigger(kind: m.kind, channel: m.channel, number: m.number)
                mappings[i].behavior = nil
                if m.kind != .program, m.value >= 64 { startDetecting(id) } // learn press doubles as detection
            }
            learning = nil
            return
        }

        let hits = mappings.filter { $0.trigger?.matches(m) == true }
        if hits.isEmpty, m.kind == .program, programChangeLoadsPatch, m.number < Allowlist.patchSlots {
            perform(.selectPatch(m.number), m)
            return
        }
        let modeAtPress = mode // a mode switch in this batch must not affect the other hits
        for h in hits {
            let action = h.action(in: modeAtPress)
            if action.isContinuous { perform(action, m); continue }
            if isPress(m, h) { perform(action, m) }
        }
    }

    /// Whether this message is a footswitch press (vs. the release of a momentary switch).
    private func isPress(_ m: MIDIInputMessage, _ h: MIDIMapping) -> Bool {
        if m.kind == .program { return true }
        let high = m.value >= 64
        switch h.behavior {
        case .momentary?: return high
        case .latching?: return true
        case .auto?, nil:
            if high {
                startDetecting(h.id)
                return true
            }
            if let t0 = detecting[h.id], Date().timeIntervalSince(t0) < detectWindow {
                setDetected(h.id, .momentary) // quick release of the first press
                return false
            }
            setDetected(h.id, .latching) // a low value on its own is a latching "off" press
            return true
        }
    }

    private func startDetecting(_ id: UUID) {
        guard detecting[id] == nil else { return }
        detecting[id] = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + detectWindow + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.detecting[id] != nil else { return }
                self.setDetected(id, .latching) // no release followed the press
            }
        }
    }

    private func setDetected(_ id: UUID, _ b: SwitchBehavior) {
        detecting[id] = nil
        if let i = mappings.firstIndex(where: { $0.id == id }), mappings[i].behavior == nil {
            mappings[i].behavior = b
        }
    }

    private func perform(_ action: MIDIAction, _ m: MIDIInputMessage) {
        if case .switchMode = action { mode = mode == .stomp ? .patch : .stomp; status = nil; return }
        if case .nothing = action { return }
        guard let model else { return }
        guard model.canInteract else {
            status = "Received \(m.label), but the pedal isn't connected."
            return
        }
        if !model.editingEnabled {
            // Same as clicking a control while locked: ask once, then run this press.
            NSApp.activate(ignoringOtherApps: true)
            status = "Unlock editing to use MIDI control."
            _ = model.requireUnlock(retry: { [weak self] in self?.perform(action, m) })
            return
        }
        status = nil
        switch action {
        case .toggleEffect(let slot):
            guard let fx = model.patch?.effects[slot], !fx.isEmpty else { return }
            model.setOn(slot: slot, !(fx.isOn ?? false))
        case .nextPatch:
            Task { await model.stepPatch(1) }
        case .previousPatch:
            Task { await model.stepPatch(-1) }
        case .selectPatch(let n):
            Task { await model.selectPatch(n) }
        case .switchMode, .nothing:
            break
        case .parameter(let slot, let index):
            guard let fx = model.patch?.effects[slot], !fx.isEmpty,
                  let def = EffectCatalog.effect(for: fx.effectID)?.parameters, index < def.count else { return }
            let count = def[index].valueCount
            let raw = Int((Double(m.value) / 127 * Double(count - 1)).rounded())
            model.setParameter(slot: slot, index: index, raw: raw)
        }
    }

    private var bluetoothWindow: CABTLEMIDIWindowController?

    /// Apple's Bluetooth LE MIDI pairing window (the one Audio MIDI Setup uses).
    /// New BLE MIDI devices show up as sources once connected there.
    func showBluetoothPanel() {
        if bluetoothWindow == nil { bluetoothWindow = CABTLEMIDIWindowController() }
        bluetoothWindow?.showWindow(nil)
        bluetoothWindow?.window?.makeKeyAndOrderFront(nil)
    }

    func addMapping(_ action: MIDIAction) {
        let m = MIDIMapping(action: action)
        mappings.append(m)
        learning = m.id
    }

    func remove(_ id: UUID) { mappings.removeAll { $0.id == id } }

    func setPatchAction(_ id: UUID, _ a: MIDIAction?) {
        if let i = mappings.firstIndex(where: { $0.id == id }) { mappings[i].patchAction = a }
    }

    func setBehavior(_ id: UUID, _ b: SwitchBehavior) {
        detecting[id] = nil
        if let i = mappings.firstIndex(where: { $0.id == id }) { mappings[i].behavior = b == .auto ? nil : b }
    }
    func clearTrigger(_ id: UUID) {
        if let i = mappings.firstIndex(where: { $0.id == id }) { mappings[i].trigger = nil }
    }
}
