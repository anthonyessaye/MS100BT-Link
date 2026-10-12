// Draws the MS-100BT Link app icon (1024×1024 PNG).
// Usage: swift make-icon.swift out.png [mac|square|foreground]
//   mac (default): macOS tile with margins and shadow
//   square: full-bleed tile (iOS, Android legacy icons; the platform rounds the corners)
//   foreground: pedal and arcs only on transparent, inside Android's adaptive-icon safe zone
import AppKit

let S: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let rgb = CGColorSpaceCreateDeviceRGB()
func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }
func grad(_ colors: [CGColor]) -> CGGradient { CGGradient(colorsSpace: rgb, colors: colors as CFArray, locations: nil)! }
func rr(_ r: CGRect, _ rad: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil) }

let mode = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "mac"

// macOS icon grid: 824×824 body centred, corner radius ≈ 185, soft drop shadow.
let body = mode == "mac" ? CGRect(x: 100, y: 100, width: 824, height: 824) : CGRect(x: 0, y: 0, width: S, height: S)
let corner: CGFloat = mode == "mac" ? 185 : 0
if mode == "foreground" {
    // Content (arcs + pedal) is about 690 px wide; the adaptive safe zone is 66% of 1024. Scale it in.
    ctx.translateBy(x: 512, y: 512); ctx.scaleBy(x: 0.72, y: 0.72); ctx.translateBy(x: -540, y: -512)
}
ctx.saveGState()
if mode == "mac" {
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: c(0, 0, 0, 0.45))
}
if mode != "foreground" { ctx.addPath(rr(body, corner)); ctx.setFillColor(c(0.1, 0.1, 0.11)); ctx.fillPath() }
ctx.restoreGState()
ctx.saveGState()
if mode != "foreground" {
    ctx.addPath(rr(body, corner)); ctx.clip()
    ctx.drawLinearGradient(grad([c(0.2, 0.2, 0.22), c(0.07, 0.07, 0.08)]),
                           start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: [])
}
// wireless arcs, top right
ctx.setLineCap(.round)
for (i, r) in [CGFloat(52), 96, 140].enumerated() {
    ctx.setStrokeColor(c(1, 0.62, 0.25, 0.9 - CGFloat(i) * 0.25))
    ctx.setLineWidth(24)
    ctx.addArc(center: CGPoint(x: 706, y: 706), radius: r, startAngle: .pi * 0.08, endAngle: .pi * 0.42, clockwise: false)
    ctx.strokePath()
}
ctx.restoreGState()

// stompbox enclosure
let pedal = CGRect(x: 262, y: 170, width: 440, height: 600)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 30, color: c(0, 0, 0, 0.6))
ctx.addPath(rr(pedal, 56)); ctx.setFillColor(c(1, 0.55, 0.15)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(rr(pedal, 56)); ctx.clip()
ctx.drawLinearGradient(grad([c(1, 0.66, 0.26), c(0.86, 0.36, 0.06)]),
                       start: CGPoint(x: 0, y: pedal.maxY), end: CGPoint(x: 0, y: pedal.minY), options: [])
ctx.restoreGState()
ctx.addPath(rr(pedal.insetBy(dx: 3, dy: 3), 53)); ctx.setStrokeColor(c(1, 1, 1, 0.35)); ctx.setLineWidth(5); ctx.strokePath()

// knob panel
let panel = CGRect(x: pedal.minX + 34, y: pedal.maxY - 250, width: pedal.width - 68, height: 200)
ctx.addPath(rr(panel, 30)); ctx.setFillColor(c(0, 0, 0, 0.22)); ctx.fillPath()
for (i, angle) in [CGFloat(-50), 15, 70].enumerated() {
    let cx = panel.minX + panel.width * (CGFloat(i) + 0.5) / 3, cy = panel.midY - 6
    let r: CGFloat = 50
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 10, color: c(0, 0, 0, 0.55))
    ctx.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)); ctx.setFillColor(c(0.12, 0.12, 0.13)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)); ctx.clip()
    ctx.drawRadialGradient(grad([c(0.38, 0.38, 0.4), c(0.1, 0.1, 0.11)]),
                           startCenter: CGPoint(x: cx - 15, y: cy + 18), startRadius: 2,
                           endCenter: CGPoint(x: cx, y: cy), endRadius: r, options: [])
    ctx.restoreGState()
    let a = (90 - angle) * .pi / 180
    ctx.setStrokeColor(c(1, 1, 1)); ctx.setLineWidth(10); ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: cx + cos(a) * 12, y: cy + sin(a) * 12))
    ctx.addLine(to: CGPoint(x: cx + cos(a) * 38, y: cy + sin(a) * 38)); ctx.strokePath()
}

// LED with glow
let led = CGPoint(x: pedal.midX, y: panel.minY - 52)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 40, color: c(1, 0.15, 0.1, 1))
ctx.addEllipse(in: CGRect(x: led.x - 20, y: led.y - 20, width: 40, height: 40)); ctx.setFillColor(c(1, 0.2, 0.15)); ctx.fillPath()
ctx.restoreGState()
ctx.addEllipse(in: CGRect(x: led.x - 8, y: led.y + 2, width: 12, height: 12)); ctx.setFillColor(c(1, 1, 1, 0.7)); ctx.fillPath()

// footswitch
let fs = CGPoint(x: pedal.midX, y: pedal.minY + 120)
for (r, top, bottom) in [(CGFloat(78), c(0.92, 0.92, 0.94), c(0.45, 0.45, 0.48)), (52, c(0.62, 0.62, 0.65), c(0.85, 0.85, 0.88))] {
    ctx.saveGState()
    if r == 78 { ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 16, color: c(0, 0, 0, 0.55)) }
    ctx.addEllipse(in: CGRect(x: fs.x - r, y: fs.y - r, width: 2 * r, height: 2 * r)); ctx.setFillColor(bottom); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: fs.x - r, y: fs.y - r, width: 2 * r, height: 2 * r)); ctx.clip()
    ctx.drawLinearGradient(grad([top, bottom]), start: CGPoint(x: 0, y: fs.y + r), end: CGPoint(x: 0, y: fs.y - r), options: [])
    ctx.restoreGState()
}

// screws
for p in [CGPoint(x: pedal.minX + 26, y: pedal.maxY - 26), CGPoint(x: pedal.maxX - 26, y: pedal.maxY - 26),
          CGPoint(x: pedal.minX + 26, y: pedal.minY + 26), CGPoint(x: pedal.maxX - 26, y: pedal.minY + 26)] {
    ctx.addEllipse(in: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)); ctx.setFillColor(c(0.85, 0.85, 0.85)); ctx.fillPath()
}

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
