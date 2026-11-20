import AcousticCore
import SwiftUI

/// Bespoke 1.1pt hairline circular geometric emblems for each Satie soundscape.
/// Stark OLED monochrome vector craft — zero generic icon bloat.
struct SoundscapeGlyph: View {
    let mode: FocusSoundscape
    let isActive: Bool
    var size: CGFloat = 34

    var body: some View {
        Canvas { ctx, sz in
            let rect = CGRect(origin: .zero, size: sz)
            let center = CGPoint(x: sz.width * 0.5, y: sz.height * 0.5)
            let r = min(sz.width, sz.height) * 0.44
            let strokeColor: Color = isActive ? .black : Color.white.opacity(0.76)
            let softStroke: Color = isActive ? .black.opacity(0.45) : Color.white.opacity(0.32)
            let lw: CGFloat = max(1.0, size * 0.032)

            // Outer circular frame
            let outer = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            if isActive {
                ctx.fill(outer, with: .color(.white))
            } else {
                ctx.fill(outer, with: .color(Color.white.opacity(0.04)))
                ctx.stroke(outer, with: .color(Color.white.opacity(0.24)), lineWidth: lw)
            }

            // Clip inner line-art neatly inside the circular emblem
            ctx.clipToLayer { inner in
                inner.fill(outer, with: .color(.white))
            }

            let ir = r * 0.72
            switch mode {
            case .focus:
                // Soft Light: overlapping luminous refraction arcs + warm center zenith
                var a1 = Path()
                a1.addArc(center: CGPoint(x: center.x - ir * 0.48, y: center.y), radius: ir * 0.92, startAngle: .degrees(-68), endAngle: .degrees(68), clockwise: false)
                ctx.stroke(a1, with: .color(strokeColor), lineWidth: lw)

                var a2 = Path()
                a2.addArc(center: CGPoint(x: center.x + ir * 0.48, y: center.y), radius: ir * 0.92, startAngle: .degrees(112), endAngle: .degrees(248), clockwise: false)
                ctx.stroke(a2, with: .color(strokeColor), lineWidth: lw)

                var horizon = Path()
                horizon.move(to: CGPoint(x: center.x - r, y: center.y))
                horizon.addLine(to: CGPoint(x: center.x + r, y: center.y))
                ctx.stroke(horizon, with: .color(softStroke), lineWidth: lw * 0.85)

                let dotR = max(1.6, size * 0.055)
                let dot = Path(ellipseIn: CGRect(x: center.x - dotR, y: center.y - dotR, width: dotR * 2, height: dotR * 2))
                ctx.fill(dot, with: .color(strokeColor))

            case .pulse:
                // Kinetic Pulse: architectural longitude/latitude harmonic phase sphere
                for frac in [-0.45, 0.0, 0.45] {
                    let y = center.y + CGFloat(frac) * r * 0.95
                    var h = Path()
                    h.move(to: CGPoint(x: center.x - r, y: y))
                    h.addLine(to: CGPoint(x: center.x + r, y: y))
                    ctx.stroke(h, with: .color(frac == 0 ? strokeColor : softStroke), lineWidth: lw * 0.9)
                }
                for wFrac in [0.34, 0.70] {
                    let rx = r * CGFloat(wFrac)
                    let oval = Path(ellipseIn: CGRect(x: center.x - rx, y: center.y - r, width: rx * 2, height: r * 2))
                    ctx.stroke(oval, with: .color(strokeColor), lineWidth: lw * 0.9)
                }
                var v = Path()
                v.move(to: CGPoint(x: center.x, y: center.y - r))
                v.addLine(to: CGPoint(x: center.x, y: center.y + r))
                ctx.stroke(v, with: .color(softStroke), lineWidth: lw * 0.85)

            case .rain:
                // Rain & Glass: diagonal rain threads + concentric calm water ripples
                for offset in [-0.36, 0.0, 0.36] {
                    let x0 = center.x + CGFloat(offset) * ir * 1.25
                    var drop = Path()
                    drop.move(to: CGPoint(x: x0 + ir * 0.14, y: center.y - ir * 0.72))
                    drop.addLine(to: CGPoint(x: x0 - ir * 0.08, y: center.y - ir * 0.05))
                    ctx.stroke(drop, with: .color(offset == 0 ? strokeColor : softStroke), lineWidth: lw)
                }
                for scale in [0.46, 0.86] {
                    let rw = ir * CGFloat(scale) * 1.2
                    let rh = ir * CGFloat(scale) * 0.38
                    let rip = Path(ellipseIn: CGRect(x: center.x - rw, y: center.y + ir * 0.36 - rh, width: rw * 2, height: rh * 2))
                    ctx.stroke(rip, with: .color(scale < 0.6 ? strokeColor : softStroke), lineWidth: lw * 0.9)
                }

            case .drift:
                // Gymnopédie: nocturnal crescent arc + architectural stipple stars
                var moon = Path()
                moon.addArc(center: CGPoint(x: center.x - ir * 0.08, y: center.y), radius: ir * 0.74, startAngle: .degrees(38), endAngle: .degrees(322), clockwise: false)
                moon.addArc(center: CGPoint(x: center.x + ir * 0.30, y: center.y), radius: ir * 0.56, startAngle: .degrees(294), endAngle: .degrees(66), clockwise: true)
                moon.closeSubpath()
                ctx.stroke(moon, with: .color(strokeColor), lineWidth: lw)

                let stars: [(CGFloat, CGFloat)] = [(0.34, -0.30), (0.48, 0.04), (0.26, 0.28), (0.12, -0.04)]
                for (sx, sy) in stars {
                    let sr = max(1.0, size * 0.032)
                    let p = Path(ellipseIn: CGRect(x: center.x + sx * ir - sr, y: center.y + sy * ir - sr, width: sr * 2, height: sr * 2))
                    ctx.fill(p, with: .color(strokeColor))
                }

            case .still:
                // Still (Zero-Ego Study): calm nested horizon waves (zen garden stillness)
                for row in [-1, 0, 1] {
                    let baseY = center.y + CGFloat(row) * ir * 0.42
                    let amp = ir * (row == 0 ? 0.20 : 0.14)
                    var wave = Path()
                    let steps = 24
                    for s in 0...steps {
                        let t = CGFloat(s) / CGFloat(steps)
                        let x = center.x - r + t * r * 2.0
                        let y = baseY + sin(t * .pi * 2.0) * amp
                        if s == 0 { wave.move(to: CGPoint(x: x, y: y)) }
                        else { wave.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    ctx.stroke(wave, with: .color(row == 0 ? strokeColor : softStroke), lineWidth: lw)
                }
            }
            _ = rect
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
