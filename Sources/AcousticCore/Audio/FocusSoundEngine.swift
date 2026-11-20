import AVFoundation
import Foundation
import Synchronization

public enum FocusSoundscape: String, CaseIterable, Identifiable, Sendable {
    case focus
    case rain
    case drift

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .focus: return "Deep Focus"
        case .rain: return "Pink Rain"
        case .drift: return "Night Drift"
        }
    }

    public var shortLabel: String {
        switch self {
        case .focus: return "FOCUS"
        case .rain: return "RAIN"
        case .drift: return "DRIFT"
        }
    }
}

/// Real-time procedural ambient soundscape synthesizer (AVAudioEngine + lock-free AVAudioSourceNode).
/// Generates zero-sample, offline Endel/Eno-style generative work soundscapes and feeds StereoRingBuffer directly.
public final class FocusSoundEngine: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let ringBuffer: StereoRingBuffer

    // Lock-free atomic parameters live inside the reference-type RenderState (~Copyable Atomic cannot be copied into closures)
    private let renderState = RenderState()
    private let lifecycleLock = NSLock()
    private var isEngineRunning = false

    public var isPlaying: Bool {
        renderState.isActiveAtom.load(ordering: .acquiring) != 0
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

    public func start(mode: FocusSoundscape? = nil) {
        if let mode { setMode(mode) }
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        ensureEngineConfiguredLocked()
        if !isEngineRunning {
            do {
                try engine.start()
                isEngineRunning = true
                Log.audio.info("FocusSoundEngine started (mode=\(self.currentMode.rawValue, privacy: .public))")
            } catch {
                Log.audio.error("FocusSoundEngine failed to start: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        renderState.isActiveAtom.store(1, ordering: .releasing)
    }

    public func stop() {
        renderState.isActiveAtom.store(0, ordering: .releasing)
        // Allow smooth 300ms fade-out before pausing AVAudioEngine to avoid clicks
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.35) { [weak self] in
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

            let active = state.isActiveAtom.load(ordering: .relaxed) != 0
            let modeIdx = state.modeAtom.load(ordering: .relaxed)
            let targetVol = Float(bitPattern: state.volumeBitsAtom.load(ordering: .relaxed))

            state.render(
                outL: outL,
                outR: outR,
                frames: Int(frameCount),
                active: active,
                modeIndex: modeIdx,
                targetVolume: targetVol
            )

            // Feed our DSP ring buffer directly while Focus soundscape is audible
            if active || state.masterEnv > 0.001 {
                rb.writePlanar(leftSrc: outL, rightSrc: outR, frameCount: Int(frameCount))
            }
            return noErr
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        sourceNode = node
    }
}

// MARK: - Lock-Free Real-Time DSP Synthesis State (Zero Allocations on Render Thread)

private final class RenderState: @unchecked Sendable {
    let isActiveAtom = Atomic<Int>(0)
    let modeAtom = Atomic<Int>(0)
    let volumeBitsAtom = Atomic<UInt32>(Float(0.45).bitPattern)

    var sr: Double = 48_000.0
    var invSR: Double = 1.0 / 48_000.0
    var time: Double = 0
    var masterEnv: Float = 0

    // Mode crossfade weights [focus, rain, drift]
    var wFocus: Float = 1
    var wRain: Float = 0
    var wDrift: Float = 0

    // Warm harmonic pad oscillator phases (L/R stereo pairs)
    var padPhasesL: [Double] = [0, 0, 0, 0, 0]
    var padPhasesR: [Double] = [0, 0, 0, 0, 0]

    // Eno-style polyrhythmic generative bell voices (4 independent prime-cycle voices)
    var bellPhases: [Double] = [0, 0, 0, 0]
    var bellFreqs: [Double] = [293.66, 440.0, 523.25, 659.25]
    var bellEnvs: [Float] = [0, 0, 0, 0]
    var bellTimers: [Double] = [0.6, 2.4, 4.9, 7.2]
    var bellPans: [Float] = [-0.45, 0.35, -0.25, 0.50]

    // Paul Kellet pink-noise filter states (L and R)
    var pbL: [Float] = [0, 0, 0, 0, 0, 0, 0]
    var pbR: [Float] = [0, 0, 0, 0, 0, 0, 0]
    var brownL: Float = 0
    var brownR: Float = 0
    var lpPadL: Float = 0
    var lpPadR: Float = 0
    var rainLpL: Float = 0
    var rainLpR: Float = 0

    // Soft stochastic rain droplet resonant pings
    var dropPhase: Double = 0
    var dropEnv: Float = 0
    var dropFreq: Double = 1400
    var dropPan: Float = 0

    // Fast XorShift64 PRNG (RT-safe, zero locks)
    var rng: UInt64 = 0x8a5cd789635d2dff

    // Stereo diffusion delay tank (~0.55s L, ~0.71s R @ 48kHz)
    var delayLenL = 26_400
    var delayLenR = 34_080
    var delayBufL: UnsafeMutablePointer<Float>?
    var delayBufR: UnsafeMutablePointer<Float>?
    var delayIdxL = 0
    var delayIdxR = 0
    var dampL: Float = 0
    var dampR: Float = 0

    // D Dorian / A minor pentatonic frequencies for Focus & Drift
    let focusChords: [[Double]] = [
        [73.42, 110.00, 146.83, 220.00, 329.63], // D2, A2, D3, A3, E4 (D5/9)
        [65.41, 98.00,  146.83, 196.00, 293.66], // C2, G2, D3, G3, D4 (Cadd9)
        [87.31, 130.81, 164.81, 220.00, 329.63], // F2, C3, E3, A3, E4 (Fmaj7)
        [110.00, 146.83, 164.81, 246.94, 329.63] // A2, D3, E3, B3, E4 (Asus4/9)
    ]
    let driftScale: [Double] = [261.63, 293.66, 329.63, 392.00, 440.00, 523.25, 587.33, 659.25]

    deinit {
        delayBufL?.deallocate()
        delayBufR?.deallocate()
    }

    func configure(sampleRate: Double) {
        sr = sampleRate
        invSR = 1.0 / sampleRate
        delayLenL = max(1024, Int(sampleRate * 0.54))
        delayLenR = max(1024, Int(sampleRate * 0.71))
        delayBufL?.deallocate()
        delayBufR?.deallocate()
        delayBufL = .allocate(capacity: delayLenL)
        delayBufR = .allocate(capacity: delayLenR)
        delayBufL?.initialize(repeating: 0, count: delayLenL)
        delayBufR?.initialize(repeating: 0, count: delayLenR)
        delayIdxL = 0
        delayIdxR = 0
    }

    @inline(__always)
    private func nextWhite() -> Float {
        rng ^= rng >> 12
        rng ^= rng << 25
        rng ^= rng >> 27
        let v = (rng &* 0x2545F4914F6CDD1D) >> 40
        return Float(v) * (2.0 / 16777216.0) - 1.0
    }

    func render(
        outL: UnsafeMutablePointer<Float>,
        outR: UnsafeMutablePointer<Float>,
        frames: Int,
        active: Bool,
        modeIndex: Int,
        targetVolume: Float
    ) {
        guard let dL = delayBufL, let dR = delayBufR else {
            outL.update(repeating: 0, count: frames)
            outR.update(repeating: 0, count: frames)
            return
        }

        let targetMaster: Float = active ? targetVolume : 0.0
        let tFocus: Float = modeIndex == 0 ? 1.0 : 0.0
        let tRain: Float = modeIndex == 1 ? 1.0 : 0.0
        let tDrift: Float = modeIndex == 2 ? 1.0 : 0.0
        let envStep: Float = Float(invSR * 4.2)
        let twoPi = Double.pi * 2.0

        for i in 0..<frames {
            time += invSR

            // Smooth anti-click master & mode crossfade envelopes
            masterEnv += (targetMaster - masterEnv) * envStep
            wFocus += (tFocus - wFocus) * envStep
            wRain += (tRain - wRain) * envStep
            wDrift += (tDrift - wDrift) * envStep

            if masterEnv < 0.00002 && !active {
                outL[i] = 0
                outR[i] = 0
                continue
            }

            // --- 1. Slow evolving chord progression (18s per harmonic shift) ---
            let chordPos = (time / 18.0).truncatingRemainder(dividingBy: Double(focusChords.count))
            let cIdxA = Int(chordPos) % focusChords.count
            let cIdxB = (cIdxA + 1) % focusChords.count
            let cFrac = chordPos - floor(chordPos)
            // Gentle smoothstep only in the last 35% of each 18s phrase
            let blend = max(0.0, min(1.0, (cFrac - 0.65) / 0.35))
            let smoothBlend = blend * blend * (3.0 - 2.0 * blend)

            var padL: Float = 0
            var padR: Float = 0
            if wFocus > 0.001 || wDrift > 0.001 {
                let chordA = focusChords[cIdxA]
                let chordB = focusChords[cIdxB]
                let breath = Float(0.72 + 0.28 * sin(time * 0.24))

                for v in 0..<5 {
                    let f = chordA[v] + (chordB[v] - chordA[v]) * smoothBlend
                    // Slight L/R stereo detune creates organic binaural width
                    let detune = 0.28 + Double(v) * 0.09
                    padPhasesL[v] += (f + detune) * invSR
                    if padPhasesL[v] >= 1.0 { padPhasesL[v] -= 1.0 }
                    padPhasesR[v] += (f - detune) * invSR
                    if padPhasesR[v] >= 1.0 { padPhasesR[v] -= 1.0 }

                    let sL = sin(padPhasesL[v] * twoPi)
                    let sR = sin(padPhasesR[v] * twoPi)
                    // Subtle warm second harmonic on mid voices
                    let hL = v > 0 && v < 4 ? 0.16 * sin(padPhasesL[v] * twoPi * 2.0) : 0.0
                    let hR = v > 0 && v < 4 ? 0.16 * sin(padPhasesR[v] * twoPi * 2.0) : 0.0
                    let weight: Float = v == 0 ? 0.26 : (v < 3 ? 0.19 : 0.12)
                    padL += Float(sL + hL) * weight * breath
                    padR += Float(sR + hR) * weight * breath
                }

                // Warm breathing low-pass filter on the pad
                let cutoff = Float(0.045 + 0.055 * (0.5 + 0.5 * sin(time * 0.14)))
                lpPadL += (padL - lpPadL) * cutoff
                lpPadR += (padR - lpPadR) * cutoff
            }

            // --- 2. Polyrhythmic Eno-style soft harmonic bells (used in Focus & Drift) ---
            var bellSumL: Float = 0
            var bellSumR: Float = 0
            if wFocus > 0.001 || wDrift > 0.001 {
                let cycles: [Double] = [5.3, 8.7, 11.9, 15.1]
                for b in 0..<4 {
                    bellTimers[b] -= invSR
                    if bellTimers[b] <= 0 {
                        bellTimers[b] = cycles[b] * (0.8 + Double(abs(nextWhite())) * 0.45)
                        let noteIdx = Int(abs(nextWhite()) * Float(driftScale.count)) % driftScale.count
                        bellFreqs[b] = driftScale[noteIdx] * (wDrift > 0.5 && b == 3 ? 2.0 : 1.0)
                        bellEnvs[b] = 1.0
                        bellPans[b] = nextWhite() * 0.65
                    }
                    if bellEnvs[b] > 0.0005 {
                        bellPhases[b] += bellFreqs[b] * invSR
                        if bellPhases[b] >= 1.0 { bellPhases[b] -= 1.0 }
                        let env = bellEnvs[b]
                        // Soft rounded attack + long meditative tail
                        let shaped = env * env * (1.0 - env * env * env) * 2.2
                        let tone = Float(sin(bellPhases[b] * twoPi)) * shaped * 0.18
                        let pL = 0.5 * (1.0 - bellPans[b])
                        let pR = 0.5 * (1.0 + bellPans[b])
                        bellSumL += tone * pL
                        bellSumR += tone * pR
                        bellEnvs[b] *= Float(1.0 - invSR * 0.34)
                    }
                }
            }

            // --- 3. Velvet Stereo Pink/Brown Rain (Paul Kellet 7-pole filter) ---
            var rainL: Float = 0
            var rainR: Float = 0
            let needNoise = (wRain > 0.001 || wFocus > 0.001)
            if needNoise {
                let wL = nextWhite()
                let wR = nextWhite()

                pbL[0] = 0.99886 * pbL[0] + wL * 0.0555179
                pbL[1] = 0.99332 * pbL[1] + wL * 0.0750759
                pbL[2] = 0.96900 * pbL[2] + wL * 0.1538520
                pbL[3] = 0.86650 * pbL[3] + wL * 0.3104856
                pbL[4] = 0.55000 * pbL[4] + wL * 0.5329522
                pbL[5] = -0.7616 * pbL[5] - wL * 0.0168980
                let pinkL = (pbL[0] + pbL[1] + pbL[2] + pbL[3] + pbL[4] + pbL[5] + pbL[6] + wL * 0.5362) * 0.045
                pbL[6] = wL * 0.115926

                pbR[0] = 0.99886 * pbR[0] + wR * 0.0555179
                pbR[1] = 0.99332 * pbR[1] + wR * 0.0750759
                pbR[2] = 0.96900 * pbR[2] + wR * 0.1538520
                pbR[3] = 0.86650 * pbR[3] + wR * 0.3104856
                pbR[4] = 0.55000 * pbR[4] + wR * 0.5329522
                pbR[5] = -0.7616 * pbR[5] - wR * 0.0168980
                let pinkR = (pbR[0] + pbR[1] + pbR[2] + pbR[3] + pbR[4] + pbR[5] + pbR[6] + wR * 0.5362) * 0.045
                pbR[6] = wR * 0.115926

                brownL = (brownL + wL * 0.018) * 0.994
                brownR = (brownR + wR * 0.018) * 0.994

                let swellL = Float(0.78 + 0.22 * sin(time * 0.22))
                let swellR = Float(0.78 + 0.22 * cos(time * 0.17 + 0.8))

                // Soft rain low-pass smoothing
                rainLpL += ((pinkL * 0.65 + brownL * 0.95) * swellL - rainLpL) * 0.18
                rainLpR += ((pinkR * 0.65 + brownR * 0.95) * swellR - rainLpR) * 0.18

                // Occasional gentle resonant droplet
                if wRain > 0.05 {
                    if dropEnv < 0.002 && nextWhite() > 0.9996 {
                        dropEnv = 0.14
                        dropFreq = 950.0 + Double(abs(nextWhite())) * 1300.0
                        dropPan = nextWhite() * 0.8
                    }
                    if dropEnv > 0.0005 {
                        dropPhase += dropFreq * invSR
                        if dropPhase >= 1.0 { dropPhase -= 1.0 }
                        let dropSig = Float(sin(dropPhase * twoPi)) * dropEnv
                        rainL += dropSig * (0.5 * (1.0 - dropPan))
                        rainR += dropSig * (0.5 * (1.0 + dropPan))
                        dropEnv *= Float(1.0 - invSR * 22.0)
                    }
                }

                rainL += rainLpL * 1.15
                rainR += rainLpR * 1.15
            }

            // --- 4. Mix active soundscape modes ---
            let focusMixL = lpPadL * 0.92 + bellSumL * 0.55 + rainLpL * 0.14
            let focusMixR = lpPadR * 0.92 + bellSumR * 0.55 + rainLpR * 0.14

            let rainMixL = rainL * 1.05 + lpPadL * 0.18
            let rainMixR = rainR * 1.05 + lpPadR * 0.18

            let driftMixL = lpPadL * 0.58 + bellSumL * 1.15
            let driftMixR = lpPadR * 0.58 + bellSumR * 1.15

            let dryL = focusMixL * wFocus + rainMixL * wRain + driftMixL * wDrift
            let dryR = focusMixR * wFocus + rainMixR * wRain + driftMixR * wDrift

            // --- 5. Lush Stereo Cross-Feedback Diffusion Tank (warm ambient space) ---
            let tapL = dL[delayIdxL]
            let tapR = dR[delayIdxR]
            dampL += (tapL - dampL) * 0.18
            dampR += (tapR - dampR) * 0.18

            let wetSend = wFocus * 0.34 + wRain * 0.12 + wDrift * 0.48
            dL[delayIdxL] = dryL + dampR * 0.54
            dR[delayIdxR] = dryR + dampL * 0.54
            delayIdxL = (delayIdxL + 1) % delayLenL
            delayIdxR = (delayIdxR + 1) % delayLenR

            // Soft tanh limiter so it never clips under any combination
            let sigL = tanh((dryL + dampL * wetSend) * 1.15) * masterEnv
            let sigR = tanh((dryR + dampR * wetSend) * 1.15) * masterEnv

            outL[i] = sigL
            outR[i] = sigR
        }
    }
}
