import SwiftUI
import ZoomCore

enum Theme {
    static let background = LinearGradient(colors: [Color(white: 0.075), Color(white: 0.12)],
                                           startPoint: .top, endPoint: .bottom)
    static let panel = Color(white: 0.14)
    static let panelRaised = Color(white: 0.18)
    static let stroke = Color.white.opacity(0.08)
    static let text = Color.white.opacity(0.92)
    static let dim = Color.white.opacity(0.5)
    static let accent = Color(red: 1.0, green: 0.55, blue: 0.15)

    static func color(for category: String?) -> Color {
        switch category {
        case "Dynamics": return Color(red: 0.18, green: 0.70, blue: 0.70)
        case "Filter": return Color(red: 0.35, green: 0.75, blue: 0.40)
        case "Drive", "Bass Drive": return Color(red: 0.95, green: 0.50, blue: 0.12)
        case "Amp", "Bass Amp", "Bass Preamp": return Color(red: 0.85, green: 0.22, blue: 0.20)
        case "Modulation": return Color(red: 0.58, green: 0.36, blue: 0.90)
        case "SFX": return Color(red: 0.92, green: 0.30, blue: 0.60)
        case "Delay": return Color(red: 0.20, green: 0.50, blue: 0.95)
        case "Reverb": return Color(red: 0.30, green: 0.35, blue: 0.85)
        default: return Color(white: 0.35)
        }
    }
}

/// Rotary knob: drag up/down (or scroll) to change, double-click for the default value.
struct Knob: View {
    let label: String
    let display: String
    let raw: Int
    let count: Int
    let defaultRaw: Int
    var tint: Color = Theme.accent
    var size: CGFloat = 64
    var enabled = true
    let onChange: (Int) -> Void

    @State private var dragStart: Int?

    private var fraction: Double { count > 1 ? Double(raw) / Double(count - 1) : 0 }
    private let sweep = 270.0

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().trim(from: 0, to: sweep / 360)
                    .stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(135))
                Circle().trim(from: 0, to: sweep / 360 * fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(135))
                    .shadow(color: tint.opacity(0.6), radius: 4)
                Circle()
                    .fill(RadialGradient(colors: [Color(white: 0.32), Color(white: 0.10)],
                                         center: .init(x: 0.35, y: 0.3), startRadius: 1, endRadius: size * 0.55))
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.6), lineWidth: 1))
                    .shadow(color: .black.opacity(0.6), radius: 4, y: 3)
                    .padding(size * 0.14)
                Capsule().fill(Color.white)
                    .frame(width: 3, height: size * 0.2)
                    .offset(y: -size * 0.2)
                    .rotationEffect(.degrees(-135 + sweep * fraction))
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { g in
                    guard enabled, count > 1 else { return }
                    let start = dragStart ?? raw
                    if dragStart == nil { dragStart = raw }
                    let span = max(Double(count - 1), 1)
                    let step = -g.translation.height / 180 * span // full range in 180 pt
                    let v = min(max(Int((Double(start) + step).rounded()), 0), count - 1)
                    if v != raw { onChange(v) }
                }
                .onEnded { _ in dragStart = nil })
            .onTapGesture(count: 2) { if enabled { onChange(defaultRaw) } }
            .opacity(enabled ? 1 : 0.55)
            .help("Drag up/down · double-click for default")

            Text(display)
                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.text)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.dim)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(width: size + 24)
    }
}

/// Two-state parameter (ON/OFF, MONO/P-P…) as a small toggle switch.
struct MiniSwitch: View {
    let label: String
    let options: [String]
    let raw: Int
    var enabled = true
    let onChange: (Int) -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                ForEach(options.indices, id: \.self) { i in
                    Text(options[i])
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .frame(minWidth: 34)
                        .background(i == raw ? Theme.accent : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                        .foregroundStyle(i == raw ? Color.black : Theme.dim)
                        .contentShape(Rectangle())
                        .onTapGesture { if enabled && i != raw { onChange(i) } }
                }
            }
            .padding(3)
            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
            .opacity(enabled ? 1 : 0.55)
            .frame(height: 64)
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold)).tracking(0.8)
                .foregroundStyle(Theme.dim)
        }
    }
}

/// Glowing status LED.
struct LED: View {
    let on: Bool
    var color: Color = Color(red: 1, green: 0.2, blue: 0.15)
    var size: CGFloat = 10
    var body: some View {
        Circle()
            .fill(on ? color : Color(white: 0.2))
            .overlay(Circle().fill(.white.opacity(on ? 0.5 : 0.08)).scaleEffect(0.35).offset(x: -size * 0.12, y: -size * 0.12))
            .frame(width: size, height: size)
            .shadow(color: on ? color.opacity(0.9) : .clear, radius: on ? 6 : 0)
    }
}

/// Stompbox body: category-coloured enclosure with screws and a bevel.
struct PedalBody<Content: View>: View {
    let color: Color
    var corner: CGFloat = 16
    var empty = false
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            if empty {
                RoundedRectangle(cornerRadius: corner)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .foregroundStyle(Theme.dim.opacity(0.6))
                    .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: corner))
            } else {
                RoundedRectangle(cornerRadius: corner)
                    .fill(LinearGradient(colors: [color.opacity(0.95), color.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: corner)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .black.opacity(0.3)],
                                                     startPoint: .top, endPoint: .bottom), lineWidth: 1.2))
                    .overlay(RoundedRectangle(cornerRadius: corner - 6)
                        .fill(Color.black.opacity(0.22)).padding(8))
                    .shadow(color: .black.opacity(0.55), radius: 12, y: 8)
                GeometryReader { g in
                    ForEach(0..<4, id: \.self) { i in
                        Circle().fill(Color(white: 0.75)).frame(width: 5, height: 5)
                            .position(x: i % 2 == 0 ? 10 : g.size.width - 10, y: i < 2 ? 10 : g.size.height - 10)
                    }
                }
            }
            content
        }
    }
}
