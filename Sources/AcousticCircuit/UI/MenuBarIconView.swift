import AcousticCore
import AppKit
import Foundation

/// Ultra-compact 22pt Retina view placed inside NSStatusItem.button for a crisp 6-bar architectural meter
/// that uses minimal space on notched MacBook menu bars.
final class MenuBarIconView: NSView {
    private var levels: [Float] = [Float](repeating: 0, count: 6)
    private var isSilent: Bool = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(snapshot: AcousticSnapshot) {
        for i in 0..<6 {
            levels[i] = snapshot.bands24[i * 4]
        }
        self.isSilent = snapshot.isSilent
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
            let v = isSilent ? Float(0.14) : levels[i]
            let bh = max(2.0, CGFloat(v) * maxBarH)
            let alpha: CGFloat = isSilent ? 0.45 : (v > 0.62 ? 1.0 : 0.74)
            ctx.setFillColor(gray: gray, alpha: alpha)
            let rect = CGRect(x: startX + CGFloat(i) * (barW + gap), y: baseY, width: barW, height: bh)
            ctx.fill(rect)
        }
    }
}
