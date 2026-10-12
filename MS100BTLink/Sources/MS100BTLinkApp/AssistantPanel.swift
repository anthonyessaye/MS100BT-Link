import SwiftUI
import ZoomCore

/// Right-hand panel: chat with the tone assistant.
struct AssistantPanel: View {
    @EnvironmentObject var ai: AIAssistant
    @EnvironmentObject var model: LinkModel
    var close: () -> Void
    @State private var draft = ""
    @State private var showSettings = false

    private let starters = [
        "Edge-style dotted-eighth delay with a little shimmer",
        "Warm blues crunch, like an old Fender pushed hard",
        "Ambient pad: slow swells and a huge reverb",
        "Make the current patch darker and less busy",
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Tone Assistant").font(.headline)
                    Text("\(ai.provider.shortLabel) · " + (ai.models.first { $0.id == ai.model }?.name ?? ai.model))
                        .font(.caption2).foregroundStyle(Theme.dim).lineLimit(1)
                }
                Spacer()
                Button { ai.reset() } label: { Image(systemName: "square.and.pencil") }.help("New conversation")
                Button { showSettings = true } label: { Image(systemName: "gearshape") }.help("AI provider & key")
                Button(action: close) { Image(systemName: "xmark") }
            }
            .buttonStyle(.plain).foregroundStyle(Theme.text)
            .padding(12)
            Divider().overlay(Theme.stroke)

            if !ai.isConfigured {
                setupCard
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if ai.items.isEmpty { emptyState }
                            ForEach(ai.items) { item in row(item).id(item.id) }
                            if ai.busy {
                                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Thinking…").foregroundStyle(Theme.dim) }
                                    .id("busy")
                            }
                        }
                        .padding(12)
                    }
                    .onChange(of: ai.items.count) {
                        withAnimation {
                            if ai.busy { proxy.scrollTo("busy", anchor: .bottom) }
                            else if let last = ai.items.last?.id { proxy.scrollTo(last, anchor: .bottom) }
                        }
                    }
                    .onChange(of: ai.busy) { if ai.busy { withAnimation { proxy.scrollTo("busy", anchor: .bottom) } } }
                }
                inputBar
            }
        }
        .background(Theme.panel)
        .sheet(isPresented: $showSettings) { AISettingsView().environmentObject(ai) }
    }

    // MARK: pieces

    private var setupCard: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "sparkles").font(.system(size: 36)).foregroundStyle(Theme.accent)
            Text("Build patches by describing a sound").font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            Text("Connect Claude, ChatGPT or a local model with your own API key. Patches are suggested to you first; nothing is saved on the pedal unless you save it.")
                .font(.callout).foregroundStyle(Theme.dim).multilineTextAlignment(.center)
            Button("Set up AI provider") { showSettings = true }.buttonStyle(PillButtonStyle(active: true))
            Spacer()
        }
        .padding(24)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Describe the sound you want. I'll pick effects and settings and show you a patch to try.")
                .font(.callout).foregroundStyle(Theme.dim)
            ForEach(starters, id: \.self) { s in
                Button { ai.send(s) } label: {
                    Text(s).font(.callout).multilineTextAlignment(.leading)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            if model.patch == nil {
                Label("Connect the pedal so I can read and build on your patches.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(Theme.accent)
            }
        }
    }

    @ViewBuilder
    private func row(_ item: ChatItem) -> some View {
        switch item.kind {
        case .user(let t):
            HStack {
                Spacer(minLength: 40)
                Text(t).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Theme.accent.opacity(0.9), in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.black)
            }
        case .assistant(let t):
            Text((try? AttributedString(markdown: t, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(t))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .activity(let t):
            Label(t, systemImage: "wrench.and.screwdriver").font(.caption).foregroundStyle(Theme.dim)
        case .error(let t):
            Label(t, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                .textSelection(.enabled)
        case .proposal(let id):
            if let p = ai.proposals[id] { ProposalCard(proposal: p) }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Describe a sound or a change…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(10)
                .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 10))
                .onSubmit(send)
            if ai.busy {
                Button { ai.stop() } label: { Image(systemName: "stop.circle.fill").font(.title2) }
                    .buttonStyle(.plain).help("Stop")
            } else {
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2).foregroundStyle(Theme.accent) }
                    .buttonStyle(.plain).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(12)
    }

    private func send() {
        let t = draft
        draft = ""
        ai.send(t)
    }
}

/// A proposed patch: chain preview, knob values on demand, Try / Discard.
struct ProposalCard: View {
    @EnvironmentObject var ai: AIAssistant
    @EnvironmentObject var model: LinkModel
    let proposal: Proposal
    @State private var expanded = false

    var body: some View {
        let p = proposal.patch
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(p.name ?? "Untitled").font(.system(size: 16, weight: .bold, design: .rounded))
                Spacer()
                if let t = p.tempo { Label("\(t)", systemImage: "metronome").font(.caption).foregroundStyle(Theme.dim) }
            }
            HStack(spacing: 4) {
                ForEach(p.effects.filter { !$0.isEmpty }) { fx in
                    VStack(spacing: 3) {
                        LED(on: fx.isOn == true, size: 6)
                        Text(fx.displayName).font(.system(size: 10, weight: .heavy)).lineLimit(2)
                            .multilineTextAlignment(.center).minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .padding(4)
                    .background(Theme.color(for: fx.category).opacity(fx.isOn == true ? 0.9 : 0.35), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(p.effects.filter { !$0.isEmpty }) { fx in
                        Text("**\(fx.displayName)** " + fx.parameters.map { "\($0.name) \($0.text)" }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(Theme.dim)
                    }
                }
            }
            HStack(spacing: 8) {
                switch proposal.state {
                case .proposed, .failed:
                    Button("Try on pedal") { ai.tryOnPedal(proposal.id) }
                        .buttonStyle(PillButtonStyle(active: true))
                        .disabled(!model.canInteract)
                    Button("Discard") { ai.discard(proposal.id) }.buttonStyle(.plain).foregroundStyle(Theme.dim)
                case .sending:
                    ProgressView().controlSize(.small); Text("Sending…").font(.caption)
                case .onPedal:
                    Label("Playing on the pedal", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                case .discarded:
                    Text("Discarded").font(.caption).foregroundStyle(Theme.dim)
                }
                Spacer()
                Button(expanded ? "Hide knobs" : "Knobs") { expanded.toggle() }.buttonStyle(.plain).font(.caption).foregroundStyle(Theme.dim)
            }
            if case .failed(let why) = proposal.state {
                Text(why).font(.caption).foregroundStyle(.orange)
            }
            if proposal.state == .onPedal {
                Text("Not saved yet. Use Patches → Save to… to keep it.").font(.caption2).foregroundStyle(Theme.dim)
            }
        }
        .padding(12)
        .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 12))
        .opacity(proposal.state == .discarded ? 0.5 : 1)
    }
}

/// Provider, model, key, and behaviour settings.
struct AISettingsView: View {
    @EnvironmentObject var ai: AIAssistant
    @Environment(\.dismiss) private var dismiss
    @State private var keyDraft = ""
    @State private var custom = false

    private static let customTag = "__custom__"

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: Binding(get: { ai.provider }, set: { ai.switchProvider($0); keyDraft = ""; custom = false })) {
                    ForEach(AIProviderKind.allCases) { Text($0.shortLabel).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(ai.provider.label).font(.caption).foregroundStyle(.secondary)
                if ai.provider != .anthropic {
                    TextField("Base URL", text: $ai.baseURL, prompt: Text(ai.provider.defaultBaseURL))
                        .onSubmit { Task { await ai.refreshModels() } }
                }
            } header: { Text("Provider") }

            Section {
                SecureField(ai.apiKey == nil ? "API key" : "API key (saved: enter a new one to replace)", text: $keyDraft)
                    .onSubmit { saveKey() }
                HStack {
                    Button("Save key", action: saveKey).disabled(keyDraft.isEmpty)
                    if ai.apiKey != nil {
                        Button("Remove key", role: .destructive) { ai.setAPIKey("") }
                    }
                    Spacer()
                    Text(ai.apiKey != nil ? "Stored in your Keychain" : (ai.provider.needsKey ? "Required" : "Optional for local models"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("API key") }

            Section {
                HStack {
                    Picker("Model", selection: modelSelection) {
                        // Empty until the provider is set up and has listed its models.
                        if ai.model.isEmpty && !custom {
                            Text(ai.models.isEmpty ? "No models yet" : "Choose a model").tag("")
                        } else if !custom && !ai.models.contains(where: { $0.id == ai.model }) && !ai.models.isEmpty {
                            Text(ai.model).tag(ai.model) // saved model the provider didn't list
                        }
                        ForEach(ai.models) { m in
                            Text(m.name == m.id ? m.id : "\(m.name)  ·  \(m.id)").tag(m.id)
                        }
                        Divider()
                        Text("Custom…").tag(Self.customTag)
                    }
                    Button { Task { await ai.refreshModels() } } label: {
                        if ai.modelsLoading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                    }
                    .buttonStyle(.borderless)
                    .help("Reload the model list from the provider")
                }
                if custom {
                    TextField("Model ID", text: $ai.model, prompt: Text(ai.provider == .anthropic ? "claude-opus-5-5" : "model ID"))
                }
                if let err = ai.modelsError {
                    Text("Couldn't load models: \(err)").font(.caption).foregroundStyle(.orange)
                } else if ai.models.isEmpty && ai.provider.needsKey && ai.apiKey == nil {
                    Text("Save your API key to load the list of models.").font(.caption).foregroundStyle(.secondary)
                } else if ai.provider == .anthropic && ai.model == AIProviderKind.anthropic.defaultModel {
                    Text("Recommended.").font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("Model") }

            Section {
                Toggle("Try proposals on the pedal automatically", isOn: $ai.autoTry)
                Text("Proposals go to the pedal's edit buffer only. They are never stored unless you save them (or the pedal's Auto Save is on).")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Behaviour") }
            Section {
                Text("Your messages and your pedal's patch data (names, effects, knob values) are sent to the provider you choose. The key never leaves this Mac except to that provider.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 600)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .task {
            if ai.models.isEmpty { await ai.refreshModels() }
            custom = !ai.model.isEmpty && !ai.models.isEmpty && !ai.models.contains { $0.id == ai.model }
        }
    }

    private var modelSelection: Binding<String> {
        Binding(get: { custom ? Self.customTag : ai.model },
                set: { v in
                    if v == Self.customTag { custom = true } else { custom = false; ai.model = v }
                })
    }

    private func saveKey() {
        guard !keyDraft.isEmpty else { return }
        ai.setAPIKey(keyDraft)
        keyDraft = ""
    }
}
