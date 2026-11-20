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
        case .focus: return "Soft Light"
        case .pulse: return "Kinetic Pulse"
        case .rain: return "Rain & Glass"
        case .drift: return "Gymnopédie"
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
    case morning = 0    // 06:00 - 11:59 (luminous, open)
    case afternoon = 1  // 12:00 - 19:59 (balanced, grounded)
    case night = 2      // 20:00 - 05:59 (warmer transposition & softer air)

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

/// Studio-grade procedural furniture-music synthesizer (AVAudioEngine + lock-free AVAudioSourceNode).
/// Implements Soft Light's two-layer score/engine design in native Swift:
/// - Deterministic seeded 32-bar harmonic forms with Pass 2+ intra-chord swaps & water glints (`SatieScore`)
/// - FM glassy bells (-3c/+3c carriers, decaying 1:1 FM depth, 2x/4x/9x overtones, asymmetric tanh pickup)
/// - 3-player wooden-body bowed strings (520 / 1150 / 2900 Hz formant tables + delayed vibrato)
/// - Tempo-synced dotted echo, dual-LFO stereo chorus, 4×4 Hadamard bandpass room reverb,
///   95 Hz rumble cut, soft-knee bus compressor, and smooth Core Audio Process Tap auto-ducking.
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

    public func setDucked(_ ducked: Bool) {
        renderState.isDuckedAtom.store(ducked ? 1 : 0, ordering: .releasing)
    }

    public func triggerSessionChime() {
        renderState.chimeTriggerAtom.store(1, ordering: .releasing)
    }

    public func start(mode: FocusSoundscape? = nil) {
        if let mode { setMode(mode) }
        setCircadianPhase(.current())
        setDucked(false)

        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        renderState.isActiveAtom.store(1, ordering: .releasing)
        if isEngineRunning && engine.isRunning { return }

        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        if sourceNode == nil {
            let state = self.renderState
            let rb = self.ringBuffer
            let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
                let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
                guard abl.count >= 2,
                      let outL = abl[0].mData?.assumingMemoryBound(to: Float.self),
                      let outR = abl[1].mData?.assumingMemoryBound(to: Float.self) else {
                    return noErr
                }
                let frames = Int(frameCount)
                state.render(outL: outL, outR: outR, frames: frames, sampleRate: 48_000)
                if state.isAudibleOutput {
                    rb.writePlanar(leftSrc: outL, rightSrc: outR, frameCount: frames)
                }
                return noErr
            }
            sourceNode = node
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
        }

        do {
            engine.prepare()
            try engine.start()
            isEngineRunning = true
            Log.audio.info("Satie synth started (mode=\(self.currentMode.shortLabel, privacy: .public), circadian=\(CircadianPhase.current().label, privacy: .public))")
        } catch {
            renderState.isActiveAtom.store(0, ordering: .releasing)
            Log.audio.error("Satie synth failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func stop() {
        renderState.isActiveAtom.store(0, ordering: .releasing)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.55) { [weak self] in
            guard let self else { return }
            self.lifecycleLock.lock()
            defer { self.lifecycleLock.unlock() }
            if self.renderState.isActiveAtom.load(ordering: .acquiring) == 0 && self.isEngineRunning {
                self.engine.pause()
                self.isEngineRunning = false
            }
        }
    }

    public func stopImmediately() {
        renderState.isActiveAtom.store(0, ordering: .releasing)
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        if isEngineRunning {
            engine.stop()
            isEngineRunning = false
        }
    }

    /// Deterministic offline synthesis helper used by unit & psychoacoustic meter tests.
    public static func renderOfflineTestBlock(
        mode: FocusSoundscape,
        circadian: CircadianPhase = .afternoon,
        frames: Int = 4096,
        ducked: Bool = false,
        warmupFrames: Int = 24_000,
        seed: UInt32 = 42
    ) -> (left: [Float], right: [Float]) {
        let state = FocusRenderState(seed: seed)
        state.modeAtom.store(FocusSoundscape.allCases.firstIndex(of: mode) ?? 0, ordering: .releasing)
        state.circadianAtom.store(circadian.rawValue, ordering: .releasing)
        state.volumeBitsAtom.store(Float(0.75).bitPattern, ordering: .releasing)
        state.isActiveAtom.store(1, ordering: .releasing)
        state.isDuckedAtom.store(ducked ? 1 : 0, ordering: .releasing)

        var warmL = [Float](repeating: 0, count: 512)
        var warmR = [Float](repeating: 0, count: 512)
        let warmBlocks = max(1, warmupFrames / 512)
        for _ in 0..<warmBlocks {
            warmL.withUnsafeMutableBufferPointer { lb in
                warmR.withUnsafeMutableBufferPointer { rb in
                    state.render(outL: lb.baseAddress!, outR: rb.baseAddress!, frames: 512, sampleRate: 48_000)
                }
            }
        }

        var l = [Float](repeating: 0, count: frames)
        var r = [Float](repeating: 0, count: frames)
        l.withUnsafeMutableBufferPointer { lb in
            r.withUnsafeMutableBufferPointer { rb in
                state.render(outL: lb.baseAddress!, outR: rb.baseAddress!, frames: frames, sampleRate: 48_000)
            }
        }
        return (l, r)
    }
}

// MARK: - Precomputed Band-Limited Harmonic Wavetables

private final class TimbreBank: @unchecked Sendable {
    static let tableSize = 1024
    static let tableMask = tableSize - 1

    // Indexed by octave register (0: low, 1: mid, 2: high) to avoid aliasing
    let stringTables: [[Float]]
    let padTable: [Float]
    let bassTable: [Float]
    let sineTable: [Float]

    init() {
        let n = Self.tableSize
        var sine = [Float](repeating: 0, count: n)
        for i in 0..<n {
            sine[i] = sin(Float(i) * (2.0 * Float.pi / Float(n)))
        }
        self.sineTable = sine

        // Bass: [1, 0.55, 0.32, 0.14, 0.06]
        let bassWeights: [Double] = [0, 1.0, 0.55, 0.32, 0.14, 0.06]
        self.bassTable = Self.buildTable(maxHarmonic: 5) { h, _ in bassWeights[h] }

        // Pad: 1/h / sqrt(1 + (f/620)^2) anchored around 260 Hz
        self.padTable = Self.buildTable(maxHarmonic: 18, baseHz: 260.0) { h, f in
            (1.0 / Double(h)) / sqrt(1.0 + pow(f / 620.0, 2.0))
        }

        // Strings: 3-peak wooden-body formant resonance (520 Hz, 1150 Hz, 2900 Hz)
        let bump: (Double, Double, Double) -> Double = { freq, center, width in
            let d = log2(max(1.0, freq) / center) / width
            return exp(-0.5 * d * d)
        }
        let stringPartial: (Int, Double) -> Double = { h, f in
            let body = 1.0
                + 0.9 * bump(f, 520.0, 0.35)
                + 0.7 * bump(f, 1150.0, 0.30)
                + 0.6 * bump(f, 2900.0, 0.30)
            return (body / Double(h) / sqrt(1.0 + pow(f / 3000.0, 2.0))) * 0.5
        }
        self.stringTables = [
            Self.buildTable(maxHarmonic: 24, baseHz: 260.0, partial: stringPartial),
            Self.buildTable(maxHarmonic: 14, baseHz: 520.0, partial: stringPartial),
            Self.buildTable(maxHarmonic: 8,  baseHz: 1040.0, partial: stringPartial),
        ]
    }

    private static func buildTable(
        maxHarmonic: Int,
        baseHz: Double = 220.0,
        partial: (Int, Double) -> Double
    ) -> [Float] {
        let n = tableSize
        var tbl = [Double](repeating: 0, count: n)
        for h in 1...maxHarmonic {
            let f = Double(h) * baseHz
            if f > 9500.0 { break }
            let amp = partial(h, f)
            if abs(amp) < 1e-6 { continue }
            for i in 0..<n {
                let phase = Double(i) * (2.0 * Double.pi * Double(h)) / Double(n)
                tbl[i] += amp * sin(phase)
            }
        }
        var maxAbs = 0.0
        for v in tbl { maxAbs = max(maxAbs, abs(v)) }
        let norm = maxAbs > 1e-6 ? 1.0 / maxAbs : 1.0
        return tbl.map { Float($0 * norm) }
    }

    @inline(__always)
    static func lookup(_ table: [Float], phase01: Double) -> Float {
        let f = (phase01 - floor(phase01)) * Double(tableSize)
        let i0 = Int(f) & tableMask
        let i1 = (i0 + 1) & tableMask
        let frac = Float(f - floor(f))
        return table[i0] + (table[i1] - table[i0]) * frac
    }
}

// MARK: - Pre-Allocated Voice & DSP Primitives (Zero Allocations on Audio Thread)

private struct BellVoice {
    var active: Bool = false
    var isFigure: Bool = true
    var isGlint: Bool = false
    var age: Double = 0
    var maxAge: Double = 4.0
    var freq: Double = 440
    var phaseA: Double = 0
    var phaseB: Double = 0
    var modPhase: Double = 0
    var ov2Phase: Double = 0
    var ov4Phase: Double = 0
    var ov9Phase: Double = 0
    var hasOv9: Bool = false
    var level: Float = 0
    var ringTau: Double = 1.2
    var fmPeak: Double = 0
    var fmFloor: Double = 0
    var ov2Amp: Float = 0
    var ov4Amp: Float = 0
    var ov9Amp: Float = 0
    var panL: Float = 0.707
    var panR: Float = 0.707

    mutating func trigger(event: ScoredBellEvent) {
        let f = 440.0 * pow(2.0, Double(event.midi - 69) / 12.0)
        let ring = event.kind == .glint ? 0.5 : (1.0 + 0.55 * event.duration)
        let bright = event.kind == .melody ? 1.35 : (event.kind == .glint ? 0.0 : 1.0)

        active = true
        isFigure = (event.kind == .figure)
        isGlint = (event.kind == .glint)
        age = 0
        maxAge = ring * 4.2
        freq = f
        phaseA = 0
        phaseB = 0
        modPhase = 0
        ov2Phase = 0
        ov4Phase = 0
        ov9Phase = 0
        hasOv9 = (!isGlint) && (f * 9.0 < 9000.0)
        level = Float(event.level)
        ringTau = ring
        fmPeak = (1.05 * bright * event.velocity + 0.08) * 0.42
        fmFloor = 0.08 * 0.42
        ov2Amp = isGlint ? 0 : 0.20
        ov4Amp = isGlint ? 0 : Float(0.30 * bright * event.velocity)
        ov9Amp = hasOv9 ? Float(0.16 * bright * event.velocity) : 0

        let angle = Float((event.pan + 1.0) * 0.25 * Double.pi)
        panL = cos(angle)
        panR = sin(angle)
    }

    @inline(__always)
    mutating func step(dt: Double, sineTable: [Float]) -> (Float, Float) {
        guard active else { return (0, 0) }
        age += dt
        if age >= maxAge {
            active = false
            return (0, 0)
        }

        let env: Float
        if age < 0.005 {
            env = Float(age / 0.005)
        } else {
            env = Float(exp(-(age - 0.005) / ringTau))
        }
        if env < 0.0002 {
            active = false
            return (0, 0)
        }

        // Exponentially decaying FM depth (bright glassy attack -> pure warm sustain)
        let fmIndex = fmFloor + (fmPeak - fmFloor) * exp(-age / 0.40)
        modPhase += freq * dt
        if modPhase >= 1.0 { modPhase -= floor(modPhase) }
        let modVal = Double(TimbreBank.lookup(sineTable, phase01: modPhase)) * fmIndex

        let detuneUp = 1.001734   // +3 cents
        let detuneDn = 0.998269   // -3 cents
        phaseA += freq * (isGlint ? 1.0 : detuneDn) * dt
        if phaseA >= 1.0 { phaseA -= floor(phaseA) }

        var sample: Float
        if isGlint {
            sample = TimbreBank.lookup(sineTable, phase01: phaseA + modVal * 0.1)
        } else {
            phaseB += freq * detuneUp * dt
            if phaseB >= 1.0 { phaseB -= floor(phaseB) }
            let cA = TimbreBank.lookup(sineTable, phase01: phaseA + modVal)
            let cB = TimbreBank.lookup(sineTable, phase01: phaseB + modVal)
            sample = 0.5 * (cA + cB)

            ov2Phase += freq * 2.0 * dt
            if ov2Phase >= 1.0 { ov2Phase -= floor(ov2Phase) }
            sample += ov2Amp * Float(exp(-age / 0.90)) * TimbreBank.lookup(sineTable, phase01: ov2Phase)

            ov4Phase += freq * 4.0 * dt
            if ov4Phase >= 1.0 { ov4Phase -= floor(ov4Phase) }
            sample += ov4Amp * Float(exp(-age / 0.28)) * TimbreBank.lookup(sineTable, phase01: ov4Phase)

            if hasOv9 {
                ov9Phase += freq * 9.0 * dt
                if ov9Phase >= 1.0 { ov9Phase -= floor(ov9Phase) }
                sample += ov9Amp * Float(exp(-age / 0.07)) * TimbreBank.lookup(sineTable, phase01: ov9Phase)
            }
        }

        let sig = sample * env * level
        return (sig * panL, sig * panR)
    }
}

private struct StringVoice {
    var active: Bool = false
    var age: Double = 0
    var totalDuration: Double = 6.0
    var rise: Double = 1.2
    var fall: Double = 1.5
    var freq: Double = 440
    var tableIndex: Int = 1
    var level: Float = 0
    var panL: Float = 0.707
    var panR: Float = 0.707

    // 3 players with independent detune and delayed vibrato
    var p0: Double = 0, p1: Double = 0, p2: Double = 0
    var d0: Double = 1, d1: Double = 1, d2: Double = 1
    var vPhase0: Double = 0, vPhase1: Double = 0, vPhase2: Double = 0
    var vRate0: Double = 5.2, vRate1: Double = 5.5, vRate2: Double = 5.8
    var vDepth0: Double = 0.003, vDepth1: Double = 0.003, vDepth2: Double = 0.003

    mutating func trigger(event: ScoredSustainEvent, rng: inout SeededRNG) {
        let f = 440.0 * pow(2.0, Double(event.midi - 69) / 12.0)
        active = true
        age = 0
        totalDuration = event.duration + 1.8
        rise = min(1.2, totalDuration * 0.40)
        fall = min(1.5, totalDuration * 0.50)
        freq = f
        tableIndex = f < 380 ? 0 : (f < 780 ? 1 : 2)
        level = Float(event.level)

        let angle = Float((event.pan + 1.0) * 0.25 * Double.pi)
        panL = cos(angle)
        panR = sin(angle)

        p0 = rng.nextUnit(); p1 = rng.nextUnit(); p2 = rng.nextUnit()
        d0 = pow(2.0, rng.between(-9.0, 9.0) / 1200.0)
        d1 = pow(2.0, rng.between(-9.0, 9.0) / 1200.0)
        d2 = pow(2.0, rng.between(-9.0, 9.0) / 1200.0)
        vPhase0 = rng.nextUnit(); vPhase1 = rng.nextUnit(); vPhase2 = rng.nextUnit()
        vRate0 = rng.between(4.9, 6.0)
        vRate1 = rng.between(4.9, 6.0)
        vRate2 = rng.between(4.9, 6.0)
        // Vibrato width in frequency ratio (~4..7 cents)
        vDepth0 = rng.between(4.0, 7.0) / 1731.2
        vDepth1 = rng.between(4.0, 7.0) / 1731.2
        vDepth2 = rng.between(4.0, 7.0) / 1731.2
    }

    @inline(__always)
    mutating func step(dt: Double, bank: TimbreBank) -> (Float, Float) {
        guard active else { return (0, 0) }
        age += dt
        if age >= totalDuration {
            active = false
            return (0, 0)
        }

        // Two-stage gentle bow swell -> sustain -> smooth fall
        let env: Double
        if age < rise * 0.5 {
            env = 0.35 * (age / max(0.01, rise * 0.5))
        } else if age < rise {
            env = 0.35 + 0.65 * ((age - rise * 0.5) / max(0.01, rise * 0.5))
        } else if age > totalDuration - fall {
            env = max(0.0, (totalDuration - age) / max(0.01, fall))
        } else {
            env = 1.0
        }

        // Delayed vibrato arrives only after bow settles
        let vibRamp = min(1.0, age / max(0.25, rise + 0.2))
        vPhase0 += vRate0 * dt; if vPhase0 >= 1.0 { vPhase0 -= 1.0 }
        vPhase1 += vRate1 * dt; if vPhase1 >= 1.0 { vPhase1 -= 1.0 }
        vPhase2 += vRate2 * dt; if vPhase2 >= 1.0 { vPhase2 -= 1.0 }

        let s0 = Double(TimbreBank.lookup(bank.sineTable, phase01: vPhase0)) * vDepth0 * vibRamp
        let s1 = Double(TimbreBank.lookup(bank.sineTable, phase01: vPhase1)) * vDepth1 * vibRamp
        let s2 = Double(TimbreBank.lookup(bank.sineTable, phase01: vPhase2)) * vDepth2 * vibRamp

        p0 += freq * d0 * (1.0 + s0) * dt; if p0 >= 1.0 { p0 -= floor(p0) }
        p1 += freq * d1 * (1.0 + s1) * dt; if p1 >= 1.0 { p1 -= floor(p1) }
        p2 += freq * d2 * (1.0 + s2) * dt; if p2 >= 1.0 { p2 -= floor(p2) }

        let tbl = bank.stringTables[tableIndex]
        let sum = (TimbreBank.lookup(tbl, phase01: p0)
                 + TimbreBank.lookup(tbl, phase01: p1)
                 + TimbreBank.lookup(tbl, phase01: p2)) * (1.0 / 3.0)
        let sig = sum * Float(env) * level
        return (sig * panL, sig * panR)
    }
}

private struct PadBassVoice {
    var active: Bool = false
    var isBass: Bool = false
    var age: Double = 0
    var duration: Double = 4.0
    var freq: Double = 220
    var phaseL: Double = 0
    var phaseR: Double = 0
    var level: Float = 0

    mutating func trigger(event: ScoredSustainEvent) {
        let f = 440.0 * pow(2.0, Double(event.midi - 69) / 12.0)
        active = true
        isBass = (event.kind == .bass)
        age = 0
        duration = event.duration + (isBass ? 0.4 : 0.0)
        freq = f
        phaseL = 0
        phaseR = 0.13
        level = Float(event.level)
    }

    @inline(__always)
    mutating func step(dt: Double, bank: TimbreBank) -> (Float, Float) {
        guard active else { return (0, 0) }
        age += dt
        if age >= duration {
            active = false
            return (0, 0)
        }

        if isBass {
            let env: Float
            if age < 0.012 {
                env = Float(age / 0.012) * 0.48
            } else if age < duration - 0.4 {
                env = Float(0.16 + 0.32 * exp(-(age - 0.012) / 1.0))
            } else {
                let tail = age - (duration - 0.4)
                env = Float(0.16 * exp(-tail / 0.07))
            }
            phaseL += freq * dt
            if phaseL >= 1.0 { phaseL -= floor(phaseL) }
            let s = TimbreBank.lookup(bank.bassTable, phase01: phaseL) * env * level
            return (s, s)
        } else {
            let fade = min(1.6, duration * 0.5)
            let env: Double
            if age < fade {
                env = age / max(0.01, fade)
            } else if age > duration - fade {
                env = max(0.0, (duration - age) / max(0.01, fade))
            } else {
                env = 1.0
            }
            // Wide -5c / +5c stereo pad (-0.55 / +0.55 pan)
            phaseL += freq * 0.997116 * dt; if phaseL >= 1.0 { phaseL -= floor(phaseL) }
            phaseR += freq * 1.002892 * dt; if phaseR >= 1.0 { phaseR -= floor(phaseR) }
            let vL = TimbreBank.lookup(bank.padTable, phase01: phaseL) * Float(env) * level
            let vR = TimbreBank.lookup(bank.padTable, phase01: phaseR) * Float(env) * level
            return (vL * 0.85 + vR * 0.30, vR * 0.85 + vL * 0.30)
        }
    }
}

/// Stereo tempo-synced damped delay line (matches Soft Light's 0.75-beat & 1.5-beat echoes).
private struct StereoEcho {
    private var bufL: [Float]
    private var bufR: [Float]
    private var writeIdx: Int = 0
    private var lpL: Float = 0
    private var lpR: Float = 0
    private let maxSamples: Int

    init(maxSeconds: Double = 2.5, sampleRate: Double = 48_000) {
        let cap = max(1024, Int(maxSeconds * sampleRate))
        self.maxSamples = cap
        self.bufL = [Float](repeating: 0, count: cap)
        self.bufR = [Float](repeating: 0, count: cap)
    }

    @inline(__always)
    mutating func process(_ inL: Float, _ inR: Float, delaySamples: Int, send: Float, feedback: Float, lpAlpha: Float) -> (Float, Float) {
        let d = max(1, min(maxSamples - 1, delaySamples))
        var readIdx = writeIdx - d
        if readIdx < 0 { readIdx += maxSamples }

        let dL = bufL[readIdx]
        let dR = bufR[readIdx]
        lpL += (dL - lpL) * lpAlpha
        lpR += (dR - lpR) * lpAlpha

        // Subtle cross-feed for airy width
        bufL[writeIdx] = inL * send + lpL * feedback * 0.88 + lpR * feedback * 0.12
        bufR[writeIdx] = inR * send + lpR * feedback * 0.88 + lpL * feedback * 0.12
        writeIdx += 1
        if writeIdx >= maxSamples { writeIdx = 0 }

        return (inL + lpL, inR + lpR)
    }

    mutating func clear() {
        for i in 0..<maxSamples { bufL[i] = 0; bufR[i] = 0 }
        lpL = 0; lpR = 0
    }
}

/// Dual-LFO stereo chorus matching Soft Light's 13ms/0.5Hz + 17.5ms/0.69Hz modulated taps.
private struct StereoChorus {
    private var bufL: [Float]
    private var bufR: [Float]
    private var writeIdx: Int = 0
    private var phase1: Double = 0
    private var phase2: Double = 0.37
    private let cap: Int = 4096

    init() {
        self.bufL = [Float](repeating: 0, count: 4096)
        self.bufR = [Float](repeating: 0, count: 4096)
    }

    @inline(__always)
    mutating func process(_ inL: Float, _ inR: Float, dt: Double, sampleRate: Double, depthSec: Double, amount: Float) -> (Float, Float) {
        bufL[writeIdx] = inL
        bufR[writeIdx] = inR

        phase1 += 0.50 * dt; if phase1 >= 1.0 { phase1 -= 1.0 }
        phase2 += 0.69 * dt; if phase2 >= 1.0 { phase2 -= 1.0 }

        let d1 = (0.0130 + depthSec * sin(phase1 * 2.0 * Double.pi)) * sampleRate
        let d2 = (0.0175 + depthSec * sin(phase2 * 2.0 * Double.pi)) * sampleRate

        let wL = readFrac(bufL, delay: d1) + readFrac(bufL, delay: d2)
        let wR = readFrac(bufR, delay: d2) + readFrac(bufR, delay: d1)

        writeIdx = (writeIdx + 1) & (cap - 1)
        return (inL + wL * amount * 0.5, inR + wR * amount * 0.5)
    }

    @inline(__always)
    private func readFrac(_ buf: [Float], delay: Double) -> Float {
        let pos = Double(writeIdx) - delay
        let i0 = Int(floor(pos)) & (cap - 1)
        let i1 = (i0 + 1) & (cap - 1)
        let frac = Float(pos - floor(pos))
        return buf[i0] + (buf[i1] - buf[i0]) * frac
    }

    mutating func clear() {
        for i in 0..<cap { bufL[i] = 0; bufR[i] = 0 }
    }
}

/// 4×4 Hadamard Feedback Delay Network tuned to Soft Light's warm 2.4s bandpass room (220 Hz .. 5600 Hz).
private struct HadamardRoomReverb {
    private var d0: [Float], d1: [Float], d2: [Float], d3: [Float]
    private var i0 = 0, i1 = 0, i2 = 0, i3 = 0
    private var lp0: Float = 0, lp1: Float = 0, lp2: Float = 0, lp3: Float = 0
    private var hp0: Float = 0, hp1: Float = 0, hp2: Float = 0, hp3: Float = 0

    init() {
        // Mutually prime delay lengths at 48 kHz (~31ms, 41ms, 54ms, 71ms)
        d0 = [Float](repeating: 0, count: 1499)
        d1 = [Float](repeating: 0, count: 1973)
        d2 = [Float](repeating: 0, count: 2593)
        d3 = [Float](repeating: 0, count: 3407)
    }

    @inline(__always)
    mutating func process(_ inL: Float, _ inR: Float, decay: Float = 0.80, dampLP: Float = 0.46, dampHP: Float = 0.028) -> (Float, Float) {
        let y0 = d0[i0]
        let y1 = d1[i1]
        let y2 = d2[i2]
        let y3 = d3[i3]

        // Bandpass damping (soft highs <5.6 kHz, no mud <220 Hz)
        lp0 += (y0 - lp0) * dampLP; hp0 += (lp0 - hp0) * dampHP; let f0 = lp0 - hp0
        lp1 += (y1 - lp1) * dampLP; hp1 += (lp1 - hp1) * dampHP; let f1 = lp1 - hp1
        lp2 += (y2 - lp2) * dampLP; hp2 += (lp2 - hp2) * dampHP; let f2 = lp2 - hp2
        lp3 += (y3 - lp3) * dampLP; hp3 += (lp3 - hp3) * dampHP; let f3 = lp3 - hp3

        // Orthonormal 4×4 Hadamard mix
        let m0 = 0.5 * (f0 + f1 + f2 + f3)
        let m1 = 0.5 * (f0 - f1 + f2 - f3)
        let m2 = 0.5 * (f0 + f1 - f2 - f3)
        let m3 = 0.5 * (f0 - f1 - f2 + f3)

        d0[i0] = inL * 0.55 + m0 * decay
        d1[i1] = inR * 0.55 + m1 * decay
        d2[i2] = inL * 0.45 + m2 * decay
        d3[i3] = inR * 0.45 + m3 * decay

        i0 += 1; if i0 >= d0.count { i0 = 0 }
        i1 += 1; if i1 >= d1.count { i1 = 0 }
        i2 += 1; if i2 >= d2.count { i2 = 0 }
        i3 += 1; if i3 >= d3.count { i3 = 0 }

        return (0.5 * (y0 + y2), 0.5 * (y1 + y3))
    }

    mutating func clear() {
        for k in 0..<d0.count { d0[k] = 0 }
        for k in 0..<d1.count { d1[k] = 0 }
        for k in 0..<d2.count { d2[k] = 0 }
        for k in 0..<d3.count { d3[k] = 0 }
        lp0 = 0; lp1 = 0; lp2 = 0; lp3 = 0
        hp0 = 0; hp1 = 0; hp2 = 0; hp3 = 0
    }
}

/// Stereo Paul Kellet pink/brown rainfall texture for Rain & Glass mode.
private struct RainTexture {
    private var rng: UInt64
    private var b0: Float = 0, b1: Float = 0, b2: Float = 0, b3: Float = 0, b4: Float = 0, b5: Float = 0, b6: Float = 0
    private var lp: Float = 0
    private var br: Float = 0

    init(seed: UInt64) {
        self.rng = seed
    }

    @inline(__always)
    mutating func next(cutoffAlpha: Float) -> Float {
        rng = rng &* 6364136223846793005 &+ 1442695040888963407
        let white = (Float(Int32(bitPattern: UInt32(truncatingIfNeeded: rng >> 32))) / Float(Int32.max)) * 0.5
        b0 = 0.99886 * b0 + white * 0.0555179
        b1 = 0.99332 * b1 + white * 0.0750759
        b2 = 0.96900 * b2 + white * 0.1538520
        b3 = 0.86650 * b3 + white * 0.3104856
        b4 = 0.55000 * b4 + white * 0.5329522
        b5 = -0.7616 * b5 - white * 0.0168980
        let pink = (b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362) * 0.048
        b6 = white * 0.115926
        lp += (pink - lp) * cutoffAlpha
        br += (pink - br) * 0.015
        return lp * 0.65 + br * 1.15
    }
}

// MARK: - Lock-Free Real-Time Audio Render State

private final class FocusRenderState: @unchecked Sendable {
    let isActiveAtom = Atomic<Int>(0)
    let isDuckedAtom = Atomic<Int>(0)
    let modeAtom = Atomic<Int>(0)
    let circadianAtom = Atomic<Int>(1)
    let volumeBitsAtom = Atomic<UInt32>(Float(0.65).bitPattern)
    let chimeTriggerAtom = Atomic<Int>(0)

    private let bank = TimbreBank()
    private var rng: SeededRNG

    // Voice pools (pre-allocated, fixed-size)
    private var bells = [BellVoice](repeating: BellVoice(), count: 28)
    private var nextBellSlot = 0
    private var strings = [StringVoice](repeating: StringVoice(), count: 14)
    private var nextStringSlot = 0
    private var pads = [PadBassVoice](repeating: PadBassVoice(), count: 16)
    private var nextPadSlot = 0

    // Score bar clock state
    private var activeModeIdx: Int = -1
    private var activeCircadianRaw: Int = -1
    private var currentBar: ComposedBar?
    private var currentBarStartSec: Double = 0
    private var nextBarIndex: Int = 0
    private var barBellCursor: Int = 0
    private var barSustainCursor: Int = 0
    private var clockSec: Double = 0

    // Effects buses
    private var figureEcho = StereoEcho()
    private var melodyEcho = StereoEcho()
    private var figureChorus = StereoChorus()
    private var melodyChorus = StereoChorus()
    private var stringChorus = StereoChorus()
    private var room = HadamardRoomReverb()
    private var rainL = RainTexture(seed: 0x9E3779B97F4A7C15)
    private var rainR = RainTexture(seed: 0xBF58476D1CE4E5B9)

    // Filter & envelope states
    private var strHpL: Float = 0, strHpR: Float = 0
    private var strLpL: Float = 0, strLpR: Float = 0
    private var padLpL: Float = 0, padLpR: Float = 0
    private var masterHpL: Float = 0, masterHpR: Float = 0
    private var masterLpL: Float = 0, masterLpR: Float = 0
    private var presenceBpL: Float = 0, presenceBpR: Float = 0
    private var compEnv: Float = 0

    // Pulse sub-heartbeat & 14 Hz neural modulation
    private var pulsePhase: Double = 0
    private var kickAge: Double = 10.0
    private var kickOscPhase: Double = 0
    private var lastBeatInt: Int = -1

    // Session completion chime
    private var chimeVoiceA = BellVoice()
    private var chimeVoiceB = BellVoice()

    // Smooth gains
    private var activeGain: Float = 0
    private var duckGain: Float = 1
    private var smoothVol: Float = 0.65
    private(set) var isAudibleOutput: Bool = false

    init(seed: UInt32 = 42) {
        self.rng = SeededRNG(seed: seed)
    }

    private func resetScore(for mode: FocusSoundscape, circadian: CircadianPhase) {
        for i in 0..<bells.count { bells[i].active = false }
        for i in 0..<strings.count { strings[i].active = false }
        for i in 0..<pads.count { pads[i].active = false }
        figureEcho.clear()
        melodyEcho.clear()
        figureChorus.clear()
        melodyChorus.clear()
        stringChorus.clear()
        room.clear()

        clockSec = 0
        currentBarStartSec = 0
        nextBarIndex = 0
        lastBeatInt = -1
        loadNextBar(mode: mode, circadian: circadian)
    }

    private func loadNextBar(mode: FocusSoundscape, circadian: CircadianPhase) {
        let composed = SatieScore.composeBar(mode: mode, barIndex: nextBarIndex, circadian: circadian, rng: &rng)
        var sortedBells = composed.bells
        sortedBells.sort { $0.at < $1.at }
        var sortedSus = composed.sustained
        sortedSus.sort { $0.at < $1.at }
        currentBar = ComposedBar(
            barIndex: composed.barIndex,
            barInForm: composed.barInForm,
            pass: composed.pass,
            chordName: composed.chordName,
            secondsPerBeat: composed.secondsPerBeat,
            secondsPerBar: composed.secondsPerBar,
            bells: sortedBells,
            sustained: sortedSus,
            didSwapFigure: composed.didSwapFigure,
            allowedPitchClasses: composed.allowedPitchClasses
        )
        barBellCursor = 0
        barSustainCursor = 0
        nextBarIndex += 1
    }

    func render(outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>, frames: Int, sampleRate: Double) {
        let wantActive = isActiveAtom.load(ordering: .acquiring) != 0
        let wantDucked = isDuckedAtom.load(ordering: .acquiring) != 0
        let modeIdx = max(0, min(FocusSoundscape.allCases.count - 1, modeAtom.load(ordering: .acquiring)))
        let mode = FocusSoundscape.allCases[modeIdx]
        let circadianRaw = circadianAtom.load(ordering: .acquiring)
        let circadian = CircadianPhase(rawValue: circadianRaw) ?? .afternoon
        let targetVol = Float(bitPattern: volumeBitsAtom.load(ordering: .acquiring))

        if chimeTriggerAtom.exchange(0, ordering: .acquiring) != 0 {
            chimeVoiceA.trigger(event: ScoredBellEvent(kind: .melody, at: 0, midi: 69, duration: 2.2, velocity: 0.7, level: 0.16, pan: -0.15))
            chimeVoiceB.trigger(event: ScoredBellEvent(kind: .melody, at: 0, midi: 76, duration: 2.6, velocity: 0.65, level: 0.14, pan: 0.15))
        }

        if wantActive && (modeIdx != activeModeIdx || circadianRaw != activeCircadianRaw) {
            activeModeIdx = modeIdx
            activeCircadianRaw = circadianRaw
            resetScore(for: mode, circadian: circadian)
        }

        let targetActiveGain: Float = wantActive ? 1.0 : 0.0
        let targetDuckGain: Float = wantDucked ? 0.0 : 1.0
        let dt = 1.0 / sampleRate

        // Filter coefficients at 48 kHz
        let echoLPAlpha = Float(1.0 - exp(-2.0 * Double.pi * 4500.0 / sampleRate))
        let strHPAlpha  = Float(1.0 - exp(-2.0 * Double.pi * 260.0 / sampleRate))
        let strLPAlpha  = Float(1.0 - exp(-2.0 * Double.pi * 6200.0 / sampleRate))
        let padLPAlpha  = Float(1.0 - exp(-2.0 * Double.pi * 2200.0 / sampleRate))
        let rumHPAlpha  = Float(1.0 - exp(-2.0 * Double.pi * 95.0 / sampleRate))
        let airCutHz    = (circadian == .night) ? 4600.0 : 6200.0
        let masterLPAlpha = Float(1.0 - exp(-2.0 * Double.pi * airCutHz / sampleRate))
        let presAlpha   = Float(1.0 - exp(-2.0 * Double.pi * 2400.0 / sampleRate))

        let spb = SatieScore.secondsPerBeat(for: mode)
        let figEchoSamples = Int(0.75 * spb * sampleRate)
        let melEchoSamples = Int(1.50 * spb * sampleRate)

        let activeStep: Float = wantActive ? 0.00018 : 0.00032
        let duckStep: Float   = wantDucked ? 0.00028 : 0.00009

        var blockPeak: Float = 0

        for i in 0..<frames {
            activeGain += (targetActiveGain - activeGain) * activeStep
            duckGain += (targetDuckGain - duckGain) * duckStep
            smoothVol += (targetVol - smoothVol) * 0.0006

            let masterEnv = activeGain * duckGain
            if masterEnv < 0.0001 && !chimeVoiceA.active && !chimeVoiceB.active {
                outL[i] = 0
                outR[i] = 0
                continue
            }

            // Advance bar clock & trigger scored events sample-accurately
            if let bar = currentBar {
                let relTime = clockSec - currentBarStartSec
                while barBellCursor < bar.bells.count && bar.bells[barBellCursor].at <= relTime {
                    bells[nextBellSlot].trigger(event: bar.bells[barBellCursor])
                    nextBellSlot = (nextBellSlot + 1) % bells.count
                    barBellCursor += 1
                }
                while barSustainCursor < bar.sustained.count && bar.sustained[barSustainCursor].at <= relTime {
                    let ev = bar.sustained[barSustainCursor]
                    if ev.kind == .strings {
                        strings[nextStringSlot].trigger(event: ev, rng: &rng)
                        nextStringSlot = (nextStringSlot + 1) % strings.count
                    } else {
                        pads[nextPadSlot].trigger(event: ev)
                        nextPadSlot = (nextPadSlot + 1) % pads.count
                    }
                    barSustainCursor += 1
                }
                if relTime >= bar.secondsPerBar {
                    currentBarStartSec += bar.secondsPerBar
                    loadNextBar(mode: mode, circadian: circadian)
                }
            }
            clockSec += dt

            // 1. Render Bells (split into Figure Bus vs Melody/Glint Bus)
            var figL: Float = 0, figR: Float = 0
            var melL: Float = 0, melR: Float = 0
            for b in 0..<bells.count where bells[b].active {
                let (sL, sR) = bells[b].step(dt: dt, sineTable: bank.sineTable)
                if bells[b].isFigure {
                    figL += sL; figR += sR
                } else {
                    melL += sL; melR += sR
                }
            }

            // Asymmetric pickup warmth on figure bus: (tanh(2.2x + 0.12) - tanh(0.12)) / 2.2
            let bias: Float = 0.119427 // tanh(0.12)
            figL = (tanh(2.2 * figL + 0.12) - bias) / 2.2
            figR = (tanh(2.2 * figR + 0.12) - bias) / 2.2

            // Tempo-synced dotted echo + dual-LFO chorus on figure & melody
            let (feL, feR) = figureEcho.process(figL, figR, delaySamples: figEchoSamples, send: 0.22, feedback: 0.36, lpAlpha: echoLPAlpha)
            let (fcL, fcR) = figureChorus.process(feL, feR, dt: dt, sampleRate: sampleRate, depthSec: 0.0020, amount: 0.30)

            let (meL, meR) = melodyEcho.process(melL, melR, delaySamples: melEchoSamples, send: 0.22, feedback: 0.36, lpAlpha: echoLPAlpha)
            let (mcL, mcR) = melodyChorus.process(meL, meR, dt: dt, sampleRate: sampleRate, depthSec: 0.0014, amount: 0.18)

            // 2. Render 3-Player Wooden-Body Strings
            var sL: Float = 0, sR: Float = 0
            for st in 0..<strings.count where strings[st].active {
                let (vL, vR) = strings[st].step(dt: dt, bank: bank)
                sL += vL; sR += vR
            }
            strLpL += (sL - strLpL) * strLPAlpha; strLpR += (sR - strLpR) * strLPAlpha
            strHpL += (strLpL - strHpL) * strHPAlpha; strHpR += (strLpR - strHpR) * strHPAlpha
            let strCleanL = strLpL - strHpL
            let strCleanR = strLpR - strHpR
            let (scL, scR) = stringChorus.process(strCleanL, strCleanR, dt: dt, sampleRate: sampleRate, depthSec: 0.0040, amount: 0.45)

            // 3. Render Warm Bass + Wide Stereo Pad
            var pL: Float = 0, pR: Float = 0
            var bsL: Float = 0, bsR: Float = 0
            for k in 0..<pads.count where pads[k].active {
                let (vL, vR) = pads[k].step(dt: dt, bank: bank)
                if pads[k].isBass { bsL += vL; bsR += vR } else { pL += vL; pR += vR }
            }
            padLpL += (pL - padLpL) * padLPAlpha
            padLpR += (pR - padLpR) * padLPAlpha

            // Subtle 14 Hz neural modulation + soft damped sub-pulse on Kinetic Pulse mode
            var pulseSub: Float = 0
            if mode == .pulse {
                pulsePhase += 14.0 * dt
                if pulsePhase >= 1.0 { pulsePhase -= 1.0 }
                let mod = 0.88 + 0.12 * TimbreBank.lookup(bank.sineTable, phase01: pulsePhase)
                padLpL *= mod
                padLpR *= mod

                let beatInt = Int(clockSec / spb)
                if beatInt != lastBeatInt {
                    lastBeatInt = beatInt
                    if beatInt % 2 == 0 {
                        kickAge = 0
                        kickOscPhase = 0
                    }
                }
                if kickAge < 0.34 {
                    let kFreq = 50.0 + 36.0 * exp(-kickAge * 18.0)
                    kickOscPhase += kFreq * dt
                    if kickOscPhase >= 1.0 { kickOscPhase -= 1.0 }
                    let kEnv = Float(min(1.0, kickAge / 0.012) * exp(-kickAge * 8.5))
                    pulseSub = TimbreBank.lookup(bank.sineTable, phase01: kickOscPhase) * kEnv * 0.14
                    kickAge += dt
                }
            }

            // Lush stereo Paul Kellet rainfall in Rain & Glass mode
            var rTexL: Float = 0, rTexR: Float = 0
            if mode == .rain {
                let rainSwell = Float(0.5 + 0.5 * sin(clockSec * 0.22))
                let cutAlpha = Float(1.0 - exp(-2.0 * Double.pi * (820.0 + Double(rainSwell) * 460.0) / sampleRate))
                rTexL = rainL.next(cutoffAlpha: cutAlpha) * 0.58
                rTexR = rainR.next(cutoffAlpha: cutAlpha) * 0.58
            }

            // 4. Mix into Dry Bus + 4×4 Hadamard Stereo Room Reverb
            let dryL = fcL + mcL + scL + padLpL + bsL + pulseSub + rTexL
            let dryR = fcR + mcR + scR + padLpR + bsR + pulseSub + rTexR

            let revInL = dryL + strCleanL * 0.55
            let revInR = dryR + strCleanR * 0.55
            let (wetL, wetR) = room.process(revInL, revInR, decay: mode == .drift ? 0.84 : 0.79)

            var mixL = dryL + wetL * 0.34
            var mixR = dryR + wetR * 0.34

            // 5. Master Tone Bus: 95 Hz rumble cut + gentle 2.4 kHz presence + anti-fatigue air roll-off
            masterHpL += (mixL - masterHpL) * rumHPAlpha
            masterHpR += (mixR - masterHpR) * rumHPAlpha
            mixL -= masterHpL
            mixR -= masterHpR

            // Subtle presence lift for MacBook speakers
            presenceBpL += (mixL - presenceBpL) * presAlpha
            presenceBpR += (mixR - presenceBpR) * presAlpha
            let hiMidL = mixL - presenceBpL
            let hiMidR = mixR - presenceBpR
            mixL += hiMidL * 0.16
            mixR += hiMidR * 0.16

            // Smooth upper-air roll-off (keeps >5 kHz fatigue energy tightly bounded)
            masterLpL += (mixL - masterLpL) * masterLPAlpha
            masterLpR += (mixR - masterLpR) * masterLPAlpha
            mixL = masterLpL
            mixR = masterLpR

            // 6. Gentle bus glue compressor (-21 dB threshold, 1.6:1 ratio)
            let instLevel = max(abs(mixL), abs(mixR))
            let compCoeff: Float = instLevel > compEnv ? 0.0007 : 0.00005
            compEnv += (instLevel - compEnv) * compCoeff
            let threshold: Float = 0.09 // ~-21 dBFS
            let compGain: Float
            if compEnv > threshold {
                let over = compEnv / threshold
                compGain = pow(over, -0.375) // 1.6:1 ratio
            } else {
                compGain = 1.0
            }

            // Output scaling + Flow completion chime
            var finalL = mixL * compGain * 2.15 * masterEnv * smoothVol
            var finalR = mixR * compGain * 2.15 * masterEnv * smoothVol

            if chimeVoiceA.active || chimeVoiceB.active {
                let (cAL, cAR) = chimeVoiceA.step(dt: dt, sineTable: bank.sineTable)
                let (cBL, cBR) = chimeVoiceB.step(dt: dt, sineTable: bank.sineTable)
                finalL += (cAL + cBL) * 1.4
                finalR += (cAR + cBR) * 1.4
            }

            // Soft safety limiter (never clips)
            finalL = tanh(finalL * 0.95) * 0.95
            finalR = tanh(finalR * 0.95) * 0.95

            outL[i] = finalL
            outR[i] = finalR
            blockPeak = max(blockPeak, abs(finalL), abs(finalR))
        }

        isAudibleOutput = blockPeak > 0.0008
    }
}
