import SwiftUI

// Scenes added for v1.0: a guitarist on stage, installing effects, Mac and Android, and what it works with.

/// Foot lift for stomps landing on `beats` (lifts 0.7 beat before, lands on the beat).
func stompLift(_ b: Double, _ beats: [Double]) -> Double {
    for e in beats where b > e - 0.7 && b < e {
        return sin(.pi * prog(b, e - 0.7, 0.7))
    }
    return 0
}

// MARK: - stage: a guitarist with the phone on the mic stand

struct StageScene: View {
    let style: PromoStyle
    let b: Double
    static let stomps: [Double] = [4, 8, 12]

    var body: some View {
        let done = Self.stomps.filter { $0 <= b }.count
        let pressed = Self.stomps.firstIndex { abs(b - $0) < 0.18 }
        let patches = ["AmerIdiot", "AmerIdiot", "LEAD 80s", "LEAD 80s"]
        let chains: [[(String, String, Bool)]] = [
            [("ZNR", "Dynamics", true), ("Booster", "Drive", false), ("MS 1959", "Amp", true), ("Hall", "Reverb", true)],
            [("ZNR", "Dynamics", true), ("Booster", "Drive", true), ("MS 1959", "Amp", true), ("Hall", "Reverb", true)],
            [("Comp", "Dynamics", true), ("T Scream", "Drive", true), ("Delay", "Delay", false), ("Hall", "Reverb", true)],
            [("Comp", "Dynamics", true), ("T Scream", "Drive", true), ("Delay", "Delay", true), ("Hall", "Reverb", true)],
        ]
        let selected = [1, 1, 2, 2][done]
        ZStack {
            // spotlight and stage floor
            LinearGradient(colors: [Color.white.opacity(0.10), .clear], startPoint: .top, endPoint: .bottom)
                .mask(Path { p in p.move(to: CGPoint(x: 760, y: 0)); p.addLine(to: CGPoint(x: 1020, y: 0)); p.addLine(to: CGPoint(x: 1300, y: 1080)); p.addLine(to: CGPoint(x: 420, y: 1080)) })
                .opacity(0.6 + 0.4 * beatPulse(b, sharp: 3))
            Rectangle().fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.06)], startPoint: .top, endPoint: .bottom))
                .frame(height: 230).frame(maxHeight: .infinity, alignment: .bottom)

            // guitarist, footswitch, the pedal, and the phone on a mic stand
            // the right foot rests on switch 2 and stomps it (drawn first so the shoe is on top)
            Footswitch4(pressed: pressed == nil ? nil : 1, lit: done == 0 ? nil : 1, accent: style.accent2)
                .scaleEffect(0.8)
                .offset(x: -45, y: 460)
            Guitarist(stomp: stompLift(b, Self.stomps), strum: b * 2, bob: beatPulse(b, sharp: 5))
                .frame(width: 560, height: 800)
                .offset(x: -170, y: 90)
                .opacity(prog(b, 0, 0.8))
            PromoPedal(name: "MS-100BT", category: "Drive", on: true, knobs: 3, width: 120)
                .offset(x: -480, y: 420)
            // mic stand
            Rectangle().fill(Color(white: 0.25)).frame(width: 10, height: 520).offset(x: 560, y: 240)
            Capsule().fill(Color(white: 0.2)).frame(width: 160, height: 14).offset(x: 560, y: 500)
            PhoneApp(style: style, patch: patches[done], slot: done >= 2 ? 4 : 1, chain: chains[done], selected: selected)
                .scaleEffect(0.72)
                .rotationEffect(.degrees(-4))
                .offset(x: 560, y: -40)
            // Bluetooth from the footswitch to the phone on each stomp
            if let last = Self.stomps.last(where: { $0 <= b }), b - last < 1 {
                let t = prog(b, last, 1)
                Waves(t: t, color: style.accent2)
                    .offset(x: lerp(-40, 540, easeOut(t)), y: lerp(430, 40, easeOut(t)))
            }
            Caption(style: style, title: "Play. Stomp. It follows.",
                    subtitle: "A Bluetooth footswitch, your phone on the mic stand, your pedal on the floor.", p: prog(b, 0.5, 1))
                .offset(y: -400)
        }
        .frame(width: W, height: H)
    }
}

// MARK: - effects: install with every safety check

struct EffectsScene: View {
    let style: PromoStyle
    let b: Double
    static let library: [(String, String, String, Color)] = [
        ("WaveFold", "SFX", "Verified on an MS-100BT", .green),
        ("Shatter", "Delay", "Verified on an MS-100BT", .green),
        ("Galactic", "Reverb", "Verified on an MS-100BT", .green),
        ("DualRev", "Reverb", "Low risk · stock", .teal),
        ("Arrakis", "Modulation", "Community: untested", .orange),
    ]
    static let checks = ["Full backup on file", "Effect ID and category checked", "Copies of changed files saved",
                         "Shatter written · read back", "Effect menu updated · read back"]

    var body: some View {
        let added = b >= 4.2
        HStack(alignment: .top, spacing: 60) {
            VStack(alignment: .leading, spacing: 34) {
                Caption(style: style, title: "More effects\non the pedal", subtitle: "Stock effects from other Zoom pedals\nand community ones, installed with\nevery safety check.", p: prog(b, 0.3, 1), align: .leading)
                if b >= 8 {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(Self.checks.indices, id: \.self) { i in
                            let p = prog(b, 8.6 + Double(i) * 0.9, 0.4)
                            HStack(spacing: 14) {
                                Image(systemName: p >= 1 ? "checkmark.circle.fill" : "circle.dotted")
                                    .foregroundStyle(p >= 1 ? Color.green : style.dim)
                                Text(Self.checks[i]).font(.system(size: 26, weight: .semibold))
                            }
                            .opacity(0.35 + 0.65 * p)
                        }
                    }
                    .opacity(prog(b, 8, 0.6))
                }
            }
            .frame(width: 680, alignment: .leading)

            ZStack {
                // the Effects window: library and pedal side by side
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Library").font(.system(size: 22, weight: .bold))
                        ForEach(Self.library.indices, id: \.self) { i in
                            let e = Self.library[i]
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 3).fill(Theme.color(for: e.1)).frame(width: 7, height: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(e.0).font(.system(size: 20, weight: .bold))
                                    Text(e.2).font(.system(size: 14, weight: .semibold)).foregroundStyle(e.3)
                                }
                                Spacer()
                                Image(systemName: i == 1 && added ? "checkmark.circle.fill" : "plus.circle.fill")
                                    .font(.system(size: 26)).foregroundStyle(i == 1 && added ? Color.green : style.accent)
                                    .scaleEffect(i == 1 && abs(b - 4) < 0.2 ? 0.8 : 1)
                            }
                            .padding(10)
                            .background(Color.white.opacity(i == 1 ? 0.08 : 0.03), in: RoundedRectangle(cornerRadius: 10))
                        }
                        Spacer()
                    }
                    .padding(20).frame(width: 450)
                    Divider().overlay(Color.white.opacity(0.1))
                    VStack(alignment: .leading, spacing: 14) {
                        Text("On the pedal").font(.system(size: 22, weight: .bold))
                        category("DRIVE", "Drive", ["Booster", "T Scream", "Z Scream"])
                        category("DELAY", "Delay", ["Delay", "TapeEcho"] + (added ? ["Shatter"] : []))
                        category("REVERB", "Reverb", ["Hall", "Room"])
                        Spacer()
                    }
                    .padding(20).frame(width: 400)
                }
                .frame(width: 850, height: 620)
                .background(style.panel.opacity(0.97), in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Color.white.opacity(0.08)))
                .shadow(color: .black.opacity(0.5), radius: 30, y: 20)

                // risk confirmation
                if b >= 5.6 && b < 8.4 {
                    VStack(alignment: .leading, spacing: 18) {
                        Label("Change the effects on your pedal?", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 26, weight: .bold)).foregroundStyle(.orange)
                        Text("Install: Shatter (themanro)").font(.system(size: 20))
                        HStack(spacing: 12) {
                            Image(systemName: b >= 6.8 ? "checkmark.square.fill" : "square").foregroundStyle(style.accent)
                            Text("I have a backup and accept the risk.").font(.system(size: 19))
                        }
                        HStack {
                            Spacer()
                            Text("Install on pedal").font(.system(size: 19, weight: .bold))
                                .padding(.horizontal, 18).padding(.vertical, 9)
                                .background(b >= 6.8 ? style.accent : Color.white.opacity(0.15), in: Capsule())
                                .foregroundStyle(.black)
                                .scaleEffect(abs(b - 7.8) < 0.2 ? 0.9 : 1)
                        }
                    }
                    .padding(28).frame(width: 560)
                    .background(Color(white: 0.17), in: RoundedRectangle(cornerRadius: 18))
                    .shadow(color: .black.opacity(0.6), radius: 30, y: 16)
                    .scaleEffect(easeOutBack(prog(b, 5.6, 0.6)))
                }
                if b > 2.6 && b < 8.2 {
                    let toAdd = easeInOut(prog(b, 2.6, 1.2)), toInstall = easeInOut(prog(b, 6.4, 1.2))
                    Cursor(clicking: abs(b - 4) < 0.25 || abs(b - 6.8) < 0.2 || abs(b - 7.8) < 0.25)
                        .offset(x: b < 6.4 ? lerp(300, -60, toAdd) : lerp(-60, 210, toInstall),
                                y: b < 6.4 ? lerp(300, -150, toAdd) : lerp(-150, 60, toInstall))
                }
            }
        }
    }

    func category(_ title: String, _ cat: String, _ names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 14, weight: .heavy)).tracking(1.5).foregroundStyle(Theme.color(for: cat))
            HStack(spacing: 8) {
                ForEach(names, id: \.self) { n in
                    Text(n).font(.system(size: 15, weight: .bold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(n == "Shatter" ? style.accent.opacity(0.35) : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                        .scaleEffect(n == "Shatter" ? easeOutBack(prog(b, 4.2, 0.6)) : 1)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - platforms: the Mac and an Android phone

struct PlatformsScene: View {
    let style: PromoStyle
    let b: Double
    static let taps: [(Double, Int)] = [(4, 1), (7, 2), (10, 0)]

    var body: some View {
        let tab = Self.taps.last { $0.0 <= b }?.1 ?? 0
        let tapping = Self.taps.contains { abs(b - $0.0) < 0.25 }
        VStack(spacing: 40) {
            Caption(style: style, title: "Mac and Android. One app.",
                    subtitle: "The same pedalboard on both. Export a patch on one, import it on the other.", p: prog(b, 0.3, 1))
            HStack(alignment: .bottom, spacing: 120) {
                MacApp(style: style)
                    .scaleEffect(0.92)
                    .offset(x: -40 * (1 - easeOut(prog(b, 0.5, 1.2))))
                    .opacity(prog(b, 0.5, 0.8))
                ZStack(alignment: .topLeading) {
                    phone(tab: tab).offset(x: 15, y: 10)
                    HoldingHand(tapX: [56.0, 139, 221, 304][tab], tap: tapping ? 1 : 0)
                        .frame(width: 360, height: 1200)
                }
                .frame(width: 360, height: 1200, alignment: .top)
                .scaleEffect(0.78, anchor: .top)
                .frame(width: 290, height: 640, alignment: .top)
                .offset(y: 30 * (1 - easeOut(prog(b, 1, 1.2))))
                .opacity(prog(b, 1, 0.8))
            }
            .overlay {
                // a .syx patch file travelling from the Mac to the phone
                if b > 11.5 && b < 14.5 {
                    let t = easeInOut(prog(b, 11.5, 2.2))
                    HStack(spacing: 10) {
                        Image(systemName: "doc.fill")
                        Text("AmerIdiot.syx").font(.system(size: 22, weight: .bold, design: .monospaced))
                    }
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(style.accent2, in: Capsule()).foregroundStyle(.black)
                    .offset(x: lerp(-200, 520, t), y: lerp(-80, -160, sin(t * .pi)))
                    .opacity(1 - prog(b, 13.8, 0.6))
                }
            }
        }
    }

    @ViewBuilder func phone(tab: Int) -> some View {
        if tab == 0 {
            PhoneApp(style: style, tab: 0)
        } else {
            VStack(spacing: 0) {
                Text(tab == 1 ? "Patches" : "Tone Assistant")
                    .font(.system(size: 22, weight: .bold)).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.top, 40).padding(.bottom, 12).background(Color(white: 0.14))
                if tab == 1 {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(["AmerIdiot", "Bourj", "Clean Funk", "LEAD 80s", "Shimmer", "Blues Bar", "Ambient", "Edge Dly"].enumerated()), id: \.offset) { i, n in
                            HStack(spacing: 10) {
                                Text(String(format: "%02d", i + 1)).font(.system(size: 13, weight: .bold, design: .monospaced))
                                    .padding(.horizontal, 4).background(i == 0 ? style.accent : .clear, in: RoundedRectangle(cornerRadius: 3))
                                    .foregroundStyle(i == 0 ? Color.black : style.dim)
                                Text(n).font(.system(size: 17, weight: .semibold))
                                Spacer()
                            }
                        }
                    }
                    .padding(18)
                } else {
                    VStack(alignment: .trailing, spacing: 14) {
                        Text("Warm blues crunch").font(.system(size: 16, weight: .medium))
                            .padding(10).background(style.accent, in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(.black)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Blues Bar").font(.system(size: 18, weight: .black))
                            HStack(spacing: 6) {
                                ForEach([("Comp", "Dynamics"), ("T Scream", "Drive"), ("Room", "Reverb")], id: \.0) { c in
                                    Text(c.0).font(.system(size: 12, weight: .heavy)).padding(6)
                                        .background(Theme.color(for: c.1), in: RoundedRectangle(cornerRadius: 6))
                                }
                            }
                            Text("Try on pedal").font(.system(size: 14, weight: .bold)).padding(.horizontal, 12).padding(.vertical, 6)
                                .background(style.accent, in: Capsule()).foregroundStyle(.black)
                        }
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(18)
                }
                Spacer()
                HStack {
                    ForEach(Array(["square.grid.2x2", "music.note.list", "sparkles", "ellipsis"].enumerated()), id: \.offset) { i, icon in
                        Image(systemName: icon).font(.system(size: 18)).frame(width: 52, height: 26)
                            .background(i == tab ? style.accent.opacity(0.35) : .clear, in: Capsule()).frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 16).background(Color(white: 0.15))
            }
            .frame(width: 330, height: 690)
            .background(LinearGradient(colors: [Color(white: 0.08), Color(white: 0.13)], startPoint: .top, endPoint: .bottom))
            .clipShape(RoundedRectangle(cornerRadius: 40))
            .overlay(RoundedRectangle(cornerRadius: 40).strokeBorder(Color(white: 0.06), lineWidth: 10))
            .shadow(color: .black.opacity(0.6), radius: 30, y: 20)
        }
    }
}

// MARK: - interoperability

struct InteropScene: View {
    let style: PromoStyle
    let b: Double
    static let items: [(String, String)] = [
        ("macOS", "laptopcomputer"), ("Android", "iphone"), ("USB MIDI", "cable.connector"), ("Bluetooth MIDI", "dot.radiowaves.left.and.right"),
        ("Claude", "sparkles"), ("ChatGPT", "bubble.left.and.text.bubble.right"), ("Ollama · LM Studio", "desktopcomputer"), (".syx patch files", "doc.fill"),
        ("Stock Zoom effects", "square.stack.3d.down.right.fill"), ("Community effects", "person.3.fill"), ("Any MIDI footswitch", "pianokeys"), ("Your backups", "externaldrive.fill"),
    ]
    var body: some View {
        VStack(spacing: 60) {
            Caption(style: style, title: "Plays well with everything", subtitle: "Bring your own controller, AI and effects.", p: prog(b, 0.3, 1))
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(360), spacing: 26), count: 4), spacing: 26) {
                ForEach(Self.items.indices, id: \.self) { i in
                    let p = easeOutBack(prog(b, 1.2 + Double(i) * 0.4, 0.6))
                    HStack(spacing: 16) {
                        Image(systemName: Self.items[i].1).font(.system(size: 30, weight: .semibold)).foregroundStyle(style.accent)
                            .frame(width: 44)
                        Text(Self.items[i].0).font(.system(size: 26, weight: .bold))
                        Spacer()
                    }
                    .padding(.horizontal, 24).frame(height: 92)
                    .background(style.panel.opacity(0.95), in: RoundedRectangle(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(style.accent.opacity(0.25 + 0.5 * beatPulse(b + Double(i) * 0.25, sharp: 5))))
                    .scaleEffect(p).opacity(min(p, 1))
                }
            }
        }
    }
}
