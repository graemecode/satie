import AcousticCore
import SwiftUI

/// Precision Swiss monochrome geometric emblems for Satie's 5 acoustic worlds:
/// FOCUS (concentric optical aperture) · PULSE (rhythmic 5-bar waveform) ·
/// RAIN (staggered falling rain & ripples) · STILL (serene horizon) · NIGHT (exact geometric crescent & stars).
struct SoundscapeGlyph: View {
    let mode: FocusSoundscape
    let isActive: Bool
    var isSelected: Bool = false
    var size: CGFloat = 38

    var body: some View {
        Canvas { ctx, sz in
            let center = CGPoint(x: sz.width * 0.5, y: sz.height * 0.5)
            let r = min(sz.width, sz.height) * 0.44
            let lw: CGFloat = max(1.15, size * 0.034)
            let thinLW: CGFloat = max(0.95, lw * 0.78)

            let primary: Color = isActive ? .black : Color.white.opacity(isSelected ? 0.94 : 0.76)
            let secondary: Color = isActive ? .black.opacity(0.42) : Color.white.opacity(isSelected ? 0.42 : 0.30)
            let strokeStyle = StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round)
            let thinStyle = StrokeStyle(lineWidth: thinLW, lineCap: .round, lineJoin: .round)

            // Single unified outer circular frame (never double-stroked)
            let outer = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            if isActive {
                ctx.fill(outer, with: .color(.white))
            } else {
                ctx.fill(outer, with: .color(Color.white.opacity(isSelected ? 0.09 : 0.035)))
                ctx.stroke(
                    outer,
                    with: .color(Color.white.opacity(isSelected ? 0.62 : 0.22)),
                    lineWidth: isSelected ? lw * 1.05 : thinLW
                )
            }

            let ir = r * 0.62

            switch mode {
            case .focus, .lateLight:
                // FOCUS (Soft Light): Precision Dieter Rams optical aperture — clean concentric ring, 4 hairline compass ticks, poised center point
                let ringR = ir * 0.76
                let innerRing = Path(ellipseIn: CGRect(x: center.x - ringR, y: center.y - ringR, width: ringR * 2, height: ringR * 2))
                ctx.stroke(innerRing, with: .color(primary), style: strokeStyle)

                // Four delicate cardinal focus ticks outside the aperture ring
                let tickIn = ringR + ir * 0.14
                let tickOut = r * 0.84
                for deg in [0.0, 90.0, 180.0, 270.0] {
                    let rad = deg * .pi / 180.0
                    var t = Path()
                    t.move(to: CGPoint(x: center.x + CGFloat(cos(rad)) * tickIn, y: center.y + CGFloat(sin(rad)) * tickIn))
                    t.addLine(to: CGPoint(x: center.x + CGFloat(cos(rad)) * tickOut, y: center.y + CGFloat(sin(rad)) * tickOut))
                    ctx.stroke(t, with: .color(secondary), style: thinStyle)
                }

                // Crisp central focal point
                let dotR = max(2.1, size * 0.062)
                let dot = Path(ellipseIn: CGRect(x: center.x - dotR, y: center.y - dotR, width: dotR * 2, height: dotR * 2))
                ctx.fill(dot, with: .color(primary))

            case .pulse:
                // PULSE (Kinetic Pulse): Architectural 5-bar symmetric rhythmic waveform
                let heights: [CGFloat] = [0.34, 0.74, 1.00, 0.64, 0.30]
                let spacing = ir * 0.44
                let barLW = max(1.35, lw * 1.15)
                let barStyle = StrokeStyle(lineWidth: barLW, lineCap: .round)

                for (i, hFrac) in heights.enumerated() {
                    let x = center.x + CGFloat(i - 2) * spacing
                    let halfH = ir * 0.84 * hFrac
                    var bar = Path()
                    bar.move(to: CGPoint(x: x, y: center.y - halfH))
                    bar.addLine(to: CGPoint(x: x, y: center.y + halfH))
                    let isHero = (i == 1 || i == 2 || i == 3)
                    ctx.stroke(bar, with: .color(isHero ? primary : secondary), style: barStyle)
                }

            case .rain:
                // RAIN (Rain & Glass): Staggered falling diagonal rain threads over calm concentric ripples
                let drops: [(x: CGFloat, yTop: CGFloat, len: CGFloat, bright: Bool)] = [
                    (-0.46, -0.78, 0.50, false),
                    ( 0.02, -0.92, 0.66, true),
                    ( 0.48, -0.68, 0.46, true)
                ]
                for d in drops {
                    let xTop = center.x + d.x * ir + ir * 0.10
                    let yTop = center.y + d.yTop * ir
                    let xBot = xTop - d.len * ir * 0.28
                    let yBot = yTop + d.len * ir
                    var line = Path()
                    line.move(to: CGPoint(x: xTop, y: yTop))
                    line.addLine(to: CGPoint(x: xBot, y: yBot))
                    ctx.stroke(line, with: .color(d.bright ? primary : secondary), style: strokeStyle)
                }

                // Delicate calm water surface ripples below
                let rippleY = center.y + ir * 0.46
                for (scale, bright) in [(CGFloat(0.46), true), (CGFloat(0.92), false)] {
                    let rw = ir * scale * 1.12
                    let rh = ir * scale * 0.34
                    let rip = Path(ellipseIn: CGRect(x: center.x - rw, y: rippleY - rh, width: rw * 2, height: rh * 2))
                    ctx.stroke(rip, with: .color(bright ? primary : secondary), style: thinStyle)
                }

            case .still:
                // STILL (Quiet Ambient): Serene horizon line with poised minimal reflection — pure visual quiet
                let halfSpan = ir * 1.02
                var horizon = Path()
                horizon.move(to: CGPoint(x: center.x - halfSpan, y: center.y))
                horizon.addLine(to: CGPoint(x: center.x + halfSpan, y: center.y))
                ctx.stroke(horizon, with: .color(primary), style: strokeStyle)

                // Subtle upper calm dome (rising stillness)
                let domeR = ir * 0.46
                var dome = Path()
                dome.addArc(center: CGPoint(x: center.x, y: center.y), radius: domeR, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
                ctx.stroke(dome, with: .color(primary), style: strokeStyle)

                // Two quiet centered reflection hairlines beneath the horizon
                for (idx, frac) in [0.58, 0.30].enumerated() {
                    let y = center.y + CGFloat(idx + 1) * ir * 0.30
                    let w = halfSpan * CGFloat(frac)
                    var ref = Path()
                    ref.move(to: CGPoint(x: center.x - w, y: y))
                    ref.addLine(to: CGPoint(x: center.x + w, y: y))
                    ctx.stroke(ref, with: .color(secondary), style: thinStyle)
                }

            case .dive:
                // DIVE (Deep Dive Meditation): Concentric resonance rings rising from a singing-bowl center
                for (idx, (frac, isPrimary)) in [(CGFloat(0.96), false), (CGFloat(0.62), true), (CGFloat(0.30), true)].enumerated() {
                    let r = ir * frac
                    let ring = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
                    ctx.stroke(ring, with: .color(isPrimary ? primary : secondary), style: idx == 0 ? thinStyle : strokeStyle)
                }
                let dotR = max(1.3, size * 0.036)
                let dot = Path(ellipseIn: CGRect(x: center.x - dotR, y: center.y - dotR, width: dotR * 2, height: dotR * 2))
                ctx.fill(dot, with: .color(primary))

            case .loops, .furniture, .gymnopedies, .gnossiennes, .sarabandes, .debussy, .faure, .scriabin:
                // Satie worlds (Satie Lab only for now): three notes on a gentle line
                let rises = mode == .gymnopedies
                for k in 0..<3 {
                    let fx: Double = -0.5 + 0.5 * Double(k)
                    let fy: Double = rises ? (0.25 - 0.25 * Double(k)) : (k == 1 ? 0.2 : -0.2)
                    let x: CGFloat = center.x + ir * CGFloat(fx)
                    let y: CGFloat = center.y + ir * CGFloat(fy)
                    let dr: CGFloat = max(1.6, size * 0.05)
                    let dot = Path(ellipseIn: CGRect(x: x - dr, y: y - dr, width: dr * 2, height: dr * 2))
                    ctx.fill(dot, with: .color(primary))
                }

            case .groove:
                // GROOVE (Low Sun): half sun resting on the horizon, three short rays, and a beat of dashes below
                let horizonY = center.y + ir * 0.18
                let sunR = ir * 0.52
                var sun = Path()
                sun.addArc(center: CGPoint(x: center.x, y: horizonY), radius: sunR, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
                ctx.stroke(sun, with: .color(primary), style: strokeStyle)
                var horizon = Path()
                horizon.move(to: CGPoint(x: center.x - ir * 0.92, y: horizonY))
                horizon.addLine(to: CGPoint(x: center.x + ir * 0.92, y: horizonY))
                ctx.stroke(horizon, with: .color(primary), style: strokeStyle)
                for deg in [-135.0, -90.0, -45.0] {
                    let rad = deg * .pi / 180.0
                    var ray = Path()
                    ray.move(to: CGPoint(x: center.x + CGFloat(cos(rad)) * sunR * 1.28, y: horizonY + CGFloat(sin(rad)) * sunR * 1.28))
                    ray.addLine(to: CGPoint(x: center.x + CGFloat(cos(rad)) * sunR * 1.62, y: horizonY + CGFloat(sin(rad)) * sunR * 1.62))
                    ctx.stroke(ray, with: .color(secondary), style: thinStyle)
                }
                let beatY = horizonY + ir * 0.36
                for (x0, w) in [(-0.62, 0.30), (-0.18, 0.14), (0.10, 0.30), (0.54, 0.14)] {
                    var dash = Path()
                    dash.move(to: CGPoint(x: center.x + ir * CGFloat(x0), y: beatY))
                    dash.addLine(to: CGPoint(x: center.x + ir * CGFloat(x0 + w), y: beatY))
                    ctx.stroke(dash, with: .color(secondary), style: thinStyle)
                }

            case .drift:
                // NIGHT (Gymnopédie): Exact mathematical crescent (true circle-circle intersection) + 2 subtle stars
                let R = ir * 0.88
                let c1 = CGPoint(x: center.x - ir * 0.08, y: center.y)
                let c2 = CGPoint(x: c1.x + R * 0.62, y: c1.y - R * 0.14)
                let r2 = R * 0.78

                // Exact geometric intersection of circles (c1, R) and (c2, r2) so horns meet at razor-sharp points
                let dx = c2.x - c1.x
                let dy = c2.y - c1.y
                let dist = hypot(dx, dy)
                let a = (R * R - r2 * r2 + dist * dist) / (2.0 * dist)
                let h = sqrt(max(0.0, R * R - a * a))
                let xm = c1.x + a * dx / dist
                let ym = c1.y + a * dy / dist
                let pTop = CGPoint(x: xm + h * dy / dist, y: ym - h * dx / dist)
                let pBot = CGPoint(x: xm - h * dy / dist, y: ym + h * dx / dist)

                let ang1Top = atan2(pTop.y - c1.y, pTop.x - c1.x)
                let ang1Bot = atan2(pBot.y - c1.y, pBot.x - c1.x)
                let ang2Top = atan2(pTop.y - c2.y, pTop.x - c2.x)
                let ang2Bot = atan2(pBot.y - c2.y, pBot.x - c2.x)

                var moon = Path()
                moon.addArc(center: c1, radius: R, startAngle: .radians(ang1Bot), endAngle: .radians(ang1Top), clockwise: false)
                moon.addArc(center: c2, radius: r2, startAngle: .radians(ang2Top), endAngle: .radians(ang2Bot), clockwise: true)
                moon.closeSubpath()
                ctx.stroke(moon, with: .color(primary), style: strokeStyle)

                // Two poised minimal stars in open night space (never crammed inside the crescent)
                let starPos: [(CGFloat, CGFloat, CGFloat)] = [
                    (0.46, -0.44, 1.35),
                    (0.62,  0.10, 0.95)
                ]
                for (sx, sy, srScale) in starPos {
                    let sr = max(1.0, size * 0.028 * srScale)
                    let star = Path(ellipseIn: CGRect(x: center.x + sx * ir - sr, y: center.y + sy * ir - sr, width: sr * 2, height: sr * 2))
                    ctx.fill(star, with: .color(srScale > 1.1 ? primary : secondary))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
