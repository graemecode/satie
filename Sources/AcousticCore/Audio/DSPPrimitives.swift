import Foundation

// MARK: - Fast Audio-Thread Math, PRNG & Acoustic Tuning

enum AudioMath {
    @inline(__always)
    static func smoothstep(_ x: Double) -> Double {
        let t = max(0.0, min(1.0, x))
        return t * t * (3.0 - 2.0 * t)
    }

    /// Band-limited step residual for alias-free analog oscillators (PolyBLEP).
    @inline(__always)
    static func polyBLEP(phase t: Double, dt: Double) -> Double {
        if t < dt {
            let x = t / dt
            return x + x - x * x - 1.0
        } else if t > 1.0 - dt {
            let x = (t - 1.0) / dt
            return x * x + x + x + 1.0
        }
        return 0.0
    }

    /// Fast 4-point Catmull-Rom / Hermite cubic interpolation (zero zipper noise under delay modulation).
    @inline(__always)
    static func hermite(_ xm1: Float, _ x0: Float, _ x1: Float, _ x2: Float, frac t: Float) -> Float {
        let c0 = x0
        let c1 = 0.5 * (x1 - xm1)
        let c2 = xm1 - 2.5 * x0 + 2.0 * x1 - 0.5 * x2
        let c3 = 0.5 * (x2 - xm1) + 1.5 * (x0 - x1)
        return ((c3 * t + c2) * t + c1) * t + c0
    }

    /// Railsback piano octave stretch: gently sharpens upper registers and flattens low registers
    /// so stiff-string octaves beat cleanly like a concert acoustic instrument.
    @inline(__always)
    static func railsbackHz(midi: Int, stretchAmount: Double = 1.0) -> Double {
        let semitonesFromA4 = Double(midi - 69)
        let octFromC4 = Double(midi - 60) / 12.0
        let stretchCents: Double
        if octFromC4 > 0 {
            stretchCents = (octFromC4 * octFromC4 * 0.65 + octFromC4 * 0.55) * stretchAmount
        } else {
            stretchCents = -(octFromC4 * octFromC4 * 0.45) * stretchAmount
        }
        return 440.0 * pow(2.0, (semitonesFromA4 + stretchCents / 100.0) / 12.0)
    }

    /// 5-limit Just Intonation ratios relative to chord root (eliminates 12-TET third/fifth beating on sustained pads).
    private static let jiRatios: [Double] = [
        1.0,        // Unison
        16.0 / 15.0,// m2
        9.0 / 8.0,  // M2
        6.0 / 5.0,  // m3
        5.0 / 4.0,  // M3 (-13.69 cents vs 12-TET -> glassy pure lock)
        4.0 / 3.0,  // P4
        45.0 / 32.0,// #4
        3.0 / 2.0,  // P5 (+1.96 cents vs 12-TET)
        8.0 / 5.0,  // m6
        5.0 / 3.0,  // M6
        9.0 / 5.0,  // m7
        15.0 / 8.0  // M7
    ]

    @inline(__always)
    static func justSweetenedHz(midi: Int, rootMidi: Int, blend: Double = 0.65) -> Double {
        let etHz = 440.0 * pow(2.0, Double(midi - 69) / 12.0)
        guard blend > 0.001 else { return etHz }
        let rootHz = 440.0 * pow(2.0, Double(rootMidi - 69) / 12.0)
        let diff = midi - rootMidi
        let oct = floor(Double(diff) / 12.0)
        let interval = ((diff % 12) + 12) % 12
        let jiHz = rootHz * jiRatios[interval] * pow(2.0, oct)
        // Geometric blend in log-frequency space
        return etHz * pow(jiHz / etHz, blend)
    }
}

/// Ultra-fast deterministic audio-thread PRNG (SplitMix64/Xorshift64, zero locks).
struct FastNoiseRNG: Sendable {
    var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    @inline(__always)
    mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Uniform float in [-1, 1]
    @inline(__always)
    mutating func nextBipolar() -> Float {
        let bits = Int32(bitPattern: UInt32(truncatingIfNeeded: nextUInt64() >> 32))
        return Float(bits) / Float(Int32.max)
    }

    /// Uniform double in [0, 1)
    @inline(__always)
    mutating func nextUnit() -> Double {
        Double(nextUInt64() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }
}

// MARK: - Cytomic Zero-Delay Feedback (TPT) State Variable Filter

/// Andrew Simper's trapezoidal-integrated Zero-Delay Feedback SVF.
/// Unconditionally stable under fast audio-rate modulation with exact analog frequency response.
struct CytomicSVF: Sendable {
    private var ic1eq: Float = 0
    private var ic2eq: Float = 0
    private var a1: Float = 0
    private var a2: Float = 0
    private var a3: Float = 0
    private var k: Float = 1.41421356

    init(cutoffHz: Double = 1000.0, q: Double = 0.7071, sampleRate: Double = 48_000.0) {
        set(cutoffHz: cutoffHz, q: q, sampleRate: sampleRate)
    }

    @inline(__always)
    mutating func set(cutoffHz: Double, q: Double = 0.7071, sampleRate: Double = 48_000.0) {
        let fc = max(16.0, min(sampleRate * 0.44, cutoffHz))
        let g = Float(tan(Double.pi * fc / sampleRate))
        let kVal = Float(1.0 / max(0.35, min(20.0, q)))
        let a1Val = 1.0 / (1.0 + g * (g + kVal))
        self.k = kVal
        self.a1 = a1Val
        self.a2 = g * a1Val
        self.a3 = g * a2
    }

    @inline(__always)
    mutating func processAll(_ v0: Float) -> (lp: Float, bp: Float, hp: Float) {
        let v3 = v0 - ic2eq
        let v1 = a1 * ic1eq + a2 * v3
        let v2 = ic2eq + a2 * ic1eq + a3 * v3
        ic1eq = 2.0 * v1 - ic1eq
        ic2eq = 2.0 * v2 - ic2eq
        let hp = v0 - k * v1 - v2
        return (v2, v1, hp)
    }

    @inline(__always)
    mutating func lowpass(_ x: Float) -> Float { processAll(x).lp }

    @inline(__always)
    mutating func bandpass(_ x: Float) -> Float { processAll(x).bp }

    @inline(__always)
    mutating func highpass(_ x: Float) -> Float { processAll(x).hp }

    /// Passive/active Cytomic bell filter (exact gain `linearGain` at cutoffHz, 0 dB at DC & Nyquist).
    @inline(__always)
    mutating func bell(_ x: Float, linearGain: Float) -> Float {
        let res = processAll(x)
        return x + (linearGain - 1.0) * k * res.bp
    }

    mutating func reset() {
        ic1eq = 0
        ic2eq = 0
    }
}

// MARK: - Buchla 292 / Optomix Cadmium-Sulfide Vactrol Low-Pass Gate

/// Physical model of a West Coast vactrol Low-Pass Gate:
/// dual-stage nonlinear photocell decay driving both a Cytomic ZDF lowpass filter and amplitude
/// simultaneously, giving struck sounds an unmistakable organic wooden/liquid ring.
struct VactrolLPG: Sendable {
    private var fastEnv: Double = 0
    private var slowEnv: Double = 0
    private var filter = CytomicSVF(cutoffHz: 200, q: 0.85)
    private var minCutoff: Double = 130.0
    private var maxCutoff: Double = 7800.0
    private var fastTau: Double = 0.048
    private var slowTau: Double = 0.55
    private var resonance: Double = 0.82
    private var sampleCounter: Int = 0

    mutating func trigger(
        velocity: Double,
        decayScale: Double = 1.0,
        minCutoff: Double = 130.0,
        maxCutoff: Double = 7600.0,
        resonance: Double = 0.82
    ) {
        let v = max(0.05, min(1.3, velocity))
        self.fastEnv = v
        self.slowEnv = v * 0.72
        self.minCutoff = minCutoff
        self.maxCutoff = maxCutoff
        self.fastTau = (0.032 + 0.030 * v) * max(0.35, min(2.5, decayScale))
        self.slowTau = (0.36 + 0.58 * v) * max(0.35, min(3.5, decayScale))
        self.resonance = resonance
        self.sampleCounter = 0
    }

    @inline(__always)
    mutating func process(_ x: Float, dt: Double, sampleRate: Double) -> Float {
        // Dual exponential CdS photocell conductance curve
        fastEnv *= exp(-dt / fastTau)
        slowEnv *= exp(-dt / slowTau)
        let conductance = max(0.0, min(1.25, 0.56 * fastEnv + 0.44 * slowEnv))
        // Update filter coefficients every 4 samples (12 kHz control rate -> silky, cheap)
        if (sampleCounter & 3) == 0 {
            let shaped = pow(min(1.0, conductance), 1.55)
            let fc = minCutoff + (maxCutoff - minCutoff) * shaped
            filter.set(cutoffHz: fc, q: resonance, sampleRate: sampleRate)
        }
        sampleCounter &+= 1
        let filtered = filter.lowpass(x)
        // Slight nonlinear vactrol VCA curve preserves whisper-quiet organic tail
        return filtered * Float(pow(conductance, 0.88))
    }

    mutating func reset() {
        fastEnv = 0
        slowEnv = 0
        filter.reset()
    }
}

// MARK: - Roland RE-201 / El Capistan Saturating Stereo Tape Space Echo

/// Stereo tape echo with Hermite cubic fractional interpolation, dual-LFO wow & flutter,
/// magnetic tape hysteresis saturation, and per-repeat ZDF head aging.
struct TapeSpaceEcho: Sendable {
    private var bufL: [Float]
    private var bufR: [Float]
    private var writeIdx: Int = 0
    private let mask: Int
    private var wowPhaseL: Double = 0.0
    private var wowPhaseR: Double = 0.31
    private var flutterPhaseL: Double = 0.12
    private var flutterPhaseR: Double = 0.67
    private var lpL = CytomicSVF(cutoffHz: 3400, q: 0.72)
    private var lpR = CytomicSVF(cutoffHz: 3400, q: 0.72)
    private var hpL = CytomicSVF(cutoffHz: 150, q: 0.707)
    private var hpR = CytomicSVF(cutoffHz: 150, q: 0.707)
    private var lastCutoffHz: Double = 3400

    init(sampleRate: Double = 48_000.0) {
        // Power-of-two capacity >= 3.0 seconds at 48 kHz -> 262144 samples (~5.46s)
        let cap = 1 << 18
        self.mask = cap - 1
        self.bufL = [Float](repeating: 0, count: cap)
        self.bufR = [Float](repeating: 0, count: cap)
    }

    @inline(__always)
    private func readHermite(_ buf: [Float], delaySamples: Double) -> Float {
        let pos = Double(writeIdx) - delaySamples
        let base = Int(floor(pos))
        let frac = Float(pos - floor(pos))
        let xm1 = buf[(base - 1) & mask]
        let x0  = buf[base & mask]
        let x1  = buf[(base + 1) & mask]
        let x2  = buf[(base + 2) & mask]
        return AudioMath.hermite(xm1, x0, x1, x2, frac: frac)
    }

    @inline(__always)
    mutating func process(
        _ inL: Float,
        _ inR: Float,
        delaySecL: Double,
        delaySecR: Double,
        send: Float,
        feedback: Float,
        toneHz: Double,
        wowDepthMs: Double,
        dt: Double,
        sampleRate: Double
    ) -> (Float, Float) {
        if abs(toneHz - lastCutoffHz) > 25.0 {
            lastCutoffHz = toneHz
            lpL.set(cutoffHz: toneHz, q: 0.72, sampleRate: sampleRate)
            lpR.set(cutoffHz: toneHz, q: 0.72, sampleRate: sampleRate)
        }

        // Slow capstan wow (~0.37/0.43 Hz) + fine tape flutter (~4.8/5.7 Hz)
        wowPhaseL += 0.37 * dt; if wowPhaseL >= 1.0 { wowPhaseL -= 1.0 }
        wowPhaseR += 0.43 * dt; if wowPhaseR >= 1.0 { wowPhaseR -= 1.0 }
        flutterPhaseL += 4.8 * dt; if flutterPhaseL >= 1.0 { flutterPhaseL -= 1.0 }
        flutterPhaseR += 5.7 * dt; if flutterPhaseR >= 1.0 { flutterPhaseR -= 1.0 }

        let modL = (sin(wowPhaseL * 2.0 * Double.pi) * wowDepthMs + sin(flutterPhaseL * 2.0 * Double.pi) * wowDepthMs * 0.14) * 0.001
        let modR = (sin(wowPhaseR * 2.0 * Double.pi) * wowDepthMs + sin(flutterPhaseR * 2.0 * Double.pi) * wowDepthMs * 0.14) * 0.001

        let dSampL = max(8.0, min(Double(mask - 8), (delaySecL + modL) * sampleRate))
        let dSampR = max(8.0, min(Double(mask - 8), (delaySecR + modR) * sampleRate))

        let rawL = readHermite(bufL, delaySamples: dSampL)
        let rawR = readHermite(bufR, delaySamples: dSampR)

        // Tape head roll-off + low-end mud clearing + subtle magnetic hysteresis saturation
        let agedL = hpL.highpass(lpL.lowpass(rawL))
        let agedR = hpR.highpass(lpR.lowpass(rawR))
        let satL = tanh((inL * send + agedL * feedback * 0.84 + agedR * feedback * 0.16) * 1.25) * 0.80
        let satR = tanh((inR * send + agedR * feedback * 0.84 + agedL * feedback * 0.16) * 1.25) * 0.80

        bufL[writeIdx] = satL
        bufR[writeIdx] = satR
        writeIdx = (writeIdx + 1) & mask

        return (inL + agedL, inR + agedR)
    }

    mutating func clear() {
        for i in 0..<bufL.count { bufL[i] = 0; bufR[i] = 0 }
        lpL.reset(); lpR.reset()
        hpL.reset(); hpR.reset()
    }
}

// MARK: - Studio Acoustic Space (Pre-Delay + Early Reflections + 4-Stage Allpass Diffuser + 8x8 Modulated FDN)

private struct AllpassDiffuser: Sendable {
    private var buf: [Float]
    private var idx: Int = 0
    private let len: Int

    init(length: Int) {
        self.len = max(16, length)
        self.buf = [Float](repeating: 0, count: self.len)
    }

    @inline(__always)
    mutating func process(_ x: Float, g: Float) -> Float {
        let delayed = buf[idx]
        let v = x - g * delayed
        buf[idx] = v
        idx += 1
        if idx >= len { idx = 0 }
        return delayed + g * v
    }

    mutating func clear() {
        for i in 0..<len { buf[i] = 0 }
        idx = 0
    }
}

/// Studio-grade algorithmic acoustic chamber (Schlecht / Välimäki VN-FDN architecture):
/// - Configurable pre-delay (keeps transients tactile & forward)
/// - 32-tap zero-DC Optimal Velvet-Noise early-reflection diffuser (4x echo density, zero inner multiplies)
/// - 2-stage prime allpass micro-diffuser per channel (silky transient diffusion with half the CPU)
/// - 8x8 Signed-Diagonal Walsh-Hadamard colorless orthogonal FDN with 8 irrational-ratio LFO-modulated lines
/// - Exact delay-proportional RT60 attenuation (g_i = decay^(M_i / M_ref)) and matched per-line air absorption
struct StudioAcousticSpace: Sendable {
    // Pre-delay + early reflections buffer (8192 samples = ~170ms at 48 kHz)
    private var erBufL: [Float]
    private var erBufR: [Float]
    private var erWrite: Int = 0
    private let erMask: Int = 8191
    private var erAirLpL: Float = 0
    private var erAirLpR: Float = 0
    private var erMudHpL: Float = 0
    private var erMudHpR: Float = 0

    // 2-stage prime allpass micro-diffusers (paired with Velvet-Noise pre-diffusion for colorless density)
    private var apL0 = AllpassDiffuser(length: 197)
    private var apL1 = AllpassDiffuser(length: 349)

    private var apR0 = AllpassDiffuser(length: 211)
    private var apR1 = AllpassDiffuser(length: 367)

    // 8x8 Modulated FDN tank lines (mutually prime lengths: 29ms .. 85ms at 48 kHz, power-of-two storage)
    private static let lineBaseDelays: [Double] = [1399, 1693, 2017, 2381, 2749, 3163, 3583, 4099]
    // Normalized delay ratios M_i / M_ref (M_ref = 3600 samples = 75ms) for unified concert-hall RT60 across all 8 lines
    private static let lineRatios: [Float] = [0.3886, 0.4703, 0.5603, 0.6614, 0.7636, 0.8786, 0.9953, 1.1386]
    private static let lfoRates: [Double] = [0.21, 0.27, 0.34, 0.41, 0.49, 0.56, 0.63, 0.71]
    private static let lfoDepths: [Double] = [9.5, 11.0, 12.5, 14.0, 11.5, 13.5, 15.0, 16.5]
    private static let lineMask: Int = 8191 // 8192 samples per line

    private var t0: [Float], t1: [Float], t2: [Float], t3: [Float]
    private var t4: [Float], t5: [Float], t6: [Float], t7: [Float]
    private var tw: Int = 0

    private var lp0: Float = 0, lp1: Float = 0, lp2: Float = 0, lp3: Float = 0
    private var lp4: Float = 0, lp5: Float = 0, lp6: Float = 0, lp7: Float = 0
    private var hp0: Float = 0, hp1: Float = 0, hp2: Float = 0, hp3: Float = 0
    private var hp4: Float = 0, hp5: Float = 0, hp6: Float = 0, hp7: Float = 0

    // Cached delay-proportional per-line decay gains & air-absorption alphas (0 pow() calls in steady state)
    private var cachedDecay: Float = -1
    private var cachedDampLP: Float = -1
    private var g0: Float = 0.32, g1: Float = 0.32, g2: Float = 0.32, g3: Float = 0.32
    private var g4: Float = 0.32, g5: Float = 0.32, g6: Float = 0.32, g7: Float = 0.32
    private var a0: Float = 0.36, a1: Float = 0.36, a2: Float = 0.36, a3: Float = 0.36
    private var a4: Float = 0.36, a5: Float = 0.36, a6: Float = 0.36, a7: Float = 0.36

    private var lfoP0: Double = 0.00, lfoP1: Double = 0.13, lfoP2: Double = 0.29, lfoP3: Double = 0.41
    private var lfoP4: Double = 0.53, lfoP5: Double = 0.67, lfoP6: Double = 0.79, lfoP7: Double = 0.91
    private var modD0: Double = 1399, modD1: Double = 1693, modD2: Double = 2017, modD3: Double = 2381
    private var modD4: Double = 2749, modD5: Double = 3163, modD6: Double = 3583, modD7: Double = 4099
    private var lfoTick: Int = 0

    init() {
        erBufL = [Float](repeating: 0, count: 8192)
        erBufR = [Float](repeating: 0, count: 8192)
        t0 = [Float](repeating: 0, count: 8192)
        t1 = [Float](repeating: 0, count: 8192)
        t2 = [Float](repeating: 0, count: 8192)
        t3 = [Float](repeating: 0, count: 8192)
        t4 = [Float](repeating: 0, count: 8192)
        t5 = [Float](repeating: 0, count: 8192)
        t6 = [Float](repeating: 0, count: 8192)
        t7 = [Float](repeating: 0, count: 8192)
    }

    @inline(__always)
    private static func readMod(_ buf: [Float], writeIdx: Int, delay: Double) -> Float {
        let pos = Double(writeIdx) - delay
        let i0 = Int(floor(pos)) & lineMask
        let i1 = (i0 + 1) & lineMask
        let frac = Float(pos - floor(pos))
        return buf[i0] + (buf[i1] - buf[i0]) * frac
    }

    @inline(__always)
    private mutating func updateProportionalCurves(decay: Float, dampLP: Float) {
        if decay != cachedDecay {
            cachedDecay = decay
            let d = max(0.05, min(0.985, decay))
            let invSqrt8: Float = 0.35355339
            g0 = pow(d, Self.lineRatios[0]) * invSqrt8
            g1 = pow(d, Self.lineRatios[1]) * invSqrt8
            g2 = pow(d, Self.lineRatios[2]) * invSqrt8
            g3 = pow(d, Self.lineRatios[3]) * invSqrt8
            g4 = pow(d, Self.lineRatios[4]) * invSqrt8
            g5 = pow(d, Self.lineRatios[5]) * invSqrt8
            g6 = pow(d, Self.lineRatios[6]) * invSqrt8
            g7 = pow(d, Self.lineRatios[7]) * invSqrt8
        }
        if dampLP != cachedDampLP {
            cachedDampLP = dampLP
            let lp = max(0.06, min(0.96, dampLP))
            a0 = max(0.05, min(0.95, pow(lp, Self.lineRatios[0])))
            a1 = max(0.05, min(0.95, pow(lp, Self.lineRatios[1])))
            a2 = max(0.05, min(0.95, pow(lp, Self.lineRatios[2])))
            a3 = max(0.05, min(0.95, pow(lp, Self.lineRatios[3])))
            a4 = max(0.05, min(0.95, pow(lp, Self.lineRatios[4])))
            a5 = max(0.05, min(0.95, pow(lp, Self.lineRatios[5])))
            a6 = max(0.05, min(0.95, pow(lp, Self.lineRatios[6])))
            a7 = max(0.05, min(0.95, pow(lp, Self.lineRatios[7])))
        }
    }

    @inline(__always)
    mutating func process(
        _ inL: Float,
        _ inR: Float,
        preDelayMs: Double = 18.0,
        decay: Float = 0.85,
        dampLP: Float = 0.36,
        dampHP: Float = 0.022,
        erMix: Float = 0.32,
        modScale: Double = 1.0,
        dt: Double = 1.0 / 48_000.0,
        sampleRate: Double = 48_000.0
    ) -> (Float, Float) {
        updateProportionalCurves(decay: decay, dampLP: dampLP)

        // 1. Store into ER / pre-delay line
        let w = erWrite
        let m = erMask
        erBufL[w] = inL
        erBufR[w] = inR

        // 32-tap zero-DC Optimal Velvet-Noise Early-Reflection Diffuser (4.4 ms .. 49.6 ms):
        // Four distance bands x 8 prime-jittered taps (exact 4 +1 / 4 -1 per band -> zero DC, zero inner multiplies)
        // Band 0 (4.4 .. 13.8 ms): intimate studio boundaries
        let vnL0 = erBufL[(w - 211) & m] - erBufR[(w - 281) & m] + erBufL[(w - 359) & m] - erBufR[(w - 431) & m]
                 - erBufL[(w - 503) & m] + erBufR[(w - 571) & m] - erBufL[(w - 619) & m] + erBufR[(w - 661) & m]
        let vnR0 = erBufR[(w - 223) & m] - erBufL[(w - 293) & m] + erBufR[(w - 373) & m] - erBufL[(w - 443) & m]
                 - erBufR[(w - 521) & m] + erBufL[(w - 587) & m] - erBufR[(w - 631) & m] + erBufL[(w - 677) & m]

        // Band 1 (14.4 .. 24.9 ms): lateral cross-room imaging
        let vnL1 = erBufR[(w - 709) & m] - erBufL[(w - 769) & m] - erBufR[(w - 839) & m] + erBufL[(w - 907) & m]
                 + erBufR[(w - 977) & m] - erBufL[(w - 1049) & m] + erBufR[(w - 1117) & m] - erBufL[(w - 1193) & m]
        let vnR1 = erBufL[(w - 727) & m] - erBufR[(w - 787) & m] - erBufL[(w - 857) & m] + erBufR[(w - 929) & m]
                 + erBufL[(w - 997) & m] - erBufR[(w - 1063) & m] + erBufL[(w - 1129) & m] - erBufR[(w - 1213) & m]

        // Band 2 (26.0 .. 37.3 ms): rear-wall silk diffusion
        let vnL2 = erBufL[(w - 1249) & m] + erBufR[(w - 1321) & m] - erBufL[(w - 1399) & m] - erBufR[(w - 1471) & m]
                 + erBufL[(w - 1549) & m] - erBufR[(w - 1621) & m] - erBufL[(w - 1699) & m] + erBufR[(w - 1783) & m]
        let vnR2 = erBufR[(w - 1277) & m] + erBufL[(w - 1361) & m] - erBufR[(w - 1429) & m] - erBufL[(w - 1499) & m]
                 + erBufR[(w - 1571) & m] - erBufL[(w - 1657) & m] - erBufR[(w - 1723) & m] + erBufL[(w - 1801) & m]

        // Band 3 (38.7 .. 49.6 ms): dense early-to-late handoff
        let vnL3 = -erBufR[(w - 1861) & m] + erBufL[(w - 1933) & m] + erBufR[(w - 2011) & m] - erBufL[(w - 2083) & m]
                 + erBufR[(w - 2153) & m] - erBufL[(w - 2221) & m] - erBufR[(w - 2297) & m] + erBufL[(w - 2371) & m]
        let vnR3 = -erBufL[(w - 1879) & m] + erBufR[(w - 1951) & m] + erBufL[(w - 2029) & m] - erBufR[(w - 2111) & m]
                 + erBufL[(w - 2179) & m] - erBufR[(w - 2251) & m] - erBufL[(w - 2311) & m] + erBufR[(w - 2383) & m]

        let eL = vnL0 * 0.175 + vnL1 * 0.130 + vnL2 * 0.092 + vnL3 * 0.058
        let eR = vnR0 * 0.175 + vnR1 * 0.130 + vnR2 * 0.092 + vnR3 * 0.058

        // Air absorption (~4.8 kHz wall damping) + 150 Hz low-mud clear on early reflections
        erAirLpL += (eL - erAirLpL) * 0.46
        erAirLpR += (eR - erAirLpR) * 0.46
        erMudHpL += (erAirLpL - erMudHpL) * 0.020
        erMudHpR += (erAirLpR - erMudHpR) * 0.020
        let erOutL = erAirLpL - erMudHpL
        let erOutR = erAirLpR - erMudHpR

        let preSamp = max(1, min(4096, Int(preDelayMs * 0.001 * sampleRate)))
        let preL = erBufL[(w - preSamp) & m]
        let preR = erBufR[(w - preSamp) & m]
        erWrite = (w + 1) & m

        // 2. Hybrid Velvet + 2-Stage Allpass Input Diffuser (instant high echo density, zero metallic flutter)
        let vInL = preL * 0.62 + (vnL0 * 0.12 + vnL1 * 0.08)
        let vInR = preR * 0.62 + (vnR0 * 0.12 + vnR1 * 0.08)
        var dL = apL0.process(vInL, g: 0.64)
        dL = apL1.process(dL, g: 0.58)
        var dR = apR0.process(vInR, g: 0.64)
        dR = apR1.process(dR, g: 0.58)

        // 3. Advance 8 irrational-ratio tank modulation LFOs at 6 kHz control rate
        if (lfoTick & 7) == 0 {
            let stepDt = dt * 8.0
            let twoPi = 2.0 * Double.pi
            lfoP0 += Self.lfoRates[0] * stepDt; if lfoP0 >= 1.0 { lfoP0 -= 1.0 }
            lfoP1 += Self.lfoRates[1] * stepDt; if lfoP1 >= 1.0 { lfoP1 -= 1.0 }
            lfoP2 += Self.lfoRates[2] * stepDt; if lfoP2 >= 1.0 { lfoP2 -= 1.0 }
            lfoP3 += Self.lfoRates[3] * stepDt; if lfoP3 >= 1.0 { lfoP3 -= 1.0 }
            lfoP4 += Self.lfoRates[4] * stepDt; if lfoP4 >= 1.0 { lfoP4 -= 1.0 }
            lfoP5 += Self.lfoRates[5] * stepDt; if lfoP5 >= 1.0 { lfoP5 -= 1.0 }
            lfoP6 += Self.lfoRates[6] * stepDt; if lfoP6 >= 1.0 { lfoP6 -= 1.0 }
            lfoP7 += Self.lfoRates[7] * stepDt; if lfoP7 >= 1.0 { lfoP7 -= 1.0 }

            modD0 = Self.lineBaseDelays[0] + sin(lfoP0 * twoPi) * Self.lfoDepths[0] * modScale
            modD1 = Self.lineBaseDelays[1] + sin(lfoP1 * twoPi) * Self.lfoDepths[1] * modScale
            modD2 = Self.lineBaseDelays[2] + sin(lfoP2 * twoPi) * Self.lfoDepths[2] * modScale
            modD3 = Self.lineBaseDelays[3] + sin(lfoP3 * twoPi) * Self.lfoDepths[3] * modScale
            modD4 = Self.lineBaseDelays[4] + sin(lfoP4 * twoPi) * Self.lfoDepths[4] * modScale
            modD5 = Self.lineBaseDelays[5] + sin(lfoP5 * twoPi) * Self.lfoDepths[5] * modScale
            modD6 = Self.lineBaseDelays[6] + sin(lfoP6 * twoPi) * Self.lfoDepths[6] * modScale
            modD7 = Self.lineBaseDelays[7] + sin(lfoP7 * twoPi) * Self.lfoDepths[7] * modScale
        }
        lfoTick &+= 1

        let y0 = Self.readMod(t0, writeIdx: tw, delay: modD0)
        let y1 = Self.readMod(t1, writeIdx: tw, delay: modD1)
        let y2 = Self.readMod(t2, writeIdx: tw, delay: modD2)
        let y3 = Self.readMod(t3, writeIdx: tw, delay: modD3)
        let y4 = Self.readMod(t4, writeIdx: tw, delay: modD4)
        let y5 = Self.readMod(t5, writeIdx: tw, delay: modD5)
        let y6 = Self.readMod(t6, writeIdx: tw, delay: modD6)
        let y7 = Self.readMod(t7, writeIdx: tw, delay: modD7)

        // 4. Delay-proportional dual-band damping (exact unified frequency-dependent RT60 across all 8 lines)
        lp0 += (y0 - lp0) * a0; hp0 += (lp0 - hp0) * dampHP; let f0 = lp0 - hp0
        lp1 += (y1 - lp1) * a1; hp1 += (lp1 - hp1) * dampHP; let f1 = lp1 - hp1
        lp2 += (y2 - lp2) * a2; hp2 += (lp2 - hp2) * dampHP; let f2 = lp2 - hp2
        lp3 += (y3 - lp3) * a3; hp3 += (lp3 - hp3) * dampHP; let f3 = lp3 - hp3
        lp4 += (y4 - lp4) * a4; hp4 += (lp4 - hp4) * dampHP; let f4 = lp4 - hp4
        lp5 += (y5 - lp5) * a5; hp5 += (lp5 - hp5) * dampHP; let f5 = lp5 - hp5
        lp6 += (y6 - lp6) * a6; hp6 += (lp6 - hp6) * dampHP; let f6 = lp6 - hp6
        lp7 += (y7 - lp7) * a7; hp7 += (lp7 - hp7) * dampHP; let f7 = lp7 - hp7

        // 5. Colorless Orthonormal 8x8 Signed-Diagonal Walsh-Hadamard Scatterer (Q = D * H_8 * D', ||Q||_2 == 1)
        // Breaks Hadamard row symmetry to eliminate metallic eigenmode clusters while staying 100% lossless & O(N log N)
        let s0 =  f0; let s1 = -f1; let s2 =  f2; let s3 = -f3
        let s4 = -f4; let s5 =  f5; let s6 = -f6; let s7 =  f7

        let b0a = s0 + s1; let b1a = s0 - s1
        let b2a = s2 + s3; let b3a = s2 - s3
        let b4a = s4 + s5; let b5a = s4 - s5
        let b6a = s6 + s7; let b7a = s6 - s7

        let c0 = b0a + b2a; let c1 = b1a + b3a; let c2 = b0a - b2a; let c3 = b1a - b3a
        let c4 = b4a + b6a; let c5 = b5a + b7a; let c6 = b4a - b6a; let c7 = b5a - b7a

        // Delay-proportional per-line decay gains (g0..g7 already include 1/sqrt(8)) + orthogonal output permutation
        let m0 =  (c0 + c4) * g0; let m4 = -(c0 - c4) * g4
        let m1 = -(c1 + c5) * g1; let m5 =  (c1 - c5) * g5
        let m2 =  (c2 + c6) * g2; let m6 =  (c2 - c6) * g6
        let m3 = -(c3 + c7) * g3; let m7 = -(c3 - c7) * g7

        // Inject diffused stereo energy orthogonally across the 8 lines
        t0[tw] = m0 + dL * 0.36
        t1[tw] = m1 + dR * 0.36
        t2[tw] = m2 + dL * 0.31
        t3[tw] = m3 + dR * 0.31
        t4[tw] = m4 - dL * 0.27
        t5[tw] = m5 - dR * 0.27
        t6[tw] = m6 + (dL + dR) * 0.19
        t7[tw] = m7 + (dR - dL) * 0.19
        tw = (tw + 1) & Self.lineMask

        // 6. Decorrelated stereo late output + 32-tap Velvet-Noise early reflections
        let lateL = (y0 + y2 - y4 + y6) * 0.32
        let lateR = (y1 - y3 + y5 + y7) * 0.32
        return (lateL + erOutL * erMix, lateR + erOutR * erMix)
    }

    mutating func clear() {
        for i in 0..<8192 {
            erBufL[i] = 0; erBufR[i] = 0
            t0[i] = 0; t1[i] = 0; t2[i] = 0; t3[i] = 0
            t4[i] = 0; t5[i] = 0; t6[i] = 0; t7[i] = 0
        }
        apL0.clear(); apL1.clear()
        apR0.clear(); apR1.clear()
        erAirLpL = 0; erAirLpR = 0
        erMudHpL = 0; erMudHpR = 0
        lp0 = 0; lp1 = 0; lp2 = 0; lp3 = 0; lp4 = 0; lp5 = 0; lp6 = 0; lp7 = 0
        hp0 = 0; hp1 = 0; hp2 = 0; hp3 = 0; hp4 = 0; hp5 = 0; hp6 = 0; hp7 = 0
    }
}

// MARK: - Audiophile Master Bus (Sub-Monoizer + Tube Polish + RMS Optical Glue + 2.5ms Lookahead Limiter)

struct AudiophileMasterBus: Sendable {
    // 24 dB/oct Elliptical Vinyl-Mastering Filter (high-passes ONLY the Side channel below 185 Hz;
    // leaves Mid channel 100% phase-pure while locking sub-bass strictly mono > +0.985!)
    private var sideSubHp1 = CytomicSVF(cutoffHz: 185.0, q: 0.7071)
    private var sideSubHp2 = CytomicSVF(cutoffHz: 185.0, q: 0.7071)

    // 38 Hz ultra-low DC/subsonic cleaner + circadian anti-fatigue silk filter
    private var subCleanL = CytomicSVF(cutoffHz: 38.0, q: 0.7071)
    private var subCleanR = CytomicSVF(cutoffHz: 38.0, q: 0.7071)
    private var airLpL = CytomicSVF(cutoffHz: 7800.0, q: 0.65)
    private var airLpR = CytomicSVF(cutoffHz: 7800.0, q: 0.65)
    private var lastAirHz: Double = 7800.0

    // Gentle side-band clarity filter (>480 Hz stereo air)
    private var sideAirHp = CytomicSVF(cutoffHz: 480.0, q: 0.7071)

    // DC blocker after asymmetric even-order warmth
    private var dcL: Float = 0
    private var dcR: Float = 0

    // RMS optical glue compressor state (zero bass-fundamental ripple)
    private var rmsSq: Float = 0
    private var optoGain: Float = 1.0

    // 2.5 ms lookahead true-peak limiter (120 samples at 48 kHz)
    private let lookaheadSamples = 120
    private var laBufL: [Float]
    private var laBufR: [Float]
    private var laIdx: Int = 0
    private var limGain: Float = 1.0

    init() {
        laBufL = [Float](repeating: 0, count: 120)
        laBufR = [Float](repeating: 0, count: 120)
    }

    @inline(__always)
    mutating func process(
        _ inL: Float,
        _ inR: Float,
        airCeilingHz: Double,
        stereoWidthBoost: Float = 0.12,
        outputGain: Float = 2.05,
        postMatrixInjectL: Float = 0,
        postMatrixInjectR: Float = 0,
        sampleRate: Double = 48_000.0
    ) -> (Float, Float) {
        if abs(airCeilingHz - lastAirHz) > 40.0 {
            lastAirHz = airCeilingHz
            airLpL.set(cutoffHz: airCeilingHz, q: 0.62, sampleRate: sampleRate)
            airLpR.set(cutoffHz: airCeilingHz, q: 0.62, sampleRate: sampleRate)
        }

        // 1. Clean subsonic DC (<38 Hz) while preserving genuine tactile 50-90 Hz bass
        let cleanL = subCleanL.highpass(inL)
        let cleanR = subCleanR.highpass(inR)

        // 2. Elliptical Vinyl Mastering Mid/Side Matrix:
        //    - Mid stays 100% phase-intact
        //    - Side is surgically high-passed 24 dB/oct below 155 Hz -> strict mono sub-bass (> +0.995)
        //    - Subtle stereo air bloom above 480 Hz
        let mid = 0.5 * (cleanL + cleanR)
        let rawSide = 0.5 * (cleanL - cleanR)
        let monoSubSide = sideSubHp2.highpass(sideSubHp1.highpass(rawSide))
        let airSide = sideAirHp.highpass(monoSubSide)
        let finalSide = monoSubSide + airSide * stereoWidthBoost
        var mixL = mid + finalSide
        var mixR = mid - finalSide

        // 3. Ultra-subtle even-order transformer warmth (-44 dB 2nd harmonic, DC-blocked)
        let wL = mixL + 0.022 * mixL * mixL
        let wR = mixR + 0.022 * mixR * mixR
        dcL += (wL - dcL) * 0.0005
        dcR += (wR - dcR) * 0.0005
        mixL = airLpL.lowpass(wL - dcL)
        mixR = airLpR.lowpass(wR - dcR)

        // 4. Calibrated gain staging before RMS Optical Glue Compressor (-17 dBFS target RMS)
        mixL *= outputGain
        mixR *= outputGain

        let sq = 0.5 * (mixL * mixL + mixR * mixR)
        rmsSq += (sq - rmsSq) * 0.0006 // ~35ms RMS window at 48 kHz
        let rms = sqrt(max(1e-12, rmsSq))
        let threshold: Float = 0.14 // ~-17 dBFS RMS
        let targetGain: Float
        if rms > threshold {
            let over = rms / threshold
            targetGain = pow(over, -0.44) // ~1.8:1 soft optical ratio
        } else {
            targetGain = 1.0
        }
        let coeff: Float = targetGain < optoGain ? 0.00055 : 0.00008 // ~38ms attack, ~260ms optical release
        optoGain += (targetGain - optoGain) * coeff

        let gluedL = mixL * optoGain + postMatrixInjectL
        let gluedR = mixR * optoGain + postMatrixInjectR

        // 5. 2.5ms Lookahead True-Peak Limiter (ceiling -1.0 dBFS = 0.891)
        let ceiling: Float = 0.891
        let aheadPeak = max(abs(gluedL), abs(gluedR))
        let neededGain: Float = aheadPeak > ceiling ? (ceiling / aheadPeak) : 1.0
        if neededGain < limGain {
            limGain += (neededGain - limGain) * 0.055
        } else {
            limGain += (neededGain - limGain) * 0.00016
        }

        let delayedL = laBufL[laIdx]
        let delayedR = laBufR[laIdx]
        laBufL[laIdx] = gluedL
        laBufR[laIdx] = gluedR
        laIdx += 1
        if laIdx >= lookaheadSamples { laIdx = 0 }

        // Soft safety guard guarantees strict <= 0.90 ceiling even on sudden discontinuities
        let outL = tanh(delayedL * limGain / 0.94) * 0.94
        let outR = tanh(delayedR * limGain / 0.94) * 0.94
        return (outL, outR)
    }

    mutating func clear() {
        sideSubHp1.reset(); sideSubHp2.reset()
        subCleanL.reset(); subCleanR.reset()
        airLpL.reset(); airLpR.reset()
        sideAirHp.reset()
        dcL = 0; dcR = 0
        rmsSq = 0; optoGain = 1.0
        for i in 0..<lookaheadSamples { laBufL[i] = 0; laBufR[i] = 0 }
        laIdx = 0; limGain = 1.0
    }
}

// MARK: - Velvet Brown-Pink Acoustic Speech-Masking Curtain (Endel Colored Noise / Cafe Cocoon)

/// Stereo-decorrelated warm brown/pink noise sculpted specifically for zero-fatigue speech masking:
/// - 90 Hz HPF removes muddy boom
/// - Silky 1.35 kHz Cytomic lowpass + warm 280 Hz acoustic warmth removes all white-noise hiss
/// - Gentle incommensurate atmospheric breathing so it feels like a warm wooden room or distant surf
struct VelvetBrownNoise: Sendable {
    private var rng = FastNoiseRNG(seed: 0xB804_704E_CAFE)
    private var brL: Float = 0
    private var brR: Float = 0
    private var lpL = CytomicSVF(cutoffHz: 1250, q: 0.62)
    private var lpR = CytomicSVF(cutoffHz: 1250, q: 0.62)
    private var hpL = CytomicSVF(cutoffHz: 95, q: 0.707)
    private var hpR = CytomicSVF(cutoffHz: 95, q: 0.707)
    private var tick: Int = 0

    mutating func reset() {
        brL = 0; brR = 0
        lpL.reset(); lpR.reset()
        hpL.reset(); hpR.reset()
    }

    @inline(__always)
    mutating func step(clockSec: Double, brightnessScale: Double = 1.0, sampleRate: Double = 48_000.0) -> (Float, Float) {
        if (tick & 127) == 0 {
            let breath = 0.5 + 0.5 * sin(clockSec * 0.09) * cos(clockSec * 0.041)
            let cut = (780.0 + breath * 520.0) * max(0.55, min(1.35, brightnessScale))
            lpL.set(cutoffHz: cut, q: 0.60, sampleRate: sampleRate)
            lpR.set(cutoffHz: cut * 0.96, q: 0.60, sampleRate: sampleRate)
        }
        tick &+= 1

        // Independent leaky Brownian integrators for rich natural stereo decorrelation
        let wL = rng.nextBipolar()
        let wR = rng.nextBipolar()
        brL = brL * 0.986 + wL * 0.045
        brR = brR * 0.986 + wR * 0.045

        // Soft warm cross-mix (keeps center cozy, peripherals wide)
        let fL = hpL.highpass(lpL.lowpass(brL))
        let fR = hpR.highpass(lpR.lowpass(brR))
        let outL = (fL * 0.84 + fR * 0.16) * 0.16
        let outR = (fR * 0.84 + fL * 0.16) * 0.16
        return (outL, outR)
    }
}
