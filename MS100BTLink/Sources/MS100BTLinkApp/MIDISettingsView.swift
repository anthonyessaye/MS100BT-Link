import CoreAudioKit
import SwiftUI
import ZoomCore

struct MIDISettingsView: View {
    @EnvironmentObject var midi: MIDIControl
    @EnvironmentObject var model: LinkModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("MIDI Control").font(.system(size: 22, weight: .bold, design: .rounded))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }

            // Sources
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Controllers").font(.headline)
                    Spacer()
                    Button { midi.showBluetoothPanel() } label: { Label("Connect Bluetooth MIDI…", systemImage: "antenna.radiowaves.left.and.right") }
                    Button { midi.connectSources() } label: { Image(systemName: "arrow.clockwise") }.help("Rescan MIDI devices")
                }
                if midi.sources.isEmpty {
                    Text("No MIDI devices. Turn on your Bluetooth MIDI pedal and click Connect Bluetooth MIDI…, or plug in a USB controller.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text(midi.sources.joined(separator: " · ")).font(.callout)
                }
                HStack(spacing: 6) {
                    Circle().fill(recentActivity ? Color.green : Color.gray.opacity(0.4)).frame(width: 8, height: 8)
                    Text(midi.lastMessage.map { "Last: \($0)" } ?? "Press a switch on your controller to test")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            .padding(14).background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))

            // Mode
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Footswitch mode").font(.headline)
                    Text(midi.mode == .stomp ? "Switches turn effects on and off."
                                             : "Switches load patches (set per switch below).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $midi.mode) {
                    ForEach(ControlMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 180)
            }
            .padding(14).background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))

            // Mappings
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Assignments").font(.headline)
                    Spacer()
                    Menu("Add") {
                        Menu("Toggle effect") {
                            ForEach(0..<6, id: \.self) { s in Button("FX \(s + 1)") { midi.addMapping(.toggleEffect(slot: s)) } }
                        }
                        Button("Switch Stomp/Patch mode") { midi.addMapping(.switchMode) }
                        Button("Next patch") { midi.addMapping(.nextPatch) }
                        Button("Previous patch") { midi.addMapping(.previousPatch) }
                        Menu("Load patch") {
                            ForEach(0..<Allowlist.patchSlots, id: \.self) { n in
                                Button(String(format: "%02d", n + 1)) { midi.addMapping(.selectPatch(n)) }
                            }
                        }
                        Menu("Knob (expression / CC)") {
                            ForEach(0..<6, id: \.self) { s in
                                Menu("FX \(s + 1)") {
                                    ForEach(0..<9, id: \.self) { k in
                                        Button(knobName(slot: s, index: k)) { midi.addMapping(.parameter(slot: s, index: k)) }
                                    }
                                }
                            }
                        }
                    }
                    .fixedSize()
                }
                HStack(spacing: 10) {
                    Text("Switch").frame(width: 190, alignment: .leading)
                    Text("Stomp mode").frame(width: 170, alignment: .leading)
                    Text("Patch mode").frame(width: 150, alignment: .leading)
                    Text("Learn: tap the switch once, quickly").frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(midi.mappings) { m in row(m) }
                    }
                }
                .frame(minHeight: 220)
                Toggle("Program Change messages load the matching patch (PC 0 → patch 01)", isOn: $midi.programChangeLoadsPatch)
                    .font(.callout)
            }
            .padding(14).background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))

            if !model.editingEnabled {
                Label("MIDI control changes the pedal, so it only works while editing is unlocked.", systemImage: "lock.fill")
                    .font(.callout).foregroundStyle(.orange)
            }
        }
        .padding(22)
        .frame(width: 820, height: 700)
    }

    private var recentActivity: Bool {
        midi.lastMessageAt.map { Date().timeIntervalSince($0) < 2 } ?? false
    }

    private func knobName(slot: Int, index: Int) -> String {
        if let fx = model.patch?.effects[slot], !fx.isEmpty, index < fx.parameters.count {
            return "\(fx.displayName) · \(fx.parameters[index].name)"
        }
        return "Knob \(index + 1)"
    }

    private func row(_ m: MIDIMapping) -> some View {
        let learning = midi.learning == m.id
        return HStack(spacing: 10) {
            HStack(spacing: 6) {
                Button(learning ? "Cancel" : "Learn") { midi.learning = learning ? nil : m.id }
                    .buttonStyle(.borderedProminent).tint(learning ? .orange : .accentColor)
                    .controlSize(.small)
                Group {
                    if learning { Text("Press it now…").foregroundStyle(.orange) }
                    else {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(m.trigger?.label ?? "Not assigned").foregroundStyle(m.trigger == nil ? .secondary : .primary)
                            if m.trigger != nil, !m.action.isContinuous, m.trigger?.kind != .program {
                                Text(m.behavior.map { $0 == .momentary ? "momentary" : "latching" } ?? "type: detect on next press")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .font(.caption.monospaced())
            }
            .frame(width: 190, alignment: .leading)

            Text(actionLabel(m.action))
                .fontWeight(midi.mode == .stomp ? .semibold : .regular)
                .foregroundStyle(midi.mode == .stomp ? .primary : .secondary)
                .frame(width: 170, alignment: .leading).lineLimit(1)

            Group {
                if m.action.isContinuous {
                    Text("same").foregroundStyle(.secondary)
                } else {
                    Menu(m.patchAction.map(actionLabel) ?? "Same as Stomp") {
                        Button("Same as Stomp") { midi.setPatchAction(m.id, nil) }
                        Divider()
                        Menu("Load patch") {
                            ForEach(0..<Allowlist.patchSlots, id: \.self) { n in
                                Button(patchName(n)) { midi.setPatchAction(m.id, .selectPatch(n)) }
                            }
                        }
                        Button("Next patch") { midi.setPatchAction(m.id, .nextPatch) }
                        Button("Previous patch") { midi.setPatchAction(m.id, .previousPatch) }
                        Button("Switch Stomp/Patch mode") { midi.setPatchAction(m.id, .switchMode) }
                        Button("Nothing") { midi.setPatchAction(m.id, .nothing) }
                    }
                    .fixedSize()
                    .fontWeight(midi.mode == .patch ? .semibold : .regular)
                }
            }
            .frame(width: 150, alignment: .leading)

            Spacer()
            Menu {
                if !m.action.isContinuous {
                    Picker("Switch type", selection: Binding(get: { m.behavior ?? .auto }, set: { midi.setBehavior(m.id, $0) })) {
                        ForEach(SwitchBehavior.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Divider()
                }
                Button("Clear assignment") { midi.clearTrigger(m.id) }.disabled(m.trigger == nil)
                Button("Remove", role: .destructive) { midi.remove(m.id) }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .font(.callout)
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(learning ? Color.orange.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private func patchName(_ n: Int) -> String {
        let name = (model.slots[n] ?? model.library?.patches[n])?.name
        return String(format: "%02d", n + 1) + (name.map { "  \($0)" } ?? "")
    }

    private func actionLabel(_ a: MIDIAction) -> String {
        if case .parameter(let s, let i) = a { return "FX \(s + 1): \(knobName(slot: s, index: i))" }
        if case .toggleEffect(let s) = a, let fx = model.patch?.effects[s], !fx.isEmpty { return "Toggle FX \(s + 1) (\(fx.displayName))" }
        if case .selectPatch(let n) = a { return "Load " + patchName(n) }
        return a.label
    }
}

