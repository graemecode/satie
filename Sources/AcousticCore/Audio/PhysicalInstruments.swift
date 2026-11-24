import Foundation

// MARK: - Precomputed Band-Limited Harmonic Wavetables

final class TimbreBank: @unchecked Sendable {
    static let tableSize = 1024
    static let tableMask = tableSize - 1

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

        // Warm acoustic bass harmonics
        let bassWeights: [Double] = [0, 1.0, 0.58, 0.30, 0.12, 0.05]
        self.bassTable = Self.buildTable(maxHarmonic: 5) { h, _ in bassWeights[h] }

        // Lush Juno/Prophet-style warm harmonic pad table
        self.padTable = Self.buildTable(maxHarmonic: 20, baseHz: 220.0) { h, f in
            let oddBoost = (h % 2 == 1) ? 1.15 : 0.85
            return (oddBoost / Double(h)) / sqrt(1.0 + pow(f / 680.0, 2.0))
        }

        // 3-peak wooden violin/cello body formant resonance (520 Hz, 1150 Hz, 2900 Hz)
        let bump: (Double, Double, Double) -> Double = { freq, center, width in
            let d = log2(max(1.0, freq) / center) / width
            return exp(-0.5 * d * d)
        }
        let stringPartial: (Int, Double) -> Double = { h, f in
            let body = 1.0
                + 0.90 * bump(f, 520.0, 0.35)
                + 0.72 * bump(f, 1150.0, 0.30)
                + 0.55 * bump(f, 2900.0, 0.30)
            return (body / Double(h) / sqrt(1.0 + pow(f / 2900.0, 2.0))) * 0.5
        }
        self.stringTables = [
            Self.buildTable(maxHarmonic: 24, baseHz: 240.0, partial: stringPartial),
            Self.buildTable(maxHarmonic: 14, baseHz: 500.0, partial: stringPartial),
            Self.buildTable(maxHarmonic: 8,  baseHz: 1000.0, partial: stringPartial),
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

// MARK: - 1. Vactrol Glassy Bell (Soft Light: Buchla LPG + Physical Mallet + Stiff-String Partials)

struct VactrolBellVoice: Sendable {
    var active: Bool = false
    var isFigure: Bool = true
    var isGlint: Bool = false
    var age: Double = 0
    var maxAge: Double = 4.2
    var freq: Double = 440
    var driftCents: Double = 0
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
    var malletAmp: Float = 0
    var malletFilter = CytomicSVF(cutoffHz: 1800, q: 2.2)
    var lpg = VactrolLPG()
    var panL: Float = 0.707
    var panR: Float = 0.707

    mutating func trigger(event: ScoredBellEvent, rng: inout FastNoiseRNG, sampleRate: Double = 48_000.0) {
        let baseHz = AudioMath.railsbackHz(midi: event.midi, stretchAmount: 0.75)
        let thermalOffset = (rng.nextUnit() - 0.5) * 2.4 // ±1.2 cents analog warmth
        let f = baseHz * pow(2.0, thermalOffset / 1200.0)
        let ring = event.kind == .glint ? 0.55 : (1.1 + 0.60 * event.duration)
        let bright = event.kind == .melody ? 1.32 : (event.kind == .glint ? 0.0 : 1.0)

        active = true
        isFigure = (event.kind == .figure)
        isGlint = (event.kind == .glint)
        age = 0
        maxAge = ring * 4.5
        freq = f
        driftCents = thermalOffset
        phaseA = 0
        phaseB = 0
        modPhase = 0
        ov2Phase = 0
        ov4Phase = 0
        ov9Phase = 0
        hasOv9 = (!isGlint) && (f * 9.0 < 8800.0)
        level = Float(event.level)
        ringTau = ring
        fmPeak = (1.02 * bright * event.velocity + 0.08) * 0.40
        fmFloor = 0.07 * 0.40
        ov2Amp = isGlint ? 0 : 0.21
        ov4Amp = isGlint ? 0 : Float(0.28 * bright * event.velocity)
        ov9Amp = hasOv9 ? Float(0.14 * bright * event.velocity) : 0

        // Tactile physical mallet/felt exciter transient (~9 ms resonant knock)
        malletAmp = isGlint ? 0.0 : Float(0.16 * event.velocity)
        malletFilter.reset()
        malletFilter.set(cutoffHz: min(5200.0, max(420.0, f * 2.6)), q: 2.4, sampleRate: sampleRate)

        // Buchla Vactrol LPG contours both timbre and tail organically
        lpg.reset()
        let cutoffCeiling = isGlint ? 9000.0 : min(8200.0, max(1600.0, f * (4.5 + 3.2 * event.velocity)))
        lpg.trigger(
            velocity: max(0.35, event.velocity),
            decayScale: isGlint ? 0.65 : max(0.85, ring * 0.95),
            minCutoff: max(180.0, f * 1.15),
            maxCutoff: cutoffCeiling,
            resonance: 0.78
        )

        let angle = Float((event.pan + 1.0) * 0.25 * Double.pi)
        panL = cos(angle)
        panR = sin(angle)
    }

    @inline(__always)
    mutating func step(dt: Double, sampleRate: Double, sineTable: [Float], noise: inout FastNoiseRNG) -> (Float, Float) {
        guard active else { return (0, 0) }
        age += dt
        if age >= maxAge {
            active = false
            return (0, 0)
        }

        // Smooth S-curve attack (4 ms) + natural exponential ring
        let env: Float
        if age < 0.004 {
            env = Float(AudioMath.smoothstep(age / 0.004))
        } else {
            env = Float(exp(-(age - 0.004) / ringTau))
        }
        if env < 0.00018 {
            active = false
            return (0, 0)
        }

        let fmIndex = fmFloor + (fmPeak - fmFloor) * exp(-age / 0.36)
        modPhase += freq * dt
        if modPhase >= 1.0 { modPhase -= floor(modPhase) }
        let modVal = Double(TimbreBank.lookup(sineTable, phase01: modPhase)) * fmIndex

        // Subtle stiff-string inharmonicity (B = 0.00018 -> natural struck metal/tine shimmer)
        let detuneUp = 1.00145  // +2.5 cents
        let detuneDn = 0.99855  // -2.5 cents
        phaseA += freq * (isGlint ? 1.0 : detuneDn) * dt
        if phaseA >= 1.0 { phaseA -= floor(phaseA) }

        var sample: Float
        if isGlint {
            sample = TimbreBank.lookup(sineTable, phase01: phaseA + modVal * 0.08)
        } else {
            phaseB += freq * detuneUp * dt
            if phaseB >= 1.0 { phaseB -= floor(phaseB) }
            let cA = TimbreBank.lookup(sineTable, phase01: phaseA + modVal)
            let cB = TimbreBank.lookup(sineTable, phase01: phaseB + modVal)
            sample = 0.5 * (cA + cB)

            // Stretched partials: n * sqrt(1 + B*n^2)
            ov2Phase += freq * 2.00072 * dt
            if ov2Phase >= 1.0 { ov2Phase -= floor(ov2Phase) }
            sample += ov2Amp * Float(exp(-age / 0.85)) * TimbreBank.lookup(sineTable, phase01: ov2Phase)

            ov4Phase += freq * 4.00576 * dt
            if ov4Phase >= 1.0 { ov4Phase -= floor(ov4Phase) }
            sample += ov4Amp * Float(exp(-age / 0.25)) * TimbreBank.lookup(sineTable, phase01: ov4Phase)

            if hasOv9 {
                ov9Phase += freq * 9.065 * dt
                if ov9Phase >= 1.0 { ov9Phase -= floor(ov9Phase) }
                sample += ov9Amp * Float(exp(-age / 0.065)) * TimbreBank.lookup(sineTable, phase01: ov9Phase)
            }

            // Physical mallet/felt impact transient in first 14 ms
            if age < 0.015 && malletAmp > 0.001 {
                let mEnv = Float(exp(-age / 0.0032))
                sample += malletFilter.bandpass(noise.nextBipolar()) * malletAmp * mEnv
            }
        }

        // Blend 65% Buchla vactrol LPG warmth with 35% direct bell clarity
        let lpgOut = lpg.process(sample, dt: dt, sampleRate: sampleRate)
        let sculpted = (lpgOut * 0.65 + sample * env * 0.35) * level * 1.18
        return (sculpted * panL, sculpted * panR)
    }
}

// MARK: - 2. Felt Piano Physical Model (Gymnopédie / Kankyō Ongaku — Sakamoto / Nils Frahm)

/// Dual-unison fractional-delay Karplus-Strong waveguide felt upright piano:
/// - Soft felt hammer exciter (warm low-passed noise + woody mechanical thump)
/// - Two slightly detuned waveguides (-1.6c / +1.6c) with Railsback octave stretch
/// - 1st-order stiffness dispersion allpass + pitch-dependent loop damping inside the string
/// - Wooden soundboard resonance (240 Hz & 520 Hz)
struct FeltPianoVoice: Sendable {
    private static let bufCap = 2048
    private static let bufMask = 2047

    var active: Bool = false
    var age: Double = 0
    var releaseAt: Double = 2.8
    var maxAge: Double = 6.5
    var level: Float = 0
    var panL: Float = 0.707
    var panR: Float = 0.707

    private var strA: [Float]
    private var strB: [Float]
    private var wIdx: Int = 0
    private var delayA: Double = 109.0
    private var delayB: Double = 109.1
    private var dampA: Float = 0
    private var dampB: Float = 0
    private var dispA: Float = 0
    private var dispB: Float = 0
    private var dispPrevA: Float = 0
    private var dispPrevB: Float = 0
    private var loopDecay: Float = 0.996
    private var loopAlpha: Float = 0.25

    // Felt hammer + woody soundboard filters
    private var hammerLp = CytomicSVF(cutoffHz: 420, q: 0.72)
    private var woodKnock = CytomicSVF(cutoffHz: 210, q: 2.6)
    private var boardBody = CytomicSVF(cutoffHz: 440, q: 1.4)
    private var hammerVel: Float = 0.8

    init() {
        strA = [Float](repeating: 0, count: Self.bufCap)
        strB = [Float](repeating: 0, count: Self.bufCap)
    }

    mutating func trigger(event: ScoredBellEvent, rng: inout FastNoiseRNG, sampleRate: Double = 48_000.0) {
        let f = AudioMath.railsbackHz(midi: event.midi, stretchAmount: 1.0)
        let drift = pow(2.0, ((rng.nextUnit() - 0.5) * 1.8) / 1200.0)
        let fA = f * drift * 0.99907 // -1.6 cents unison detune (characteristic upright warmth)
        let fB = f * drift * 1.00093 // +1.6 cents

        delayA = max(12.0, min(Double(Self.bufCap - 8), sampleRate / fA - 0.5))
        delayB = max(12.0, min(Double(Self.bufCap - 8), sampleRate / fB - 0.5))

        // Higher notes decay naturally faster than bass strings (authentic acoustic decay curve)
        let pitchNorm = max(0.0, min(1.0, (Double(event.midi) - 40.0) / 48.0))
        loopDecay = Float(0.9986 - pitchNorm * 0.0024)
        // Soft felt muffling: lower loopAlpha = darker, warmer felt upright timbre
        loopAlpha = Float(0.18 + event.velocity * 0.14 - pitchNorm * 0.05)

        // Clear waveguide memory cleanly for new strike
        for i in 0..<Self.bufCap { strA[i] = 0; strB[i] = 0 }
        wIdx = 0
        dampA = 0; dampB = 0
        dispA = 0; dispB = 0
        dispPrevA = 0; dispPrevB = 0

        let hammerCut = min(1350.0, max(240.0, f * (1.5 + 1.8 * event.velocity)))
        hammerLp.reset()
        hammerLp.set(cutoffHz: hammerCut, q: 0.78, sampleRate: sampleRate)
        woodKnock.reset()
        woodKnock.set(cutoffHz: 185.0 + pitchNorm * 140.0, q: 2.4, sampleRate: sampleRate)
        boardBody.reset()
        boardBody.set(cutoffHz: 420.0 + pitchNorm * 180.0, q: 1.2, sampleRate: sampleRate)

        active = true
        age = 0
        releaseAt = max(1.2, event.duration * 1.6)
        maxAge = releaseAt + 3.2
        hammerVel = Float(event.velocity)
        level = Float(event.level) * 1.65

        let angle = Float((event.pan + 1.0) * 0.25 * Double.pi)
        panL = cos(angle)
        panR = sin(angle)
    }

    @inline(__always)
    private static func readFrac(_ buf: [Float], writeIdx: Int, delay: Double) -> Float {
        let pos = Double(writeIdx) - delay
        let i0 = Int(floor(pos)) & bufMask
        let i1 = (i0 + 1) & bufMask
        let frac = Float(pos - floor(pos))
        return buf[i0] + (buf[i1] - buf[i0]) * frac
    }

    @inline(__always)
    mutating func step(dt: Double, noise: inout FastNoiseRNG) -> (Float, Float) {
        guard active else { return (0, 0) }
        age += dt
        if age >= maxAge {
            active = false
            return (0, 0)
        }

        // 1. Soft felt hammer excitation pulse (~14 ms shaped noise + warm woody thump)
        var exc: Float = 0
        var thump: Float = 0
        if age < 0.018 {
            let phase = age / 0.018
            let feltShape = Float(sin(phase * Double.pi)) * hammerVel
            let rawN = noise.nextBipolar()
            exc = hammerLp.lowpass(rawN) * feltShape * 0.62
            thump = woodKnock.bandpass(rawN) * Float(exp(-age / 0.0055)) * hammerVel * 0.16
        }

        // 2. Fractional Karplus-Strong waveguide read
        let rA = Self.readFrac(strA, writeIdx: wIdx, delay: delayA)
        let rB = Self.readFrac(strB, writeIdx: wIdx, delay: delayB)

        // 3. Soft damper release after sustain window
        let damper: Float = age > releaseAt ? 0.9925 : loopDecay

        // 4. Felt loop damping + 1st-order allpass stiffness dispersion (c = 0.22)
        dampA += (rA - dampA) * loopAlpha
        dampB += (rB - dampB) * loopAlpha
        let c: Float = 0.22
        let yA = c * dampA + dispPrevA - c * dispA
        dispPrevA = dampA; dispA = yA
        let yB = c * dampB + dispPrevB - c * dispB
        dispPrevB = dampB; dispB = yB

        strA[wIdx] = exc + yA * damper
        strB[wIdx] = exc * 0.96 + yB * damper
        wIdx = (wIdx + 1) & Self.bufMask

        // 5. Combine unison strings + woody soundboard resonance + gentle felt thump
        let rawStr = 0.5 * (rA + rB)
        let body = boardBody.bandpass(rawStr) * 0.22
        let fadeOut: Float = age > (maxAge - 0.35) ? Float(AudioMath.smoothstep((maxAge - age) / 0.35)) : 1.0
        let out = (rawStr + body + thump) * level * fadeOut

        // Subtle stereo spread between unison strings (creates intimate close-mic'd piano width)
        let sL = out * panL + (rA - rB) * level * 0.14
        let sR = out * panR - (rA - rB) * level * 0.14
        return (sL, sR)
    }
}

// MARK: - 3. Analog Hypnotic Synth Voice (Kinetic Pulse — Donato Dozzy / Floating Points)

/// Dual PolyBLEP anti-aliased analog VCO + Cytomic ZDF 2-pole resonant lowpass filter
/// + optional Buchla Vactrol pluck for hypnotic polyrhythmic counter-accents.
struct AnalogHypnoticVoice: Sendable {
    var active: Bool = false
    var isPluck: Bool = false
    var age: Double = 0
    var maxAge: Double = 2.0
    var freq: Double = 220
    var phaseSaw: Double = 0
    var phaseSub: Double = 0
    var pwmPhase: Double = 0
    var ampTau: Double = 0.45
    var fltTau: Double = 0.22
    var fltBaseHz: Double = 240
    var fltPeakHz: Double = 2400
    var fltQ: Double = 1.8
    var level: Float = 0
    var panL: Float = 0.707
    var panR: Float = 0.707
    private var svf = CytomicSVF(cutoffHz: 800, q: 1.8)
    private var lpg = VactrolLPG()
    private var stepCounter: Int = 0

    mutating func trigger(
        event: ScoredBellEvent,
        filterHorizon: Double,
        resonanceBoost: Double,
        isPluck: Bool,
        rng: inout FastNoiseRNG,
        sampleRate: Double = 48_000.0
    ) {
        let baseHz = 440.0 * pow(2.0, Double(event.midi - 69) / 12.0)
        let drift = pow(2.0, ((rng.nextUnit() - 0.5) * 3.0) / 1200.0)
        freq = baseHz * drift
        active = true
        self.isPluck = isPluck
        age = 0
        ampTau = isPluck ? (0.18 + 0.25 * event.duration) : (0.32 + 0.45 * event.duration)
        maxAge = ampTau * 4.5
        phaseSaw = rng.nextUnit() * 0.25
        phaseSub = 0
        pwmPhase = rng.nextUnit()
        fltTau = isPluck ? 0.14 : (0.19 + 0.18 * event.velocity)
        fltBaseHz = max(145.0, freq * 1.12)
        // Stay strictly below the 3.1 kHz ear-canal fatigue peak for hours-long creamy analog warmth
        fltPeakHz = min(2750.0, freq * (2.4 + 3.0 * event.velocity * filterHorizon))
        fltQ = 0.85 + 0.52 * resonanceBoost
        level = Float(event.level) * (isPluck ? 1.04 : 0.90)
        stepCounter = 0

        svf.reset()
        svf.set(cutoffHz: fltPeakHz, q: fltQ, sampleRate: sampleRate)
        if isPluck {
            lpg.reset()
            lpg.trigger(
                velocity: event.velocity,
                decayScale: 0.55,
                minCutoff: max(160.0, freq * 1.2),
                maxCutoff: min(6400.0, fltPeakHz * 1.15),
                resonance: 1.05
            )
        }

        let angle = Float((event.pan + 1.0) * 0.25 * Double.pi)
        panL = cos(angle)
        panR = sin(angle)
    }

    @inline(__always)
    mutating func step(dt: Double, sampleRate: Double, sineTable: [Float]) -> (Float, Float) {
        guard active else { return (0, 0) }
        age += dt
        if age >= maxAge {
            active = false
            return (0, 0)
        }

        let env: Float
        if age < 0.011 {
            env = Float(AudioMath.smoothstep(age / 0.011))
        } else {
            env = Float(exp(-(age - 0.011) / ampTau))
        }
        if env < 0.0002 {
            active = false
            return (0, 0)
        }

        // Silky Prophet/Juno blend: warm Triangle + Pure Sine core + gentle PolyBLEP Saw harmonics
        let inc = freq * dt
        phaseSaw += inc
        if phaseSaw >= 1.0 { phaseSaw -= 1.0 }
        let saw = Float((2.0 * phaseSaw - 1.0) - AudioMath.polyBLEP(phase: phaseSaw, dt: inc))
        let pureSine = TimbreBank.lookup(sineTable, phase01: phaseSaw)

        phaseSub += freq * 0.5 * dt
        if phaseSub >= 1.0 { phaseSub -= 1.0 }
        let tri = Float(1.0 - 4.0 * abs(phaseSub - 0.5))

        let raw: Float
        if isPluck {
            // West Coast sine-folded woody pluck
            raw = sin(pureSine * 1.55) * 0.68 + saw * 0.18 + tri * 0.24
            let gated = lpg.process(raw, dt: dt, sampleRate: sampleRate) * level * 1.20
            return (gated * panL, gated * panR)
        } else {
            raw = saw * 0.30 + tri * 0.46 + pureSine * 0.24
            if (stepCounter & 3) == 0 {
                let fc = fltBaseHz + (fltPeakHz - fltBaseHz) * exp(-age / fltTau)
                svf.set(cutoffHz: fc, q: fltQ, sampleRate: sampleRate)
            }
            stepCounter &+= 1
            let filtered = svf.lowpass(raw) * env * level
            return (filtered * panL, filtered * panR)
        }
    }
}

// MARK: - 4. Crystal Singing Bowl (Rain & Glass — Yoshimura Green Modal Resonator)

/// 4-mode physical Euler-Bernoulli / Chladni singing-bowl resonator (ratios 1.0, 2.756, 5.404, 8.933)
/// with acoustic 1.2 Hz binaural beating on the fundamental.
struct CrystalGlassBowlVoice: Sendable {
    var active: Bool = false
    var age: Double = 0
    var maxAge: Double = 6.5
    var freq: Double = 440
    var p0a: Double = 0, p0b: Double = 0, p1: Double = 0, p2: Double = 0, p3: Double = 0
    var attackSec: Double = 0.14
    var tau: Double = 2.0
    var level: Float = 0
    var panL: Float = 0.707
    var panR: Float = 0.707

    mutating func trigger(event: ScoredBellEvent, rng: inout FastNoiseRNG) {
        let baseHz = 440.0 * pow(2.0, Double(event.midi - 69) / 12.0)
        freq = baseHz * pow(2.0, ((rng.nextUnit() - 0.5) * 1.5) / 1200.0)
        active = true
        age = 0
        attackSec = event.kind == .glint ? 0.015 : 0.16
        tau = event.kind == .glint ? 0.65 : (1.7 + 0.85 * event.duration)
        maxAge = attackSec + tau * 4.5
        p0a = 0; p0b = 0.17; p1 = 0; p2 = 0; p3 = 0
        level = Float(event.level) * (event.kind == .glint ? 1.15 : 1.35)

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
        if age < attackSec {
            env = Float(AudioMath.smoothstep(age / attackSec))
        } else {
            env = Float(exp(-(age - attackSec) / tau))
        }
        if env < 0.00018 {
            active = false
            return (0, 0)
        }

        // Physical Chladni / singing-bowl eigenmodes with subtle fundamental acoustic beat
        p0a += freq * dt; if p0a >= 1.0 { p0a -= floor(p0a) }
        p0b += (freq + 1.15) * dt; if p0b >= 1.0 { p0b -= floor(p0b) }
        p1  += freq * 2.756 * dt; if p1 >= 1.0 { p1 -= floor(p1) }
        p2  += freq * 5.404 * dt; if p2 >= 1.0 { p2 -= floor(p2) }

        var s = (TimbreBank.lookup(sineTable, phase01: p0a) * 0.62
               + TimbreBank.lookup(sineTable, phase01: p0b) * 0.38)
        s += TimbreBank.lookup(sineTable, phase01: p1) * 0.18 * Float(exp(-age / (tau * 0.42)))
        if freq * 5.404 < 9000.0 {
            s += TimbreBank.lookup(sineTable, phase01: p2) * 0.06 * Float(exp(-age / (tau * 0.16)))
        }
        if freq * 8.933 < 9500.0 {
            p3 += freq * 8.933 * dt; if p3 >= 1.0 { p3 -= floor(p3) }
            s += TimbreBank.lookup(sineTable, phase01: p3) * 0.025 * Float(exp(-age / 0.09))
        }

        let sig = s * env * level
        return (sig * panL, sig * panR)
    }
}

// MARK: - 5. Three-Layer Physical Acoustic Rain Engine (Far Sheet + Minnaert Poisson Droplets + Close Taps)

private struct RainDroplet: Sendable {
    var active: Bool = false
    var age: Double = 0
    var maxAge: Double = 0.02
    var baseFreq: Double = 1600
    var phase: Double = 0
    var tau: Double = 0.004
    var amp: Float = 0
    var panL: Float = 0.707
    var panR: Float = 0.707

    mutating func spawn(rng: inout FastNoiseRNG, closeTap: Bool) {
        active = true
        age = 0
        phase = 0
        if closeTap {
            // Subtle architectural wood-eave / windowpane tick
            baseFreq = 460.0 + rng.nextUnit() * 780.0
            tau = 0.0028 + rng.nextUnit() * 0.0035
            maxAge = tau * 5.0
            amp = Float(0.020 + rng.nextUnit() * 0.026)
            let edge = rng.nextUnit() < 0.5 ? -0.78 : 0.78
            let pan = edge + (rng.nextUnit() - 0.5) * 0.25
            let angle = Float((pan + 1.0) * 0.25 * Double.pi)
            panL = cos(angle); panR = sin(angle)
        } else {
            // Minnaert resonant water-bubble droplet (upward chirp gives unmistakable wet realism)
            baseFreq = 880.0 + pow(rng.nextUnit(), 1.6) * 2800.0
            tau = 0.0032 + rng.nextUnit() * 0.0055
            maxAge = tau * 5.5
            amp = Float(0.014 + rng.nextUnit() * 0.028)
            let pan = (rng.nextUnit() * 2.0 - 1.0) * 0.85
            let angle = Float((pan + 1.0) * 0.25 * Double.pi)
            panL = cos(angle); panR = sin(angle)
        }
    }

    @inline(__always)
    mutating func step(dt: Double, sineTable: [Float]) -> (Float, Float) {
        guard active else { return (0, 0) }
        age += dt
        if age >= maxAge {
            active = false
            return (0, 0)
        }
        // Minnaert bubble cavity contraction: frequency rises ~32% during decay
        let chirpFreq = baseFreq * (1.0 + 0.32 * (1.0 - exp(-age / 0.0042)))
        phase += chirpFreq * dt
        if phase >= 1.0 { phase -= floor(phase) }
        let env = Float(min(1.0, age / 0.0004) * exp(-age / tau))
        let s = TimbreBank.lookup(sineTable, phase01: phase) * env * amp
        return (s * panL, s * panR)
    }
}

private struct PinkChannel: Sendable {
    private var b0: Float = 0, b1: Float = 0, b2: Float = 0, b3: Float = 0, b4: Float = 0, b5: Float = 0, b6: Float = 0
    private var br: Float = 0
    private var lp = CytomicSVF(cutoffHz: 1100, q: 0.65)
    private var hp = CytomicSVF(cutoffHz: 140, q: 0.707)

    @inline(__always)
    mutating func next(rng: inout FastNoiseRNG, cutoffHz: Double, updateFilter: Bool, sampleRate: Double) -> Float {
        if updateFilter {
            lp.set(cutoffHz: cutoffHz, q: 0.65, sampleRate: sampleRate)
        }
        let white = rng.nextBipolar() * 0.5
        b0 = 0.99886 * b0 + white * 0.0555179
        b1 = 0.99332 * b1 + white * 0.0750759
        b2 = 0.96900 * b2 + white * 0.1538520
        b3 = 0.86650 * b3 + white * 0.3104856
        b4 = 0.55000 * b4 + white * 0.5329522
        b5 = -0.7616 * b5 - white * 0.0168980
        let pink = (b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362) * 0.048
        b6 = white * 0.115926
        br += (pink - br) * 0.014
        return hp.highpass(lp.lowpass(pink) * 0.72 + br * 0.88)
    }
}

struct PhysicalRainEngine: Sendable {
    private var rng = FastNoiseRNG(seed: 0x5A71E_BA11_CAFE)
    private var sheetL = PinkChannel()
    private var sheetR = PinkChannel()
    private var droplets = [RainDroplet](repeating: RainDroplet(), count: 10)
    private var nextDropSlot = 0
    private var sampleCounter = 0

    @inline(__always)
    mutating func step(clockSec: Double, dt: Double, sampleRate: Double, sineTable: [Float]) -> (Float, Float) {
        let updateF = (sampleCounter & 63) == 0
        sampleCounter &+= 1

        // Slow atmospheric wind-gust breathing across two incommensurate sine cycles
        let swellL = 0.5 + 0.5 * sin(clockSec * 0.17) * cos(clockSec * 0.071)
        let swellR = 0.5 + 0.5 * sin(clockSec * 0.19 + 1.3) * cos(clockSec * 0.063)
        let cutL = 780.0 + swellL * 680.0
        let cutR = 760.0 + swellR * 680.0

        var outL = sheetL.next(rng: &rng, cutoffHz: cutL, updateFilter: updateF, sampleRate: sampleRate) * 0.44
        var outR = sheetR.next(rng: &rng, cutoffHz: cutR, updateFilter: updateF, sampleRate: sampleRate) * 0.44

        // Poisson stochastic droplet arrivals (~18 drops/sec + ~2.2 close window taps/sec)
        let u = rng.nextUnit()
        let dropRate = (16.0 + 8.0 * swellL) * dt
        if u < dropRate {
            droplets[nextDropSlot].spawn(rng: &rng, closeTap: false)
            nextDropSlot = (nextDropSlot + 1) % droplets.count
        } else if u < dropRate + 2.2 * dt {
            droplets[nextDropSlot].spawn(rng: &rng, closeTap: true)
            nextDropSlot = (nextDropSlot + 1) % droplets.count
        }

        for d in 0..<droplets.count where droplets[d].active {
            let (dL, dR) = droplets[d].step(dt: dt, sineTable: sineTable)
            outL += dL
            outR += dR
        }

        return (outL, outR)
    }
}

// MARK: - 6. Warm 3-Player Ensemble Strings & Just-Intonation Wide Pad

struct EnsembleStringVoice: Sendable {
    var active: Bool = false
    var age: Double = 0
    var totalDuration: Double = 6.0
    var rise: Double = 1.25
    var fall: Double = 1.65
    var freq: Double = 440
    var tableIndex: Int = 1
    var level: Float = 0
    var panL: Float = 0.707
    var panR: Float = 0.707

    var p0: Double = 0, p1: Double = 0, p2: Double = 0
    var d0: Double = 1, d1: Double = 1, d2: Double = 1
    var vPhase0: Double = 0, vPhase1: Double = 0, vPhase2: Double = 0
    var vRate0: Double = 5.1, vRate1: Double = 5.4, vRate2: Double = 5.8
    var vDepth0: Double = 0.003, vDepth1: Double = 0.003, vDepth2: Double = 0.003
    private var rosinFilter = CytomicSVF(cutoffHz: 2100, q: 2.2)

    mutating func trigger(event: ScoredSustainEvent, rootMidi: Int, rng: inout FastNoiseRNG, sampleRate: Double = 48_000.0) {
        let f = AudioMath.justSweetenedHz(midi: event.midi, rootMidi: rootMidi, blend: 0.55)
        active = true
        age = 0
        totalDuration = event.duration + 1.9
        rise = min(1.3, totalDuration * 0.40)
        fall = min(1.6, totalDuration * 0.50)
        freq = f
        tableIndex = f < 380 ? 0 : (f < 780 ? 1 : 2)
        level = Float(event.level)

        let angle = Float((event.pan + 1.0) * 0.25 * Double.pi)
        panL = cos(angle)
        panR = sin(angle)

        p0 = rng.nextUnit(); p1 = rng.nextUnit(); p2 = rng.nextUnit()
        d0 = pow(2.0, ((rng.nextUnit() * 2.0 - 1.0) * 8.5) / 1200.0)
        d1 = pow(2.0, ((rng.nextUnit() * 2.0 - 1.0) * 8.5) / 1200.0)
        d2 = pow(2.0, ((rng.nextUnit() * 2.0 - 1.0) * 8.5) / 1200.0)
        vPhase0 = rng.nextUnit(); vPhase1 = rng.nextUnit(); vPhase2 = rng.nextUnit()
        vRate0 = 4.8 + rng.nextUnit() * 1.1
        vRate1 = 4.8 + rng.nextUnit() * 1.1
        vRate2 = 4.8 + rng.nextUnit() * 1.1
        vDepth0 = (3.8 + rng.nextUnit() * 3.0) / 1731.2
        vDepth1 = (3.8 + rng.nextUnit() * 3.0) / 1731.2
        vDepth2 = (3.8 + rng.nextUnit() * 3.0) / 1731.2

        rosinFilter.reset()
        rosinFilter.set(cutoffHz: min(3600.0, max(900.0, f * 3.2)), q: 2.0, sampleRate: sampleRate)
    }

    @inline(__always)
    mutating func step(dt: Double, bank: TimbreBank, noise: inout FastNoiseRNG) -> (Float, Float) {
        guard active else { return (0, 0) }
        age += dt
        if age >= totalDuration {
            active = false
            return (0, 0)
        }

        // Smooth S-curve bow swell & release (zero piecewise-linear corners)
        let env: Double
        if age < rise {
            env = AudioMath.smoothstep(age / max(0.01, rise))
        } else if age > totalDuration - fall {
            env = AudioMath.smoothstep((totalDuration - age) / max(0.01, fall))
        } else {
            env = 1.0
        }

        let vibRamp = AudioMath.smoothstep(age / max(0.25, rise + 0.35))
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
        let v0 = TimbreBank.lookup(tbl, phase01: p0)
        let v1 = TimbreBank.lookup(tbl, phase01: p1)
        let v2 = TimbreBank.lookup(tbl, phase01: p2)

        // Subtle bow-hair rosin air during initial bow draw
        let rosin = (age < rise) ? rosinFilter.bandpass(noise.nextBipolar()) * Float(0.022 * (1.0 - age / rise)) : 0.0

        // Natural 3-player ensemble spatial seating (player 0 slightly left, player 1 center, player 2 slightly right)
        let sumL = (v0 * 0.42 + v1 * 0.34 + v2 * 0.24 + rosin) * Float(env) * level
        let sumR = (v0 * 0.24 + v1 * 0.34 + v2 * 0.42 + rosin) * Float(env) * level
        return (sumL * (0.75 + 0.35 * panL), sumR * (0.75 + 0.35 * panR))
    }
}

struct JustIntonationPadBassVoice: Sendable {
    var active: Bool = false
    var isBass: Bool = false
    var age: Double = 0
    var duration: Double = 4.0
    var freq: Double = 220
    var phaseL: Double = 0
    var phaseR: Double = 0
    var level: Float = 0

    mutating func trigger(event: ScoredSustainEvent, rootMidi: Int, rng: inout FastNoiseRNG) {
        isBass = (event.kind == .bass)
        // Sweeten sustained pad chords 65% toward 5-limit Just Intonation (pure harmonic lock, zero beating!)
        let baseHz = isBass
            ? 440.0 * pow(2.0, Double(event.midi - 69) / 12.0)
            : AudioMath.justSweetenedHz(midi: event.midi, rootMidi: rootMidi, blend: 0.65)
        let drift = pow(2.0, ((rng.nextUnit() - 0.5) * 1.4) / 1200.0)

        active = true
        age = 0
        duration = event.duration + (isBass ? 0.45 : 0.25)
        freq = baseHz * drift
        phaseL = isBass ? 0.0 : rng.nextUnit()
        phaseR = isBass ? 0.0 : (phaseL + 0.17)
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
            if age < 0.015 {
                env = Float(AudioMath.smoothstep(age / 0.015)) * 0.48
            } else if age < duration - 0.45 {
                env = Float(0.18 + 0.30 * exp(-(age - 0.015) / 1.1))
            } else {
                let tail = age - (duration - 0.45)
                env = Float(0.18 * exp(-tail / 0.08))
            }
            phaseL += freq * dt
            if phaseL >= 1.0 { phaseL -= floor(phaseL) }
            let s = TimbreBank.lookup(bank.bassTable, phase01: phaseL) * env * level
            return (s, s)
        } else {
            let fade = min(1.8, duration * 0.48)
            let env: Double
            if age < fade {
                env = AudioMath.smoothstep(age / max(0.01, fade))
            } else if age > duration - fade {
                env = AudioMath.smoothstep((duration - age) / max(0.01, fade))
            } else {
                env = 1.0
            }
            // Wide -4.5c / +4.5c analog stereo pad
            phaseL += freq * 0.99740 * dt; if phaseL >= 1.0 { phaseL -= floor(phaseL) }
            phaseR += freq * 1.00260 * dt; if phaseR >= 1.0 { phaseR -= floor(phaseR) }
            let vL = TimbreBank.lookup(bank.padTable, phase01: phaseL) * Float(env) * level
            let vR = TimbreBank.lookup(bank.padTable, phase01: phaseR) * Float(env) * level
            return (vL * 0.84 + vR * 0.30, vR * 0.84 + vL * 0.30)
        }
    }
}

// MARK: - 7. Hypnotic Sub-Pulse + Organic Micro-Percussion (Kinetic Pulse Groove Engine)

struct HypnoticGrooveEngine: Sendable {
    private var kickAge: Double = 10.0
    private var kickPhase: Double = 0
    private var shakerAge: Double = 10.0
    private var shakerPan: Float = 0.0
    private var shakerFilter = CytomicSVF(cutoffHz: 2400, q: 1.5)
    private var lastSubStep: Int = -1
    private var sidechainEnv: Float = 0 // smooth optical ducking envelope (zero hard click/thump)

    mutating func reset() {
        kickAge = 10.0
        shakerAge = 10.0
        lastSubStep = -1
        sidechainEnv = 0
        shakerFilter.reset()
    }

    /// Returns `(subMono, percL, percR, sidechainDuckGain)` where `sidechainDuckGain` ∈ [0.84, 1.0]
    @inline(__always)
    mutating func step(
        clockSec: Double,
        spb: Double,
        dt: Double,
        sampleRate: Double,
        sineTable: [Float],
        noise: inout FastNoiseRNG
    ) -> (sub: Float, percL: Float, percR: Float, sidechainGain: Float) {
        // 16th-note grid with subtle 54% micro-swing on off-16ths
        let sixteenth = spb * 0.25
        let rawStep = Int(floor(clockSec / sixteenth))
        let fracInStep = (clockSec / sixteenth) - Double(rawStep)
        // Trigger off-16ths slightly late (+0.08 of a 16th -> classic warm micro-swing)
        let isSwingStep = (rawStep % 2) == 1
        let triggerStep = isSwingStep ? (fracInStep >= 0.08 ? rawStep : rawStep - 1) : rawStep

        if triggerStep != lastSubStep && triggerStep >= 0 {
            lastSubStep = triggerStep
            let stepInBar = triggerStep % 16
            // Phase-locked soft felt studio pulse on beats 1 and 3 (steps 0 and 8)
            if stepInBar == 0 || stepInBar == 8 {
                kickAge = 0
                kickPhase = 0
            }
            // Whisper-quiet organic brushed micro-shaker on swung off-beats (steps 2, 6, 10, 14, plus ghost 15)
            if stepInBar == 2 || stepInBar == 6 || stepInBar == 10 || stepInBar == 14 || stepInBar == 15 {
                shakerAge = 0
                let isGhost = (stepInBar == 15)
                shakerPan = (stepInBar % 4 == 2) ? -0.32 : 0.32
                let fc = isGhost ? 2000.0 : (2400.0 + rngFreqJitter(noise: &noise))
                shakerFilter.set(cutoffHz: fc, q: 1.55, sampleRate: sampleRate)
            }
        }

        // 1. Round felt-mallet studio kick (60 Hz warm body, 14ms soft attack, zero ear-canal pressure)
        var sub: Float = 0
        if kickAge < 0.28 {
            let kFreq = 60.0 + 42.0 * exp(-kickAge * 28.0)
            kickPhase += kFreq * dt
            if kickPhase >= 1.0 { kickPhase -= floor(kickPhase) }
            let kEnv = Float(AudioMath.smoothstep(kickAge / 0.014) * exp(-kickAge * 10.5))
            sub = TimbreBank.lookup(sineTable, phase01: kickPhase) * kEnv * 0.086
            kickAge += dt
        }

        // 2. Velvet brushed micro-shaker (soft 18 ms decay, below 3 kHz fatigue band)
        var pL: Float = 0
        var pR: Float = 0
        if shakerAge < 0.048 {
            let sEnv = Float(AudioMath.smoothstep(shakerAge / 0.004) * exp(-shakerAge / 0.014))
            let br = shakerFilter.bandpass(noise.nextBipolar()) * sEnv * 0.019
            let angle = Float((Double(shakerPan) + 1.0) * 0.25 * Double.pi)
            pL = br * cos(angle)
            pR = br * sin(angle)
            shakerAge += dt
        }

        // 3. Smooth optical tape-bus breathing (16ms smooth attack + 180ms release -> gentle -1.5 dB max)
        let targetDuck: Float = (kickAge < 0.045) ? 1.0 : 0.0
        let coeff: Float = targetDuck > sidechainEnv ? Float(1.0 - exp(-dt / 0.016)) : Float(1.0 - exp(-dt / 0.180))
        sidechainEnv += (targetDuck - sidechainEnv) * coeff
        let scGain: Float = 1.0 - 0.16 * sidechainEnv
        return (sub, pL, pR, scGain)
    }

    @inline(__always)
    private func rngFreqJitter(noise: inout FastNoiseRNG) -> Double {
        (noise.nextUnit() - 0.5) * 450.0
    }
}
