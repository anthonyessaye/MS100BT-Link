import SwiftUI
import ZoomCore

/// Window: the pedal's installed effects, the effect library, and the guarded install/remove flow.
struct EffectsManagerView: View {
    @EnvironmentObject var mgr: EffectManager
    @EnvironmentObject var model: LinkModel
    @State private var query = ""
    @State private var sourceFilter = "All"
    @State private var showConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.stroke)
            HStack(spacing: 0) {
                libraryPane.frame(minWidth: 420)
                Divider().overlay(Theme.stroke)
                pedalPane.frame(minWidth: 380)
            }
            footer
        }
        .background(Theme.background)
        .foregroundStyle(Theme.text)
        .preferredColorScheme(.dark)
        .frame(minWidth: 980, minHeight: 640)
        .sheet(isPresented: $showConfirm) { ConfirmApplySheet().environmentObject(mgr).environmentObject(model) }
        .alert("Effects Manager", isPresented: Binding(get: { mgr.alert != nil }, set: { if !$0 { mgr.alert = nil } })) {
            Button("OK") { mgr.alert = nil }
        } message: { Text(mgr.alert ?? "") }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Effects").font(.system(size: 24, weight: .bold, design: .rounded))
                if let s = mgr.state {
                    Text("\(s.files.count)/\(EffectPlanValidator.maxFiles) files · \(s.freeBytes / 1024) KB free · \(s.index.allEffects.count) effects in the menu")
                        .font(.caption).foregroundStyle(Theme.dim)
                } else {
                    Text(model.isOpen ? "Read the pedal to see its effects" : "Connect the pedal first").font(.caption).foregroundStyle(Theme.dim)
                }
            }
            Spacer()
            Button { Task { await mgr.readPedal() } } label: { Label("Read pedal", systemImage: "arrow.clockwise") }
                .buttonStyle(PillButtonStyle(active: mgr.state == nil))
                .disabled(!model.isOpen || mgr.busy != nil)
            Button { Task { await mgr.backupAll() } } label: { Label("Back up all files", systemImage: "externaldrive.badge.checkmark") }
                .buttonStyle(PillButtonStyle(active: mgr.state != nil && mgr.lastFullBackup == nil))
                .disabled(!model.isOpen || mgr.busy != nil)
                .help("Copies every file on the pedal to your Mac (read-only, about 7 minutes). Required before any change.")
        }
        .padding(16)
    }

    // MARK: library

    private var sources: [String] { ["All"] + Array(Set(mgr.library.map(\.source))).sorted() }

    private var filtered: [LibraryEffect] {
        mgr.library.filter {
            (sourceFilter == "All" || $0.source == sourceFilter) && !$0.info.isSharedLibrary &&
            (query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query) || $0.pedalName.localizedCaseInsensitiveContains(query)
             || $0.category.localizedCaseInsensitiveContains(query))
        }
    }

    private var libraryPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Library").font(.headline)
                Spacer()
                Menu("Download") {
                    Button(EffectSource.stock.label) { Task { await mgr.download(.stock) } }
                    Divider()
                    ForEach(EffectSource.community) { s in Button("Community: " + s.label) { Task { await mgr.download(s) } } }
                }
                .fixedSize()
                .disabled(mgr.busy != nil)
            }
            HStack {
                TextField("Search effects", text: $query).textFieldStyle(.roundedBorder)
                Picker("", selection: $sourceFilter) { ForEach(sources, id: \.self) { Text($0).tag($0) } }
                    .labelsHidden().frame(width: 170)
            }
            if mgr.library.isEmpty {
                Text("No library yet. Download stock effects from other MultiStomps or community effects, or back up your pedal.")
                    .font(.callout).foregroundStyle(Theme.dim).padding(.top, 20)
            }
            List(filtered) { item in
                let risk = item.risk(onPedal: mgr.onPedal)
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 3).fill(Theme.color(for: categoryName(item.info.category))).frame(width: 6, height: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(item.displayName).fontWeight(.semibold)
                            Text(item.pedalName).font(.caption.monospaced()).foregroundStyle(Theme.dim)
                        }
                        Text("\(item.category) · \(item.source) · \(item.info.size / 1024) KB" + (item.info.parameters.isEmpty ? "" : " · " + item.info.parameters.prefix(4).joined(separator: ", ")))
                            .font(.caption).foregroundStyle(Theme.dim).lineLimit(1)
                    }
                    Spacer()
                    RiskBadge(risk: risk)
                    Button { mgr.add(item) } label: { Image(systemName: "plus.circle.fill").font(.title3) }
                        .buttonStyle(.plain)
                        .foregroundStyle(risk.blocksInstall || risk == .installed ? Theme.dim : Theme.accent)
                        .disabled(risk.blocksInstall || mgr.state == nil)
                        .help(risk.blocksInstall ? risk.label : "Add to the pedal (applied when you click Apply)")
                }
                .listRowBackground(Color.clear)
            }
            .scrollContentBackground(.hidden)
        }
        .padding(16)
        .background(Theme.panel.opacity(0.5))
    }

    private func categoryName(_ c: UInt8) -> String {
        switch c {
        case 0x01: return "Dynamics"; case 0x02: return "Filter"; case 0x03: return "Drive"; case 0x04: return "Amp"
        case 0x06: return "Modulation"; case 0x07: return "SFX"; case 0x08: return "Delay"; case 0x09: return "Reverb"
        default: return "Other"
        }
    }

    // MARK: pedal

    private var pedalPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("On the pedal").font(.headline)
                Spacer()
                if let n = mgr.filesAfter, mgr.hasChanges {
                    Text("\(n)/\(EffectPlanValidator.maxFiles) files after").font(.caption)
                        .foregroundStyle(n > EffectPlanValidator.maxFiles ? .red : Theme.dim)
                }
            }
            if let d = mgr.draft {
                List {
                    ForEach(d.categories.filter { ZDLCategory.shownOnMS100BT.contains($0.id) }, id: \.id) { cat in
                        Section(ZDLCategory.name(cat.id)) {
                            ForEach(cat.effects.filter { !$0.isEmpty }, id: \.self) { name in
                                HStack {
                                    let info = mgr.pendingAdds[name]?.info ?? mgr.installed[name]
                                    Text(info?.displayName ?? name).fontWeight(.medium)
                                    Text(name).font(.caption.monospaced()).foregroundStyle(Theme.dim)
                                    if mgr.pendingAdds[name] != nil {
                                        Text("NEW").font(.caption2.weight(.heavy)).padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(Color.green.opacity(0.3), in: Capsule())
                                    }
                                    Spacer()
                                    Button { mgr.remove(name) } label: { Image(systemName: "minus.circle") }
                                        .buttonStyle(.plain).foregroundStyle(Theme.dim)
                                        .help("Remove from the pedal (a copy is saved first)")
                                }
                            }
                        }
                    }
                    if !mgr.pendingRemovals.isEmpty {
                        Section("To be removed") {
                            ForEach(mgr.pendingRemovals.sorted(), id: \.self) { n in
                                Text(mgr.installed[n]?.displayName ?? n).strikethrough().foregroundStyle(.red.opacity(0.8))
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            } else {
                Spacer()
                Text("The pedal's effect menu appears here.").foregroundStyle(Theme.dim).frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .padding(16)
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 12) {
            if let b = mgr.busy {
                if let p = mgr.progress { ProgressView(value: p).frame(width: 160) } else { ProgressView().controlSize(.small) }
                Text(b).font(.caption).lineLimit(1)
            } else if let n = mgr.notice {
                Label(n, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green).lineLimit(2)
            } else if let b = mgr.lastFullBackup {
                Text("Last full backup: \(b.lastPathComponent)").font(.caption).foregroundStyle(Theme.dim)
            } else {
                Label("No full backup yet: required before any change", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Theme.accent)
            }
            Spacer()
            Button("Discard") { mgr.discard() }.disabled(!mgr.hasChanges || mgr.busy != nil)
            Button("Dry run") { Task { await mgr.dryRun() } }.disabled(!mgr.hasChanges || mgr.busy != nil)
            Button { showConfirm = true } label: { Text("Apply changes…").fontWeight(.semibold) }
                .buttonStyle(PillButtonStyle(active: mgr.hasChanges))
                .disabled(!mgr.hasChanges || mgr.busy != nil)
        }
        .padding(12)
        .background(Theme.panel)
    }
}

struct RiskBadge: View {
    let risk: LibraryEffect.Risk
    var body: some View {
        Text(risk.label)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.22), in: Capsule())
            .foregroundStyle(color)
            .lineLimit(1)
    }
    private var color: Color {
        switch risk {
        case .installed: return .gray
        case .verified, .low: return .green
        case .community: return .yellow
        default: return .red
        }
    }
}

/// The risk confirmation shown before anything is written to the pedal's file system.
struct ConfirmApplySheet: View {
    @EnvironmentObject var mgr: EffectManager
    @EnvironmentObject var model: LinkModel
    @Environment(\.dismiss) private var dismiss
    @State private var understood = false

    var body: some View {
        let problems = mgr.planProblems()
        VStack(alignment: .leading, spacing: 16) {
            Label("Change the effects on your pedal?", systemImage: "exclamationmark.triangle.fill")
                .font(.title2.weight(.bold)).foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 6) {
                if !mgr.pendingAdds.isEmpty {
                    Text("Install: " + mgr.pendingAdds.values.map { "\($0.displayName) (\($0.source))" }.sorted().joined(separator: ", "))
                }
                if !mgr.pendingRemovals.isEmpty {
                    Text("Remove: " + mgr.pendingRemovals.sorted().map { mgr.installed[$0]?.displayName ?? $0 }.joined(separator: ", "))
                }
                if mgr.pendingAdds.isEmpty && mgr.pendingRemovals.isEmpty { Text("Reorder the effect menu.") }
            }
            .font(.callout)

            Text("""
            This writes files to the pedal's internal storage, which this app normally never touches. The method was \
            verified on another MS-100BT, and the app checks every rule it knows, but your pedal can't be replaced:

            • A wrong effect or a broken file can make the pedal freeze when you scroll to it (fixed by turning it off and on).
            • Files with long names have frozen pedals at boot; the app refuses them.
            • Community effects are built by hobbyists and may not work on the MS-100BT.
            • Keep the pedal on the AC adapter and don't switch it off until this finishes.

            Before writing, the app saves the old menu and every file it changes or removes to your Mac, then checks \
            each written file by reading it back. If writing the new menu fails, it puts the old one back.
            """)
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if !problems.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("This change is refused:").fontWeight(.semibold).foregroundStyle(.red)
                    ForEach(problems, id: \.self) { Text("• " + $0).font(.callout) }
                }
            } else {
                Toggle("I have a backup of my pedal and accept the risk of changing its files.", isOn: $understood)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Install on pedal") {
                    dismiss()
                    Task {
                        if !model.editingEnabled {
                            guard model.confirmUnlock() else { return }
                            model.editingEnabled = true
                        }
                        await mgr.apply()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!problems.isEmpty || !understood)
            }
        }
        .padding(24)
        .frame(width: 600)
    }
}
