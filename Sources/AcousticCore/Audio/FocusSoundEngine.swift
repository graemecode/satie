import AVFoundation
import Foundation
import Synchronization

public enum FocusSoundscape: String, CaseIterable, Identifiable, Sendable {
    case focus
    case pulse
    case rain
    case drift

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .focus: return "Deep Focus"
        case .pulse: return "Flow Pulse"
        case .rain: return "Velvet Rain"
        case .drift: return "Night Drift"
        }
    }

    public var shortLabel: String {
        switch self {
        case .focus: return "FOCUS"
        case .pulse: return "PULSE"
        case .rain: return "RAIN"
        case .drift: return "DRIFT"
        }
    }
}

public enum CircadianPhase: Int, Sendable {
    case morning = 0    // 06:00 - 11:59 (open, luminous Lydian / Maj9)
    case afternoon = 1  // 12:00 - 19:59 (grounded Dorian / Min9 drive)
    case night = 2      // 20:00 - 05:59 (deep, warm low-passed dark ambient)

    public static func current(date: Date = Date()) -> CircadianPhase {
        let hour = Calendar.current.component(.hour, from: date)
        if hour >= 6 && hour < 12 { return .morning }
        if hour >= 12 && hour < 20 { return .afternoon }
        return .night
    }

    public var label: String {
        switch self {
        case .morning: return "MORNING"
        case .afternoon: return "DAY"
        case .night: return "NIGHT"
        }
    }
}

/// Studio-grade procedural ambient focus synthesizer (AVAudioEngine + lock-free AVAudioSourceNode).
/// Features 4×4 Hadamard FDN reverb, circadian harmonic voicing, modal felt-bell synthesis,
/// Brain.fm-style subtle 14 Hz focus modulation, ear-fatigue air roll-off, and smooth auto-ducking.
public final class FocusSoundEngine: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let ringBuffer: StereoRingBuffer

    private let renderState = FocusRenderState()
    private let lifecycleLock = NSLock()
    private var isEngineRunning = false

    public var isPlaying: Bool {
        renderState.isActiveAtom.load(ordering: .acquiring) != 0
    }

    public var isDucked: Bool {
        renderState.isDuckedAtom.load(ordering: .acquiring) != 0
    }

    public var currentMode: FocusSoundscape {
        let raw = renderState.modeAtom.load(ordering: .acquiring)
        return FocusSoundscape.allCases[max(0, min(FocusSoundscape.allCases.count - 1, raw))]
    }

    public var volume: Float {
        Float(bitPattern: renderState.volumeBitsAtom.load(ordering: .acquiring))
    }

    public init(ringBuffer: StereoRingBuffer) {
        self.ringBuffer = ringBuffer
        renderState.circadianAtom.store(CircadianPhase.current().rawValue, ordering: .releasing)
    }

    deinit {
        stopImmediately()
    }

    public func setVolume(_ value: Float) {
        let clamped = max(0.0, min(1.0, value))
        renderState.volumeBitsAtom.store(clamped.bitPattern, ordering: .releasing)
    }

    public func setMode(_ mode: FocusSoundscape) {
        if let idx = FocusSoundscape.allCases.firstIndex(of: mode) {
            renderState.modeAtom.store(idx, ordering: .releasing)
        }
    }

    public func setCircadianPhase(_ phase: CircadianPhase) {
        renderState.circadianAtom.store(phase.rawValue, ordering: .releasing)
    }

    /// Smoothly fades out soundscape (~450ms) when external apps (Zoom, Spotify, Chrome) produce audio.
    public func setDucked(_ ducked: Bool) {
        renderState.isDuckedAtom.store(ducked ? 1 : 0, ordering: .releasing)
    }

    /// Triggers a single gentle resolving fifth bell when a Flow Session finishes.
    public func triggerSessionChime() {
        renderState.chimeTriggerAtom.store(1, ordering: .releasing)
    }

    public func start(mode: FocusSoundscape? = nil) {
        if let mode { setMode(mode) }
        setCircadianPhase(.current())
        setDucked(false)

        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        ensureEngineConfiguredLocked()
        if !isEngineRunning {
            do {
                try engine.start()
                isEngineRunning = true
                Log.audio.info("FocusSoundEngine started (mode=\(self.currentMode.rawValue, privacy: .public), circadian=\(CircadianPhase.current().label, privacy: .public))")
            } catch {
                Log.audio.error("FocusSoundEngine failed to start: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        renderState.isActiveAtom.store(1, ordering: .releasing)
    }

    public func stop() {
        renderState.isActiveAtom.store(0, ordering: .releasing)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self else { return }
            self.lifecycleLock.lock()
            defer { self.lifecycleLock.unlock() }
            if self.renderState.isActiveAtom.load(ordering: .acquiring) == 0, self.isEngineRunning {
                self.engine.pause()
                self.isEngineRunning = false
                Log.audio.info("FocusSoundEngine paused after smooth fade-out")
            }
        }
    }

    public func stopImmediately() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        renderState.isActiveAtom.store(0, ordering: .releasing)
        if isEngineRunning {
            engine.stop()
            isEngineRunning = false
        }
    }

    /// Offline deterministic block render for unit testing DSP stability, zero NaNs, and auto-ducking.
    public static func renderOfflineTestBlock(
        mode: FocusSoundscape,
        circadian: CircadianPhase = .afternoon,
        frames: Int = 4096,
        sampleRate: Double = 48_000,
        ducked: Bool = false
    ) -> (left: [Float], right: [Float]) {
        let state = FocusRenderState()
        state.configure(sampleRate: sampleRate)
        state.isActiveAtom.store(1, ordering: .releasing)
        state.modeAtom.store(FocusSoundscape.allCases.firstIndex(of: mode) ?? 0, ordering: .releasing)
        state.circadianAtom.store(circadian.rawValue, ordering: .releasing)
        state.isDuckedAtom.store(ducked ? 1 : 0, ordering: .releasing)
        state.volumeBitsAtom.store(Float(0.6).bitPattern, ordering: .releasing)

        var outL = [Float](repeating: 0, count: frames)
        var outR = [Float](repeating: 0, count: frames)
        outL.withUnsafeMutableBufferPointer { lPtr in
            outR.withUnsafeMutableBufferPointer { rPtr in
                // Warm up 12000 samples (~250ms) so fade envelope settles
                var warmL = [Float](repeating: 0, count: 1024)
                var warmR = [Float](repeating: 0, count: 1024)
                warmL.withUnsafeMutableBufferPointer { wl in
                    warmR.withUnsafeMutableBufferPointer { wr in
                        for _ in 0..<12 {
                            state.render(outL: wl.baseAddress!, outR: wr.baseAddress!, frames: 1024)
                        }
                    }
                }
                state.render(outL: lPtr.baseAddress!, outR: rPtr.baseAddress!, frames: frames)
            }
        }
        return (outL, outR)
    }

    private func ensureEngineConfiguredLocked() {
        guard sourceNode == nil else { return }
        let outFormat = engine.outputNode.outputFormat(forBus: 0)
        let sr = outFormat.sampleRate > 0 ? outFormat.sampleRate : 48_000.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2) else { return }

        renderState.configure(sampleRate: sr)

        let state = renderState
        let rb = ringBuffer

        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard abl.count >= 2,
                  let outL = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let outR = abl[1].mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }

            let frames = Int(frameCount)
            state.render(outL: outL, outR: outR, frames: frames)

            // Feed dedicated Focus ring buffer only while un-ducked & audible
            if state.masterEnv * state.duckEnv > 0.002 {
                rb.writePlanar(leftSrc: outL, rightSrc: outR, frameCount: frames)
            }
            return noErr
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        sourceNode = node
    }
}

// MARK: - Lock-Free Real-Time Psychoacoustic Synthesis State (4x4 Hadamard FDN Reverb)

private final class FocusRenderState: @unchecked Sendable {
    let isActiveAtom = Atomic<Int>(0)
    let isDuckedAtom = Atomic<Int>(0)
    let modeAtom = Atomic<Int>(0)
    let circadianAtom = Atomic<Int>(1)
    let volumeBitsAtom = Atomic<UInt32>(Float(0.48).bitPattern)
    let chimeTriggerAtom = Atomic<Int>(0)

    var sr: Double = 48_000.0
    var invSR: Double = 1.0 / 48_000.0
    var time: Double = 0
    var masterEnv: Float = 0
    var duckEnv: Float = 1

    // Smooth mode crossfade weights [focus, pulse, rain, drift]
    var wFocus: Float = 1
    var wPulse: Float = 0
    var wRain: Float = 0
    var wDrift: Float = 0

    // 5 stereo pad oscillators + sub pulse
    var padPhasesL: [Double] = [0, 0, 0, 0, 0]
    var padPhasesR: [Double] = [0, 0, 0, 0, 0]
    var pulsePhase: Double = 0

    // 5 modal felt-bell voices (fundamental + warm 2nd harmonic partial)
    var bellPhases: [Double] = [0, 0, 0, 0, 0]
    var bellFreqs: [Double] = [293.66, 440.0, 523.25, 659.25, 783.99]
    var bellEnvs: [Float] = [0, 0, 0, 0, 0]
    var bellTimers: [Double] = [0.5, 2.2, 4.6, 7.1, 10.4]
    var bellPans: [Float] = [-0.48, 0.36, -0.24, 0.52, -0.10]

    // Completion chime voice (warm open fifth)
    var chimeEnv: Float = 0
    var chimePhase1: Double = 0
    var chimePhase2: Double = 0

    // Paul Kellet 7-pole stereo pink noise + warm brownian sub + 2-pole low-pass ear-fatigue filters
    var pbL: [Float] = [0, 0, 0, 0, 0, 0, 0]
    var pbR: [Float] = [0, 0, 0, 0, 0, 0, 0]
    var brownL: Float = 0
    var brownR: Float = 0
    var lpPad1L: Float = 0, lpPad2L: Float = 0
    var lpPad1R: Float = 0, lpPad2R: Float = 0
    var rainLp1L: Float = 0, rainLp2L: Float = 0
    var rainLp1R: Float = 0, rainLp2R: Float = 0
    var outAirLpL: Float = 0, outAirLpR: Float = 0

    // Soft resonant raindrop
    var dropPhase: Double = 0
    var dropEnv: Float = 0
    var dropFreq: Double = 1200
    var dropPan: Float = 0

    // Fast RT-safe XorShift64 PRNG
    var rng: UInt64 = 0x9e3779b97f4a7c15

    // 4x4 Hadamard Feedback Delay Network (FDN) reverb (mutually prime delay lengths)
    var fdnLens: [Int] = [6577, 8689, 10993, 13591]
    var fdnBufs: [UnsafeMutablePointer<Float>?] = [nil, nil, nil, nil]
    var fdnIdxs: [Int] = [0, 0, 0, 0]
    var fdnDamp: [Float] = [0, 0, 0, 0]

    // Circadian harmonic progressions (Morning = open F Lydian/Maj9, Afternoon = D Dorian, Night = dark C Min9)
    let morningChords: [[Double]] = [
        [87.31, 130.81, 174.61, 220.00, 329.63], // Fmaj7
        [98.00, 146.83, 196.00, 246.94, 329.63], // G6
        [65.41, 130.81, 196.00, 246.94, 293.66], // Cmaj9
        [110.00, 164.81, 196.00, 246.94, 329.63] // Am9
    ]
    let afternoonChords: [[Double]] = [
        [73.42, 110.00, 146.83, 220.00, 329.63], // D5/9
        [65.41, 98.00,  146.83, 196.00, 293.66], // Cadd9
        [87.31, 130.81, 164.81, 220.00, 329.63], // Fmaj7
        [110.00, 146.83, 164.81, 246.94, 329.63] // Asus4/9
    ]
    let nightChords: [[Double]] = [
        [65.41, 98.00,  130.81, 155.56, 233.08], // Cm7
        [51.91, 103.83, 130.81, 155.56, 233.08], // Abmaj9
        [58.27, 116.54, 146.83, 174.61, 261.63], // Bbadd9
        [87.31, 130.81, 155.56, 196.00, 261.63]  // Fm9
    ]

    let morningScale: [Double]   = [261.63, 293.66, 329.63, 392.00, 440.00, 523.25, 587.33, 659.25]
    let afternoonScale: [Double] = [293.66, 329.63, 349.23, 440.00, 493.88, 523.25, 587.33, 659.25]
    let nightScale: [Double]     = [196.00, 233.08, 261.63, 293.66, 311.13, 392.00, 466.16, 523.25]

    deinit {
        for ptr in fdnBufs { ptr?.deallocate() }
    }

    func configure(sampleRate: Double) {
        sr = sampleRate
        invSR = 1.0 / sampleRate
        let scale = sampleRate / 48_000.0
        let basePrimes = [6577, 8689, 10993, 13591]
        for k in 0..<4 {
            fdnBufs[k]?.deallocate()
            let len = max(512, Int(Double(basePrimes[k]) * scale))
            fdnLens[k] = len
            let ptr = UnsafeMutablePointer<Float>.allocate(capacity: len)
            ptr.initialize(repeating: 0, count: len)
            fdnBufs[k] = ptr
            fdnIdxs[k] = 0
            fdnDamp[k] = 0
        }
    }

    @inline(__always)
    private func nextWhite() -> Float {
        rng ^= rng >> 12
        rng ^= rng << 25
        rng ^= rng >> 27
        let v = (rng &* 0x2545F4914F6CDD1D) >> 40
        return Float(v) * (2.0 / 16777216.0) - 1.0
    }

    func render(outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>, frames: Int) {
        guard let b0 = fdnBufs[0], let b1 = fdnBufs[1], let b2 = fdnBufs[2], let b3 = fdnBufs[3] else {
            outL.update(repeating: 0, count: frames)
            outR.update(repeating: 0, count: frames)
            return
        }

        let active = isActiveAtom.load(ordering: .relaxed) != 0
        let ducked = isDuckedAtom.load(ordering: .relaxed) != 0
        let modeIdx = modeAtom.load(ordering: .relaxed)
        let circIdx = circadianAtom.load(ordering: .relaxed)
        let targetVol = Float(bitPattern: volumeBitsAtom.load(ordering: .relaxed))

        if chimeTriggerAtom.exchange(0, ordering: .acquiring) != 0 {
            chimeEnv = 1.0
            chimePhase1 = 0
            chimePhase2 = 0
        }

        let targetMaster: Float = active ? targetVol : 0.0
        let targetDuck: Float = ducked ? 0.0 : 1.0
        let tFocus: Float = modeIdx == 0 ? 1.0 : 0.0
        let tPulse: Float = modeIdx == 1 ? 1.0 : 0.0
        let tRain: Float  = modeIdx == 2 ? 1.0 : 0.0
        let tDrift: Float = modeIdx == 3 ? 1.0 : 0.0

        let envStep = Float(invSR * 3.8)
        let duckStep = Float(invSR * (ducked ? 6.5 : 1.6)) // Fast calm duck-down, gentle bloom back up
        let twoPi = Double.pi * 2.0

        let chords = circIdx == 0 ? morningChords : (circIdx == 2 ? nightChords : afternoonChords)
        let scale = circIdx == 0 ? morningScale : (circIdx == 2 ? nightScale : afternoonScale)
        let circadianCutoffBias: Float = circIdx == 0 ? 0.025 : (circIdx == 2 ? -0.022 : 0.0)

        let len0 = fdnLens[0], len1 = fdnLens[1], len2 = fdnLens[2], len3 = fdnLens[3]
        var idx0 = fdnIdxs[0], idx1 = fdnIdxs[1], idx2 = fdnIdxs[2], idx3 = fdnIdxs[3]

        for i in 0..<frames {
            time += invSR

            masterEnv += (targetMaster - masterEnv) * envStep
            duckEnv += (targetDuck - duckEnv) * duckStep
            wFocus += (tFocus - wFocus) * envStep
            wPulse += (tPulse - wPulse) * envStep
            wRain  += (tRain  - wRain)  * envStep
            wDrift += (tDrift - wDrift) * envStep

            let totalGain = masterEnv * duckEnv
            if totalGain < 0.00002 && chimeEnv < 0.0005 && !active {
                outL[i] = 0
                outR[i] = 0
                continue
            }

            // --- 1. Slow Circadian Chord Pad (20s harmonic cycles) ---
            let chordPos = (time / 20.0).truncatingRemainder(dividingBy: Double(chords.count))
            let cA = Int(chordPos) % chords.count
            let cB = (cA + 1) % chords.count
            let cFrac = chordPos - floor(chordPos)
            let bl = max(0.0, min(1.0, (cFrac - 0.60) / 0.40))
            let sBlend = bl * bl * (3.0 - 2.0 * bl)

            var padL: Float = 0
            var padR: Float = 0
            let needPad = (wFocus + wPulse + wDrift) > 0.001
            if needPad {
                let chA = chords[cA]
                let chB = chords[cB]
                let breath = Float(0.76 + 0.24 * sin(time * 0.21))
                // Subtle Brain.fm-style 14Hz neural focus amplitude modulation in PULSE mode
                let betaMod: Float = 1.0 - wPulse * 0.14 * Float(0.5 + 0.5 * sin(time * twoPi * 14.0))

                for v in 0..<5 {
                    let f = chA[v] + (chB[v] - chA[v]) * sBlend
                    let det = 0.24 + Double(v) * 0.08
                    padPhasesL[v] += (f + det) * invSR
                    if padPhasesL[v] >= 1.0 { padPhasesL[v] -= 1.0 }
                    padPhasesR[v] += (f - det) * invSR
                    if padPhasesR[v] >= 1.0 { padPhasesR[v] -= 1.0 }

                    // Warm triangle-blended sine (richer, less fatiguing than pure clinical sine)
                    let sL = sin(padPhasesL[v] * twoPi) + 0.14 * sin(padPhasesL[v] * twoPi * 2.0) + 0.05 * sin(padPhasesL[v] * twoPi * 3.0)
                    let sR = sin(padPhasesR[v] * twoPi) + 0.14 * sin(padPhasesR[v] * twoPi * 2.0) + 0.05 * sin(padPhasesR[v] * twoPi * 3.0)
                    let w: Float = v == 0 ? 0.26 : (v < 3 ? 0.19 : 0.11)
                    padL += Float(sL) * w * breath * betaMod
                    padR += Float(sR) * w * breath * betaMod
                }

                // 2-pole warm breathing low-pass filter (12 dB/oct silk smoothness)
                let cut = max(0.025, min(0.16, Float(0.055 + 0.045 * (0.5 + 0.5 * sin(time * 0.13))) + circadianCutoffBias))
                lpPad1L += (padL - lpPad1L) * cut
                lpPad2L += (lpPad1L - lpPad2L) * cut
                lpPad1R += (padR - lpPad1R) * cut
                lpPad2R += (lpPad1R - lpPad2R) * cut
            }

            // --- 2. Muted Motoric Sub-Pulse (PULSE mode — steady 112 BPM focus cadence) ---
            var pulseSig: Float = 0
            if wPulse > 0.001 {
                let beatPhase = (time * 112.0 / 60.0).truncatingRemainder(dividingBy: 1.0)
                let subEnv = Float(pow(max(0.0, 1.0 - beatPhase * 2.6), 2.4))
                let rootF = chords[cA][0]
                pulsePhase += rootF * invSR
                if pulsePhase >= 1.0 { pulsePhase -= 1.0 }
                // Soft rounded low throb (never clicky or clubby)
                let attack = Float(min(1.0, beatPhase * 28.0))
                pulseSig = Float(sin(pulsePhase * twoPi)) * subEnv * attack * 0.42
            }

            // --- 3. Felt-Piano / Modal Glass Voices (5 independent prime-ratio cycles) ---
            var bellL: Float = 0
            var bellR: Float = 0
            if (wFocus + wPulse + wDrift) > 0.001 {
                let cycles: [Double] = [6.1, 9.7, 13.1, 17.3, 23.9]
                let tempoScale: Double = wPulse > 0.5 ? 0.48 : (wDrift > 0.5 ? 1.15 : 0.88)
                for b in 0..<5 {
                    bellTimers[b] -= invSR
                    if bellTimers[b] <= 0 {
                        bellTimers[b] = cycles[b] * tempoScale * (0.78 + Double(abs(nextWhite())) * 0.45)
                        let idx = Int(abs(nextWhite()) * Float(scale.count)) % scale.count
                        bellFreqs[b] = scale[idx] * (wDrift > 0.5 && b == 4 ? 2.0 : 1.0)
                        bellEnvs[b] = 1.0
                        bellPans[b] = nextWhite() * 0.62
                    }
                    if bellEnvs[b] > 0.0004 {
                        bellPhases[b] += bellFreqs[b] * invSR
                        if bellPhases[b] >= 1.0 { bellPhases[b] -= 1.0 }
                        let e = bellEnvs[b]
                        // Soft felt-hammer attack + warm resonant decay + decaying 2nd harmonic partial
                        let feltAttack = (1.0 - e * e * e * e)
                        let amp = e * e * feltAttack * 0.24
                        let tone = Float(sin(bellPhases[b] * twoPi) + Double(e) * 0.22 * sin(bellPhases[b] * twoPi * 2.0)) * amp
                        bellL += tone * 0.5 * (1.0 - bellPans[b])
                        bellR += tone * 0.5 * (1.0 + bellPans[b])
                        bellEnvs[b] *= Float(1.0 - invSR * (wPulse > 0.5 ? 0.68 : 0.30))
                    }
                }
            }

            // --- 4. Velvet Stereo Pink/Brown Rain (Paul Kellet + 2-pole warm smoothing) ---
            var rainL: Float = 0
            var rainR: Float = 0
            if (wRain + wFocus + wPulse) > 0.001 {
                let wL = nextWhite()
                let wR = nextWhite()

                pbL[0] = 0.99886 * pbL[0] + wL * 0.0555179
                pbL[1] = 0.99332 * pbL[1] + wL * 0.0750759
                pbL[2] = 0.96900 * pbL[2] + wL * 0.1538520
                pbL[3] = 0.86650 * pbL[3] + wL * 0.3104856
                pbL[4] = 0.55000 * pbL[4] + wL * 0.5329522
                pbL[5] = -0.7616 * pbL[5] - wL * 0.0168980
                let pinkL = (pbL[0] + pbL[1] + pbL[2] + pbL[3] + pbL[4] + pbL[5] + pbL[6] + wL * 0.5362) * 0.042
                pbL[6] = wL * 0.115926

                pbR[0] = 0.99886 * pbR[0] + wR * 0.0555179
                pbR[1] = 0.99332 * pbR[1] + wR * 0.0750759
                pbR[2] = 0.96900 * pbR[2] + wR * 0.1538520
                pbR[3] = 0.86650 * pbR[3] + wR * 0.3104856
                pbR[4] = 0.55000 * pbR[4] + wR * 0.5329522
                pbR[5] = -0.7616 * pbR[5] - wR * 0.0168980
                let pinkR = (pbR[0] + pbR[1] + pbR[2] + pbR[3] + pbR[4] + pbR[5] + pbR[6] + wR * 0.5362) * 0.042
                pbR[6] = wR * 0.115926

                brownL = (brownL + wL * 0.018) * 0.994
                brownR = (brownR + wR * 0.018) * 0.994

                let swL = Float(0.78 + 0.22 * sin(time * 0.19))
                let swR = Float(0.78 + 0.22 * cos(time * 0.15 + 0.9))

                rainLp1L += ((pinkL * 0.62 + brownL * 0.98) * swL - rainLp1L) * 0.20
                rainLp2L += (rainLp1L - rainLp2L) * 0.26
                rainLp1R += ((pinkR * 0.62 + brownR * 0.98) * swR - rainLp1R) * 0.20
                rainLp2R += (rainLp1R - rainLp2R) * 0.26

                if wRain > 0.05 {
                    if dropEnv < 0.002 && nextWhite() > 0.99955 {
                        dropEnv = 0.12
                        dropFreq = 820.0 + Double(abs(nextWhite())) * 1100.0
                        dropPan = nextWhite() * 0.78
                    }
                    if dropEnv > 0.0005 {
                        dropPhase += dropFreq * invSR
                        if dropPhase >= 1.0 { dropPhase -= 1.0 }
                        let dSig = Float(sin(dropPhase * twoPi)) * dropEnv
                        rainL += dSig * 0.5 * (1.0 - dropPan)
                        rainR += dSig * 0.5 * (1.0 + dropPan)
                        dropEnv *= Float(1.0 - invSR * 20.0)
                    }
                }
                rainL += rainLp2L * 1.25
                rainR += rainLp2R * 1.25
            }

            // --- 5. Mix active modes ---
            let fL = lpPad2L * 0.96 + bellL * 0.62 + rainLp2L * 0.14
            let fR = lpPad2R * 0.96 + bellR * 0.62 + rainLp2R * 0.14

            let pL = lpPad2L * 0.72 + pulseSig + bellL * 0.75 + rainLp2L * 0.16
            let pR = lpPad2R * 0.72 + pulseSig + bellR * 0.75 + rainLp2R * 0.16

            let rL = rainL * 1.08 + lpPad2L * 0.15
            let rR = rainR * 1.08 + lpPad2R * 0.15

            let dL = lpPad2L * 0.55 + bellL * 1.25
            let dR = lpPad2R * 0.55 + bellR * 1.25

            var dryL = fL * wFocus + pL * wPulse + rL * wRain + dL * wDrift
            var dryR = fR * wFocus + pR * wPulse + rR * wRain + dR * wDrift

            // Optional warm completion chime (open fifth A4 + E5)
            var chimeSig: Float = 0
            if chimeEnv > 0.0004 {
                chimePhase1 += 440.0 * invSR
                chimePhase2 += 659.25 * invSR
                if chimePhase1 >= 1.0 { chimePhase1 -= 1.0 }
                if chimePhase2 >= 1.0 { chimePhase2 -= 1.0 }
                let ce = chimeEnv * chimeEnv * (1.0 - chimeEnv * chimeEnv * chimeEnv) * 1.6
                chimeSig = Float(sin(chimePhase1 * twoPi) + 0.65 * sin(chimePhase2 * twoPi)) * ce * 0.24
                chimeEnv *= Float(1.0 - invSR * 0.26)
                dryL += chimeSig
                dryR += chimeSig
            }

            // --- 6. True 4x4 Hadamard FDN Reverb (zero metallic ringing, velvet studio hall) ---
            let t0 = b0[idx0], t1 = b1[idx1], t2 = b2[idx2], t3 = b3[idx3]
            // Per-line high-frequency air damping
            fdnDamp[0] += (t0 - fdnDamp[0]) * 0.22
            fdnDamp[1] += (t1 - fdnDamp[1]) * 0.20
            fdnDamp[2] += (t2 - fdnDamp[2]) * 0.18
            fdnDamp[3] += (t3 - fdnDamp[3]) * 0.16

            let y0 = fdnDamp[0], y1 = fdnDamp[1], y2 = fdnDamp[2], y3 = fdnDamp[3]
            // Unitary 4x4 Hadamard feedback matrix (scale 0.5 * fbGain)
            let fb: Float = 0.5 * (0.76 + wDrift * 0.08 - wRain * 0.16)
            let h0 = (y0 + y1 + y2 + y3) * fb
            let h1 = (y0 - y1 + y2 - y3) * fb
            let h2 = (y0 + y1 - y2 - y3) * fb
            let h3 = (y0 - y1 - y2 + y3) * fb

            b0[idx0] = h0 + dryL * 0.45
            b1[idx1] = h1 + dryR * 0.45
            b2[idx2] = h2 + dryL * 0.35
            b3[idx3] = h3 + dryR * 0.35

            idx0 += 1; if idx0 >= len0 { idx0 = 0 }
            idx1 += 1; if idx1 >= len1 { idx1 = 0 }
            idx2 += 1; if idx2 >= len2 { idx2 = 0 }
            idx3 += 1; if idx3 >= len3 { idx3 = 0 }

            let wetL = (y0 + y2) * 0.55
            let wetR = (y1 + y3) * 0.55
            let wetAmt = wFocus * 0.44 + wPulse * 0.34 + wRain * 0.18 + wDrift * 0.58

            // Gentle ~6kHz ear-fatigue air roll-off + analog soft saturation
            let mixedL = (dryL + wetL * wetAmt) * totalGain + chimeSig * 0.35
            let mixedR = (dryR + wetR * wetAmt) * totalGain + chimeSig * 0.35
            outAirLpL += (mixedL - outAirLpL) * 0.52
            outAirLpR += (mixedR - outAirLpR) * 0.52

            outL[i] = tanh(outAirLpL * 1.12)
            outR[i] = tanh(outAirLpR * 1.12)
        }

        fdnIdxs[0] = idx0; fdnIdxs[1] = idx1; fdnIdxs[2] = idx2; fdnIdxs[3] = idx3
    }
}
