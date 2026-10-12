import SwiftUI

/// Visual style of one video version.
struct PromoStyle {
    let name: String
    let bpm: Double
    let bgTop: Color
    let bgBottom: Color
    let accent: Color
    let accent2: Color
    let text: Color
    let dim: Color
    let panel: Color
    let synthGrid: Bool
    let titleDesign: Font.Design

    static let studio = PromoStyle(
        name: "studio", bpm: 124,
        bgTop: Color(white: 0.06), bgBottom: Color(white: 0.13),
        accent: Color(red: 1.0, green: 0.55, blue: 0.15), accent2: Color(red: 1.0, green: 0.78, blue: 0.4),
        text: .white, dim: Color.white.opacity(0.55), panel: Color(white: 0.15),
        synthGrid: false, titleDesign: .rounded)

    static let neon = PromoStyle(
        name: "neon", bpm: 104,
        bgTop: Color(red: 0.05, green: 0.02, blue: 0.14), bgBottom: Color(red: 0.20, green: 0.04, blue: 0.30),
        accent: Color(red: 1.0, green: 0.25, blue: 0.75), accent2: Color(red: 0.25, green: 0.9, blue: 1.0),
        text: .white, dim: Color.white.opacity(0.6), panel: Color(red: 0.12, green: 0.06, blue: 0.22),
        synthGrid: true, titleDesign: .default)
}

// MARK: - animation helpers

func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }
/// 0→1 progress of `b` through [start, start+dur].
func prog(_ b: Double, _ start: Double, _ dur: Double) -> Double { clamp01((b - start) / dur) }
func easeOut(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
func easeInOut(_ t: Double) -> Double { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
func easeOutBack(_ t: Double) -> Double {
    let c1 = 1.70158, c3 = c1 + 1
    return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
}
func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
/// Decaying flash on every beat (1 on the beat, fading).
func beatPulse(_ b: Double, sharp: Double = 7) -> Double { exp(-(b - floor(b)) * sharp) }
/// Typewriter: first n characters of `s` at progress t.
func typed(_ s: String, _ t: Double) -> String { String(s.prefix(Int((Double(s.count) * clamp01(t)).rounded(.down)))) }
