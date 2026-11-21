import AcousticCore
import AppKit
import CoreText
import Foundation

/// Transparent Retina CoreGraphics architectural schematic layer placed over AcousticMetalView in Studio / Fullscreen modes.
final class SchematicOverlayView: NSView {
    private var snapshot: AcousticSnapshot = .empty
    private var preset: VisualPreset = .circuit
    private var sourceLabel: String = "SYSTEM OUTPUT"

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil // Pass all mouse events through cleanly
    }

    func update(snapshot: AcousticSnapshot, preset: VisualPreset, sourceLabel: String) {
        self.snapshot = snapshot
        self.preset = preset
        self.sourceLabel = sourceLabel
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)

        switch preset {
        case .circuit:
            drawCircuitSchematic(ctx: ctx, size: bounds.size)
        case .ecology:
            drawEcologyFrames(ctx: ctx, size: bounds.size)
        case .phosphor, .liquid, .horizon:
            // Pure unobstructed GPU canvas
            break
        }
    }

    // MARK: - Mode 01: Room C Architectural Schematic

    private func drawCircuitSchematic(ctx: CGContext, size: CGSize) {
        let w = size.width
        let h = size.height
        guard w > 320, h > 260 else { return }

        let padX = max(24.0, w * 0.052)
        let usableW = w - padX * 2.0
        let a = snapshot

        let titleFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        let subFont = NSFont.monospacedSystemFont(ofSize: 9.2, weight: .regular)
        let microFont = NSFont.monospacedSystemFont(ofSize: 8.2, weight: .regular)
        let keyFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)
        let sectionFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)

        let white = NSColor(white: 1.0, alpha: 0.96)
        let soft = NSColor(calibratedRed: 0.84, green: 0.89, blue: 0.96, alpha: 0.62)
        let dim = NSColor(calibratedRed: 0.84, green: 0.89, blue: 0.96, alpha: 0.42)
        let hair = NSColor(calibratedRed: 0.86, green: 0.91, blue: 0.98, alpha: 0.32).cgColor
        let hairStrong = NSColor(calibratedRed: 0.86, green: 0.91, blue: 0.98, alpha: 0.44).cgColor

        // Top section heading
        drawText("24 BANDS INTO THE CIRCUIT", at: CGPoint(x: padX, y: h * 0.038), font: titleFont, color: white)
        let rateKhz = Int(round(a.sampleRate / 1000.0))
        drawText(
            "GENERATIVE ENGINE · \(rateKhz) KHZ · 35 HZ → 14 KHZ · LIVE IMPULSE ROUTING",
            at: CGPoint(x: padX, y: h * 0.038 + 18),
            font: subFont,
            color: soft
        )

        // Scale axis line + frequency zone markers
        let axisY = h * 0.112
        ctx.setStrokeColor(hair)
        ctx.setLineWidth(1.0)
        ctx.move(to: CGPoint(x: padX, y: axisY))
        ctx.addLine(to: CGPoint(x: w - padX, y: axisY))
        ctx.strokePath()

        let scaleLabels = ["SUB", "BASS", "LOW-MID", "HIGH-MID", "AIR"]
        for (idx, lbl) in scaleLabels.enumerated() {
            let frac = CGFloat(idx) / CGFloat(scaleLabels.count - 1)
            let lx = padX + frac * usableW
            let align: NSTextAlignment = idx == 0 ? .left : (idx == scaleLabels.count - 1 ? .right : .center)
            drawText(lbl, at: CGPoint(x: lx, y: axisY - 13), font: microFont, color: soft, align: align)
        }

        // 24 sensor 5x5 mosaic tiles + curved Bézier impulse wires converging into the Metal 3D core
        let cellGap: CGFloat = 5.0
        let cellW = (usableW - cellGap * 23.0) / 24.0
        let cellH = min(cellW * 0.95, 22.0)
        let tilesY = axisY + 16.0
        let coreX = w * 0.5
        let coreY = h * 0.465
        let coreR = min(w * 0.22, h * 0.22)

        for i in 0..<24 {
            let cx = padX + CGFloat(i) * (cellW + cellGap) + cellW * 0.5
            let x0 = cx - cellW * 0.5
            let bandLabel = String(format: "%02d", AcousticSnapshot.roomCBandOrder[i])
            drawText(bandLabel, at: CGPoint(x: cx, y: tilesY - 12), font: microFont, color: soft, align: .center)

            // 5x5 rolling activity mosaic inside each tile
            let tile = a.tileHistory[i]
            let sw = cellW / 5.0
            let sh = cellH / 5.0
            for gy in 0..<5 {
                for gx in 0..<5 {
                    let v = CGFloat(tile[gy * 5 + gx])
                    let lum = 0.08 + v * 0.92
                    ctx.setFillColor(red: lum * 0.94, green: lum * 0.97, blue: min(1.0, lum * 1.04), alpha: 1.0)
                    ctx.fill(CGRect(x: x0 + CGFloat(gx) * sw, y: tilesY + CGFloat(gy) * sh, width: max(1, sw - 0.5), height: max(1, sh - 0.5)))
                }
            }
            ctx.setStrokeColor(hair)
            ctx.setLineWidth(0.75)
            ctx.stroke(CGRect(x: x0, y: tilesY, width: cellW, height: cellH))

            // Binary impulse readout (0 / 1)
            let firing = a.impulses24[i] > 0.24
            drawText(firing ? "1" : "0", at: CGPoint(x: cx, y: tilesY + cellH + 3), font: microFont, color: firing ? white : dim, align: .center)

            // Curved Bézier routing wire down into the Metal 3D filament core
            let startY = tilesY + cellH + 17.0
            let endX = coreX + (CGFloat(i) - 11.5) / 11.5 * coreR * 0.72
            let endY = coreY - coreR * 0.45
            let ctrlX = cx + (coreX - cx) * 0.28
            let ctrlY = startY + (endY - startY) * 0.56

            ctx.beginPath()
            ctx.move(to: CGPoint(x: cx, y: startY))
            ctx.addQuadCurve(to: CGPoint(x: endX, y: endY), control: CGPoint(x: ctrlX, y: ctrlY))
            let wireAlpha: CGFloat = firing ? min(0.85, 0.22 + CGFloat(a.impulses24[i]) * 0.65) : 0.075
            ctx.setStrokeColor(red: 0.88, green: 0.93, blue: 1.0, alpha: wireAlpha)
            ctx.setLineWidth(firing ? 1.05 : 0.6)
            ctx.strokePath()

            // Live traveling white impulse dot along the wire
            if firing || a.bands24[i] > 0.55 {
                let p = CGFloat((a.time * 1.45 + Double(i) * 0.17).truncatingRemainder(dividingBy: 1.0))
                let omt = 1.0 - p
                let px = omt * omt * cx + 2.0 * omt * p * ctrlX + p * p * endX
                let py = omt * omt * startY + 2.0 * omt * p * ctrlY + p * p * endY
                ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.95)
                ctx.fillEllipse(in: CGRect(x: px - 1.8, y: py - 1.8, width: 3.6, height: 3.6))
            }
        }

        // Bottom framed "SOUND FROM THE CIRCUIT" box
        let boxY = h * 0.705
        let boxH = h * 0.225
        let boxRect = CGRect(x: padX, y: boxY, width: usableW, height: boxH)

        // Subtle dark slate translucent backing so bottom box stays super crisp
        ctx.setFillColor(red: 0.032, green: 0.048, blue: 0.080, alpha: 0.64)
        ctx.fill(boxRect)
        ctx.setStrokeColor(hairStrong)
        ctx.setLineWidth(1.0)
        ctx.stroke(boxRect)

        // Output stem connecting core bottom -> box top
        ctx.setStrokeColor(hair)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: coreX, y: coreY + coreR * 0.76))
        ctx.addLine(to: CGPoint(x: coreX, y: boxY))
        ctx.strokePath()

        drawText("SOUND FROM THE CIRCUIT", at: CGPoint(x: w * 0.5, y: boxY + 6), font: sectionFont, color: white, align: .center)
        drawText("REAL-TIME CHROMAGRAM · KEY ESTIMATOR · 24-BAND LEVEL READOUT", at: CGPoint(x: w * 0.5, y: boxY + 20), font: microFont, color: dim, align: .center)

        // Circle of Fifths chromagram wheel (left inside box)
        let wheelR = min(26.0, boxH * 0.185)
        let wheelX = padX + wheelR + 28.0
        let wheelY = boxY + boxH * 0.44

        ctx.setStrokeColor(hairStrong)
        ctx.setLineWidth(0.9)
        ctx.strokeEllipse(in: CGRect(x: wheelX - wheelR, y: wheelY - wheelR, width: wheelR * 2, height: wheelR * 2))

        ctx.beginPath()
        for i in 0..<12 {
            let pc = AcousticSnapshot.fifthsOrder[i]
            let ang = (CGFloat(i) / 12.0) * .pi * 2.0 - .pi * 0.5
            let rad = wheelR * (0.18 + CGFloat(a.chroma12[pc]) * 0.78)
            let pt = CGPoint(x: wheelX + cos(ang) * rad, y: wheelY + sin(ang) * rad)
            if i == 0 { ctx.move(to: pt) } else { ctx.addLine(to: pt) }
        }
        ctx.closePath()
        ctx.setFillColor(red: 0.90, green: 0.95, blue: 1.0, alpha: 0.22)
        ctx.fillPath()

        ctx.beginPath()
        for i in 0..<12 {
            let pc = AcousticSnapshot.fifthsOrder[i]
            let ang = (CGFloat(i) / 12.0) * .pi * 2.0 - .pi * 0.5
            let rad = wheelR * (0.18 + CGFloat(a.chroma12[pc]) * 0.78)
            let pt = CGPoint(x: wheelX + cos(ang) * rad, y: wheelY + sin(ang) * rad)
            if i == 0 { ctx.move(to: pt) } else { ctx.addLine(to: pt) }
        }
        ctx.closePath()
        ctx.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 0.95)
        ctx.setLineWidth(1.1)
        ctx.strokePath()

        let wheelFont = NSFont.monospacedSystemFont(ofSize: 7.0, weight: .regular)
        for i in 0..<12 {
            let pc = AcousticSnapshot.fifthsOrder[i]
            let ang = (CGFloat(i) / 12.0) * .pi * 2.0 - .pi * 0.5
            let lx = wheelX + cos(ang) * (wheelR + 9.5)
            let ly = wheelY + sin(ang) * (wheelR + 9.5) - 4.5
            drawText(AcousticSnapshot.pitchNames[pc], at: CGPoint(x: lx, y: ly), font: wheelFont, color: a.chroma12[pc] > 0.52 ? white : dim, align: .center)
        }

        // Detected key & energy/tension telemetry beside wheel
        let metaX = wheelX + wheelR + 28.0
        drawText(a.detectedKey, at: CGPoint(x: metaX, y: wheelY - 19), font: keyFont, color: white)
        drawText(String(format: "ENERGY  %.2f", a.energy), at: CGPoint(x: metaX, y: wheelY - 2), font: microFont, color: soft)
        drawText(String(format: "TENSION %.2f", a.tension), at: CGPoint(x: metaX, y: wheelY + 11), font: microFont, color: soft)

        // Middle PC1 / PC2 sliders
        if w > 640 {
            let slX = w * 0.49
            let slW = w * 0.14
            drawSlider(ctx: ctx, x: slX, y: wheelY - 8, w: slW, value: CGFloat(a.energy), label: "PC1", font: microFont, labelColor: dim, stroke: hair)
            drawSlider(ctx: ctx, x: slX, y: wheelY + 9, w: slW, value: CGFloat(a.tension), label: "PC2", font: microFont, labelColor: dim, stroke: hair)
        }

        // Right-side DSP numeric readout
        if w > 760 {
            let rtX = w * 0.69
            drawText(String(format: "BASS   %.3f · MID %.3f", a.bass, a.mid), at: CGPoint(x: rtX, y: wheelY - 16), font: microFont, color: soft)
            drawText(String(format: "TREBLE %.3f · FLX %.3f", a.treble, a.flux), at: CGPoint(x: rtX, y: wheelY - 3), font: microFont, color: soft)
            drawText("SOURCE \(sourceLabel)", at: CGPoint(x: rtX, y: wheelY + 10), font: microFont, color: dim)
        }

        // 24 stark-white architectural dB bars + hanging output stems
        let barsH = min(36.0, boxH * 0.27)
        let barsTop = boxY + boxH - barsH - 10.0
        let innerPad: CGFloat = 14.0
        let barGap: CGFloat = 4.0
        let barW = (usableW - innerPad * 2.0 - barGap * 23.0) / 24.0

        for i in 0..<24 {
            let bx = padX + innerPad + CGFloat(i) * (barW + barGap)
            ctx.setStrokeColor(hair)
            ctx.setLineWidth(0.75)
            ctx.stroke(CGRect(x: bx, y: barsTop, width: barW, height: barsH))

            let fillH = max(2.0, CGFloat(a.bands24[i]) * (barsH - 2.0))
            ctx.setFillColor(red: 0.94, green: 0.96, blue: 1.0, alpha: 0.96)
            ctx.fill(CGRect(x: bx + 0.8, y: barsTop + barsH - fillH - 0.5, width: max(1, barW - 1.6), height: fillH))

            // Output stems hanging below box
            let stemX = bx + barW * 0.5
            let stemBot = boxY + boxH + 16.0
            if stemBot + 14 < h {
                ctx.setStrokeColor(hair)
                ctx.beginPath()
                ctx.move(to: CGPoint(x: stemX, y: boxY + boxH))
                ctx.addLine(to: CGPoint(x: stemX, y: stemBot))
                ctx.strokePath()

                ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: a.bands24[i] > 0.5 ? 0.95 : 0.45)
                ctx.fillEllipse(in: CGRect(x: stemX - 1.8, y: stemBot - 1.8, width: 3.6, height: 3.6))

                let lbl = String(format: "%02d", AcousticSnapshot.roomCBandOrder[i])
                drawText(lbl, at: CGPoint(x: stemX, y: stemBot + 4), font: microFont, color: dim, align: .center)
            }
        }
    }

    // MARK: - Mode 02: Acoustic Ecology Wall Schematic Panels

    private func drawEcologyFrames(ctx: CGContext, size: CGSize) {
        let w = size.width
        let h = size.height
        guard w > 520, h > 320 else { return }

        let a = snapshot
        let pad: CGFloat = 16.0
        let leftW = w * 0.24
        let rightW = w * 0.23
        let midX = w * 0.265
        let midW = w * 0.48
        let rightX = w - pad - rightW

        let hdrFont = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .semibold)
        let rowFont = NSFont.monospacedSystemFont(ofSize: 9.2, weight: .regular)
        let white = NSColor(white: 0.96, alpha: 1)
        let soft = NSColor(calibratedRed: 0.84, green: 0.88, blue: 0.94, alpha: 0.56)
        let gold = NSColor(calibratedRed: 0.95, green: 0.88, blue: 0.72, alpha: 0.95)
        let hair = NSColor(calibratedRed: 0.88, green: 0.91, blue: 0.95, alpha: 0.34).cgColor

        func drawPanel(_ rect: CGRect, title: String, fillOpaque: Bool = true) {
            if fillOpaque {
                ctx.setFillColor(red: 0.048, green: 0.059, blue: 0.078, alpha: 0.96)
                ctx.fill(rect)
            }
            ctx.setStrokeColor(hair)
            ctx.setLineWidth(1.0)
            ctx.stroke(rect)
            drawText(title, at: CGPoint(x: rect.minX + 9, y: rect.minY + 6), font: hdrFont, color: white)
        }

        // Center frame around the Metal 5,000-agent colony (transparent interior!)
        let midRect = CGRect(x: midX, y: h * 0.055, width: midW, height: h * 0.89)
        drawPanel(midRect, title: "ACTIVE CROP / ACOUSTIC COLONY (5,000 GPU AGENTS)", fillOpaque: false)

        // Left Top: FULL VIEW minimap
        let miniRect = CGRect(x: pad, y: h * 0.055, width: leftW, height: h * 0.30)
        drawPanel(miniRect, title: "FULL VIEW")
        let palette: [CGColor] = [
            CGColor(red: 0.91, green: 0.93, blue: 0.96, alpha: 0.85),
            CGColor(red: 0.85, green: 0.55, blue: 0.37, alpha: 0.85),
            CGColor(red: 0.50, green: 0.72, blue: 0.63, alpha: 0.85),
            CGColor(red: 0.84, green: 0.71, blue: 0.42, alpha: 0.85),
            CGColor(red: 0.54, green: 0.66, blue: 0.84, alpha: 0.85)
        ]
        let t = a.time
        let centers: [(CGFloat, CGFloat)] = [
            (0.28 + CGFloat(sin(t * 0.36)) * 0.09, 0.48 + CGFloat(cos(t * 0.31)) * 0.11),
            (0.54 + CGFloat(cos(t * 0.28)) * 0.10, 0.35 + CGFloat(sin(t * 0.42)) * 0.10),
            (0.73 + CGFloat(sin(t * 0.46)) * 0.08, 0.58 + CGFloat(cos(t * 0.37)) * 0.11),
            (0.43 + CGFloat(cos(t * 0.34)) * 0.09, 0.69 + CGFloat(sin(t * 0.29)) * 0.09),
            (0.65 + CGFloat(sin(t * 0.39)) * 0.08, 0.28 + CGFloat(cos(t * 0.48)) * 0.08)
        ]
        for idx in 0..<180 {
            let c = idx % 5
            let ang = CGFloat(idx) * 2.39996 + CGFloat(t) * 0.45
            let rad = CGFloat(sqrt(Double((idx % 37) + 1) / 37.0)) * (0.12 + CGFloat(a.bands24[idx % 24]) * 0.14)
            let px = miniRect.minX + 10 + max(0.03, min(0.97, centers[c].0 + cos(ang) * rad)) * (miniRect.width - 20)
            let py = miniRect.minY + 26 + max(0.04, min(0.96, centers[c].1 + sin(ang) * rad)) * (miniRect.height - 34)
            ctx.setFillColor(palette[c])
            ctx.fill(CGRect(x: px, y: py, width: 1.8, height: 1.8))
        }

        // Left Bottom: ACOUSTIC ANALYTICS table
        let anaTop = miniRect.maxY + 12
        let anaRect = CGRect(x: pad, y: anaTop, width: leftW, height: midRect.maxY - anaTop)
        drawPanel(anaRect, title: "ACOUSTIC ANALYTICS")
        let rows: [(String, String)] = [
            ("DETECTED KEY", a.detectedKey),
            ("RMS ENERGY", String(format: "%.3f", a.energy)),
            ("BASS 35-180HZ", String(format: "%.3f", a.bass)),
            ("MID 180-2.4K", String(format: "%.3f", a.mid)),
            ("AIR 2.4K-14K", String(format: "%.3f", a.treble)),
            ("SPECTRAL FLUX", String(format: "%.3f", a.flux)),
            ("STEREO PHASE", String(format: "%+.2f", a.stereoCorrelation)),
            ("SAMPLE RATE", "\(Int(a.sampleRate)) HZ"),
            ("GPU AGENTS", "5,000")
        ]
        for (idx, (k, v)) in rows.enumerated() {
            let ry = anaRect.minY + 30 + CGFloat(idx) * 23
            if ry + 16 > anaRect.maxY { break }
            drawText(k, at: CGPoint(x: anaRect.minX + 10, y: ry), font: rowFont, color: soft)
            drawText(v, at: CGPoint(x: anaRect.maxX - 10, y: ry), font: rowFont, color: white, align: .right)
            ctx.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 0.06)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: anaRect.minX + 9, y: ry + 16))
            ctx.addLine(to: CGPoint(x: anaRect.maxX - 9, y: ry + 16))
            ctx.strokePath()
        }

        // Right Top: SPECTRAL HEATMAP (48 x 24 scrolling thermal magma spectrogram)
        let hmRect = CGRect(x: rightX, y: h * 0.055, width: rightW, height: h * 0.30)
        drawPanel(hmRect, title: "SPECTRAL HEATMAP")
        let hx = hmRect.minX + 10, hy = hmRect.minY + 26
        let hw = hmRect.width - 20, hh = hmRect.height - 36
        let cols = a.heatHistory.count
        let cw = hw / CGFloat(max(1, cols))
        let ch = hh / 24.0
        for c in 0..<cols {
            let slice = a.heatHistory[c]
            for r in 0..<24 {
                let v = CGFloat(slice[23 - r])
                let cr = min(1.0, v * 1.35)
                let cg = min(1.0, max(0.0, v - 0.25) * 1.08)
                let cb = min(1.0, max(0.0, v - 0.65) * 1.45 + (1.0 - v) * 0.14)
                ctx.setFillColor(red: cr, green: cg, blue: cb, alpha: 1.0)
                ctx.fill(CGRect(x: hx + CGFloat(c) * cw, y: hy + CGFloat(r) * ch, width: cw + 0.5, height: ch + 0.5))
            }
        }

        // Right Bottom: SIGNAL EVENT LOG
        let logTop = hmRect.maxY + 12
        let logRect = CGRect(x: rightX, y: logTop, width: rightW, height: midRect.maxY - logTop)
        drawPanel(logRect, title: "SIGNAL EVENT LOG")
        let logLines = [
            "[KEY]  \(a.detectedKey)",
            String(format: "[BEAT] %.0f%% ONSET LOCK", a.beat * 100),
            String(format: "[BASS] 35-180HZ @ %.0f%%", a.bass * 100),
            String(format: "[MIDS] DENSITY %.0f%%", a.mid * 100),
            String(format: "[FLUX] TRANSIENT %.2f", a.flux),
            "[MODE] \(sourceLabel)",
            "[DSP]  vDSP 4096-FFT",
            "[GPU]  METAL 120HZ"
        ]
        for (idx, line) in logLines.enumerated() {
            let ly = logRect.minY + 30 + CGFloat(idx) * 23
            if ly + 14 > logRect.maxY { break }
            drawText(line, at: CGPoint(x: logRect.minX + 10, y: ly), font: rowFont, color: idx < 2 ? gold : soft)
        }
    }

    // MARK: - Drawing Helpers

    private func drawSlider(ctx: CGContext, x: CGFloat, y: CGFloat, w: CGFloat, value: CGFloat, label: String, font: NSFont, labelColor: NSColor, stroke: CGColor) {
        drawText(label, at: CGPoint(x: x - 30, y: y - 4), font: font, color: labelColor)
        ctx.setStrokeColor(stroke)
        ctx.setLineWidth(0.75)
        ctx.stroke(CGRect(x: x, y: y - 2.5, width: w, height: 6))
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.95)
        let thumbW: CGFloat = 14
        let tx = x + max(0, min(1, value)) * (w - thumbW)
        ctx.fill(CGRect(x: tx, y: y - 2.5, width: thumbW, height: 6))
    }

    private func drawText(_ text: String, at point: CGPoint, font: NSFont, color: NSColor, align: NSTextAlignment = .left) {
        guard !text.isEmpty, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let ctFont = font as CTFont
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: ctFont,
            kCTForegroundColorAttributeName: color.cgColor
        ]
        guard let attrStr = CFAttributedStringCreate(kCFAllocatorDefault, text as CFString, attrs as CFDictionary) else {
            return
        }
        let line = CTLineCreateWithAttributedString(attrStr)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

        var drawX = point.x
        if align == .center { drawX -= width * 0.5 }
        else if align == .right { drawX -= width }

        // Since isFlipped == true, flip the text matrix so glyphs render upright with top-left origin
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1.0, y: -1.0)
        ctx.textPosition = CGPoint(x: drawX, y: point.y + ascent)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
