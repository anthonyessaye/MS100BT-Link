import SwiftUI

// Flat illustrations for the promo: a guitarist, a Bluetooth footswitch, a phone and a Mac window
// running the app, and a hand tapping the phone. Everything animates from the beat `b`.

private let skin = Color(red: 0.93, green: 0.74, blue: 0.6)
private let skinShade = Color(red: 0.82, green: 0.6, blue: 0.48)
private let hair = Color(red: 0.16, green: 0.11, blue: 0.09)
private let shirt = Color(red: 0.2, green: 0.24, blue: 0.3)
private let jeans = Color(red: 0.19, green: 0.3, blue: 0.5)
private let shoe = Color(white: 0.12)

/// Draws a thick limb from `a` through `joint` to `c` with round joints.
private func limb(_ ctx: inout GraphicsContext, _ a: CGPoint, _ joint: CGPoint, _ c: CGPoint, _ width: CGFloat, _ color: Color) {
    var p = Path()
    p.move(to: a); p.addLine(to: joint); p.addLine(to: c)
    ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
}

private func polar(_ from: CGPoint, _ length: CGFloat, _ degrees: Double) -> CGPoint {
    let r = degrees * .pi / 180
    return CGPoint(x: from.x + length * CGFloat(cos(r)), y: from.y + length * CGFloat(sin(r)))
}

/// A guitarist standing with an electric guitar. `stomp` 0…1 lifts the right foot (1 = highest);
/// `strum` is the strumming phase; `bob` nods the head on the beat.
struct Guitarist: View {
    var stomp: Double = 0
    var strum: Double = 0
    var bob: Double = 0
    var body: some View {
        Canvas { ctx, size in
            let s = size.width / 700 // drawn on a 700 × 1000 grid
            ctx.scaleBy(x: s, y: s)
            let hip = CGPoint(x: 350, y: 560)
            let bobY = CGFloat(6 * bob)

            // legs: left planted, right lifts toward the footswitch
            let lHip = CGPoint(x: 315, y: hip.y), rHip = CGPoint(x: 385, y: hip.y)
            let lKnee = CGPoint(x: 300, y: 740), lFoot = CGPoint(x: 290, y: 920)
            let lift = CGFloat(easeInOut(stomp))
            let rKnee = CGPoint(x: 420 + 40 * lift, y: 740 - 70 * lift)
            let rFoot = CGPoint(x: 445 + 60 * lift, y: 920 - 90 * lift)
            limb(&ctx, lHip, lKnee, lFoot, 70, jeans)
            limb(&ctx, rHip, rKnee, rFoot, 70, jeans)
            for (f, dx) in [(lFoot, -18.0), (rFoot, 22.0)] {
                ctx.fill(Path(roundedRect: CGRect(x: f.x - 40 + dx, y: f.y - 8, width: 92, height: 38), cornerRadius: 16), with: .color(shoe))
            }

            // torso
            let chest = CGRect(x: 255, y: 300 + bobY * 0.4, width: 190, height: 290)
            ctx.fill(Path(roundedRect: chest, cornerRadius: 60), with: .linearGradient(
                Gradient(colors: [shirt.opacity(1), Color(white: 0.12)]), startPoint: CGPoint(x: 350, y: 300), endPoint: CGPoint(x: 350, y: 600)))
            // strap
            var strap = Path()
            strap.move(to: CGPoint(x: 290, y: 310)); strap.addLine(to: CGPoint(x: 430, y: 520))
            ctx.stroke(strap, with: .color(Color(red: 0.35, green: 0.18, blue: 0.1)), lineWidth: 16)

            // head and neck
            ctx.fill(Path(CGRect(x: 332, y: 260 + bobY, width: 36, height: 50)), with: .color(skinShade))
            let head = CGRect(x: 295, y: 150 + bobY, width: 110, height: 125)
            ctx.fill(Path(ellipseIn: head), with: .color(skin))
            var hairPath = Path()
            hairPath.addEllipse(in: CGRect(x: 288, y: 132 + bobY, width: 124, height: 82))
            hairPath.addRect(CGRect(x: 289, y: 170 + bobY, width: 22, height: 50))
            ctx.fill(hairPath, with: .color(hair))
            ctx.fill(Path(ellipseIn: CGRect(x: 368, y: 205 + bobY, width: 9, height: 11)), with: .color(Color(white: 0.15))) // eye
            var smile = Path()
            smile.addArc(center: CGPoint(x: 372, y: 238 + bobY), radius: 13, startAngle: .degrees(20), endAngle: .degrees(120), clockwise: false)
            ctx.stroke(smile, with: .color(Color(white: 0.2)), lineWidth: 3)

            // guitar (angled across the body)
            var g = ctx
            g.translateBy(x: 360, y: 470)
            g.rotate(by: .degrees(-24))
            g.fill(Path(roundedRect: CGRect(x: -330, y: -14, width: 300, height: 28), cornerRadius: 4), with: .color(Color(red: 0.42, green: 0.25, blue: 0.13))) // neck
            g.fill(Path(roundedRect: CGRect(x: -380, y: -24, width: 60, height: 48), cornerRadius: 10), with: .color(Color(white: 0.1))) // headstock
            for k in 0..<6 { // frets and strings
                g.fill(Path(CGRect(x: -320 + CGFloat(k) * 48, y: -14, width: 3, height: 28)), with: .color(Color(white: 0.75).opacity(0.6)))
            }
            var bodyPath = Path()
            bodyPath.addEllipse(in: CGRect(x: -70, y: -95, width: 210, height: 190))
            bodyPath.addEllipse(in: CGRect(x: -110, y: -72, width: 150, height: 144))
            g.fill(bodyPath, with: .radialGradient(Gradient(colors: [Color(red: 1, green: 0.62, blue: 0.2), Color(red: 0.72, green: 0.15, blue: 0.05)]),
                                                    center: CGPoint(x: 30, y: 0), startRadius: 10, endRadius: 130))
            g.fill(Path(roundedRect: CGRect(x: -40, y: -46, width: 26, height: 92), cornerRadius: 4), with: .color(Color(white: 0.9))) // pickup
            g.fill(Path(roundedRect: CGRect(x: 30, y: -46, width: 26, height: 92), cornerRadius: 4), with: .color(Color(white: 0.9)))
            for k in 0..<6 {
                g.fill(Path(CGRect(x: -330, y: -11 + CGFloat(k) * 4.4, width: 420, height: 1.3)), with: .color(Color.white.opacity(0.55)))
            }

            // arms: fretting arm to the neck, strumming arm over the strings
            let lShoulder = CGPoint(x: 275, y: 335 + bobY * 0.4), rShoulder = CGPoint(x: 425, y: 335 + bobY * 0.4)
            let fretHand = CGPoint(x: 150, y: 520)
            limb(&ctx, lShoulder, CGPoint(x: 200, y: 460), fretHand, 44, shirt)
            ctx.fill(Path(ellipseIn: CGRect(x: fretHand.x - 26, y: fretHand.y - 24, width: 52, height: 48)), with: .color(skin))
            let swing = 14 * sin(strum * 2 * .pi)
            let rElbow = polar(rShoulder, 140, 95 - swing * 0.3)
            let rHand = polar(rElbow, 120, 165 + swing)
            limb(&ctx, rShoulder, rElbow, rHand, 44, shirt)
            ctx.fill(Path(ellipseIn: CGRect(x: rHand.x - 26, y: rHand.y - 24, width: 52, height: 48)), with: .color(skin))
        }
    }
}

/// A 4-switch Bluetooth MIDI footswitch on the floor.
struct Footswitch4: View {
    var pressed: Int? = nil
    var lit: Int? = nil
    var accent: Color
    var body: some View {
        HStack(spacing: 22) {
            ForEach(0..<4, id: \.self) { i in
                VStack(spacing: 8) {
                    LED(on: lit == i, color: accent, size: 10)
                    Circle().fill(LinearGradient(colors: [Color(white: 0.85), Color(white: 0.4)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 46, height: 46).scaleEffect(pressed == i ? 0.8 : 1)
                }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.1)).shadow(color: .black.opacity(0.6), radius: 10, y: 8))
        .overlay(alignment: .topTrailing) {
            Image(systemName: "dot.radiowaves.right").font(.system(size: 16, weight: .bold)).foregroundStyle(accent).padding(8)
        }
    }
}

/// Bluetooth waves travelling from one point to the other (t 0…1).
struct Waves: View {
    let t: Double
    let color: Color
    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { k in
                let p = clamp01(t * 1.4 - Double(k) * 0.2)
                Circle().stroke(color.opacity(0.9 * (1 - p)), lineWidth: 5)
                    .frame(width: 40 + 260 * p, height: 40 + 260 * p)
            }
        }
    }
}

/// The app on an Android phone: top bar, the selected pedal, the chain, and the bottom tab bar.
struct PhoneApp: View {
    let style: PromoStyle
    var patch = "AmerIdiot"
    var slot = 1
    var chain: [(String, String, Bool)] = [("ZNR", "Dynamics", true), ("Booster", "Drive", false), ("MS 1959", "Amp", true), ("Hall", "Reverb", true)]
    var selected = 2
    var tab = 0
    var body: some View {
        let fx = chain[min(selected, chain.count - 1)]
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.left").font(.system(size: 14, weight: .bold))
                Text(String(format: "%02d", slot)).font(.system(size: 14, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 6).padding(.vertical, 2).background(style.accent, in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.black)
                Text(patch).font(.system(size: 20, weight: .black, design: .rounded)).lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .bold))
                Spacer()
                Image(systemName: "lock.open.fill").font(.system(size: 16)).foregroundStyle(style.accent)
            }
            .padding(.horizontal, 16).padding(.top, 34).padding(.bottom, 12)
            .background(Color(white: 0.14))
            Spacer(minLength: 10)
            PromoPedal(name: fx.0, category: fx.1, on: fx.2, knobs: 3, width: 190)
            Spacer(minLength: 10)
            HStack(spacing: 8) {
                ForEach(chain.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 8)
                        .fill(LinearGradient(colors: [Theme.color(for: chain[i].1), Theme.color(for: chain[i].1).opacity(0.6)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 52, height: 68)
                        .overlay(LED(on: chain[i].2, size: 7).padding(6), alignment: .top)
                        .saturation(chain[i].2 ? 1 : 0.15)
                        .offset(y: chain[i].2 ? 0 : -10)
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(i == selected ? Color.white : .clear, lineWidth: 2).padding(-3))
                }
            }
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(Color.black.opacity(0.35))
            HStack {
                ForEach(Array(["square.grid.2x2.fill", "music.note.list", "sparkles", "ellipsis"].enumerated()), id: \.offset) { i, icon in
                    VStack(spacing: 4) {
                        Image(systemName: icon).font(.system(size: 18))
                            .frame(width: 52, height: 26)
                            .background(i == tab ? style.accent.opacity(0.35) : .clear, in: Capsule())
                        Text(["Board", "Patches", "AI", "More"][i]).font(.system(size: 11, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 10).padding(.bottom, 12)
            .background(Color(white: 0.15))
        }
        .frame(width: 330, height: 690)
        .background(LinearGradient(colors: [Color(white: 0.08), Color(white: 0.13)], startPoint: .top, endPoint: .bottom))
        .clipShape(RoundedRectangle(cornerRadius: 40))
        .overlay(RoundedRectangle(cornerRadius: 40).strokeBorder(Color(white: 0.06), lineWidth: 10))
        .overlay(Capsule().fill(Color.black).frame(width: 16, height: 16).padding(.top, 12), alignment: .top) // camera
        .shadow(color: .black.opacity(0.6), radius: 30, y: 20)
    }
}

/// The app's main window on the Mac, simplified.
struct MacApp: View {
    let style: PromoStyle
    var patch = "AmerIdiot"
    var chain: [(String, String, Bool)] = [("ZNR", "Dynamics", true), ("Booster", "Drive", false), ("MS 1959", "Amp", true), ("Hall", "Reverb", true)]
    var selected = 2
    var body: some View {
        let fx = chain[min(selected, chain.count - 1)]
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    ForEach([Color.red, .yellow, .green], id: \.self) { c in Circle().fill(c.opacity(0.85)).frame(width: 13) }
                }
                Spacer().frame(width: 30)
                pill("ZOOM MS-100BT", dot: true)
                Spacer()
                HStack(spacing: 8) {
                    Text("01").font(.system(size: 14, weight: .bold, design: .monospaced)).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(style.accent, in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.black)
                    Text(patch).font(.system(size: 20, weight: .bold, design: .rounded))
                }
                .padding(.horizontal, 16).padding(.vertical, 6).background(Color.black.opacity(0.35), in: Capsule())
                Spacer()
                pill("Editing", active: true); pill("Effects"); pill("AI"); pill("MIDI")
            }
            .padding(.horizontal, 18).frame(height: 56).background(Color(white: 0.14))
            HStack(spacing: 0) {
                VStack {
                    Spacer(minLength: 16)
                    PromoPedal(name: fx.0, category: fx.1, on: fx.2, knobs: 3, width: 210)
                    Spacer(minLength: 16)
                    HStack(spacing: 14) {
                        ForEach(chain.indices, id: \.self) { i in
                            VStack(spacing: 6) {
                                LED(on: chain[i].2, size: 8)
                                Text(chain[i].0).font(.system(size: 13, weight: .heavy, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
                                Spacer(minLength: 0)
                                Circle().fill(Color(white: 0.75)).frame(width: 22)
                            }
                            .padding(8)
                            .frame(width: 92, height: 112)
                            .background(LinearGradient(colors: [Theme.color(for: chain[i].1), Theme.color(for: chain[i].1).opacity(0.6)], startPoint: .top, endPoint: .bottom),
                                        in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(i == selected ? Color.white : .clear, lineWidth: 2).padding(-4))
                            .saturation(chain[i].2 ? 1 : 0.15)
                            .offset(y: chain[i].2 ? 0 : -14)
                        }
                    }
                    .padding(.vertical, 18).frame(maxWidth: .infinity).background(Color.black.opacity(0.35))
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Patches").font(.system(size: 16, weight: .bold))
                    ForEach(Array(["AmerIdiot", "Bourj", "Clean Funk", "LEAD 80s", "Shimmer", "Blues Bar"].enumerated()), id: \.offset) { i, n in
                        HStack(spacing: 8) {
                            Text(String(format: "%02d", i + 1)).font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(i == 0 ? Color.black : style.dim)
                                .padding(.horizontal, 4).background(i == 0 ? style.accent : .clear, in: RoundedRectangle(cornerRadius: 3))
                            Text(n).font(.system(size: 14, weight: .semibold))
                        }
                    }
                    Spacer()
                }
                .padding(16).frame(width: 190).frame(maxHeight: .infinity).background(Color(white: 0.15))
            }
        }
        .frame(width: 900, height: 600)
        .background(LinearGradient(colors: [Color(white: 0.08), Color(white: 0.13)], startPoint: .top, endPoint: .bottom))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.6), radius: 40, y: 24)
    }

    func pill(_ t: String, active: Bool = false, dot: Bool = false) -> some View {
        HStack(spacing: 6) {
            if dot { Circle().fill(Color.green).frame(width: 8) }
            Text(t).font(.system(size: 13, weight: .semibold))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(active ? style.accent : Color(white: 0.22), in: Capsule())
        .foregroundStyle(active ? Color.black : .white)
    }
}

/// A hand holding the phone from below; the thumb reaches the tab at `tapX` (phone coordinates in a
/// 360 × 900 frame where the phone sits at (15, 10)); `tap` 1 = pressing.
struct HoldingHand: View {
    var tapX: Double = 56
    var tap: Double = 0
    var body: some View {
        Canvas { ctx, _ in
            // fingers curling over the right edge (tips on the screen side)
            for k in 0..<3 {
                let y = 600 + CGFloat(k) * 58
                ctx.fill(Path(roundedRect: CGRect(x: 322, y: y, width: 70, height: 46), cornerRadius: 23), with: .color(skin))
                ctx.fill(Path(roundedRect: CGRect(x: 326, y: y + 8, width: 18, height: 30), cornerRadius: 9), with: .color(skinShade.opacity(0.5)))
            }
            // palm coming up from below, cupping the phone's lower half
            var palm = Path()
            palm.move(to: CGPoint(x: -10, y: 1200))
            palm.addCurve(to: CGPoint(x: 120, y: 700), control1: CGPoint(x: -20, y: 790), control2: CGPoint(x: 40, y: 720))
            palm.addCurve(to: CGPoint(x: 390, y: 640), control1: CGPoint(x: 220, y: 680), control2: CGPoint(x: 330, y: 620))
            palm.addLine(to: CGPoint(x: 400, y: 1200))
            palm.closeSubpath()
            ctx.fill(palm, with: .linearGradient(Gradient(colors: [skin, skinShade]), startPoint: CGPoint(x: 200, y: 680), endPoint: CGPoint(x: 200, y: 1000)))
            // thumb: from the palm up to the tab (lifted a little when not pressing)
            let base = CGPoint(x: 70, y: 780)
            let tip = CGPoint(x: tapX - 8, y: 668 - 22 * (1 - tap))
            var thumb = Path()
            thumb.move(to: base); thumb.addLine(to: tip)
            ctx.stroke(thumb, with: .color(skinShade), style: StrokeStyle(lineWidth: 62, lineCap: .round))
            ctx.stroke(thumb, with: .color(skin), style: StrokeStyle(lineWidth: 54, lineCap: .round))
            let a = atan2(tip.y - base.y, tip.x - base.x)
            var nail = ctx
            nail.translateBy(x: tip.x - 6 * cos(a), y: tip.y - 6 * sin(a))
            nail.rotate(by: .radians(a + .pi / 2))
            nail.fill(Path(roundedRect: CGRect(x: -15, y: -4, width: 30, height: 34), cornerRadius: 12), with: .color(Color.white.opacity(0.4)))
            if tap > 0.5 { // touch ripple
                ctx.stroke(Path(ellipseIn: CGRect(x: tapX - 34, y: 634, width: 68, height: 68)), with: .color(Color.white.opacity(0.6)), lineWidth: 3)
            }
        }
    }
}
