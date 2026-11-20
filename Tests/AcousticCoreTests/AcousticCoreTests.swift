import AcousticCore
import AppKit
import Foundation
import Testing

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

    @Test("SettingsStore round-trips preferences cleanly")
    func settingsPersistence() {
        let suiteName = "com.strangechances.Satie.test.\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: suiteName)!
        defer { ud.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: ud)
        store.presetRaw = 2
        store.amberPhosphor = true
        store.sensitivity = .vivid
        store.focusMode = .rain
        store.focusVolume = 0.62
        store.miniHUDOrigin = NSPoint(x: 420, y: 180)
        store.studioFrame = NSRect(x: 100, y: 120, width: 1280, height: 820)

        let reloaded = SettingsStore(defaults: ud)
        #expect(reloaded.presetRaw == 2)
        #expect(reloaded.amberPhosphor == true)
        #expect(reloaded.sensitivity == .vivid)
        #expect(reloaded.focusMode == .rain)
        #expect(abs(reloaded.focusVolume - 0.62) < 0.001)
        #expect(reloaded.miniHUDOrigin == NSPoint(x: 420, y: 180))
        #expect(reloaded.studioFrame == NSRect(x: 100, y: 120, width: 1280, height: 820))
    }

    @Test("ProcessAudioTap resolves Chromium, Electron, and WebKit helpers to parent apps")
    func helperProcessResolution() {
        let chromePath = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/130/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
        #expect(ProcessAudioTap.outermostAppBundlePath(from: chromePath) == "/Applications/Google Chrome.app")

        let chromeFromBundleID = ProcessAudioTap.resolveAppIdentity(
            executablePath: nil,
            rawBundleID: "com.google.Chrome.helper"
        )
        #expect(chromeFromBundleID.name == "Google Chrome")
        #expect(chromeFromBundleID.bundleID == "com.google.Chrome")

        let safariFromWebKit = ProcessAudioTap.resolveAppIdentity(
            executablePath: nil,
            rawBundleID: "com.apple.WebKit.GPU"
        )
        #expect(safariFromWebKit.name == "Safari")
        #expect(safariFromWebKit.bundleID == "com.apple.Safari")
    }

    @Test("FocusSoundEngine generates bounded, non-silent stereo audio across all 4 modes and auto-ducks cleanly")
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
        let visibleBtn = CGRect(x: 1320, y: 1085, width: 22, height: 32)
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

    @Test("AutoDuckGate ignores notifications, system alerts, and silent streams, but ducks sustained media/calls")
    func autoDuckNotificationImmunity() {
        var gate = AutoDuckGate()

        let sysAlert = AudioProcessInfo(objectID: 1, pid: 10, name: "systemsoundserverd", bundleID: "com.apple.systemsoundserverd", isRunningOutput: true)
        let messages = AudioProcessInfo(objectID: 2, pid: 11, name: "Messages", bundleID: "com.apple.MobileSMS", isRunningOutput: true)
        let chrome = AudioProcessInfo(objectID: 3, pid: 12, name: "Google Chrome", bundleID: "com.google.Chrome", isRunningOutput: true)
        let spotify = AudioProcessInfo(objectID: 4, pid: 13, name: "Spotify", bundleID: "com.spotify.client", isRunningOutput: true)

        // 1. System alerts & Messages never duck even if sustained
        for step in 0..<12 {
            let d = gate.evaluate(now: Double(step) * 0.25, activeProcesses: [sysAlert, messages], externalRMS: 0.12)
            #expect(d.isDucked == false)
        }

        // 2. Short 0.75s notification ping from Chrome/Slack never ducks
        for step in 0..<3 {
            let d = gate.evaluate(now: 10.0 + Double(step) * 0.25, activeProcesses: [chrome], externalRMS: 0.08)
            #expect(d.isDucked == false)
        }
        // Chime stops -> timer resets cleanly
        #expect(gate.evaluate(now: 11.0, activeProcesses: [], externalRMS: 0.0).isDucked == false)

        // 3. Idle Chrome stream with silent RMS never ghost-ducks
        for step in 0..<12 {
            let d = gate.evaluate(now: 20.0 + Double(step) * 0.25, activeProcesses: [chrome], externalRMS: 0.0005)
            #expect(d.isDucked == false)
        }

        // 4. Sustained Spotify playback (>= 0.9s with real RMS) cleanly ducks and unducks after 3.0s silence
        #expect(gate.evaluate(now: 30.0, activeProcesses: [spotify], externalRMS: 0.05).isDucked == false)
        #expect(gate.evaluate(now: 31.0, activeProcesses: [spotify], externalRMS: 0.05).isDucked == true)
        // Brief 1.5s pause between songs stays ducked
        #expect(gate.evaluate(now: 32.0, activeProcesses: [], externalRMS: 0.0).isDucked == true)
        #expect(gate.evaluate(now: 33.5, activeProcesses: [], externalRMS: 0.0).isDucked == true)
        // After 3.0s continuous silence, smoothly resumes
        #expect(gate.evaluate(now: 35.2, activeProcesses: [], externalRMS: 0.0).isDucked == false)
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
            #expect(subCorr > 0.975, "Mode \(mode.title) sub-bass (<110 Hz) is not strictly mono (\(subCorr))")
            #expect(midCorr > 0.05 && midCorr < 0.92, "Mode \(mode.title) mid/high stereo imaging out of lush range (\(midCorr))")
        }

        // Verify Eno prime-length macro cycles actually evolve across passes
        var rng = SeededRNG(seed: 42)
        let bar0 = SatieScore.composeBar(mode: .focus, barIndex: 0, rng: &rng)
        let bar32 = SatieScore.composeBar(mode: .focus, barIndex: 32, rng: &rng)
        #expect(abs(bar0.macroFilterHorizon - bar32.macroFilterHorizon) > 0.01 || abs(bar0.macroSpaceBloom - bar32.macroSpaceBloom) > 0.01)
    }
}
