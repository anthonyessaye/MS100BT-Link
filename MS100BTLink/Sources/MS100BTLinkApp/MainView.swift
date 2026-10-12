import SwiftUI
import ZoomCore

struct MainView: View {
    @EnvironmentObject var model: LinkModel
    @EnvironmentObject var midi: MIDIControl
    @State private var selectedSlot: Int
    @State private var sidebar: Sidebar?

    init(initialSlot: Int = 0, initialSidebar: Sidebar? = .patches) {
        _selectedSlot = State(initialValue: initialSlot)
        _sidebar = State(initialValue: initialSidebar)
    }
    @State private var showMIDI = false
    @State private var showLibrary = false
    @State private var lastPatchName: String?

    enum Sidebar: String { case patches = "Patches", assistant = "Assistant" }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(sidebar: $sidebar, showMIDI: $showMIDI)
            Divider().overlay(Theme.stroke)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if let hint = model.hint {
                        Banner(text: hint) { model.hint = nil }.padding([.horizontal, .top], 16)
                    }
                    if model.patch == nil {
                        WelcomeCard()
                    } else {
                        Stage(slot: selectedSlot, openEffects: { showLibrary = true })
                        ChainStrip(selected: $selectedSlot, openEffects: { showLibrary = true })
                    }
                    StatusLine()
                }
                if let side = sidebar {
                    Divider().overlay(Theme.stroke)
                    Group {
                        if side == .assistant {
                            AssistantPanel(close: { sidebar = nil }).frame(width: 380)
                        } else {
                            SidebarView(close: { sidebar = nil }).frame(width: 300)
                        }
                    }
                    .transition(.move(edge: .trailing))
                }
            }
        }
        .background(Theme.background)
        .foregroundStyle(Theme.text)
        .animation(.easeOut(duration: 0.2), value: sidebar)
        .sheet(isPresented: $showLibrary) {
            EffectLibrarySheet(slot: selectedSlot).environmentObject(model)
        }
        .sheet(isPresented: $showMIDI) { MIDISettingsView().environmentObject(midi).environmentObject(model) }
        // Follow the action: when exactly one pedal changes (on/off or effect type) from any
        // source (click, MIDI footswitch, the pedal itself, the assistant), show it on the stage.
        // Patch switches change several slots at once and leave the selection alone.
        .onChange(of: model.patch?.effects.map { "\($0.effectID):\($0.isOn == true)" }) { old, new in
            guard let old, let new, old.count == new.count, model.patch?.name == lastPatchName else {
                lastPatchName = model.patch?.name
                return
            }
            let changed = new.indices.filter { old[$0] != new[$0] }
            if changed.count == 1, model.patch?.effects[changed[0]].isEmpty == false {
                withAnimation(.easeOut(duration: 0.2)) { selectedSlot = changed[0] }
            }
        }
        .onChange(of: model.patch?.effects.map(\.effectID)) {
            if let fx = model.patch?.effects, selectedSlot < fx.count, fx[selectedSlot].isEmpty,
               let first = fx.firstIndex(where: { !$0.isEmpty }), !showLibrary {
                selectedSlot = first
            }
        }
    }
}

// MARK: - top bar

struct TopBar: View {
    @EnvironmentObject var model: LinkModel
    @Environment(\.openWindow) private var openWindow
    @Binding var sidebar: MainView.Sidebar?
    @Binding var showMIDI: Bool

    var body: some View {
        HStack(spacing: 14) {
            ConnectionPill()
            Spacer()
            PatchSwitcher(openList: { sidebar = .patches })
            Spacer()
            if let t = model.patch?.tempo {
                Label("\(t)", systemImage: "metronome")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Theme.panelRaised, in: Capsule())
                    .help("Patch tempo (BPM)")
            }
            Button {
                if model.editingEnabled { model.editingEnabled = false }
                else if model.confirmUnlock() { model.editingEnabled = true }
            } label: {
                Label(model.editingEnabled ? "Editing" : "Locked", systemImage: model.editingEnabled ? "lock.open.fill" : "lock.fill")
            }
            .buttonStyle(PillButtonStyle(active: model.editingEnabled))
            .help(model.editingEnabled ? "Changes are sent to the pedal. Click to lock." : "Unlock to change the pedal from the Mac.")
            Button { sidebar = sidebar == .assistant ? nil : .assistant } label: { Label("AI", systemImage: "sparkles") }
                .buttonStyle(PillButtonStyle(active: sidebar == .assistant))
                .help("Tone assistant: describe a sound, get a patch")
            MIDIModePill(showMIDI: $showMIDI)
            Button { sidebar = sidebar == .patches ? nil : .patches } label: { Image(systemName: "sidebar.right") }
                .buttonStyle(PillButtonStyle(active: sidebar == .patches))
                .help("Patches & effects")
        }
        .padding(.horizontal, 16)
        .padding(.leading, 64) // room for the window buttons
        .frame(height: 56)
        .background(Theme.panel.opacity(0.6))
    }
}

/// MIDI button with the footswitch mode; click the mode to flip Stomp/Patch.
struct MIDIModePill: View {
    @EnvironmentObject var midi: MIDIControl
    @Binding var showMIDI: Bool

    var body: some View {
        HStack(spacing: 0) {
            Button { showMIDI = true } label: { Label("MIDI", systemImage: "pianokeys") }
                .buttonStyle(.plain)
                .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 7)
            Button { midi.mode = midi.mode == .stomp ? .patch : .stomp } label: {
                Text(midi.mode.label.uppercased())
                    .font(.system(size: 10, weight: .heavy)).tracking(0.8)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(midi.mode == .stomp ? Color(white: 0.3) : Theme.accent, in: Capsule())
                    .foregroundStyle(midi.mode == .stomp ? Theme.text : .black)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)
            .help("Footswitch mode: Stomp toggles effects, Patch loads patches. Click to switch.")
        }
        .font(.system(size: 13, weight: .semibold))
        .background(Theme.panelRaised, in: Capsule())
    }
}

struct PillButtonStyle: ButtonStyle {
    var active: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(active ? Theme.accent.opacity(configuration.isPressed ? 0.7 : 1) : Theme.panelRaised.opacity(configuration.isPressed ? 0.6 : 1),
                        in: Capsule())
            .foregroundStyle(active ? Color.black : Theme.text)
    }
}

struct ConnectionPill: View {
    @EnvironmentObject var model: LinkModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Menu {
            if model.isOpen {
                Toggle("Live updates", isOn: Binding(get: { model.liveUpdates }, set: { v in Task { await model.setLiveUpdates(v) } }))
                Toggle("Show changed effect on the pedal's screen", isOn: $model.showOnPedalScreen)
                Button("Reload from pedal") { Task { await model.refresh() } }
                Button("Disconnect") { model.disconnect() }
            } else {
                Button("Connect") { Task { await model.connect() } }
                Button("Pair a new pedal…") { Task { await model.scanAndPair() } }
            }
            Divider()
            Button("Diagnostics…") { openWindow(id: "diagnostics") }
        } label: {
            HStack(spacing: 8) {
                LED(on: model.isOpen, color: model.isOpen ? .green : .gray, size: 9)
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.devices.first(where: { $0.address == model.selectedAddress })?.name ?? "No pedal")
                        .font(.system(size: 13, weight: .semibold))
                    Text(statusText).font(.system(size: 11)).foregroundStyle(Theme.dim)
                }
            }
        } primaryAction: {
            if !model.isOpen { Task { await model.connect() } }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Theme.panelRaised, in: Capsule())
    }

    private var statusText: String {
        if let b = model.busy { return b }
        if model.isOpen { return model.unsolicitedCount > 0 ? "Connected · live" : "Connected" }
        return model.selectedAddress == nil ? "Pair your pedal" : "Click to connect"
    }
}

struct PatchSwitcher: View {
    @EnvironmentObject var model: LinkModel
    var openList: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button { Task { await model.stepPatch(-1) } } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.plain).disabled(!model.canInteract)
            Button(action: openList) {
                HStack(spacing: 10) {
                    Text(model.currentSlot.map { String(format: "%02d", $0 + 1) } ?? "––")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .fixedSize()
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 5))
                        .foregroundStyle(.black)
                    Text(model.patch?.name ?? "Not connected")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .frame(minWidth: 140)
                }
            }
            .buttonStyle(.plain)
            Button { Task { await model.stepPatch(1) } } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.plain).disabled(!model.canInteract)
        }
        .font(.system(size: 15, weight: .bold))
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(Color.black.opacity(0.35), in: Capsule())
    }
}

// MARK: - stage (selected pedal, large)

struct Stage: View {
    @EnvironmentObject var model: LinkModel
    let slot: Int
    var openEffects: () -> Void

    var body: some View {
        let fx = model.patch?.effects[slot]
        ZStack {
            if let fx, !fx.isEmpty {
                VStack(spacing: 16) {
                    BigPedal(fx: fx, changeEffect: openEffects)
                    HStack(spacing: 10) {
                        Button(action: openEffects) {
                            Label("Change effect", systemImage: "arrow.left.arrow.right")
                                .font(.system(size: 14, weight: .bold))
                                .padding(.horizontal, 18).padding(.vertical, 10)
                                .background(Theme.accent, in: Capsule())
                                .foregroundStyle(.black)
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut("e", modifiers: .command)
                        .help("Pick a different effect for slot \(fx.index + 1) (⌘E)")
                        Button { Task { await model.setEffect(slot: fx.index, id: 0) } } label: {
                            Label("Remove", systemImage: "trash")
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .background(Theme.panelRaised, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Empty slot \(fx.index + 1)")
                    }
                    .disabled(!model.canInteract)
                }
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "plus.circle").font(.system(size: 44, weight: .light))
                    Text("Slot \(slot + 1) is empty").font(.title3.weight(.semibold))
                    Button("Choose an effect", action: openEffects)
                        .buttonStyle(PillButtonStyle(active: true))
                        .disabled(!model.canInteract)

                }
                .foregroundStyle(Theme.dim)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

struct BigPedal: View {
    @EnvironmentObject var model: LinkModel
    let fx: PatchDump.EffectSlot
    var changeEffect: () -> Void

    var body: some View {
        let color = Theme.color(for: fx.category)
        let defs = EffectCatalog.effect(for: fx.effectID)?.parameters ?? []
        PedalBody(color: color, corner: 22) {
            VStack(spacing: 18) {
                HStack {
                    LED(on: fx.isOn == true, size: 14)
                    Spacer()
                    Text(fx.category?.uppercased() ?? "")
                        .font(.system(size: 11, weight: .heavy)).tracking(2)
                        .foregroundStyle(.white.opacity(0.75))
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: min(max(fx.parameters.count, 1), 3)),
                          spacing: 18) {
                    ForEach(fx.parameters) { p in
                        control(p, defs.indices.contains(p.index) ? defs[p.index] : nil, color: color)
                    }
                }
                .padding(.vertical, 18).padding(.horizontal, 12)
                .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
                Text(fx.displayName)
                    .font(.system(size: 30, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                Footswitch(on: fx.isOn == true, enabled: model.canInteract) {
                    model.setOn(slot: fx.index, !(fx.isOn ?? false))
                }
            }
            .padding(28)
        }
        .frame(width: 380)
        .frame(maxHeight: 560)
        .saturation(fx.isOn == true ? 1 : 0.2)
        .brightness(fx.isOn == true ? 0 : -0.06)
        .animation(.easeOut(duration: 0.25), value: fx.isOn)
    }

    @ViewBuilder
    private func control(_ p: PatchDump.ParameterValue, _ def: EffectCatalog.Parameter?, color: Color) -> some View {
        let count = def?.valueCount ?? 0
        if let def, count == 2 {
            MiniSwitch(label: p.name, options: [def.display(0) ?? "0", def.display(1) ?? "1"], raw: p.raw,
                       enabled: model.canInteract) { model.setParameter(slot: fx.index, index: p.index, raw: $0) }
        } else {
            Knob(label: p.name, display: p.text, raw: p.raw, count: count, defaultRaw: def?.defaultRaw ?? 0,
                 tint: .white, size: 62, enabled: model.canInteract) {
                model.setParameter(slot: fx.index, index: p.index, raw: $0)
            }
        }
    }
}

struct Footswitch: View {
    let on: Bool
    var enabled = true
    var size: CGFloat = 54
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(RadialGradient(colors: [Color(white: 0.85), Color(white: 0.45)], center: .init(x: 0.4, y: 0.35),
                                             startRadius: 1, endRadius: size * 0.6))
                Circle().strokeBorder(Color.black.opacity(0.5), lineWidth: 2)
                Circle().fill(Color(white: on ? 0.55 : 0.7)).padding(size * 0.22)
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.6), radius: 5, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(on ? "Turn effect off" : "Turn effect on")
    }
}

// MARK: - signal chain

struct ChainStrip: View {
    @EnvironmentObject var model: LinkModel
    @Binding var selected: Int
    var openEffects: () -> Void

    var body: some View {
        ZStack {
            // One cable through the whole chain; pedals that are off lift off it.
            Capsule()
                .fill(LinearGradient(colors: [Color(white: 0.30), Color(white: 0.12)], startPoint: .top, endPoint: .bottom))
                .frame(height: 6)
                .padding(.horizontal, 30)
                .offset(y: -9) // level with the jacks
            HStack(spacing: 0) {
                Jack(label: "IN")
                ForEach(model.patch?.effects ?? []) { fx in
                    Spacer(minLength: 10)
                    MiniPedal(fx: fx, selected: fx.index == selected)
                        .onTapGesture { selected = fx.index; if fx.isEmpty { openEffects() } }
                }
                Spacer(minLength: 10)
                Jack(label: "OUT")
            }
        }
        .padding(.horizontal, 20).padding(.top, 34).padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.35))
    }
}

struct MiniPedal: View {
    @EnvironmentObject var model: LinkModel
    let fx: PatchDump.EffectSlot
    let selected: Bool
    private var off: Bool { !fx.isEmpty && fx.isOn != true }

    var body: some View {
        PedalBody(color: Theme.color(for: fx.category), corner: 10, empty: fx.isEmpty) {
            VStack(spacing: 6) {
                if fx.isEmpty {
                    Image(systemName: "plus").font(.system(size: 20, weight: .light)).foregroundStyle(Theme.dim)
                } else {
                    LED(on: fx.isOn == true, size: 8)
                    Text(fx.displayName)
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.7)
                        .foregroundStyle(.white)
                    Spacer(minLength: 0)
                    Footswitch(on: fx.isOn == true, enabled: model.canInteract, size: 26) {
                        model.setOn(slot: fx.index, !(fx.isOn ?? false))
                    }
                }
            }
            .padding(.vertical, 12).padding(.horizontal, 8)
        }
        .frame(width: 92, height: 118)
        .saturation(off ? 0.12 : 1)
        .brightness(off ? -0.08 : 0)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.white : .clear, lineWidth: 2).padding(-4))
        .opacity(off ? 0.8 : 1)
        .scaleEffect(off ? 0.94 : 1)
        .offset(y: off ? -22 : 0) // lifted off the cable: signal bypasses it
        .shadow(color: .black.opacity(off ? 0.5 : 0), radius: 10, y: 14)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: off)
        .contentShape(Rectangle())
        .help(fx.isEmpty ? "Empty slot \(fx.index + 1)" : "\(fx.displayName) · slot \(fx.index + 1)")
    }
}

struct Jack: View {
    let label: String
    var body: some View {
        VStack(spacing: 4) {
            Circle().fill(Color(white: 0.25)).overlay(Circle().fill(Color.black).padding(5)).frame(width: 22, height: 22)
            Text(label).font(.system(size: 9, weight: .heavy)).foregroundStyle(Theme.dim)
        }
    }
}

// MARK: - sidebar

struct SidebarView: View {
    var close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Patches").font(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(Theme.dim)
            }
            .padding(12)
            PatchList()
        }
        .background(Theme.panel)
    }
}

struct PatchList: View {
    @EnvironmentObject var model: LinkModel
    @State private var query = ""

    var body: some View {
        VStack(spacing: 8) {
            TextField("Search patches", text: $query)
                .textFieldStyle(.roundedBorder).padding(.horizontal, 12)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(0..<Allowlist.patchSlots, id: \.self) { n in
                        let p = model.slots[n] ?? model.library?.patches[n]
                        if query.isEmpty || (p?.name ?? "").localizedCaseInsensitiveContains(query) {
                            PatchRow(n: n, patch: p)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            VStack(alignment: .leading, spacing: 8) {
                if let progress = model.backupProgress {
                    ProgressView(value: Double(progress), total: 50) { Text("Reading patch \(progress) of 50…").font(.caption) }
                } else {
                    Text(model.library.map { "Last backup \($0.date)" } ?? "No backup yet: back up before saving")
                        .font(.caption).foregroundStyle(model.library == nil ? Theme.accent : Theme.dim)
                }
                HStack {
                    Button("Back up all") { Task { await model.backupAll() } }
                        .disabled(!model.canInteract || model.backupProgress != nil)
                    Spacer()
                    Menu("Save to…") {
                        ForEach(0..<Allowlist.patchSlots, id: \.self) { n in
                            let name = (model.slots[n] ?? model.library?.patches[n])?.name ?? "—"
                            Button(String(format: "%02d  %@", n + 1, name)) { Task { await model.store(slot: n) } }
                        }
                    }
                    .fixedSize()
                    .disabled(!model.canInteract || model.library == nil)
                }
                HStack {
                    Button("Export patch…") { model.exportPatch() }.disabled(model.patch == nil)
                    Button("Import…") { Task { await model.importPatch() } }.disabled(!model.canInteract)
                }
                .font(.caption)
            }
            .padding(12)
            .background(Theme.panelRaised)
        }
    }
}

struct PatchRow: View {
    @EnvironmentObject var model: LinkModel
    let n: Int
    let patch: PatchDump?

    var body: some View {
        let active = model.currentSlot == n
        HStack(spacing: 10) {
            Text(String(format: "%02d", n + 1))
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(active ? .black : Theme.dim)
                .frame(width: 26, height: 20)
                .background(active ? Theme.accent : Color.clear, in: RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 3) {
                Text(patch?.name ?? "Unknown").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(patch == nil ? Theme.dim : Theme.text)
                if let patch {
                    HStack(spacing: 3) {
                        ForEach(patch.effects.filter { !$0.isEmpty }) { fx in
                            RoundedRectangle(cornerRadius: 2).fill(Theme.color(for: fx.category))
                                .frame(width: 14, height: 6).opacity(fx.isOn == true ? 1 : 0.4)
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
        .background(active ? Color.white.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { Task { await model.selectPatch(n) } }
        .help(patch.map { $0.effects.filter { !$0.isEmpty }.map(\.displayName).joined(separator: " → ") } ?? "Back up to see this patch")
    }
}

// MARK: - misc

struct WelcomeCard: View {
    @EnvironmentObject var model: LinkModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 48, weight: .light)).foregroundStyle(Theme.accent)
            Text(model.selectedAddress == nil ? "Pair your MS-100BT" : "Connect your MS-100BT")
                .font(.system(size: 26, weight: .bold, design: .rounded))
            Text(model.selectedAddress == nil
                 ? "On the pedal: press knob 1 → MENU → Bluetooth → pairing, then click Pair."
                 : "Turn the pedal on and keep it near your Mac.")
                .foregroundStyle(Theme.dim)
            if let busy = model.busy {
                ProgressView(busy).controlSize(.small)
            } else if model.selectedAddress == nil {
                Button("Pair pedal") { Task { await model.scanAndPair() } }.buttonStyle(PillButtonStyle(active: true))
            } else {
                Button("Connect") { Task { await model.connect() } }.buttonStyle(PillButtonStyle(active: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StatusLine: View {
    @EnvironmentObject var model: LinkModel
    @EnvironmentObject var midi: MIDIControl

    var body: some View {
        HStack(spacing: 14) {
            if model.isOpen {
                Label(model.liveUpdates ? "Live" : "Manual refresh", systemImage: "waveform")
                Text(model.editingEnabled ? "Edits play right away; use Save to keep them" : "Locked: using a control asks to unlock")
            }
            Spacer()
            if let m = midi.lastMessage, let at = midi.lastMessageAt, Date().timeIntervalSince(at) < 5 {
                Label(m, systemImage: "pianokeys")
            }
            if let s = midi.status { Text(s).foregroundStyle(Theme.accent) }
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.dim)
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(Theme.panel.opacity(0.6))
    }
}

struct Banner: View {
    let text: String
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.accent)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(Theme.dim)
        }
        .font(.callout)
        .padding(12)
        .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
    }
}
