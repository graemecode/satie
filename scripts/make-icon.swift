import AppKit
import Foundation

guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: swift make-icon.swift <output-iconset-dir>\n", stderr)
    exit(1)
}

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func renderIcon(size: Int) -> Data? {
    let s = CGFloat(size)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    guard let nsCtx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.current = nsCtx
    let ctx = nsCtx.cgContext

    // macOS squircle-like rounded rect
    let inset = s * 0.08
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let corner = rect.width * 0.225
    let clipPath = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
    ctx.addPath(clipPath)
    ctx.clip()

    // Midnight-slate Room C radial gradient
    let cs = CGColorSpaceCreateDeviceRGB()
    let grad = CGGradient(
        colorsSpace: cs,
        colors: [
            CGColor(red: 0.11, green: 0.17, blue: 0.27, alpha: 1),
            CGColor(red: 0.045, green: 0.072, blue: 0.122, alpha: 1),
            CGColor(red: 0.025, green: 0.040, blue: 0.070, alpha: 1)
        ] as CFArray,
        locations: [0.0, 0.58, 1.0]
    )!
    let center = CGPoint(x: s * 0.5, y: s * 0.5)
    ctx.drawRadialGradient(grad, startCenter: center, startRadius: s * 0.04, endCenter: center, endRadius: s * 0.55, options: [])

    // Subtle hairline schematic ring
    ctx.setStrokeColor(CGColor(red: 0.86, green: 0.92, blue: 1.0, alpha: 0.16))
    ctx.setLineWidth(max(1.0, s * 0.004))
    ctx.strokeEllipse(in: CGRect(x: s * 0.18, y: s * 0.18, width: s * 0.64, height: s * 0.64))

    // Luminous white 3D filament loops
    let R = s * 0.27
    for k in 0..<28 {
        let fk = Double(k)
        let phase = fk / 28.0 * Double.pi * 2.0
        let alpha = CGFloat(0.14 + (k % 5 == 0 ? 0.55 : 0.22))
        ctx.setStrokeColor(CGColor(red: 0.93, green: 0.96, blue: 1.0, alpha: alpha))
        ctx.setLineWidth(max(0.8, s * (k % 6 == 0 ? 0.0085 : 0.0045)))
        ctx.beginPath()
        for i in 0...72 {
            let u = Double(i) / 72.0 * Double.pi * 2.0
            let wobble = 0.28 + 0.14 * sin(u * 3.0 + phase * 1.7)
            let rTube = (0.72 + 0.28 * sin(fk * 0.7))
            let x = (rTube + wobble * cos(u * 2.0 + phase)) * cos(u + phase)
            let y = (rTube + wobble * cos(u * 2.0 + phase)) * sin(u + phase) * 0.86 + sin(u * 3.0 + phase) * 0.16
            let pt = CGPoint(x: center.x + CGFloat(x) * R, y: center.y + CGFloat(y) * R)
            if i == 0 { ctx.move(to: pt) } else { ctx.addLine(to: pt) }
        }
        ctx.strokePath()
    }

    // Crisp outer rim stroke
    ctx.addPath(clipPath)
    ctx.setStrokeColor(CGColor(red: 0.88, green: 0.93, blue: 1.0, alpha: 0.28))
    ctx.setLineWidth(max(1.0, s * 0.008))
    ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let specs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (name, px) in specs {
    if let data = renderIcon(size: px) {
        try data.write(to: outDir.appendingPathComponent(name))
    }
}
