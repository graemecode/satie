import AcousticCore
import AppKit
import SwiftUI

/// Braun / Leica-inspired stark monochrome circular focus timer dial + 24h Circadian Energy Curve.
/// Supports smooth circular dragging with Force Touch tick haptics on every 5-minute notch (0 = ∞, 5..120m).
struct RadialTimerView: View {
    @ObservedObject var state: AppState
    let onClose: () -> Void

    @State private var lastSnappedMinutes: Int = 0
    private let presets: [Int] = [0, 15, 25, 45, 60, 90]

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("FOCUS SESSION")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.50))
                    .tracking(1.1)
                Spacer()
                if state.flowMinutes > 0 {
                    Text(sessionPhaseTag)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(Color.white.opacity(0.76))
                } else {
                    Text("CONTINUOUS")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Color.white.opacity(0.42))
                }
            }

            // Interactive Circular Tick-Wheel Dial
            ZStack {
                let dialSize: CGFloat = 132
                let frac: Double = state.flowMinutes > 0 ? min(1.0, Double(state.flowMinutes) / 120.0) : 0.0
                let liveFrac: Double = {
                    if let rem = state.flowRemainingSeconds, state.flowMinutes > 0 {
                        return max(0.0, min(1.0, rem / Double(state.flowMinutes * 60)))
                    }
                    return frac
                }()

                Canvas { ctx, sz in
                    let c = CGPoint(x: sz.width * 0.5, y: sz.height * 0.5)
                    let outerR = sz.width * 0.47
                    let tickInR = sz.width * 0.415
                    let majorInR = sz.width * 0.39

                    // 24 precision 5-minute dial ticks (like a camera focus ring)
                    for i in 0..<24 {
                        let angle = -Double.pi * 0.5 + (Double(i) / 24.0) * 2.0 * Double.pi
                        let isMajor = (i % 3 == 0)
                        let r0 = isMajor ? majorInR : tickInR
                        var tick = Path()
                        tick.move(to: CGPoint(x: c.x + CGFloat(cos(angle)) * r0, y: c.y + CGFloat(sin(angle)) * r0))
                        tick.addLine(to: CGPoint(x: c.x + CGFloat(cos(angle)) * outerR, y: c.y + CGFloat(sin(angle)) * outerR))
                        let lit = (Double(i) / 24.0) <= frac && state.flowMinutes > 0
                        ctx.stroke(
                            tick,
                            with: .color(lit ? Color.white.opacity(0.85) : Color.white.opacity(isMajor ? 0.28 : 0.14)),
                            lineWidth: isMajor ? 1.25 : 0.85
                        )
                    }

                    // Hairline inner track
                    let trackR = sz.width * 0.345
                    let track = Path(ellipseIn: CGRect(x: c.x - trackR, y: c.y - trackR, width: trackR * 2, height: trackR * 2))
                    ctx.stroke(track, with: .color(Color.white.opacity(0.12)), lineWidth: 1.5)

                    // Active sweep arc
                    if state.flowMinutes > 0 {
                        let sweep = state.isFocusPlaying ? liveFrac : frac
                        var arc = Path()
                        arc.addArc(
                            center: c,
                            radius: trackR,
                            startAngle: .degrees(-90),
                            endAngle: .degrees(-90 + sweep * 360.0),
                            clockwise: false
                        )
                        ctx.stroke(arc, with: .color(.white), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))

                        // Tactile white handle dot at target duration angle
                        let handleAng = -Double.pi * 0.5 + frac * 2.0 * Double.pi
                        let hx = c.x + CGFloat(cos(handleAng)) * trackR
                        let hy = c.y + CGFloat(sin(handleAng)) * trackR
                        let knob = Path(ellipseIn: CGRect(x: hx - 4.5, y: hy - 4.5, width: 9, height: 9))
                        ctx.fill(knob, with: .color(.white))
                    }
                }
                .frame(width: dialSize, height: dialSize)
                .contentShape(Circle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { val in
                            let c = CGPoint(x: dialSize * 0.5, y: dialSize * 0.5)
                            let dx = val.location.x - c.x
                            let dy = val.location.y - c.y
                            var ang = atan2(dy, dx) + Double.pi * 0.5
                            if ang < 0 { ang += 2.0 * Double.pi }
                            let rawMin = Int(round((ang / (2.0 * Double.pi)) * 120.0 / 5.0)) * 5
                            let snapped = (rawMin >= 120) ? 120 : max(0, rawMin)
                            if snapped != lastSnappedMinutes {
                                lastSnappedMinutes = snapped
                                state.setFlowMinutes(snapped)
                                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                            }
                        }
                )

                // Center readout
                VStack(spacing: 2) {
                    Text(centerTimeText)
                        .font(.system(size: state.flowMinutes == 0 ? 24 : 18, weight: .medium, design: .monospaced))
                        .foregroundColor(.white)
                    Text(state.flowMinutes == 0 ? "OPEN" : (state.isFocusPlaying ? "REMAINING" : "MINUTES"))
                        .font(.system(size: 8.5, weight: .regular, design: .monospaced))
                        .foregroundColor(Color.white.opacity(0.45))
                        .tracking(0.8)
                }
                .allowsHitTesting(false)
            }

            // Quick 1-tap preset pills
            HStack(spacing: 4) {
                ForEach(presets, id: \.self) { mins in
                    let selected = state.flowMinutes == mins
                    Button {
                        lastSnappedMinutes = mins
                        state.setFlowMinutes(mins)
                        state.performHaptic()
                    } label: {
                        Text(mins == 0 ? "∞" : "\(mins)M")
                            .font(.system(size: 9.5, weight: selected ? .semibold : .regular, design: .monospaced))
                            .foregroundColor(selected ? .black : Color.white.opacity(0.62))
                            .frame(maxWidth: .infinity)
                            .frame(height: 24)
                            .background(selected ? Color.white : Color.white.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            // Minimal 24-hour Circadian Energy Curve
            VStack(spacing: 5) {
                HStack {
                    Text("CIRCADIAN · \(state.effectiveCircadianPhase.detailedLabel)")
                        .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                        .foregroundColor(Color.white.opacity(0.48))
                    Spacer()
                    HStack(spacing: 2) {
                        ForEach(CircadianOverride.allCases) { opt in
                            let on = state.circadianOverride == opt
                            Button {
                                state.circadianOverride = opt
                                state.performHaptic()
                            } label: {
                                Text(opt.label)
                                    .font(.system(size: 8.2, weight: on ? .semibold : .regular, design: .monospaced))
                                    .foregroundColor(on ? .black : Color.white.opacity(0.50))
                                    .padding(.horizontal, 6)
                                    .frame(height: 17)
                                    .background(on ? Color.white : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(2)
                    .background(Color.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }

                CircadianCurveCanvas()
                    .frame(height: 24)
            }
            .padding(.top, 2)
        }
        .padding(12)
        .background(Color.white.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.11), lineWidth: 1)
        )
        .onAppear {
            lastSnappedMinutes = state.flowMinutes
        }
    }

    private var centerTimeText: String {
        if state.flowMinutes == 0 { return "∞" }
        if state.isFocusPlaying, let rem = state.flowRemainingSeconds {
            let total = max(0, Int(ceil(rem)))
            return String(format: "%02d:%02d", total / 60, total % 60)
        }
        return "\(state.flowMinutes):00"
    }

    private var sessionPhaseTag: String {
        guard state.isFocusPlaying, let p = state.sessionProgress else {
            return "ARC READY"
        }
        if p < 0.12 { return "ARRIVAL" }
        if p > 0.88 { return "SOFT LANDING" }
        return "DEEP LOCK"
    }
}

private struct CircadianCurveCanvas: View {
    var body: some View {
        Canvas { ctx, sz in
            let now = Date()
            let comps = Calendar.current.dateComponents([.hour, .minute], from: now)
            let nowHour = Double(comps.hour ?? 12) + Double(comps.minute ?? 0) / 60.0

            // Baseline hairline
            var base = Path()
            base.move(to: CGPoint(x: 0, y: sz.height - 2))
            base.addLine(to: CGPoint(x: sz.width, y: sz.height - 2))
            ctx.stroke(base, with: .color(Color.white.opacity(0.10)), lineWidth: 0.75)

            // 24-hour circadian alertness wave
            var curve = Path()
            let steps = 64
            for i in 0...steps {
                let h = (Double(i) / Double(steps)) * 24.0
                let e = CircadianPhase.energyCurve(hour: h)
                let x = CGFloat(i) / CGFloat(steps) * sz.width
                let y = sz.height - 3 - CGFloat(e) * (sz.height - 6)
                if i == 0 { curve.move(to: CGPoint(x: x, y: y)) }
                else { curve.addLine(to: CGPoint(x: x, y: y)) }
            }
            ctx.stroke(curve, with: .color(Color.white.opacity(0.42)), lineWidth: 1.0)

            // Current time marker dot + vertical drop hairline
            let cx = CGFloat(nowHour / 24.0) * sz.width
            let cy = sz.height - 3 - CGFloat(CircadianPhase.energyCurve(hour: nowHour)) * (sz.height - 6)
            var drop = Path()
            drop.move(to: CGPoint(x: cx, y: cy))
            drop.addLine(to: CGPoint(x: cx, y: sz.height - 2))
            ctx.stroke(drop, with: .color(Color.white.opacity(0.35)), lineWidth: 0.75)

            let dot = Path(ellipseIn: CGRect(x: cx - 3, y: cy - 3, width: 6, height: 6))
            ctx.fill(dot, with: .color(.white))
        }
    }
}
