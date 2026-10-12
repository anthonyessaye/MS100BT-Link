import AppKit
import SwiftUI
import ZoomCore

/// Renders README screenshots of the real views, filled with demo data. Nothing is sent anywhere.
/// Run: `"MS-100BT Link.app/Contents/MacOS/MS100BTLinkApp" --screenshots docs/media`
@MainActor
enum Screenshots {
    /// A real 146-byte patch dump from an MS-100BT, used as the base for demo patches.
    static let baseDump = PatchDump.decode("F0 52 00 5E 28 02 10 00 00 06 0A 48 00 00 32 00 00 00 00 00 00 00 00 00 00 00 10 00 00 18 4C 0C 38 00 45 50 01 00 00 00 00 00 00 00 00 00 00 20 00 00 72 03 14 40 00 1F 00 43 06 00 00 00 00 00 00 00 00 60 00 28 00 4E 05 10 01 41 00 00 60 30 06 00 00 00 00 12 00 00 60 01 00 06 07 40 48 00 32 00 00 00 00 00 00 00 00 00 00 00 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 04 00 00 00 40 54 0F 42 00 6F 75 72 6A 20 20 20 00 20 20 00 F7"
        .split(separator: " ").map { UInt8($0, radix: 16)! })!

    static func patch(_ name: String, _ fx: [(String, Bool, [String: Any])], tempo: Int = 120) -> PatchDump {
        let spec: [String: Any] = ["name": name, "tempo": tempo,
                                   "effects": fx.map { ["effect": $0.0, "on": $0.1, "params": $0.2] }]
        let available = PatchAssistant.availableIDs(seen: [baseDump])
        switch PatchAssistant.buildPatch(spec: spec, base: baseDump, available: available) {
        case .success(let edit): return edit.decoded!
        case .failure(let e):
            FileHandle.standardError.write(Data("demo patch \(name) invalid: \(e)\n".utf8))
            return baseDump
        }
    }

    static let demoPatch = patch("CRUNCH", [
        ("Comp", true, ["Sense": 6]), ("Z Scream", true, ["Gain": 62, "Tone": 55]),
        ("Phaser", false, [:]), ("Delay", true, ["Time": 357, "F.B": 32, "Mix": 38]), ("Hall", true, ["Mix": 30]),
    ], tempo: 126)

    static let names = ["CLEAN", "CRUNCH", "LEAD", "DREAMY", "AMBIENT", "FUNK", "BLUES", "SHIMMER", "ROCK", "SURF",
                        "JANGLE", "METAL", "SLAPBACK", "OCTAVE", "SWELL", "TREM", "VIBE", "WAH", "TAPE", "SPACE"]
    static let chains: [[(String, Bool, [String: Any])]] = [
        [("Comp", true, [:]), ("Chorus", true, [:]), ("Hall", true, [:])],
        [("Booster", true, [:]), ("Z Scream", true, [:]), ("Delay", true, [:]), ("TiledRoom", true, [:])],
        [("Phaser", true, [:]), ("Delay", true, [:]), ("Hall", true, [:]), ("Tremolo", false, [:])],
        [("Comp", true, [:]), ("OverDrive", true, [:]), ("Room", true, [:])],
    ]

    static func render(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = LinkModel()
        model.demoMode = true
        model.devices = [DeviceSummary(address: "00-00-00-00-00-00", name: "ZOOM MS-100BT", isPaired: true, isConnected: true)]
        model.selectedAddress = "00-00-00-00-00-00"
        model.state = .open
        model.editingEnabled = false // never change the user's saved lock from a screenshot run
        model.patch = demoPatch
        model.currentSlot = 1
        for n in 0..<50 { model.slots[n] = n == 1 ? demoPatch : patch(names[n % names.count], chains[n % chains.count]) }

        let midi = MIDIControl()
        midi.model = model
        midi.sources = ["Chocolate Plus (Bluetooth)"]
        var maps = MIDIControl.defaultMappings
        for i in maps.indices { maps[i].trigger = MIDITrigger(kind: .cc, channel: 1, number: 80 + i); maps[i].behavior = .latching }
        midi.mappings = maps
        midi.lastMessage = "CC 83 = 127 · ch 1"
        midi.lastMessageAt = Date()

        let ai = AIAssistant()
        ai.demoMode = true
        ai.link = model
        let proposal = patch("EDGE DLY", [
            ("Comp", true, ["Sense": 5]), ("Delay", true, ["Time": 357, "F.B": 35, "Mix": 40]),
            ("Chorus", true, [:]), ("Hall", true, ["Mix": 25]),
        ], tempo: 126)
        var p = Proposal(edit: PatchEdit(proposal), patch: proposal)
        p.state = .onPedal
        ai.proposals = [p.id: p]
        ai.items = [
            ChatItem(kind: .user("Edge-style dotted-eighth delay with a little shimmer")),
            ChatItem(kind: .activity("Browsed 14 effects in Delay")),
            ChatItem(kind: .activity("Looked up Delay, Chorus, Hall")),
            ChatItem(kind: .activity("Read the current patch “CRUNCH”")),
            ChatItem(kind: .assistant("Dotted-eighth delay at **357 ms** (126 BPM) into a slow chorus and a bright hall. Play single notes and let the repeats bounce.")),
            ChatItem(kind: .proposal(p.id)),
            ChatItem(kind: .user("A bit darker please")),
            ChatItem(kind: .assistant("Rolled the hall's tone down and pulled the delay mix back a touch.")),
        ]

        let window = CGSize(width: 1440, height: 900)
        shoot(MainView(initialSlot: 3, initialSidebar: .patches), window, "main", model, midi, ai, dir)
        shoot(MainView(initialSlot: 3, initialSidebar: .assistant), window, "assistant", model, midi, ai, dir)
        shoot(EffectLibrarySheet(slot: 2), CGSize(width: 980, height: 660), "effect-library", model, midi, ai, dir, chrome: false)
        shoot(MIDISettingsView(), CGSize(width: 820, height: 700), "midi", model, midi, ai, dir, chrome: false)
    }

    private static func shoot<V: View>(_ view: V, _ size: CGSize, _ name: String,
                                       _ model: LinkModel, _ midi: MIDIControl, _ ai: AIAssistant, _ dir: URL,
                                       chrome: Bool = true) {
        let content = ZStack(alignment: .topLeading) {
            view
                .environmentObject(model).environmentObject(midi).environmentObject(ai)
                .frame(width: size.width, height: size.height)
            if chrome { HStack(spacing: 8) { // window controls, as in the real (title-bar-less) window
                ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18),
                         Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) { Circle().fill($0).frame(width: 12, height: 12) }
            }
            .padding(.leading, 18).padding(.top, 22) }
        }
        .background(Theme.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .preferredColorScheme(.dark)

        let host = NSHostingView(rootView: content)
        host.frame = CGRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .darkAqua)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6)) // let onAppear/task settle
        host.layoutSubtreeIfNeeded()

        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        print("wrote \(name).png")
    }
}
