import AcousticCore
import AppKit
import Foundation

/// Ultra-crisp Retina NSStatusItem view rendering Satie's Standing Wave logo in the macOS menu bar:
/// - Idle/paused: clean static Standing Wave emblem (matching the app icon).
/// - Playing: the Standing Wave comes alive, breathing and gliding smoothly with real-time audio.
/// - Muted: dimmed emblem with a crisp diagonal slash.
final class MenuBarIconView: NSView {
    private var smoothBass: CGFloat = 0
    private var smoothMid: CGFloat = 0
    private var smoothTreble: CGFloat = 0
    private var smoothEnergy: CGFloat = 0
    private var phase: CGFloat = 0
    private var lastUpdateTime: CFTimeInterval = CACurrentMediaTime()
    private var isPlaying: Bool = false
    private var isSilent: Bool = true
    private var isMuted: Bool = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(snapshot: AcousticSnapshot, isPlaying: Bool = false, isMuted: Bool = false) {
        let now = CACurrentMediaTime()
        let dt = CGFloat(max(0.004, min(0.12, now - lastUpdateTime)))
        lastUpdateTime = now

        let active = isPlaying && !snapshot.isSilent && !isMuted
        let targetBass = active ? CGFloat(snapshot.bass) : 0
        let targetMid = active ? CGFloat(snapshot.mid) : 0
        let targetTreble = active ? CGFloat(snapshot.treble) : 0
        let targetEnergy = active ? CGFloat(snapshot.energy) : 0

        let lerp = min(1.0, dt * 11.0)
        smoothBass += (targetBass - smoothBass) * lerp
        smoothMid += (targetMid - smoothMid) * lerp
        smoothTreble += (targetTreble - smoothTreble) * lerp
        smoothEnergy += (targetEnergy - smoothEnergy) * lerp

        if active && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            phase += dt * (2.6 + smoothEnergy * 2.8)
            if phase > .pi * 200 { phase.formTruncatingRemainder(dividingBy: .pi * 2) }
        }

        self.isPlaying = isPlaying
        self.isSilent = snapshot.isSilent
        self.isMuted = isMuted
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)

        let w = bounds.width
        let h = bounds.height
        let midY = h * 0.5
        let waveW: CGFloat = min(21.5, w - 5.0)
        let startX = (w - waveW) * 0.5

        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let gray: CGFloat = isDark ? 1.0 : 0.0
        let active = isPlaying && !isSilent && !isMuted
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        let primaryAlpha: CGFloat = isMuted ? 0.30 : (active ? 0.98 : 0.86)
        let ghostAlpha: CGFloat = isMuted ? 0.14 : (active ? 0.44 : 0.34)

        // Base standing-wave amplitude (4.8pt calm resting emblem; swells up to ~6.5pt half-height to match macOS menu bar optical height)
        let baseAmp: CGFloat = active ? (4.6 + smoothEnergy * 1.9) : 4.8

        func lobeBoost(at u: CGFloat) -> CGFloat {
            guard active else { return 1.0 }
            let leftW = exp(-pow((u - 0.18) / 0.14, 2.0))
            let midW = exp(-pow((u - 0.50) / 0.18, 2.0))
            let rightW = exp(-pow((u - 0.82) / 0.14, 2.0))
            return 1.0 + leftW * smoothBass * 0.42 + midW * smoothMid * 0.36 + rightW * smoothTreble * 0.42
        }

        func strokeWave(sign: CGFloat, ampScale: CGFloat, phaseShift: CGFloat, lineWidth: CGFloat, alpha: CGFloat) {
            let steps = 44
            ctx.beginPath()
            for i in 0...steps {
                let u = CGFloat(i) / CGFloat(steps)
                let env = pow(sin(.pi * u), 1.35)
                let carrier: CGFloat
                if active && !reduceMotion {
                    // Preserve Satie's 3-lobe standing wave while breathing smoothly with a traveling harmonic ripple
                    let standing = sin(3.0 * .pi * u + phaseShift)
                    let breathe = 0.84 + 0.16 * cos(phase + (sign > 0 ? 0.0 : .pi * 0.35))
                    let travel = 0.24 * sin(3.0 * .pi * u - phase + phaseShift) * (0.35 + smoothEnergy * 0.65)
                    carrier = standing * breathe + travel
                } else {
                    carrier = sin(3.0 * .pi * u + phaseShift)
                }
                let x = startX + u * waveW
                let y = midY + sign * baseAmp * ampScale * env * lobeBoost(at: u) * carrier
                if i == 0 {
                    ctx.move(to: CGPoint(x: x, y: y))
                } else {
                    ctx.addLine(to: CGPoint(x: x, y: y))
                }
            }
            ctx.setStrokeColor(gray: gray, alpha: alpha)
            ctx.setLineWidth(lineWidth)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.strokePath()
        }

        // Translucent secondary harmonic veil (echoes the layered ribbon sheen of Satie's app icon)
        let ghostPhase: CGFloat = active && !reduceMotion ? (0.36 + 0.22 * sin(phase * 0.7)) : 0.28
        strokeWave(sign: +1.0, ampScale: 0.78, phaseShift:  ghostPhase, lineWidth: 0.9, alpha: ghostAlpha)
        strokeWave(sign: -1.0, ampScale: 0.78, phaseShift: -ghostPhase, lineWidth: 0.9, alpha: ghostAlpha)

        // Primary symmetrical Standing Wave curves (forming the crisp 3-lobe diamond/eye silhouette)
        strokeWave(sign: +1.0, ampScale: 1.0, phaseShift: 0.0, lineWidth: 1.25, alpha: primaryAlpha)
        strokeWave(sign: -1.0, ampScale: 1.0, phaseShift: 0.0, lineWidth: 1.25, alpha: primaryAlpha)

        // Crisp hairline slash when Mac audio is muted so state is unmistakable at a glance
        if isMuted {
            ctx.setStrokeColor(gray: gray, alpha: 0.88)
            ctx.setLineWidth(1.25)
            ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: startX + 3.0, y: midY - 6.0))
            ctx.addLine(to: CGPoint(x: startX + waveW - 3.0, y: midY + 6.0))
            ctx.strokePath()
        }
    }
}
