import AppKit
import SwiftUI
import ZoomCore

let W: CGFloat = 1920, H: CGFloat = 1080

/// Scene boundaries in beats (4 beats = 1 bar). Music sections line up with these.
struct Timeline {
    static let scenes: [(start: Double, end: Double)] = [
        (0, 8), (8, 24), (24, 36), (36, 48), (48, 64), (64, 80), (80, 88), (88, 98),
    ]
    static let totalBeats = 98.0
}

/// Whole frame at global beat `beat`.
struct Frame: View {
    let style: PromoStyle
    let beat: Double
    let icon: NSImage

    var body: some View {
        ZStack {
            Backdrop(style: style, beat: beat)
            ForEach(Timeline.scenes.indices, id: \.self) { i in
                let s = Timeline.scenes[i]
                if beat >= s.start - 0.01 && beat < s.end {
                    let b = beat - s.start
                    let len = s.end - s.start
                    let fade = min(prog(b, 0, 0.5), i == Timeline.scenes.count - 1 ? 1 : 1 - prog(b, len - 0.6, 0.6))
                    scene(i, b)
                        .opacity(fade)
                        .scaleEffect(1 + 0.02 * (1 - fade))
                }
            }
            if beat >= Timeline.scenes[1].start && beat < Timeline.scenes.last!.start {
                Brand(style: style, icon: icon).opacity(prog(beat, 8, 1))
            }
            // final fade to black
            Color.black.opacity(prog(beat, Timeline.totalBeats - 2.5, 2.5))
        }
        .frame(width: W, height: H)
        .foregroundStyle(style.text)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    func scene(_ i: Int, _ b: Double) -> some View {
        switch i {
        case 0: IntroScene(style: style, b: b, icon: icon)
        case 1: ChainScene(style: style, b: b)
        case 2: KnobScene(style: style, b: b)
        case 3: LibraryScene(style: style, b: b)
        case 4: MIDIScene(style: style, b: b)
        case 5: AIScene(style: style, b: b)
        case 6: BackupScene(style: style, b: b)
        default: OutroScene(style: style, b: b, icon: icon)
        }
    }
}

// MARK: - backdrop & shared pieces

struct Backdrop: View {
    let style: PromoStyle
    let beat: Double
    var body: some View {
        ZStack {
            LinearGradient(colors: [style.bgTop, style.bgBottom], startPoint: .top, endPoint: .bottom)
            Circle().fill(style.accent.opacity(0.22)).frame(width: 900).blur(radius: 160)
                .offset(x: -520 + 120 * sin(beat * 0.11), y: -260 + 60 * cos(beat * 0.07))
            Circle().fill(style.accent2.opacity(0.14)).frame(width: 800).blur(radius: 170)
                .offset(x: 560 + 100 * cos(beat * 0.09), y: 300 + 70 * sin(beat * 0.13))
            if style.synthGrid { SynthGrid(style: style, beat: beat) }
        }
    }
}

struct SynthGrid: View {
    let style: PromoStyle
    let beat: Double
    var body: some View {
        Canvas { ctx, size in
            let horizon = size.height * 0.76
            var p = Path()
            // receding horizontal lines, moving toward the viewer with the beat
            let phase = beat.truncatingRemainder(dividingBy: 1)
            for k in 0..<14 {
                let z = (Double(k) + phase) / 14
                let y = horizon + (size.height - horizon) * pow(z, 2.2)
                p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
            }
            for k in -16...16 {
                let x0 = size.width / 2 + CGFloat(k) * 40
                let x1 = size.width / 2 + CGFloat(k) * 260
                p.move(to: CGPoint(x: x0, y: horizon)); p.addLine(to: CGPoint(x: x1, y: size.height))
            }
            ctx.stroke(p, with: .color(style.accent.opacity(0.35)), lineWidth: 1.5)
            ctx.fill(Path(CGRect(x: 0, y: horizon - 2, width: size.width, height: 3)), with: .color(style.accent2.opacity(0.6)))
        }
    }
}

struct Brand: View {
    let style: PromoStyle
    let icon: NSImage
    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: icon).resizable().frame(width: 44, height: 44)
            Text("MS-100BT Link").font(.system(size: 24, weight: .bold, design: style.titleDesign))
        }
        .opacity(0.85)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 44).padding(.leading, 56)
    }
}

struct Caption: View {
    let style: PromoStyle
    let title: String
    let subtitle: String
    let p: Double
    var align: HorizontalAlignment = .center
    var body: some View {
        VStack(alignment: align, spacing: 14) {
            Text(title)
                .font(.system(size: 72, weight: .black, design: style.titleDesign))
                .shadow(color: style.accent.opacity(style.synthGrid ? 0.8 : 0.3), radius: style.synthGrid ? 18 : 8)
            Text(subtitle)
                .font(.system(size: 30, weight: .medium, design: style.titleDesign))
                .foregroundStyle(style.dim)
        }
        .multilineTextAlignment(align == .center ? .center : .leading)
        .opacity(p)
        .offset(y: 40 * (1 - easeOut(p)))
    }
}

/// Stompbox as in the app's chain, larger, with knob glyphs.
struct PromoPedal: View {
    let name: String
    let category: String?
    var on = true
    var knobs = 3
    var width: CGFloat = 200
    var pressed = false
    var body: some View {
        let empty = category == nil
        PedalBody(color: Theme.color(for: category), corner: 18, empty: empty) {
            if empty {
                Image(systemName: "plus").font(.system(size: 40, weight: .light)).foregroundStyle(Color.white.opacity(0.4))
            } else {
                VStack(spacing: 14) {
                    HStack(spacing: 10) {
                        ForEach(0..<knobs, id: \.self) { i in Glyph(angle: [-60, 10, 70][i % 3]) }
                    }
                    .padding(10)
                    .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
                    LED(on: on, size: 12)
                    Text(name).font(.system(size: 24, weight: .black, design: .rounded)).foregroundStyle(.white)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Spacer(minLength: 0)
                    Circle().fill(LinearGradient(colors: [Color(white: 0.9), Color(white: 0.45)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 46, height: 46)
                        .scaleEffect(pressed ? 0.85 : 1)
                        .shadow(color: .black.opacity(0.5), radius: 3, y: 3)
                }
                .padding(.vertical, 20).padding(.horizontal, 14)
            }
        }
        .frame(width: width, height: width * 1.3)
        .saturation(on || empty ? 1 : 0.12)
        .brightness(on || empty ? 0 : -0.08)
    }
}

struct Glyph: View {
    let angle: Double
    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [Color(white: 0.36), Color(white: 0.1)], center: .init(x: 0.35, y: 0.3), startRadius: 1, endRadius: 20))
            Capsule().fill(Color.white).frame(width: 3, height: 10).offset(y: -7).rotationEffect(.degrees(angle))
        }
        .frame(width: 34, height: 34)
        .shadow(color: .black.opacity(0.5), radius: 2, y: 2)
    }
}

struct Cursor: View {
    var clicking = false
    var body: some View {
        ZStack {
            if clicking { Circle().stroke(Color.white.opacity(0.7), lineWidth: 3).frame(width: 70, height: 70) }
            Image(systemName: "cursorarrow").font(.system(size: 40)).foregroundStyle(.white)
                .shadow(color: .black, radius: 3).offset(x: 12, y: 16)
        }
    }
}

// MARK: - 1. intro

struct IntroScene: View {
    let style: PromoStyle
    let b: Double
    let icon: NSImage
    var body: some View {
        let ip = easeOutBack(prog(b, 0.5, 1.5))
        VStack(spacing: 34) {
            Image(nsImage: icon).resizable().frame(width: 300, height: 300)
                .scaleEffect(ip)
                .rotationEffect(.degrees(-12 * (1 - prog(b, 0.5, 1.5))))
                .shadow(color: style.accent.opacity(0.35 + 0.3 * beatPulse(b)), radius: 40)
            Text("MS-100BT Link")
                .font(.system(size: 110, weight: .black, design: style.titleDesign))
                .opacity(prog(b, 2, 1.2))
                .offset(y: 30 * (1 - easeOut(prog(b, 2, 1.2))))
                .shadow(color: style.accent.opacity(style.synthGrid ? 0.9 : 0.2), radius: style.synthGrid ? 24 : 6)
            Text("Your Zoom MultiStomp, on your Mac.")
                .font(.system(size: 40, weight: .medium, design: style.titleDesign))
                .foregroundStyle(style.dim)
                .opacity(prog(b, 3.5, 1.2))
        }
    }
}

// MARK: - 2. pedalboard

struct ChainScene: View {
    let style: PromoStyle
    let b: Double
    static let pedals: [(String, String?)] = [("Comp", "Dynamics"), ("Z Scream", "Drive"), ("Phaser", "Modulation"),
                                               ("Delay", "Delay"), ("Hall", "Reverb"), ("", nil)]
    var body: some View {
        let phaserOff = b >= 9 && b < 13
        VStack(spacing: 70) {
            Caption(style: style, title: "A real pedalboard", subtitle: "See the whole chain. Click a footswitch to bypass an effect.", p: prog(b, 0.3, 1))
            ZStack {
                Capsule().fill(LinearGradient(colors: [Color(white: 0.32), Color(white: 0.12)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 1700, height: 10)
                    .opacity(prog(b, 0, 1))
                HStack(spacing: 46) {
                    jack("IN")
                    ForEach(Self.pedals.indices, id: \.self) { i in
                        let drop = easeOutBack(prog(b, 1 + Double(i), 0.8))
                        let off = i == 2 && phaserOff
                        PromoPedal(name: Self.pedals[i].0, category: Self.pedals[i].1, on: !off, width: 200,
                                   pressed: i == 2 && (abs(b - 9) < 0.15 || abs(b - 13) < 0.15))
                            .offset(y: -700 * (1 - drop) + (off ? -46 : 0))
                            .scaleEffect(off ? 0.94 : 1)
                            .opacity(prog(b, 1 + Double(i), 0.2))
                    }
                    jack("OUT")
                }
                if b > 7.5 && b < 14 {
                    let t = easeInOut(prog(b, 7.5, 1.3))
                    Cursor(clicking: abs(b - 9) < 0.25 || abs(b - 13) < 0.25)
                        .offset(x: lerp(400, -245 + 42, t), y: lerp(420, 120 - (phaserOff ? 46 : 0), t))
                }
            }
        }
    }
    func jack(_ s: String) -> some View {
        VStack(spacing: 6) {
            Circle().fill(Color(white: 0.25)).overlay(Circle().fill(Color.black).padding(9)).frame(width: 40, height: 40)
            Text(s).font(.system(size: 16, weight: .heavy)).foregroundStyle(style.dim)
        }
    }
}

// MARK: - 3. knobs

struct KnobScene: View {
    let style: PromoStyle
    let b: Double
    var body: some View {
        let t1 = easeInOut(prog(b, 1, 3)), t2 = easeInOut(prog(b, 4, 3)), t3 = easeInOut(prog(b, 7, 3))
        let time = Int(lerp(lerp(280, 460, t1), 357, t3))
        let fb = Int(lerp(20, 42, t2))
        let mix = Int(lerp(lerp(30, 55, t1), 40, t3))
        let level = Int(lerp(100, 120, t2))
        HStack(spacing: 120) {
            PedalBody(color: Theme.color(for: "Delay"), corner: 26) {
                VStack(spacing: 30) {
                    HStack { LED(on: true, size: 16); Spacer(); Text("DELAY").font(.system(size: 16, weight: .heavy)).tracking(3).foregroundStyle(.white.opacity(0.8)) }
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(150)), count: 3), spacing: 26) {
                        knob("Time", "\(time)", time, 4000)
                        knob("F.B", "\(fb)", fb, 101)
                        knob("Mix", "\(mix)", mix, 101)
                        knob("HiDMP", "8", 7, 11)
                        knob("Level", "\(level)", level, 151)
                        knob("Tail", "ON", 1, 2)
                    }
                    .padding(22)
                    .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 16))
                    Text("Delay").font(.system(size: 52, weight: .black, design: .rounded)).foregroundStyle(.white)
                    Circle().fill(LinearGradient(colors: [Color(white: 0.9), Color(white: 0.45)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 80, height: 80)
                }
                .padding(40)
            }
            .frame(width: 620, height: 860)
            .rotation3DEffect(.degrees(8 * (1 - easeOut(prog(b, 0, 1.5)))), axis: (x: 0, y: 1, z: 0))
            .offset(x: -40 * (1 - easeOut(prog(b, 0, 1.5))))

            VStack(alignment: .leading, spacing: 40) {
                Caption(style: style, title: "Every knob.\nLive.", subtitle: "Turn it on the Mac, hear it on the pedal.\nDouble-click any knob to reset it.", p: prog(b, 0.5, 1), align: .leading)
                HStack(spacing: 12) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                    Text("Sent to the pedal")
                }
                .font(.system(size: 26, weight: .bold))
                .padding(.horizontal, 22).padding(.vertical, 12)
                .background(style.accent.opacity(0.25 + 0.5 * beatPulse(b, sharp: 4)), in: Capsule())
                .opacity(prog(b, 2, 1))
            }
            .frame(width: 760, alignment: .leading)
        }
    }
    func knob(_ name: String, _ display: String, _ raw: Int, _ count: Int) -> some View {
        Knob(label: name, display: display, raw: raw, count: count, defaultRaw: 0, tint: .white, size: 100) { _ in }
            .scaleEffect(1.1)
    }
}

// MARK: - 4. effect library

struct LibraryScene: View {
    let style: PromoStyle
    let b: Double
    static let effects: [(String, String)] = EffectCatalog.ms100btEffectIDs.sorted().compactMap { id in
        EffectCatalog.name(for: id).map { ($0, EffectCatalog.category(for: id) ?? "") }
    }
    var body: some View {
        let query = typed("delay", prog(b, 3, 2.5))
        let scroll = b * 26
        ZStack {
            // scrolling wall of effects
            VStack(spacing: 18) {
                ForEach(0..<9, id: \.self) { row in
                    HStack(spacing: 18) {
                        ForEach(0..<11, id: \.self) { col in
                            let e = Self.effects[(row * 11 + col) % Self.effects.count]
                            let hit = !query.isEmpty && e.0.localizedCaseInsensitiveContains(query)
                            tile(e.0, e.1, hit: hit, dim: query.count >= 3 && !hit)
                        }
                    }
                    .offset(x: CGFloat((row % 2 == 0 ? -1 : 1) * 60) - CGFloat(scroll.truncatingRemainder(dividingBy: 160)))
                }
            }
            .rotationEffect(.degrees(-8))
            .scaleEffect(1.15)
            .opacity(0.9)
            LinearGradient(colors: [style.bgTop.opacity(0.95), style.bgTop.opacity(0.2), style.bgBottom.opacity(0.95)],
                           startPoint: .top, endPoint: .bottom)
            VStack(spacing: 40) {
                Caption(style: style, title: "100 effects", subtitle: "Browse by category, search by name or knob, swap in one click.", p: prog(b, 0.3, 1))
                HStack(spacing: 14) {
                    Image(systemName: "magnifyingglass")
                    Text(query.isEmpty ? "Search effects" : query + (Int(b * 2) % 2 == 0 ? "|" : " "))
                        .foregroundStyle(query.isEmpty ? style.dim : style.text)
                    Spacer()
                }
                .font(.system(size: 34, weight: .medium))
                .padding(.horizontal, 28).padding(.vertical, 20)
                .frame(width: 720)
                .background(style.panel.opacity(0.95), in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(style.accent.opacity(0.6), lineWidth: 2))
                .opacity(prog(b, 2, 1))
            }
        }
    }
    func tile(_ name: String, _ cat: String, hit: Bool, dim: Bool) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) { Glyph(angle: -40); Glyph(angle: 30) }.scaleEffect(0.7)
            Text(name).font(.system(size: 17, weight: .black, design: .rounded)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(width: 142, height: 110)
        .background(LinearGradient(colors: [Theme.color(for: cat), Theme.color(for: cat).opacity(0.55)], startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(hit ? Color.white : .clear, lineWidth: 4))
        .scaleEffect(hit ? 1.12 : 1)
        .opacity(dim ? 0.25 : 1)
    }
}

// MARK: - 5. MIDI

struct MIDIScene: View {
    let style: PromoStyle
    let b: Double
    // presses: (beat, switch index)
    static let stomp: [(Double, Int)] = [(2, 1), (4, 2), (6, 1)]
    static let patch: [(Double, Int)] = [(10, 0), (12, 1), (14, 2)]
    static let patches: [(String, [(String, String)])] = [
        ("CRUNCH", [("Comp", "Dynamics"), ("Z Scream", "Drive"), ("Delay", "Delay"), ("Hall", "Reverb")]),
        ("DREAMY", [("Chorus", "Modulation"), ("Delay", "Delay"), ("Hall", "Reverb"), ("Tremolo", "Modulation")]),
        ("LEAD", [("Booster", "Drive"), ("Z Scream", "Drive"), ("Delay", "Delay"), ("Plate", "Reverb")]),
        ("AMBIENT", [("Phaser", "Modulation"), ("Delay", "Delay"), ("Hall", "Reverb"), ("Tremolo", "Modulation")]),
    ]
    var body: some View {
        let patchMode = b >= 8
        let presses = Self.stomp + Self.patch
        let last = presses.last { $0.0 <= b }
        let patchIndex = Self.patch.filter { $0.0 <= b }.last.map { $0.1 + 1 } ?? 0
        let (patchName, chain) = Self.patches[patchIndex]
        let z = !(b >= 2 && b < 6) // Z Scream on/off
        let d = !(b >= 4)          // Delay off after second press
        VStack(spacing: 54) {
            Caption(style: style, title: "Stomp with any MIDI footswitch",
                    subtitle: "Bluetooth or USB · Stomp mode toggles effects · Patch mode loads patches", p: prog(b, 0.3, 1))
            HStack(spacing: 110) {
                // controller (message chip floats over this row; see overlay below)
                VStack(spacing: 22) {
                    Text(patchMode ? "PATCH" : "STOMP")
                        .font(.system(size: 22, weight: .heavy)).tracking(2)
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .background(patchMode ? style.accent : Color(white: 0.3), in: Capsule())
                        .foregroundStyle(patchMode ? Color.black : .white)
                        .scaleEffect(1 + 0.25 * exp(-max(b - 8, 0) * 4) * (b >= 8 ? 1 : 0))
                    HStack(spacing: 40) {
                        ForEach(0..<4, id: \.self) { i in
                            let pressed = presses.contains { abs(b - $0.0) < 0.18 && $0.1 == i }
                            VStack(spacing: 14) {
                                LED(on: last?.1 == i, color: style.accent2, size: 14)
                                Circle().fill(LinearGradient(colors: [Color(white: 0.85), Color(white: 0.4)], startPoint: .top, endPoint: .bottom))
                                    .frame(width: 74, height: 74).scaleEffect(pressed ? 0.82 : 1)
                                    .shadow(color: .black.opacity(0.6), radius: 5, y: 4)
                                Text("\(i + 1)").font(.system(size: 20, weight: .bold)).foregroundStyle(style.dim)
                            }
                        }
                    }
                    .padding(.horizontal, 40).padding(.vertical, 30)
                    .background(RoundedRectangle(cornerRadius: 22).fill(Color(white: 0.11)).shadow(color: .black.opacity(0.5), radius: 20, y: 12))
                }
                // pedal chain
                VStack(spacing: 64) {
                    Text(patchName).font(.system(size: 48, weight: .black, design: style.titleDesign))
                        .id(patchName)
                    HStack(spacing: 22) {
                        ForEach(chain.indices, id: \.self) { i in
                            let on = patchMode ? true : (i == 1 ? z : i == 2 ? d : true)
                            PromoPedal(name: chain[i].0, category: chain[i].1, on: on, knobs: 2, width: 150)
                                .offset(y: on ? 0 : -34)
                        }
                    }
                }
            }
            .overlay { chip }
        }
    }

    @ViewBuilder var chip: some View {
        let presses = Self.stomp + Self.patch
        let patchMode = b >= 8
        if let l = presses.last(where: { $0.0 <= b }), b - l.0 < 0.9 {
                let t = easeOut(prog(b, l.0, 0.9))
                Text(patchMode ? "PC \(l.1) · ch 1" : "CC \(80 + l.1) = 127")
                    .font(.system(size: 26, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(style.accent2.opacity(0.9), in: Capsule())
                    .foregroundStyle(.black)
                    .offset(x: lerp(-330, 330, t), y: 170 + 40 * sin(t * .pi))
                    .opacity(1 - t * 0.8)
        }
    }
}

// MARK: - 6. AI

struct AIScene: View {
    let style: PromoStyle
    let b: Double
    var body: some View {
        HStack(spacing: 90) {
            VStack(alignment: .leading, spacing: 34) {
                Caption(style: style, title: "Describe a sound.\nGet a patch.", subtitle: "A tone assistant that builds patches\nfrom plain words. Claude, ChatGPT or a\nlocal model, with your own key.", p: prog(b, 0.3, 1), align: .leading)
            }
            .frame(width: 720, alignment: .leading)
            chat.frame(width: 860, height: 760)
        }
    }

    var chat: some View {
        let request = "Edge-style dotted-eighth delay with a little shimmer"
        let chips: [(String, String)] = [("Comp", "Dynamics"), ("Delay", "Delay"), ("Chorus", "Modulation"), ("Hall", "Reverb")]
        return VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(style.accent)
                Text("Tone Assistant").font(.system(size: 26, weight: .bold))
                Text("· Claude").font(.system(size: 22)).foregroundStyle(style.dim)
                Spacer()
            }
            Divider().overlay(Color.white.opacity(0.1))
            HStack {
                Spacer(minLength: 120)
                Text(typed(request, prog(b, 1, 3)))
                    .font(.system(size: 25, weight: .medium))
                    .padding(.horizontal, 20).padding(.vertical, 14)
                    .background(style.accent, in: RoundedRectangle(cornerRadius: 18))
                    .foregroundStyle(.black)
            }
            .opacity(prog(b, 1.1, 0.2))
            if b > 4.3 && b < 6.2 {
                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle().fill(style.dim).frame(width: 12).opacity(0.3 + 0.7 * beatPulse(b * 2 + Double(i) * 0.33, sharp: 4))
                    }
                    Text("Thinking…").foregroundStyle(style.dim)
                }
                .font(.system(size: 22))
            }
            ForEach(Array(["Browsed 14 effects in Delay", "Looked up Delay, Chorus, Hall", "Read the current patch"].enumerated()), id: \.offset) { i, line in
                Label(line, systemImage: "wrench.and.screwdriver")
                    .font(.system(size: 20)).foregroundStyle(style.dim)
                    .opacity(prog(b, 5 + Double(i) * 0.5, 0.3))
            }
            Text(typed("Dotted-eighth delay into a slow chorus and a bright hall. Play single notes and let the repeats bounce.", prog(b, 7, 1.5)))
                .font(.system(size: 23))
                .frame(maxWidth: .infinity, alignment: .leading)
            // proposal card
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("EDGE DLY").font(.system(size: 30, weight: .black, design: .rounded))
                    Spacer()
                    Label("126", systemImage: "metronome").font(.system(size: 20)).foregroundStyle(style.dim)
                }
                HStack(spacing: 10) {
                    ForEach(chips.indices, id: \.self) { i in
                        let p = easeOutBack(prog(b, 9 + Double(i) * 0.5, 0.6))
                        VStack(spacing: 6) {
                            LED(on: b >= 13.2, size: 9)
                            Text(chips[i].0).font(.system(size: 18, weight: .heavy))
                        }
                        .frame(maxWidth: .infinity, minHeight: 74)
                        .background(Theme.color(for: chips[i].1).opacity(0.9), in: RoundedRectangle(cornerRadius: 10))
                        .scaleEffect(p).opacity(min(p, 1))
                    }
                }
                HStack(spacing: 16) {
                    if b < 13.2 {
                        Text("Try on pedal").font(.system(size: 21, weight: .bold))
                            .padding(.horizontal, 22).padding(.vertical, 11)
                            .background(style.accent, in: Capsule()).foregroundStyle(.black)
                            .scaleEffect(abs(b - 13) < 0.2 ? 0.9 : 1)
                        Text("Knobs").foregroundStyle(style.dim)
                    } else {
                        Label("Playing on the pedal", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 22, weight: .semibold)).foregroundStyle(.green)
                    }
                    Spacer()
                }
            }
            .padding(22)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
            .opacity(prog(b, 8.6, 0.4))
            Spacer(minLength: 0)
        }
        .padding(30)
        .background(style.panel.opacity(0.96), in: RoundedRectangle(cornerRadius: 28))
        .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(Color.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 20)
        .overlay(alignment: .bottomLeading) {
            if b > 11.5 && b < 14 {
                Cursor(clicking: abs(b - 13) < 0.25)
                    .offset(x: lerp(600, 98, easeInOut(prog(b, 11.5, 1.3))), y: lerp(60, -158, easeInOut(prog(b, 11.5, 1.3))))
            }
        }
    }
}

// MARK: - 7. backup & safety

struct BackupScene: View {
    let style: PromoStyle
    let b: Double
    static let names = ["CLEAN", "CRUNCH", "LEAD", "DREAMY", "AMBIENT", "FUNK", "BLUES", "SHIMMER", "ROCK", "SURF"]
    var body: some View {
        let n = Int(lerp(0, 50, easeInOut(prog(b, 0.5, 5))))
        HStack(spacing: 100) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Reading patch \(n) of 50").font(.system(size: 26, weight: .semibold)).foregroundStyle(style.dim)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1)).frame(width: 620, height: 16)
                    Capsule().fill(style.accent).frame(width: 620 * CGFloat(n) / 50, height: 16)
                }
                VStack(spacing: 8) {
                    ForEach(0..<7, id: \.self) { i in
                        let slot = max(n - 6, 1) + i
                        let read = slot <= n
                        HStack(spacing: 16) {
                            Text(String(format: "%02d", slot)).font(.system(size: 20, weight: .bold, design: .monospaced)).foregroundStyle(style.dim)
                            Text(Self.names[slot % Self.names.count]).font(.system(size: 22, weight: .semibold))
                            Spacer()
                            HStack(spacing: 4) {
                                ForEach(0..<4, id: \.self) { k in
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Theme.color(for: ["Drive", "Modulation", "Delay", "Reverb", "Dynamics"][(slot + k) % 5]))
                                        .frame(width: 26, height: 10)
                                }
                            }
                        }
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(Color.white.opacity(slot == n ? 0.12 : 0.04), in: RoundedRectangle(cornerRadius: 10))
                        .opacity(read ? 1 : 0.3)
                    }
                }
                .frame(width: 620)
            }
            VStack(alignment: .leading, spacing: 30) {
                Caption(style: style, title: "Back up all 50.", subtitle: "Save, load, import and export patches.\nEditing sits behind a lock, and the\nfirmware is never touched.", p: prog(b, 0.3, 1), align: .leading)
                Label("Safe by design", systemImage: "lock.shield.fill")
                    .font(.system(size: 28, weight: .bold)).foregroundStyle(style.accent2)
                    .opacity(prog(b, 3, 1))
            }
            .frame(width: 700, alignment: .leading)
        }
    }
}

// MARK: - 8. outro

struct OutroScene: View {
    let style: PromoStyle
    let b: Double
    let icon: NSImage
    var body: some View {
        VStack(spacing: 30) {
            Image(nsImage: icon).resizable().frame(width: 220, height: 220)
                .scaleEffect(easeOutBack(prog(b, 0, 1.2)))
                .shadow(color: style.accent.opacity(0.5), radius: 40)
            Text("MS-100BT Link").font(.system(size: 96, weight: .black, design: style.titleDesign))
                .opacity(prog(b, 0.8, 1))
            Text("Free & open source · macOS · MIT").font(.system(size: 36, weight: .semibold)).foregroundStyle(style.accent2)
                .opacity(prog(b, 1.6, 1))
            Text("github.com/anthonyessaye/MS100BT-Link")
                .font(.system(size: 34, weight: .medium, design: .monospaced))
                .padding(.horizontal, 28).padding(.vertical, 14)
                .background(Color.white.opacity(0.08), in: Capsule())
                .opacity(prog(b, 2.4, 1))
            Text("Unofficial. Not affiliated with Zoom Corporation.").font(.system(size: 20)).foregroundStyle(style.dim)
                .opacity(prog(b, 3.2, 1))
        }
    }
}
