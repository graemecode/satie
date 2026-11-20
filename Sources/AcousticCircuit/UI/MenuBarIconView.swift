import AcousticCore
import AppKit
import Foundation

/// Ultra-compact 22pt Retina view placed inside NSStatusItem.button for a crisp 6-bar architectural meter
/// with clear muted & auto-ducked states.
final class MenuBarIconView: NSView {
    private var levels: [Float] = [Float](repeating: 0, count: 6)
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

    func update(snapshot: AcousticSnapshot, isMuted: Bool = false) {
        for i in 0..<6 {
            levels[i] = snapshot.bands24[i * 4]
        }
        self.isSilent = snapshot.isSilent
        self.isMuted = isMuted
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let w = bounds.width
        let h = bounds.height

        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let gray: CGFloat = isDark ? 1.0 : 0.0

        let barCount = 6
        let barW: CGFloat = 1.65
        let gap: CGFloat = 1.25
        let meterW = CGFloat(barCount) * barW + CGFloat(barCount - 1) * gap
        let startX: CGFloat = (w - meterW) * 0.5
        let maxBarH: CGFloat = 12.0
        let baseY: CGFloat = (h - maxBarH) * 0.5

        for i in 0..<barCount {
            let v = (isSilent || isMuted) ? Float(0.14) : levels[i]
            let bh = max(2.0, CGFloat(v) * maxBarH)
            let alpha: CGFloat
            if isMuted {
                alpha = 0.28
            } else if isSilent {
                alpha = 0.45
            } else {
                alpha = v > 0.62 ? 1.0 : 0.76
            }
            ctx.setFillColor(gray: gray, alpha: alpha)
            let rect = CGRect(x: startX + CGFloat(i) * (barW + gap), y: baseY, width: barW, height: bh)
            ctx.fill(rect)
        }

        // Crisp hairline slash when Mac audio is muted so state is unmistakable at a glance
        if isMuted {
            ctx.setStrokeColor(gray: gray, alpha: 0.85)
            ctx.setLineWidth(1.25)
            ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: startX - 1.0, y: baseY + 1.0))
            ctx.addLine(to: CGPoint(x: startX + meterW + 1.0, y: baseY + maxBarH - 1.0))
            ctx.strokePath()
        }
    }
}
