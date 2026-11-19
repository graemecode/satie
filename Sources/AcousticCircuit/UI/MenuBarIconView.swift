import AcousticCore
import AppKit
import CoreText
import Foundation

/// Custom Retina view placed inside NSStatusItem.button for live 8-bar architectural menu bar metering + key pill.
final class MenuBarIconView: NSView {
    private var levels: [Float] = [Float](repeating: 0, count: 8)
    private var shortKey: String = "—"
    private var isSilent: Bool = true
    private var showKey: Bool = true

    private static let keyFont: CTFont = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .medium) as CTFont

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(snapshot: AcousticSnapshot, showKey: Bool) {
        for i in 0..<8 {
            levels[i] = snapshot.bands24[i * 3]
        }
        self.shortKey = snapshot.shortKey
        self.isSilent = snapshot.isSilent
        self.showKey = showKey
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let w = bounds.width
        let h = bounds.height

        // Resolve concrete grayscale value from menu bar appearance (never pass dynamic NSCatalogColor to CoreText)
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let gray: CGFloat = isDark ? 1.0 : 0.0

        let barCount = 8
        let barW: CGFloat = 2.0
        let gap: CGFloat = 1.6
        let meterW = CGFloat(barCount) * barW + CGFloat(barCount - 1) * gap
        let startX: CGFloat = (showKey && !isSilent && shortKey != "—") ? 6.0 : (w - meterW) * 0.5
        let maxBarH: CGFloat = 13.0
        let baseY: CGFloat = (h - maxBarH) * 0.5

        for i in 0..<barCount {
            let v = isSilent ? Float(0.12) : levels[i]
            let bh = max(2.0, CGFloat(v) * maxBarH)
            let alpha: CGFloat = isSilent ? 0.45 : (v > 0.62 ? 1.0 : 0.72)
            ctx.setFillColor(gray: gray, alpha: alpha)
            let rect = CGRect(x: startX + CGFloat(i) * (barW + gap), y: baseY, width: barW, height: bh)
            ctx.fill(rect)
        }

        if showKey && !isSilent && shortKey != "—" && !shortKey.isEmpty {
            let textColor = CGColor(gray: gray, alpha: 0.90)
            let attrs: [CFString: Any] = [
                kCTFontAttributeName: Self.keyFont,
                kCTForegroundColorAttributeName: textColor
            ]
            guard let attrStr = CFAttributedStringCreate(kCFAllocatorDefault, shortKey as CFString, attrs as CFDictionary) else {
                return
            }
            let line = CTLineCreateWithAttributedString(attrStr)
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)

            let tx = startX + meterW + 5.5
            let baselineY = (h - (ascent - descent)) * 0.5
            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.textPosition = CGPoint(x: tx, y: baselineY)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
    }
}
