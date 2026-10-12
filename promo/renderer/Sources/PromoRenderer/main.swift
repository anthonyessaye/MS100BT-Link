import AppKit
import SwiftUI

// Usage:
//   PromoRenderer <studio|neon> <icon.png> --frame <beat> <out.png>   render one still (preview)
//   PromoRenderer <studio|neon> <icon.png> --video [fps]              raw RGBA frames to stdout (pipe into ffmpeg)

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write(Data("usage: PromoRenderer <studio|neon> <icon.png> --frame <beat> <out.png> | --video [fps]\n".utf8))
    exit(64)
}
let style = args[1] == "neon" ? PromoStyle.neon : PromoStyle.studio
guard let icon = NSImage(contentsOfFile: args[2]) else { fatalError("icon not found") }

@MainActor func render(_ beat: Double) -> CGImage {
    let r = ImageRenderer(content: Frame(style: style, beat: beat, icon: icon))
    r.scale = 1
    r.proposedSize = .init(width: W, height: H)
    return r.cgImage!
}

/// RGBA8 bytes of a frame, exactly W×H.
@MainActor func rgba(_ img: CGImage) -> Data {
    let w = Int(W), h = Int(H)
    var data = Data(count: w * h * 4)
    data.withUnsafeMutableBytes { buf in
        let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return data
}

MainActor.assumeIsolated {
    switch args[3] {
    case "--frame":
        let beat = Double(args[4]) ?? 0
        let img = render(beat)
        let rep = NSBitmapImageRep(cgImage: img)
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[5]))
    case "--video":
        let fps = args.count > 4 ? Double(args[4]) ?? 30 : 30
        let seconds = Timeline.totalBeats * 60 / style.bpm
        let frames = Int((seconds * fps).rounded())
        let out = FileHandle.standardOutput
        for f in 0..<frames {
            autoreleasepool {
                let beat = Double(f) / fps * style.bpm / 60
                out.write(rgba(render(beat)))
                if f % 60 == 0 { FileHandle.standardError.write(Data("frame \(f)/\(frames)\n".utf8)) }
            }
        }
    default:
        exit(64)
    }
}
