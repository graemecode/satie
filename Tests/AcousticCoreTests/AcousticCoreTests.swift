import AcousticCore
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
}
