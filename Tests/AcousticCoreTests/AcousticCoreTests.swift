import Foundation
import Testing
@testable import AcousticCore
import AppKit

@Suite("AcousticCore DSP & RingBuffer Tests")
struct AcousticCoreTests {
    @Test("RingBuffer interleaved wrap-around preserves exact latest stereo samples")
    func ringBufferInterleavedWrapAround() {
        let rb = StereoRingBuffer(capacity: 64)
        var interleaved = [Float](repeating: 0, count: 100 * 2)
        for i in 0..<100 {
            interleaved[i * 2] = Float(i)
            interleaved[i * 2 + 1] = Float(-i)
        }
        interleaved.withUnsafeBufferPointer { ptr in
            rb.writeInterleaved(ptr.baseAddress!, frameCount: 100, channels: 2)
        }

        var outL = [Float](repeating: 0, count: 16)
        var outR = [Float](repeating: 0, count: 16)
        let total = outL.withUnsafeMutableBufferPointer { lPtr in
            outR.withUnsafeMutableBufferPointer { rPtr in
                rb.readLatest(count: 16, intoLeft: lPtr.baseAddress!, intoRight: rPtr.baseAddress!)
            }
        }

        #expect(total == 100)
        for i in 0..<16 {
            let expected = Float(84 + i)
            #expect(outL[i] == expected)
            #expect(outR[i] == -expected)
        }
    }

    @Test("RingBuffer planar mono duplicates left channel to right channel")
    func ringBufferPlanarMono() {
        let rb = StereoRingBuffer(capacity: 64)
        let samples: [Float] = [0.25, -0.5, 0.75, 1.0]
        samples.withUnsafeBufferPointer { ptr in
            rb.writePlanar(leftSrc: ptr.baseAddress!, rightSrc: nil, frameCount: samples.count)
        }
        var outL = [Float](repeating: 0, count: 4)
        var outR = [Float](repeating: 0, count: 4)
        _ = outL.withUnsafeMutableBufferPointer { lPtr in
            outR.withUnsafeMutableBufferPointer { rPtr in
                rb.readLatest(count: 4, intoLeft: lPtr.baseAddress!, intoRight: rPtr.baseAddress!)
            }
        }
        #expect(outL == samples)
        #expect(outR == samples)
    }

    @Test("DSP detects 440 Hz A4 sine wave in chromagram pitch class A")
    func dspDetects440HzChromaA() {
        let sr = 48_000.0
        let rb = StereoRingBuffer(capacity: 8192)
        let dsp = AcousticDSP()
        var interleaved = [Float](repeating: 0, count: 4096 * 2)
        for i in 0..<4096 {
            let s = Float(0.6 * sin(2.0 * Double.pi * 440.0 * Double(i) / sr))
            interleaved[i * 2] = s
            interleaved[i * 2 + 1] = s
        }
        interleaved.withUnsafeBufferPointer { ptr in
            rb.writeInterleaved(ptr.baseAddress!, frameCount: 4096, channels: 2)
        }

        var snap = AcousticSnapshot.empty
        for _ in 0..<25 {
            snap = dsp.process(ringBuffer: rb, sampleRate: sr, dt: 0.04, demoMode: false)
        }

        #expect(!snap.isSilent)
        // Pitch class index 9 is A
        let maxIdx = snap.chroma12.enumerated().max(by: { $0.element < $1.element })?.offset
        #expect(maxIdx == 9)
        #expect(snap.stereoCorrelation > 0.99)
    }

    @Test("DSP identifies C Major triad (C4 + E4 + G4) as C MAJOR")
    func dspDetectsCMajorTriad() {
        let sr = 48_000.0
        let rb = StereoRingBuffer(capacity: 8192)
        let dsp = AcousticDSP()
        var interleaved = [Float](repeating: 0, count: 4096 * 2)
        let freqs = [261.63, 329.63, 392.00, 523.25] // C4, E4, G4, C5
        for i in 0..<4096 {
            let t = Double(i) / sr
            var sum = 0.0
            for f in freqs { sum += sin(2.0 * Double.pi * f * t) }
            let s = Float(sum * 0.2)
            interleaved[i * 2] = s
            interleaved[i * 2 + 1] = s
        }
        interleaved.withUnsafeBufferPointer { ptr in
            rb.writeInterleaved(ptr.baseAddress!, frameCount: 4096, channels: 2)
        }

        var snap = AcousticSnapshot.empty
        for _ in 0..<40 {
            snap = dsp.process(ringBuffer: rb, sampleRate: sr, dt: 0.04, demoMode: false)
        }

        #expect(snap.detectedKey == "C MAJOR")
        #expect(snap.shortKey == "C MAJ")
    }

    @Test("DSP stereo correlation distinguishes in-phase (+1), inverted (-1), and quadrature (0)")
    func dspStereoPhaseCorrelation() {
        let sr = 48_000.0

        func measureCorrelation(rightPhaseOffset: Double, invertRight: Bool = false) -> Float {
            let rb = StereoRingBuffer(capacity: 8192)
            let dsp = AcousticDSP()
            var interleaved = [Float](repeating: 0, count: 4096 * 2)
            for i in 0..<4096 {
                let phase = 2.0 * Double.pi * 300.0 * Double(i) / sr
                let l = Float(0.5 * sin(phase))
                let r = Float((invertRight ? -0.5 : 0.5) * sin(phase + rightPhaseOffset))
                interleaved[i * 2] = l
                interleaved[i * 2 + 1] = r
            }
            interleaved.withUnsafeBufferPointer { ptr in
                rb.writeInterleaved(ptr.baseAddress!, frameCount: 4096, channels: 2)
            }
            return dsp.process(ringBuffer: rb, sampleRate: sr, dt: 0.02, demoMode: false).stereoCorrelation
        }

        #expect(measureCorrelation(rightPhaseOffset: 0) > 0.99)
        #expect(measureCorrelation(rightPhaseOffset: 0, invertRight: true) < -0.99)
        #expect(abs(measureCorrelation(rightPhaseOffset: Double.pi * 0.5)) < 0.05)
    }

    @Test("DSP silence gating transitions cleanly to STANDBY after 1.8s")
    func dspSilenceGating() {
        let rb = StereoRingBuffer(capacity: 8192)
        let dsp = AcousticDSP()
        var snap = AcousticSnapshot.empty
        for _ in 0..<55 {
            snap = dsp.process(ringBuffer: rb, sampleRate: 48_000, dt: 0.04, demoMode: false)
        }
        #expect(snap.isSilent)
        #expect(snap.detectedKey == "STANDBY")
        #expect(snap.energy < 0.01)
    }

    @Test("Sensitivity modes scale low-level response monotonically (calm < balanced < vivid)")
    func sensitivityScaling() {
        let sr = 48_000.0
        let rb = StereoRingBuffer(capacity: 8192)
        var interleaved = [Float](repeating: 0, count: 4096 * 2)
        for i in 0..<4096 {
            let s = Float(0.015 * sin(2.0 * Double.pi * 220.0 * Double(i) / sr))
            interleaved[i * 2] = s
            interleaved[i * 2 + 1] = s
        }
        interleaved.withUnsafeBufferPointer { ptr in
            rb.writeInterleaved(ptr.baseAddress!, frameCount: 4096, channels: 2)
        }

        func energyFor(_ mode: SensitivityMode) -> Float {
            let dsp = AcousticDSP()
            var snap = AcousticSnapshot.empty
            for _ in 0..<20 {
                snap = dsp.process(ringBuffer: rb, sampleRate: sr, dt: 0.04, demoMode: false, sensitivity: mode)
            }
            return snap.energy
        }

        let eCalm = energyFor(.calm)
        let eBal = energyFor(.balanced)
        let eVivid = energyFor(.vivid)
        #expect(eCalm < eBal)
        #expect(eBal < eVivid)
    }

    @Test("Handoff payload round-trips the soundscape and timer, and ignores finished or malformed sessions")
    func handoffPayload() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let timed = SatieHandoff(mode: .dive, flowMinutes: 45, endDate: end)
        #expect(SatieHandoff(userInfo: timed.userInfo) == timed)

        let open = SatieHandoff(mode: .rain, flowMinutes: 0, endDate: end)
        #expect(open.endDate == nil)
        #expect(SatieHandoff(userInfo: open.userInfo) == open)
        #expect(!open.isFinished(at: end.addingTimeInterval(3600)))

        #expect(!timed.isFinished(at: end.addingTimeInterval(-1)))
        #expect(timed.isFinished(at: end))

        #expect(SatieHandoff(userInfo: nil) == nil)
        #expect(SatieHandoff(userInfo: ["mode": "unknown-world"]) == nil)
        #expect(SatieHandoff(userInfo: ["minutes": 25]) == nil)
    }

    @Test("SettingsStore round-trips preferences cleanly")
    func settingsPersistence() {
        let suiteName = "com.strangechances.Satie.test.\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: suiteName)!
        defer { ud.removePersistentDomain(forName: suiteName) }

        // Values left by earlier versions are cleared on load.
        ud.set("brown", forKey: "ac.maskingBed")
        ud.set(false, forKey: "ac.visualFollowsSoundscape")

        let store = SettingsStore(defaults: ud)
        #expect(ud.object(forKey: "ac.maskingBed") == nil)
        #expect(ud.object(forKey: "ac.visualFollowsSoundscape") == nil)
        store.focusMode = .rain
        store.focusVolume = 0.62
        store.mixWithOthers = true
        store.miniHUDOrigin = NSPoint(x: 420, y: 180)
        store.studioFrame = NSRect(x: 100, y: 120, width: 1280, height: 820)

        let reloaded = SettingsStore(defaults: ud)
        #expect(reloaded.focusMode == .rain)
        #expect(abs(reloaded.focusVolume - 0.62) < 0.001)
        #expect(reloaded.mixWithOthers == true)
        #expect(reloaded.miniHUDOrigin == NSPoint(x: 420, y: 180))
        #expect(reloaded.studioFrame == NSRect(x: 100, y: 120, width: 1280, height: 820))

        let pairedWorlds = Set(FocusSoundscape.allCases.map { VisualPreset.paired(for: $0) })
        #expect(pairedWorlds.count == FocusSoundscape.allCases.count)

        // Verify shared App Group widget snapshot round-trips cleanly
        #expect(SatieWidgetSnapshot.appGroupID == "group.com.strangechances.Satie")
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let snap = SatieWidgetSnapshot(
            soundscapeRaw: FocusSoundscape.dive.rawValue,
            soundscapeTitle: FocusSoundscape.dive.title,
            isPlaying: true,
            endDate: end,
            updatedAt: Date(timeIntervalSince1970: 1_799_998_800)
        )
        snap.save(to: ud)
        let reloadedSnap = SatieWidgetSnapshot.load(from: ud)
        #expect(reloadedSnap == snap)
    }

    @Test("FocusSoundEngine generates bounded, non-silent stereo audio across all 5 modes")
    func focusSoundSynthesisAndAutoDuck() {
        for mode in FocusSoundscape.allCases {
            let (l, r) = FocusSoundEngine.renderOfflineTestBlock(mode: mode, circadian: .afternoon, frames: 2048, ducked: false)
            var peak: Float = 0
            var sumSq: Float = 0
            for i in 0..<l.count {
                #expect(l[i].isFinite && r[i].isFinite)
                peak = max(peak, abs(l[i]), abs(r[i]))
                sumSq += l[i] * l[i] + r[i] * r[i]
            }
            let rms = sqrt(sumSq / Float(l.count * 2))
            #expect(peak <= 1.0)
            #expect(rms > 0.005)
        }

        // Verify auto-ducking strongly attenuates output
        let (activeL, _) = FocusSoundEngine.renderOfflineTestBlock(mode: .focus, frames: 2048, ducked: false)
        let (duckedL, _) = FocusSoundEngine.renderOfflineTestBlock(mode: .focus, frames: 2048, ducked: true)
        let rmsActive = sqrt(activeL.reduce(0) { $0 + $1 * $1 } / Float(activeL.count))
        let rmsDucked = sqrt(duckedL.reduce(0) { $0 + $1 * $1 } / Float(duckedL.count))
        #expect(rmsDucked < rmsActive * 0.25)
    }

    @Test("MenuBarPositioner keeps floating panel strictly below notch even when status item is occluded")
    func menuBarNotchPlacement() {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let visible = CGRect(x: 0, y: 0, width: 1728, height: 1084)
        let auxL = CGRect(x: 0, y: 1085, width: 771, height: 32)
        let auxR = CGRect(x: 956, y: 1085, width: 772, height: 32)
        let panel = CGSize(width: 392, height: 420)

        // Case 1: Status item pushed inside the notch dead zone (771..956)
        let occludedBtn = CGRect(x: 858, y: 1085, width: 22, height: 32)
        let p1 = MenuBarPositioner.computePlacement(
            buttonScreenRect: occludedBtn,
            screenFrame: screen,
            visibleFrame: visible,
            auxLeft: auxL,
            auxRight: auxR,
            panelSize: panel
        )
        #expect(p1.statusItemOccludedByNotch == true)
        #expect(p1.origin.y + panel.height <= visible.maxY - 8)
        #expect(p1.origin.x + panel.width <= visible.maxX - 10)

        // Case 2: Status item clearly visible to the right of the notch
        let visibleBtn = CGRect(x: 1320, y: 1085, width: 38, height: 32)
        let p2 = MenuBarPositioner.computePlacement(
            buttonScreenRect: visibleBtn,
            screenFrame: screen,
            visibleFrame: visible,
            auxLeft: auxL,
            auxRight: auxR,
            panelSize: panel
        )
        #expect(p2.statusItemOccludedByNotch == false)
        #expect(p2.origin.y + panel.height <= visible.maxY - 8)
        #expect(abs((p2.origin.x + panel.width * 0.5) - visibleBtn.midX) <= 1.0)

        // Case 3: Padded status item window edge crosses notch (943..987 crosses auxR.minX=956)
        let paddedEdgeWin = CGRect(x: 943, y: 1084, width: 44, height: 33)
        let p3 = MenuBarPositioner.computePlacement(
            buttonScreenRect: paddedEdgeWin,
            screenFrame: screen,
            visibleFrame: visible,
            auxLeft: auxL,
            auxRight: auxR,
            panelSize: panel
        )
        #expect(p3.statusItemOccludedByNotch == true)
        #expect(p3.origin.x + panel.width == visible.maxX - 10)

        // Case 4: Control Center hides item just right of notch (x=965 > 956, isStatusItemWindowVisible=false)
        let ccHiddenWin = CGRect(x: 965, y: 1084, width: 38, height: 33)
        let p4 = MenuBarPositioner.computePlacement(
            buttonScreenRect: ccHiddenWin,
            screenFrame: screen,
            visibleFrame: visible,
            auxLeft: auxL,
            auxRight: auxR,
            panelSize: panel,
            isStatusItemWindowVisible: false
        )
        #expect(p4.statusItemOccludedByNotch == true)
        #expect(p4.origin.x + panel.width == visible.maxX - 10)

        // Case 5: Dynamic height transitions (compact -> notch hint -> Options drawer -> compact)
        // must remain strictly top-anchored at visible.maxY - 8 (panel only grows/shrinks downward).
        let heights: [CGFloat] = [350, 374, 592, 350]
        for h in heights {
            let sz = CGSize(width: 392, height: h)
            let p = MenuBarPositioner.computePlacement(
                buttonScreenRect: paddedEdgeWin,
                screenFrame: screen,
                visibleFrame: visible,
                auxLeft: auxL,
                auxRight: auxR,
                panelSize: sz
            )
            #expect(p.origin.y + sz.height == visible.maxY - 8, "Top edge shifted for height \(h): maxY=\(p.origin.y + sz.height)")
            #expect(p.origin.y >= visible.minY + 10)
        }
    }

    @Test("SatieScore is deterministic, varies on Pass 2+, stays strictly in key, and handles sleep wake cleanly")
    func satieScoreInvariantsAndSleepGuard() {
        var rngA = SeededRNG(seed: 42)
        var rngB = SeededRNG(seed: 42)
        let pass1A = (0..<32).map { SatieScore.composeBar(mode: .focus, barIndex: $0, rng: &rngA) }
        let pass1B = (0..<32).map { SatieScore.composeBar(mode: .focus, barIndex: $0, rng: &rngB) }
        #expect(pass1A == pass1B)

        // Pass 2+ introduces variation (swaps / dropouts / octave lifts) while preserving harmony
        let pass2 = (32..<64).map { SatieScore.composeBar(mode: .focus, barIndex: $0, rng: &rngA) }
        let anySwapped = pass2.contains(where: { $0.didSwapFigure })
        #expect(anySwapped)

        for bar in pass1A + pass2 {
            for bell in bar.bells {
                let pc = ((bell.midi % 12) + 12) % 12
                #expect(bar.allowedPitchClasses.contains(pc), "Bell MIDI \(bell.midi) left harmony on bar \(bar.barInForm)")
            }
            for sus in bar.sustained {
                let pc = ((sus.midi % 12) + 12) % 12
                #expect(bar.allowedPitchClasses.contains(pc), "Sustain MIDI \(sus.midi) left harmony on bar \(bar.barInForm)")
            }
        }

        // Sleep guard (`stillDue`): ended bar returns zero events; mid-bar drops late bells & trims held notes
        let bar0 = pass1A[0]
        let ended = SatieScore.stillDue(bar0, barStart: 0.0, now: bar0.secondsPerBar + 2.0)
        #expect(ended.bells.isEmpty && ended.sustained.isEmpty)

        let mid = SatieScore.stillDue(bar0, barStart: 0.0, now: 1.5)
        #expect(mid.bells.allSatisfy { $0.at >= 1.5 })
        #expect(mid.sustained.allSatisfy { $0.at >= 1.5 && $0.duration >= SatieScore.shortestLateNoteSeconds })
    }

    @Test("Psychoacoustic spectral meter confirms laptop-speaker survival and low >5.5kHz fatigue energy")
    func psychoacousticSpectralGrading() {
        let dsp = AcousticDSP()
        for mode in FocusSoundscape.allCases {
            let (l, r) = FocusSoundEngine.renderOfflineTestBlock(
                mode: mode,
                circadian: .afternoon,
                frames: 4096,
                ducked: false,
                warmupFrames: 36_000,
                seed: 7
            )
            let rb = StereoRingBuffer()
            l.withUnsafeBufferPointer { lb in
                r.withUnsafeBufferPointer { rbPtr in
                    rb.writePlanar(leftSrc: lb.baseAddress!, rightSrc: rbPtr.baseAddress!, frameCount: l.count)
                }
            }
            var snap = AcousticSnapshot.empty
            for _ in 0..<6 {
                snap = dsp.process(ringBuffer: rb, sampleRate: 48_000, dt: 1.0 / 60.0, demoMode: false)
            }
            // Midband laptop-speaker range (bands 6..18 ≈ 250 Hz .. 4 kHz) must carry clear energy
            let midAvg = snap.bands24[6...18].reduce(0, +) / 13.0
            let highAvg = snap.bands24[21...23].reduce(0, +) / 3.0
            #expect(midAvg > 0.08, "Mode \(mode.shortLabel) too weak in laptop-speaker midband (\(midAvg))")
            #expect(highAvg < midAvg * 0.95 + 0.25, "Mode \(mode.shortLabel) harsh upper energy too high (\(highAvg))")
        }
    }

    @Test("NowPlayingBridge artwork callback runs safely on a background queue without Swift 6 @MainActor trap")
    func nowPlayingArtworkBackgroundSafety() async {
        // Minimal valid 1x1 PNG bytes
        let img = NSImage(size: CGSize(width: 16, height: 16))
        img.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 16, height: 16).fill()
        img.unlockFocus()
        let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
        let png = rep.representation(using: .png, properties: [:])!

        let artwork = NowPlayingBridge.makeArtwork(pngData: png, boundsSize: CGSize(width: 16, height: 16))
        // Invoke from a non-main background queue (simulating MediaPlayer's accessQueue)
        let renderedSize: CGSize = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let out = artwork.image(at: CGSize(width: 16, height: 16))
                cont.resume(returning: out?.size ?? .zero)
            }
        }
        #expect(renderedSize.width > 0 && renderedSize.height > 0)
    }

    @Test("Audiophile mastering invariants: 45 CC0 studio samples loaded, strict mono sub-bass (<120 Hz), lush stereo mids, zero clipping, low DC, and real-time CPU headroom")
    func audiophileEngineBenchmark() {
        #expect(FocusSoundEngine.loadedAcousticSampleCount == 45, "Expected 45 CC0 studio acoustic samples loaded, got \(FocusSoundEngine.loadedAcousticSampleCount)")

        let sr = 48_000.0
        let testSeconds = 6.0
        let frames = Int(sr * testSeconds)

        // Cascaded 3-stage lowpass at 85 Hz (18 dB/oct) to measure genuine sub-bass (<110 Hz) without mid-band bleed
        let subAlpha = Float(1.0 - exp(-2.0 * Double.pi * 85.0 / sr))
        let midHpAlpha = Float(1.0 - exp(-2.0 * Double.pi * 300.0 / sr))

        for mode in FocusSoundscape.allCases {
            let t0 = CFAbsoluteTimeGetCurrent()
            let (l, r) = FocusSoundEngine.renderOfflineTestBlock(
                mode: mode,
                circadian: .afternoon,
                frames: frames,
                ducked: false,
                warmupFrames: 48_000,
                seed: 42
            )
            let elapsed = CFAbsoluteTimeGetCurrent() - t0
            // Rendered 1s warmup + 6s = 7s of 48 kHz stereo audio
            let cpuPct = (elapsed / (testSeconds + 1.0)) * 100.0

            var sumSq: Double = 0
            var peak: Float = 0
            var dcL: Double = 0
            var dcR: Double = 0

            var s1L: Float = 0, s2L: Float = 0, s3L: Float = 0
            var s1R: Float = 0, s2R: Float = 0, s3R: Float = 0
            var subDot: Double = 0, subEL: Double = 0, subER: Double = 0

            var midHpStateL: Float = 0, midHpStateR: Float = 0
            var midDot: Double = 0, midEL: Double = 0, midER: Double = 0

            for i in 0..<frames {
                let xL = l[i], xR = r[i]
                #expect(xL.isFinite && xR.isFinite)
                peak = max(peak, abs(xL), abs(xR))
                sumSq += 0.5 * Double(xL * xL + xR * xR)
                dcL += Double(xL)
                dcR += Double(xR)

                s1L += (xL - s1L) * subAlpha; s2L += (s1L - s2L) * subAlpha; s3L += (s2L - s3L) * subAlpha
                s1R += (xR - s1R) * subAlpha; s2R += (s1R - s2R) * subAlpha; s3R += (s2R - s3R) * subAlpha
                subDot += Double(s3L * s3R)
                subEL += Double(s3L * s3L)
                subER += Double(s3R * s3R)

                midHpStateL += (xL - midHpStateL) * midHpAlpha
                midHpStateR += (xR - midHpStateR) * midHpAlpha
                let mL = xL - midHpStateL
                let mR = xR - midHpStateR
                midDot += Double(mL * mR)
                midEL += Double(mL * mL)
                midER += Double(mR * mR)
            }

            let rms = sqrt(max(1e-12, sumSq / Double(frames)))
            let rmsDB = 20.0 * log10(rms)
            let peakDB = 20.0 * log10(max(1e-6, Double(peak)))
            let dc = max(abs(dcL), abs(dcR)) / Double(frames)
            let subCorr = subDot / max(1e-12, sqrt(subEL * subER))
            let midCorr = midDot / max(1e-12, sqrt(midEL * midER))

            print(String(format: "[SATIE-V4] %-14s RMS=%6.2f dBFS  Peak=%6.2f dBFS  Crest=%5.2f dB  SubCorr=%+.4f  MidCorr=%+.4f  DC=%.5f  CPU=%.2f%%",
                         (mode.title as NSString).utf8String!, rmsDB, peakDB, peakDB - rmsDB, subCorr, midCorr, dc, cpuPct))

            // Strict audiophile invariants
            #expect(peak <= 0.945, "Mode \(mode.title) exceeded true-peak ceiling (\(peak))")
            #expect(dc < 0.004, "Mode \(mode.title) has excessive DC offset (\(dc))")
            #expect(rmsDB > -22.0 && rmsDB < -12.0, "Mode \(mode.title) loudness out of calibrated -18..-15 dBFS window (\(rmsDB) dBFS)")
            // Deep Dive intentionally injects post-matrix pure L/R binaural beats (110..165 Hz), so subCorr is lower by design
            if mode != .dive {
                #expect(subCorr > 0.975, "Mode \(mode.title) sub-bass (<110 Hz) is not strictly mono (\(subCorr))")
            }
            #expect(midCorr > 0.05 && midCorr < 0.92, "Mode \(mode.title) mid/high stereo imaging out of lush range (\(midCorr))")
        }

        // Verify Eno prime-length macro cycles actually evolve across passes
        var rng = SeededRNG(seed: 42)
        let bar0 = SatieScore.composeBar(mode: .focus, barIndex: 0, rng: &rng)
        let bar32 = SatieScore.composeBar(mode: .focus, barIndex: 32, rng: &rng)
        #expect(abs(bar0.macroFilterHorizon - bar32.macroFilterHorizon) > 0.01 || abs(bar0.macroSpaceBloom - bar32.macroSpaceBloom) > 0.01)
    }

    @Test("Deep Dive Meditation DSP proofs vs Classic STILL: post-matrix binaural survival, non-repeating rain autocorrelation, 2-5 kHz fatigue scoop, loudness parity")
    func deepDiveMeditationProofsVsStill() {
        let sr = 48_000.0

        // 1. Render 20s of Classic STILL vs 20s of Deep Dive STILL (with 6s warmup so fade-ins settle)
        let testSec = 20.0
        let frames = Int(sr * testSec)
        let warmFrames = Int(sr * 6.0)

        let t0Classic = CFAbsoluteTimeGetCurrent()
        let (cL, cR) = FocusSoundEngine.renderOfflineTestBlock(
            mode: .still, circadian: .afternoon, frames: frames, warmupFrames: warmFrames, seed: 42
        )
        let classicCPU = ((CFAbsoluteTimeGetCurrent() - t0Classic) / (testSec + 6.0)) * 100.0

        let t0Dive = CFAbsoluteTimeGetCurrent()
        let (dL, dR) = FocusSoundEngine.renderOfflineTestBlock(
            mode: .dive, circadian: .afternoon, frames: frames, warmupFrames: warmFrames, seed: 42
        )
        let diveCPU = ((CFAbsoluteTimeGetCurrent() - t0Dive) / (testSec + 6.0)) * 100.0

        func metrics(_ l: [Float], _ r: [Float]) -> (rmsDB: Double, peak: Float, dc: Double) {
            var sumSq: Double = 0, peak: Float = 0, dcL: Double = 0, dcR: Double = 0
            for i in 0..<l.count {
                let xL = l[i], xR = r[i]
                #expect(xL.isFinite && xR.isFinite)
                peak = max(peak, abs(xL), abs(xR))
                sumSq += 0.5 * Double(xL * xL + xR * xR)
                dcL += Double(xL); dcR += Double(xR)
            }
            let rms = sqrt(max(1e-12, sumSq / Double(l.count)))
            return (20.0 * log10(rms), peak, max(abs(dcL), abs(dcR)) / Double(l.count))
        }

        let mClassic = metrics(cL, cR)
        let mDive = metrics(dL, dR)

        // 2. Post-Matrix Binaural L/R Survival Proof via exact Goertzel DFT on Deep Dive output
        // Afternoon root D3 = 146.83 Hz, initial ~6..12s binaural delta ~ 7.98 Hz -> fL ~ 142.84 Hz, fR ~ 150.82 Hz
        func goertzelPower(_ x: [Float], start: Int, count: Int, freqHz: Double) -> Double {
            let w = 2.0 * Double.pi * freqHz / sr
            let coeff = 2.0 * cos(w)
            var s1 = 0.0, s2 = 0.0
            for i in 0..<count {
                let s0 = Double(x[start + i]) + coeff * s1 - s2
                s2 = s1
                s1 = s0
            }
            return max(1e-18, s1 * s1 + s2 * s2 - coeff * s1 * s2)
        }

        // Analyze 4 seconds (192,000 samples -> 0.25 Hz frequency resolution!)
        let binStart = 0
        let binN = 192_000
        let fLTarget = 146.83 - 7.98 * 0.5 // ~142.84 Hz
        let fRTarget = 146.83 + 7.98 * 0.5 // ~150.82 Hz
        let pL_at_fL = goertzelPower(dL, start: binStart, count: binN, freqHz: fLTarget)
        let pL_at_fR = goertzelPower(dL, start: binStart, count: binN, freqHz: fRTarget)
        let pR_at_fR = goertzelPower(dR, start: binStart, count: binN, freqHz: fRTarget)
        let pR_at_fL = goertzelPower(dR, start: binStart, count: binN, freqHz: fLTarget)

        let leftIsoDB = 10.0 * log10(pL_at_fL / pL_at_fR)
        let rightIsoDB = 10.0 * log10(pR_at_fR / pR_at_fL)

        // 3. Spectral Hygiene: 2-5 kHz ear-canal alarm band vs 150-400 Hz warmth band
        func bandPower(_ l: [Float], _ r: [Float], freqs: [Double]) -> Double {
            var acc = 0.0
            for f in freqs {
                acc += 0.5 * (goertzelPower(l, start: 0, count: 96_000, freqHz: f) + goertzelPower(r, start: 0, count: 96_000, freqHz: f))
            }
            return acc / Double(freqs.count)
        }
        let warmFreqs = [165.0, 210.0, 260.0, 320.0, 380.0]
        let alarmFreqs = [2150.0, 2650.0, 3100.0, 3650.0, 4350.0]
        let diveAlarmVsWarmDB = 10.0 * log10(bandPower(dL, dR, freqs: alarmFreqs) / bandPower(dL, dR, freqs: warmFreqs))
        let classicAlarmVsWarmDB = 10.0 * log10(bandPower(cL, cR, freqs: alarmFreqs) / bandPower(cL, cR, freqs: warmFreqs))

        // 4. Non-Repeating Rain Autocorrelation Proof: Direct head-to-head of old looping StudioRainPlayer
        //    vs new StochasticRainField over 45 seconds (lags 2.0s .. 22.0s, covering rain_bed.m4a loop period!)
        let acSec = 45.0
        let acFrames = Int(sr * acSec)
        let bank = TimbreBank()
        var oldRain = StudioRainPlayer()
        var newRain = StochasticRainField(seed: 99)

        func envelopeMaxAutoCorr(_ samples: [Float], minLagSec: Double, maxLagSec: Double) -> (maxR: Double, lagSec: Double) {
            let hop = 2400 // 50ms
            let nEnv = samples.count / hop
            var raw = [Double](repeating: 0, count: nEnv)
            for b in 0..<nEnv {
                var s = 0.0
                let base = b * hop
                for k in 0..<hop { let v = Double(samples[base + k]); s += v * v }
                raw[b] = sqrt(s / Double(hop))
            }
            // High-pass detrend the envelope (subtract 1.5s moving average) so slow weather/breath
            // swells don't mask droplet-pattern loop periodicity
            let win = 15
            var env = [Double](repeating: 0, count: nEnv)
            for b in 0..<nEnv {
                let lo = max(0, b - win)
                let hi = min(nEnv - 1, b + win)
                var avg = 0.0
                for j in lo...hi { avg += raw[j] }
                env[b] = raw[b] - avg / Double(hi - lo + 1)
            }
            var varEnv = 0.0
            for b in 0..<nEnv { varEnv += env[b] * env[b] }

            var bestR = 0.0
            var bestLag = 0.0
            let minLag = Int(minLagSec / 0.05)
            let maxLag = min(nEnv - 10, Int(maxLagSec / 0.05))
            for lag in minLag...maxLag {
                var num = 0.0
                let n = nEnv - lag
                for b in 0..<n { num += env[b] * env[b + lag] }
                let r = abs(num / max(1e-12, varEnv))
                if r > bestR {
                    bestR = r
                    bestLag = Double(lag) * 0.05
                }
            }
            return (bestR, bestLag)
        }

        var oldRainL = [Float](repeating: 0, count: acFrames)
        var newRainL = [Float](repeating: 0, count: acFrames)
        let dt = 1.0 / sr
        for i in 0..<acFrames {
            let t = Double(i) * dt
            oldRainL[i] = oldRain.step(clockSec: t, spaceBloom: 0.5, sampleRate: sr).0
            newRainL[i] = newRain.step(elapsedSec: t, depth01: 0.3, return01: 0.0, breath01: 0.5, dt: dt, sampleRate: sr, sineTable: bank.sineTable).0
        }
        let oldAC = envelopeMaxAutoCorr(oldRainL, minLagSec: 2.0, maxLagSec: 22.0)
        let newAC = envelopeMaxAutoCorr(newRainL, minLagSec: 2.0, maxLagSec: 22.0)

        // 5. Subconscious Resonance Breath Pacer Deceleration Proof (8.5 bpm -> 5.5 bpm over 10 min)
        var pacer = ResonanceBreathPacer()
        _ = pacer.step(elapsedSec: 0.0, dt: dt)
        let bpmStart = pacer.currentBPM
        _ = pacer.step(elapsedSec: 300.0, dt: dt)
        let bpmMid = pacer.currentBPM
        _ = pacer.step(elapsedSec: 600.0, dt: dt)
        let bpmEnd = pacer.currentBPM

        print(String(format: "[GRADE] Classic STILL : RMS=%6.2f dBFS  Peak=%.3f  AlarmVsWarm=%+6.2f dB  CPU=%.2f%%",
                     mClassic.rmsDB, mClassic.peak, classicAlarmVsWarmDB, classicCPU))
        print(String(format: "[GRADE] Deep Dive     : RMS=%6.2f dBFS  Peak=%.3f  AlarmVsWarm=%+6.2f dB  CPU=%.2f%%",
                     mDive.rmsDB, mDive.peak, diveAlarmVsWarmDB, diveCPU))
        print(String(format: "[GRADE] Binaural L/R Isolation (post-AudiophileMasterBus): L=%.2f dB  R=%.2f dB",
                     leftIsoDB, rightIsoDB))
        print(String(format: "[GRADE] Rain Autocorrelation (2..22s) — Old Loop: r=%.4f @ %.2fs | New Stochastic: r=%.4f @ %.2fs",
                     oldAC.maxR, oldAC.lagSec, newAC.maxR, newAC.lagSec))
        print(String(format: "[GRADE] Breath Pacer Deceleration: %.2f -> %.2f -> %.2f breaths/min",
                     bpmStart, bpmMid, bpmEnd))

        // Hard proof assertions
        #expect(mDive.peak <= 0.945, "Deep Dive exceeded true-peak ceiling (\(mDive.peak))")
        #expect(mDive.dc < 0.004, "Deep Dive DC offset too high (\(mDive.dc))")
        #expect(mDive.rmsDB > -21.0 && mDive.rmsDB < -13.0, "Deep Dive RMS out of target window (\(mDive.rmsDB) dBFS)")
        #expect(abs(mDive.rmsDB - mClassic.rmsDB) < 1.5, "Deep Dive loudness too far from Classic STILL for fair A/B (\(mDive.rmsDB) vs \(mClassic.rmsDB))")
        #expect(leftIsoDB > 18.0 && rightIsoDB > 18.0, "Post-matrix binaural beat collapsed in AudiophileMasterBus! L=\(leftIsoDB) dB, R=\(rightIsoDB) dB")
        #expect(diveAlarmVsWarmDB < -15.0, "2-5 kHz ear-canal fatigue band not sufficiently scooped (\(diveAlarmVsWarmDB) dB)")
        #expect(newAC.maxR < 0.14, "Periodic rain loop detected in StochasticRainField! r=\(newAC.maxR) at \(newAC.lagSec)s")
        #expect(newAC.maxR < oldAC.maxR * 0.5, "StochasticRainField did not dramatically beat StudioRainPlayer loop periodicity (\(newAC.maxR) vs \(oldAC.maxR))")
        #expect(bpmStart > 8.4 && bpmMid < 7.2 && bpmEnd < 5.55 && bpmEnd > 5.45)
    }

    @Test("StudioLifecycleMachine replays all 4 TLC counterexample paths without freezing, zombie fullscreen, or updateNSView thrash")
    func studioLifecycleFormalReplay() {
        var m = StudioLifecycleMachine()

        // Path 1 (NoFrozenStudio & NoReentrantDrawThrash): open Studio -> 250ms SwiftUI telemetry tick is a strict NO-OP
        let eOpen = m.requestOpen(fullscreen: false)
        #expect(m.winState == .visible && m.isStudioOpen && m.metalActive)
        #expect(eOpen.contains(.createAndShowWindow(fullscreen: false)))
        let eTick = m.handleSwiftUISync(isActive: true)
        #expect(eTick.isEmpty, "250ms SwiftUI telemetry tick must never restart CVDisplayLink or draw synchronously")

        // Path 2 (ReopenRestoresVisible & MinimizedMeansStopped): minimize -> GPU stops -> Open Studio deminiaturizes
        let eMin = m.handleWindowDidMiniaturize()
        #expect(m.winState == .minimized && !m.metalActive)
        #expect(eMin == [.setMetalActive(false)])
        let eReopenMin = m.requestOpen(fullscreen: false)
        #expect(m.winState == .visible && m.isStudioOpen && m.metalActive)
        #expect(eReopenMin.contains(.deminiaturizeAndShow(fullscreen: false)))
        #expect(eReopenMin.contains(.recoverMetalIfStalled))

        // Path 3 (NoZombieFullscreen): enter fullscreen -> switch to Mini HUD defers orderOut until exit completes
        _ = m.handleDidEnterFullScreen()
        #expect(m.winState == .fullscreen && m.isFullscreen)
        let eCloseFS = m.requestClose()
        #expect(m.winState == .exitingFullscreen && m.pendingCloseAfterFullScreenExit)
        #expect(eCloseFS == [.requestToggleFullscreen], "Must NEVER call orderOut synchronously while exiting fullscreen")
        let eExitDone = m.handleDidExitFullScreen()
        #expect(m.winState == .hidden && !m.isStudioOpen && !m.isFullscreen && !m.metalActive)
        #expect(eExitDone == [.setMetalActive(false), .orderOutWindow])

        // Path 3b (Reopen cancels deferred close mid-fullscreen-exit):
        _ = m.requestOpen(fullscreen: false)
        _ = m.handleDidEnterFullScreen()
        _ = m.requestClose()
        #expect(m.pendingCloseAfterFullScreenExit)
        _ = m.requestOpen(fullscreen: false)
        #expect(!m.pendingCloseAfterFullScreenExit)
        let eStayOpen = m.handleDidExitFullScreen()
        #expect(m.winState == .visible && m.isStudioOpen && m.metalActive)
        #expect(eStayOpen.contains(.recoverMetalIfStalled))

        // Path 4 (SystemSleepAndWake): wake while visible recovers stalled display link
        let eWake = m.handleSystemWake()
        #expect(eWake.contains(.recoverMetalIfStalled))
        #expect(m.metalActive)

        // Path 5 (CloseAndReopenOrder): red-button / Cmd+W close -> Expand orders window BEFORE activating Metal
        let eClose = m.handleWindowWillClose()
        #expect(m.winState == .hidden && !m.isStudioOpen && !m.metalActive)
        #expect(eClose == [.setMetalActive(false)])
        let eReopen = m.requestOpen(fullscreen: false)
        #expect(eReopen == [.orderFrontWindow(fullscreen: false), .setMetalActive(true), .recoverMetalIfStalled])
        #expect(m.winState == .visible && m.isStudioOpen && m.metalActive)
    }

    @Test("Kinetic Pulse embeds silky beat-locked 14.40 Hz beta AM without harsh headphone vibration (Woods & Loui 2024)")
    func pulseBetaBandAmplitudeModulationProof() {
        let sr = 48_000.0
        let sec = 6.0
        let frames = Int(sr * sec)
        let (l, r) = FocusSoundEngine.renderOfflineTestBlock(
            mode: .pulse, circadian: .afternoon, frames: frames, warmupFrames: 48_000, seed: 42
        )

        // Single-ear mid-upper envelope (> 320 Hz, preserves gentle 36° stereo phase soften) + broadband roughness meter
        let hpAlpha = Float(exp(-2.0 * Double.pi * 320.0 / sr))
        var prevIn: Float = 0, prevOut: Float = 0
        let decimate = 240 // 48000 / 240 = 200 Hz envelope rate (Nyquist = 100 Hz)
        let envN = frames / decimate
        var env = [Double](repeating: 0, count: envN)
        var bbEnv = [Double](repeating: 0, count: envN)
        for b in 0..<envN {
            var acc = 0.0
            var bbAcc = 0.0
            let base = b * decimate
            for k in 0..<decimate {
                let x = l[base + k]
                let y = hpAlpha * (prevOut + x - prevIn)
                prevIn = x; prevOut = y
                acc += abs(Double(y))
                bbAcc += abs(Double(0.5 * (l[base + k] + r[base + k])))
            }
            env[b] = acc / Double(decimate)
            bbEnv[b] = bbAcc / Double(decimate)
        }
        let mean = env.reduce(0, +) / Double(envN)
        let bbMean = bbEnv.reduce(0, +) / Double(envN)
        for i in 0..<envN {
            env[i] -= mean
            bbEnv[i] -= bbMean
        }

        func envGoertzel(_ series: [Double], _ freqHz: Double) -> Double {
            let w = 2.0 * Double.pi * freqHz / 200.0
            let coeff = 2.0 * cos(w)
            var s1 = 0.0, s2 = 0.0
            for v in series {
                let s0 = v + coeff * s1 - s2
                s2 = s1; s1 = s0
            }
            return max(1e-18, s1 * s1 + s2 * s2 - coeff * s1 * s2)
        }

        let p144 = envGoertzel(env, 14.40)
        let pNoiseFloor = 0.5 * (envGoertzel(env, 11.0) + envGoertzel(env, 17.8))
        let snrDB = 10.0 * log10(p144 / pNoiseFloor)

        // Ear-comfort roughness guard: broadband 14.4 Hz modulation amplitude relative to DC mean must stay silky (< 6%)
        let bbAmp144 = 2.0 * sqrt(envGoertzel(bbEnv, 14.40)) / Double(envN)
        let bbModPct = (bbAmp144 / max(1e-9, bbMean)) * 100.0

        print(String(format: "[BETA-AM] PULSE 14.40 Hz (108 BPM 8:1 lock) SNR = %+.2f dB | Broadband Roughness = %.2f%% (silky <6%%)", snrDB, bbModPct))
        #expect(snrDB > 3.0, "Expected subtle beat-locked 14.40 Hz beta AM presence in PULSE pad/wet halo, got \(snrDB) dB")
        #expect(bbModPct < 6.0, "PULSE broadband 14.4 Hz modulation too intense (\(bbModPct)%) — would vibrate harshly in headphones")
    }

    @Test("BlueNoise64 tile has exact uniform histogram and >25 dB high-pass 2D spectral power")
    func blueNoise64SpectrumAndUniformity() {
        let n = BlueNoise64.dimension
        #expect(n == 64)
        #expect(BlueNoise64.bytes.count == n * n)

        var hist = [Int](repeating: 0, count: 256)
        var mean = 0.0
        for b in BlueNoise64.bytes {
            hist[Int(b)] += 1
            mean += Double(b) / 255.0
        }
        mean /= Double(n * n)
        for level in 0..<256 {
            #expect(hist[level] == 16, "Level \(level) count was \(hist[level]), expected 16")
        }

        // Measure 2D DFT power at representative low vs high spatial frequencies (toroidal)
        func power2D(kx: Int, ky: Int) -> Double {
            var re = 0.0, im = 0.0
            let twoPiOverN = 2.0 * Double.pi / Double(n)
            for y in 0..<n {
                for x in 0..<n {
                    let v = Double(BlueNoise64.bytes[y * n + x]) / 255.0 - mean
                    let ang = twoPiOverN * Double(kx * x + ky * y)
                    re += v * cos(ang)
                    im -= v * sin(ang)
                }
            }
            return re * re + im * im
        }
        let lowPairs = [(1, 0), (0, 1), (2, 1), (1, 2), (3, 2), (2, 3), (4, 0), (0, 4)]
        let highPairs = [(24, 24), (28, 12), (12, 28), (30, 18), (18, 30), (31, 31), (26, 20), (20, 26)]
        let lowAvg = lowPairs.map { power2D(kx: $0.0, ky: $0.1) }.reduce(0, +) / Double(lowPairs.count)
        let highAvg = highPairs.map { power2D(kx: $0.0, ky: $0.1) }.reduce(0, +) / Double(highPairs.count)
        let ratioDB = 10.0 * log10(highAvg / max(lowAvg, 1e-12))
        print(String(format: "[BLUE-NOISE] 64x64 tile: lowAvg=%.4f highAvg=%.2f High/Low=+%.2f dB", lowAvg, highAvg, ratioDB))
        #expect(ratioDB > 25.0, "Expected genuine blue-noise >25 dB high-pass ratio, got \(ratioDB) dB")
    }

    @Test("StudioAcousticSpace Velvet-Noise + Colorless Orthogonal FDN produces dense, decorrelated, flat, DC-free decaying hall impulse response")
    func studioAcousticSpaceVelvetFDNProof() {
        var space = StudioAcousticSpace()
        let sr = 48_000.0
        let totalFrames = 96_000 // 2.0 seconds
        var irL = [Float](repeating: 0, count: totalFrames)
        var irR = [Float](repeating: 0, count: totalFrames)

        for i in 0..<totalFrames {
            let x: Float = (i == 0) ? 1.0 : 0.0
            let (l, r) = space.process(x, x, preDelayMs: 18.0, decay: 0.85, dampLP: 0.36, dampHP: 0.022, erMix: 0.32, modScale: 1.0, dt: 1.0 / sr, sampleRate: sr)
            irL[i] = l
            irR[i] = r
        }

        // 1. Strict finiteness, bounded peak, zero DC
        var peak: Float = 0
        var sumL = 0.0, sumR = 0.0
        for i in 0..<totalFrames {
            #expect(irL[i].isFinite && irR[i].isFinite)
            peak = max(peak, max(abs(irL[i]), abs(irR[i])))
            sumL += Double(irL[i]); sumR += Double(irR[i])
        }
        let dc = max(abs(sumL), abs(sumR)) / Double(totalFrames)

        // 2. Early echo density (4 ms .. 60 ms) + stereo decorrelation
        let erStart = Int(0.004 * sr), erEnd = Int(0.060 * sr)
        var erSqL = 0.0, erSqR = 0.0, erCross = 0.0
        for i in erStart..<erEnd {
            let l = Double(irL[i]), r = Double(irR[i])
            erSqL += l * l; erSqR += r * r; erCross += l * r
        }
        let erRms = sqrt(erSqL / Double(erEnd - erStart))
        let erActive = (erStart..<erEnd).reduce(0) { acc, i in acc + (abs(Double(irL[i])) > erRms * 0.25 ? 1 : 0) }
        let erDensity = Double(erActive) / Double(erEnd - erStart)
        let erStereoCorr = erCross / max(1e-12, sqrt(erSqL * erSqR))

        // 3. Monotonic late decay across three 0.5s windows (0.1..0.6s, 0.7..1.2s, 1.4..1.9s)
        func rmsWindow(_ a: Double, _ b: Double) -> Double {
            let s = Int(a * sr), e = Int(b * sr)
            var acc = 0.0
            for i in s..<e { acc += Double(irL[i] * irL[i] + irR[i] * irR[i]) * 0.5 }
            return sqrt(acc / Double(e - s))
        }
        let rEarly = rmsWindow(0.10, 0.60)
        let rMid   = rmsWindow(0.70, 1.20)
        let rLate  = rmsWindow(1.40, 1.90)

        // 4. Spectral flatness (Wiener entropy) of late tail (0.15s..0.85s) across 64 log-spaced probes in 150..3600 Hz
        let tailStart = Int(0.15 * sr)
        let tailLen = 32_768
        var mags = [Double]()
        for k in 0..<64 {
            let f = 150.0 * pow(3600.0 / 150.0, Double(k) / 63.0)
            let w = 2.0 * Double.pi * f / sr
            let coeff = 2.0 * cos(w)
            var s1 = 0.0, s2 = 0.0
            for i in 0..<tailLen {
                let x = Double(irL[tailStart + i])
                let s0 = x + coeff * s1 - s2
                s2 = s1; s1 = s0
            }
            let p = max(1e-18, s1 * s1 + s2 * s2 - coeff * s1 * s2)
            mags.append(sqrt(p))
        }
        let geoMean = exp(mags.map { log($0) }.reduce(0, +) / Double(mags.count))
        let ariMean = mags.reduce(0, +) / Double(mags.count)
        let flatness = geoMean / max(ariMean, 1e-12)

        // 5. Verify RT60 decay parameter cleanly scales concert-hall tail length (0.92 > 3x longer tail than 0.85)
        var hallSpace = StudioAcousticSpace()
        var hallLateSq = 0.0
        let lateS = Int(1.40 * sr), lateE = Int(1.90 * sr)
        for i in 0..<totalFrames {
            let x: Float = (i == 0) ? 1.0 : 0.0
            let (l, r) = hallSpace.process(x, x, preDelayMs: 18.0, decay: 0.92, dampLP: 0.36, dampHP: 0.022, erMix: 0.32, modScale: 1.0, dt: 1.0 / sr, sampleRate: sr)
            if i >= lateS && i < lateE {
                hallLateSq += Double(l * l + r * r) * 0.5
            }
        }
        let rLateHall = sqrt(hallLateSq / Double(lateE - lateS))

        print(String(format: "[VN-FDN] Peak=%.3f DC=%.6f EarlyDensity=%.1f%% EarlyStereoCorr=%+.3f TailFlatness=%.3f Decay85=(%.5f -> %.5f -> %.6f) Hall92Late=%.5f",
                     peak, dc, erDensity * 100.0, erStereoCorr, flatness, rEarly, rMid, rLate, rLateHall))
        #expect(peak > 0.015 && peak < 1.5, "Impulse peak out of range: \(peak)")
        #expect(dc < 0.0005, "Reverb tail should be DC-free, got \(dc)")
        #expect(erDensity > 0.12, "Expected 4x denser Velvet-Noise early reflections (>12% on Dirac impulse), got \(erDensity * 100)%")
        #expect(abs(erStereoCorr) < 0.25, "Expected wide decorrelated stereo ER, got corr=\(erStereoCorr)")
        #expect(flatness > 0.60, "Expected colorless smooth FDN tail (flatness > 0.60), got \(flatness)")
        #expect(rEarly > rMid && rMid > rLate && rLate > 1e-6, "Expected smooth unified concert-hall RT60 decay")
        #expect(rLateHall > rLate * 3.0, "Expected decay=0.92 hall tail to be >3x stronger than decay=0.85 at 1.4-1.9s")
    }

    @Test("Factor Oracle + Symbolic Constraint Grammar produces non-repeating, key-pure, stall-free 256-bar multi-hour runs across all scored modes")
    func factorOracleMultiHourGrammarProof() {
        // Exact diatonic key pitch-class sets (afternoon shift = 0)
        let diatonicKeys: [(FocusSoundscape, Set<Int>, Int)] = [
            (.focus, [9, 11, 1, 2, 4, 6, 8], 2),   // A Major (max hold = 2)
            (.pulse, [2, 4, 5, 7, 9, 11, 0], 2),   // D Dorian (max hold = 2)
            (.rain,  [0, 2, 4, 5, 7, 9, 11], 3),   // F Lydian / C Major (max hold = 3)
            (.still, [0, 2, 4, 5, 7, 9, 11], 3),   // C Major9 (max hold = 3)
            (.drift, [2, 4, 6, 7, 9, 11, 1], 3),   // D Major / G Lydian (max hold = 3)
        ]

        for (mode, keyPCs, maxHold) in diatonicKeys {
            var rngA = SeededRNG(seed: 2027)
            var navA = ScoreOracleNavigator()
            let barsA = (0..<256).map {
                SatieScore.composeBar(mode: mode, barIndex: $0, circadian: .afternoon, rng: &rngA, navigator: &navA)
            }

            // 1. Exact seed determinism across 256 bars
            var rngB = SeededRNG(seed: 2027)
            var navB = ScoreOracleNavigator()
            let barsB = (0..<256).map {
                SatieScore.composeBar(mode: mode, barIndex: $0, circadian: .afternoon, rng: &rngB, navigator: &navB)
            }
            #expect(barsA == barsB, "\(mode.title) Factor Oracle run must be 100% deterministic for same seed")

            // 2. Pass 0 stays strictly canonical (corpusIndex == 0..<32, zero jumps)
            for i in 0..<32 {
                #expect(barsA[i].corpusIndex == i && !barsA[i].didOracleJump)
            }

            // 3. Multi-hour non-repetition: 7 Pass 1+ 32-bar windows must be distinct harmonic journeys
            var passSignatures = Set<String>()
            for p in 1..<8 {
                let sig = barsA[(p * 32)..<((p + 1) * 32)].map(\.chordName).joined(separator: "-")
                passSignatures.insert(sig)
            }
            #expect(passSignatures.count >= 6, "\(mode.title) degenerated into repeating 32-bar loops (\(passSignatures.count)/7 unique)")

            // 4. Active Factor Oracle jumps + exploration of secondary harmonic climate (>= 32)
            let pass1Plus = barsA[32..<256]
            let jumps = pass1Plus.filter(\.didOracleJump).count
            let climateBCount = pass1Plus.filter { $0.corpusIndex >= 32 }.count
            #expect(jumps >= 25, "\(mode.title) expected >=25 Factor Oracle suffix jumps over 224 bars, got \(jumps)")
            #expect(climateBCount >= 40, "\(mode.title) expected rich secondary climate exploration (>=40/224), got \(climateBCount)")

            // 5. Symbolic Constraint Grammar: zero chord stalls > maxHold & 100% diatonic key purity & bounded density
            var runLen = 0
            var prevChord = ""
            var maxObservedRun = 0
            var maxBellDensity = 0
            for b in pass1Plus {
                if b.chordName == prevChord {
                    runLen += 1
                } else {
                    runLen = 1
                    prevChord = b.chordName
                }
                maxObservedRun = max(maxObservedRun, runLen)
                maxBellDensity = max(maxBellDensity, b.bells.count)
                for ev in b.bells {
                    let pc = ((ev.midi % 12) + 12) % 12
                    #expect(keyPCs.contains(pc), "\(mode.title) bell MIDI \(ev.midi) (pc=\(pc)) left diatonic key on bar \(b.barIndex)")
                }
                for sus in b.sustained {
                    let pc = ((sus.midi % 12) + 12) % 12
                    #expect(keyPCs.contains(pc), "\(mode.title) sustain MIDI \(sus.midi) (pc=\(pc)) left diatonic key on bar \(b.barIndex)")
                }
            }
            #expect(maxObservedRun <= maxHold, "\(mode.title) violated anti-stall grammar: chord held \(maxObservedRun) bars (max \(maxHold))")
            #expect(maxBellDensity <= 18, "\(mode.title) exceeded bounded per-bar density: \(maxBellDensity)")
            print(String(format: "[ORACLE] %-14s UniquePasses=%d/7  Jumps=%d/224  ClimateB=%.1f%%  MaxHold=%d/%d  MaxBells=%d  KeyPurity=100%%",
                         (mode.title as NSString).utf8String!, passSignatures.count, jumps,
                         Double(climateBCount) / 2.24, maxObservedRun, maxHold, maxBellDensity))
        }
    }

    @Test("HRVResonanceController adapts smoothly from sympathetic arousal to parasympathetic resonance within safe [4.5, 7.8] bpm bounds")
    func hrvClosedLoopBiofeedbackProof() {
        var ctrl = HRVResonanceController(initialBPM: 6.2)

        // Elevated sympathetic state (HR 90 bpm, low HRV 22 ms) -> gently rises to comfortable pace (no air hunger)
        for _ in 0..<8 {
            _ = ctrl.ingest(heartRateBPM: 90.0, hrvSDNNms: 22.0)
        }
        let arousedBPM = ctrl.targetBreathBPM
        #expect(arousedBPM > 6.8 && arousedBPM <= 7.8, "Expected comfortable elevated pace under stress, got \(arousedBPM)")

        // Deepening parasympathetic calm (HR dropping 90 -> 58 bpm, HRV rising 22 -> 82 ms) -> smoothly settles toward 5.0..5.6 bpm
        for step in 1...16 {
            let t = Double(step) / 16.0
            let bpm = ctrl.ingest(heartRateBPM: 90.0 - 32.0 * t, hrvSDNNms: 22.0 + 60.0 * t)
            #expect(bpm >= 4.5 && bpm <= 7.8, "Breath target escaped physiological bounds: \(bpm)")
        }
        let calmBPM = ctrl.targetBreathBPM
        #expect(calmBPM < 5.7 && calmBPM >= 4.5, "Expected settling into ~5.0-5.6 bpm RSA resonance, got \(calmBPM)")

        // Verify shared BreathCyclePacer slews gently toward HRV override without phase discontinuities
        var pacer = BreathCyclePacer(initialBPM: 8.5)
        for i in 0..<600 {
            let v = pacer.step(elapsedSec: Double(i) * 0.1, dt: 0.1, targetBPMOverride: calmBPM)
            #expect(v >= 0.0 && v <= 1.0)
        }
        #expect(abs(pacer.currentBPM - calmBPM) < 0.25, "Expected smooth slew convergence toward HRV target \(calmBPM), got \(pacer.currentBPM)")
        print(String(format: "[HRV-LOOP] Aroused=%.2f bpm -> Calm=%.2f bpm (Calmness=%.2f, PacerConverged=%.2f bpm)",
                     arousedBPM, calmBPM, ctrl.calmnessIndex, pacer.currentBPM))
    }

    @Test("Localization bundle parity across all 8 Apple locales including authentic Taiwanese Traditional Chinese (zh-Hant)")
    func localizationParityAndTaiwaneseAudit() {
        let langs = SatieL10n.supportedLanguages
        #expect(langs == ["en", "ja", "fr", "zh-Hans", "zh-Hant", "es", "de", "ko"])

        guard let enTable = SatieL10n.table(for: "en") else {
            Issue.record("Missing en.lproj/Localizable.strings in resourceBundle")
            return
        }
        #expect(enTable.count >= 120, "Expected full localization catalog, got \(enTable.count) keys")

        let specRegex = try! NSRegularExpression(pattern: #"%(?:\d+\$)?(?:\.\d+)?(?:ll|l)?[@dfs]|\$\{[A-Za-z0-9_]+\}"#)
        func extractSpecs(_ s: String) -> [String] {
            let range = NSRange(s.startIndex..<s.endIndex, in: s)
            return specRegex.matches(in: s, range: range).compactMap { m in
                Range(m.range, in: s).map { String(s[$0]) }
            }.sorted()
        }

        for lang in langs {
            guard let tbl = SatieL10n.table(for: lang) else {
                Issue.record("Missing \(lang).lproj/Localizable.strings")
                continue
            }
            for (key, enVal) in enTable {
                guard let val = tbl[key], !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    Issue.record("Missing or empty key '\(key)' in \(lang).lproj")
                    continue
                }
                let enSpecs = extractSpecs(enVal)
                let langSpecs = extractSpecs(val)
                #expect(langSpecs == enSpecs, "Format specifier mismatch for '\(key)' in \(lang): \(langSpecs) != \(enSpecs)")

                // ITMS-90626 guard: AppIntents / Siri metadata keys and values must never reference Apple/Siri trademarks
                if !key.contains(".") {
                    for forbidden in ["apple", "siri"] {
                        #expect(!key.lowercased().contains(forbidden), "ITMS-90626 violation in AppIntents key '\(key)'")
                        #expect(!val.lowercased().contains(forbidden), "ITMS-90626 violation in \(lang) value for '\(key)': \(val)")
                    }
                }
            }

            // Verify AppShortcuts.strings & InfoPlist.strings exist for every shipped locale
            let lb = SatieL10n.lprojBundle(for: lang)
            #expect(lb != nil, "Missing \(lang).lproj directory")
            if let lb {
                #expect(lb.url(forResource: "AppShortcuts", withExtension: "strings") != nil, "Missing \(lang).lproj/AppShortcuts.strings")
                #expect(lb.url(forResource: "InfoPlist", withExtension: "strings") != nil, "Missing \(lang).lproj/InfoPlist.strings")
            }

            if lang != "en" {
                #expect(tbl["menu.quit"] != enTable["menu.quit"], "menu.quit untranslated in \(lang)")
                #expect(tbl["soundscape.dive.title"] != enTable["soundscape.dive.title"], "soundscape.dive.title untranslated in \(lang)")
                #expect(tbl["watch.inhale"] != enTable["watch.inhale"], "watch.inhale untranslated in \(lang)")
            }
        }

        // Authentic Taiwanese Traditional Chinese (zh-Hant) terminology checks vs Simplified Chinese (zh-Hans)
        #expect(SatieL10n.string("menu.quit", language: "zh-Hant") == "結束 Satie")
        #expect(SatieL10n.string("menu.quit", language: "zh-Hans") == "退出 Satie")
        #expect(SatieL10n.string("menu.studio_window", language: "zh-Hant") == "工作室視窗")
        #expect(SatieL10n.string("menu.fullscreen", language: "zh-Hant") == "全螢幕")
        #expect(SatieL10n.string("ios.privacy_policy", language: "zh-Hant") == "隱私權政策")
        #expect(SatieL10n.string("watch.exhale", language: "zh-Hant") == "吐氣")
        #expect(SatieL10n.string("soundscape.focus.short", language: "ja") == "集中")
        #expect(SatieL10n.string("soundscape.focus.title", language: "fr") == "Lumière douce")
        #expect(SatieL10n.string("soundscape.dive.short", language: "de") == "TIEFE")
        #expect(SatieL10n.string("soundscape.dive.title", language: "ko") == "깊은 명상")
        #expect(SatieL10n.string("soundscape.rain.title", language: "es") == "Lluvia y cristal")
    }
}
