import SwiftUI
import ZoomCore

/// Developer view: connection details, SDP, identity, and the raw console.
struct DiagnosticsView: View {
    @EnvironmentObject var model: LinkModel

    var body: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let hint = model.hint { HintBanner(text: hint) { model.hint = nil } }
                    DevicePanel()
                    InfoPanel()
                }
                .padding(16)
            }
            .frame(minWidth: 340, idealWidth: 380)
            ConsolePanel().frame(minWidth: 460)
        }
        .frame(minWidth: 860, minHeight: 560)
    }
}

/// Connect / Refresh / Disconnect, kept in the window (macOS toolbars drop button tints).
struct ActionRow: View {
    @EnvironmentObject var model: LinkModel

    var body: some View {
        HStack(spacing: 10) {
            if model.isOpen {
                Button { Task { await model.refresh() } } label: {
                    Label("Refresh", systemImage: "arrow.triangle.2.circlepath").frame(minWidth: 110)
                }
                .tint(.blue)
                .disabled(model.busy != nil)
                Button { model.disconnect() } label: {
                    Label("Disconnect", systemImage: "xmark.circle").frame(minWidth: 110)
                }
                .tint(.red)
            } else {
                Button { Task { await model.connect() } } label: {
                    Label("Connect", systemImage: "dot.radiowaves.left.and.right").frame(minWidth: 110)
                }
                .tint(.green)
                .disabled(model.selectedAddress == nil || model.busy != nil)
                .keyboardShortcut("k")
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        if let why = disabledReason {
            Text(why).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var disabledReason: String? {
        if model.busy != nil { return "Working… buttons come back when this step finishes." }
        if !model.isOpen && model.selectedAddress == nil { return "Pick or pair a pedal to connect." }
        return nil
    }
}

struct HintBanner: View {
    let text: String
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct Panel<Content: View>: View {
    let title: String
    var tier: Int? = nil
    /// Fade the content until the tier is reached. Off for panels that hold controls.
    var dimsContent = true
    @ViewBuilder var content: Content
    @EnvironmentObject var model: LinkModel

    var body: some View {
        let reached = tier.map { model.tier >= $0 } ?? true
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                if let tier {
                    Text("Tier \(tier)")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(reached ? Color.green.opacity(0.2) : Color.secondary.opacity(0.15), in: Capsule())
                }
            }
            content.opacity(reached || !dimsContent ? 1 : 0.4)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct Field: View {
    let label: String
    let value: String
    var mono = false
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
            Text(value).font(mono ? .body.monospaced() : .body).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

struct DevicePanel: View {
    @EnvironmentObject var model: LinkModel

    var body: some View {
        Panel(title: "Device", tier: 1, dimsContent: false) {
            ActionRow()
            Divider()
            HStack {
                Picker("Pedal", selection: $model.selectedAddress) {
                    if model.devices.isEmpty { Text("No paired devices").tag(String?.none) }
                    ForEach(model.devices) { d in Text("\(d.name)  ·  \(d.address)").tag(Optional(d.address)) }
                }
                .labelsHidden()
                .disabled(model.isOpen)
                Button { model.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload paired devices")
            }
            HStack {
                Button("Scan & Pair…") { Task { await model.scanAndPair() } }
                Button("SDP Query") { Task { await model.querySDP() } }
                    .disabled(model.selectedAddress == nil)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.busy != nil || model.isOpen)
            if model.isOpen {
                Text("Disconnect to scan, pair or query SDP.").font(.caption).foregroundStyle(.secondary)
            }

            if let d = model.devices.first(where: { $0.address == model.selectedAddress }) {
                Field(label: "Name", value: d.name)
                Field(label: "Address", value: d.address, mono: true)
                Field(label: "Paired", value: d.isPaired ? "yes" : "no")
            }
            Divider()
            Toggle(isOn: $model.editingEnabled) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.editingEnabled ? "Editing unlocked" : "Editing locked").fontWeight(.semibold)
                    Text("Allows patch select, live edits, sending and storing patches.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .tint(.orange)
            Toggle(isOn: Binding(get: { model.liveUpdates }, set: { v in Task { await model.setLiveUpdates(v) } })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Live updates").fontWeight(.semibold)
                    Text(model.unsolicitedCount > 0 ? "Pedal is pushing changes (\(model.unsolicitedCount) so far)"
                                                    : "Holds edit mode; re-reads every 2 s if the pedal stays quiet")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            Divider()
            Field(label: "Channel", value: model.state.label)
            Field(label: "Uptime", value: model.uptime, mono: true)
            Field(label: "RSSI", value: model.rssi.map { "\($0) dBm" } ?? "—")

            if model.sdpDone {
                DisclosureGroup("SDP services (\(model.records.count))") {
                if model.records.isEmpty { Text("No records").foregroundStyle(.secondary) }
                ForEach(model.records) { r in
                    DisclosureGroup {
                        ForEach(r.attributes) { a in
                            Text(String(format: "0x%04X  ", a.id) + a.value)
                                .font(.caption.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } label: {
                        Text(r.summary).font(.callout.monospaced())
                            .foregroundStyle(r.isSerialPort ? .primary : .secondary)
                    }
                }
                }
                .font(.subheadline)
            }
        }
    }
}

struct InfoPanel: View {
    @EnvironmentObject var model: LinkModel

    var body: some View {
        VStack(spacing: 16) {
            Panel(title: "Identity", tier: 3) {
                Field(label: "Device ID", value: model.identity.map { "0x" + $0.deviceID.hex } ?? "—", mono: true)
                Field(label: "Firmware", value: model.identity?.version ?? "—")
                Field(label: "Mode byte", value: model.identity.map { String($0.mode) } ?? "—")
                Field(label: "Program", value: model.program?.displayString
                      ?? (model.programNoReply ? "not reported by the pedal" : "—"))
            }
        }
    }
}

struct ConsolePanel: View {
    @EnvironmentObject var model: LinkModel
    private let timeFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Console").font(.headline)
                Spacer()
                Button("Copy as Hex") { model.copyHex() }
                Button("Export Log…") { model.exportLog() }
                Button { model.revealLogs() } label: { Image(systemName: "folder") }.help("Show logs in Finder")
                Button { model.console.removeAll() } label: { Image(systemName: "trash") }.help("Clear console")
            }
            .padding(10)
            Divider()
            ScrollViewReader { proxy in
                List(model.console) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(timeFormat.string(from: line.time)).foregroundStyle(.tertiary)
                        Text(arrow(line.kind)).foregroundStyle(color(line.kind)).frame(width: 14)
                        VStack(alignment: .leading, spacing: 2) {
                            if !line.bytes.isEmpty { Text(line.bytes.hex) }
                            if !line.text.isEmpty { Text(line.text).foregroundStyle(.secondary) }
                        }
                        .textSelection(.enabled)
                    }
                    .font(.caption.monospaced())
                    .id(line.id)
                }
                .onChange(of: model.console.count) {
                    if let last = model.console.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func arrow(_ k: ConsoleLine.Kind) -> String {
        switch k {
        case .tx: return "→"
        case .rx: return "←"
        case .decoded: return "≡"
        case .blocked: return "✋"
        case .info: return "·"
        }
    }

    private func color(_ k: ConsoleLine.Kind) -> Color {
        switch k {
        case .tx: return .blue
        case .rx: return .green
        case .decoded: return .purple
        case .blocked: return .red
        case .info: return .secondary
        }
    }
}
