import Foundation

// MARK: - 1. Mutable Instruments Rings-Inspired 64-Mode Physical Modal Resonator Bank

/// Single damped 2nd-order physical eigenmode (digital biquad/resonator with exact pole radius & frequency).
private struct Eigenmode: Sendable {
    var y1: Float = 0
    var y2: Float = 0
    var a1: Float = 0
    var a2: Float = 0
    var gain: Float = 0
    var active: Bool = false

    mutating func configure(freqHz: Double, decaySec: Double, amplitude: Double, sampleRate: Double) {
        guard freqHz > 20.0 && freqHz < sampleRate * 0.43 && amplitude > 0.0005 else {
            active = false
            gain = 0
            return
        }
        let omega = 2.0 * Double.pi * freqHz / sampleRate
        // Exact exponential pole radius r = exp(-3 / (decaySec * sr)) -> -60 dB at ~2.3*decaySec
        let r = exp(-3.0 / max(0.02, decaySec * sampleRate))
        a1 = Float(2.0 * r * cos(omega))
        a2 = Float(-(r * r))
        // Normalize resonator peak response by (1 - r) * sin(omega) so excitation energy stays uniform across pitch
        gain = Float(amplitude * (1.0 - r) * sin(omega) * 2.4)
        active = true
    }

    @inline(__always)
    mutating func tick(_ x: Float) -> Float {
        guard active else { return 0 }
        let y = gain * x + a1 * y1 + a2 * y2
        y2 = y1
        y1 = y
        return y
    }

    mutating func reset() {
        y1 = 0
        y2 = 0
    }
}

/// 16-mode single voice of a Mutable Instruments Rings-style modal resonator.
/// Supports continuous `structure` morphing (harmonic string -> wooden marimba -> glass/metal plate)
/// and physical wave-equation strike `position` node shaping: amp_n *= |sin(n * pi * position)|.
struct RingsVoice: Sendable {
    private static let modeCount = 14

    var active: Bool = false
    var age: Double = 0
    var maxAge: Double = 3.5
    var panL: Float = 0.707
    var panR: Float = 0.707
    var level: Float = 0
    private var exciterAge: Double = 0
    private var exciterAmp: Float = 0
    private var exciterFilter = CytomicSVF(cutoffHz: 1800, q: 1.4)
    private var modes: [Eigenmode]

    init() {
        self.modes = [Eigenmode](repeating: Eigenmode(), count: Self.modeCount)
    }

    /// Triggers the physical modal bank by striking it with a brief shaped mallet impulse.
    /// - Parameters:
    ///   - structure: `0.0` = warm harmonic string/wood, `0.35` = stiff marimba/bell, `0.7` = glass/bar
    ///   - brightness: `0.0..1.0` controls upper-mode damping and amplitude roll-off
    ///   - damping: base decay time in seconds (0.3 .. 4.0)
    ///   - position: physical strike point along bar/string (`0.08 .. 0.50`)
    mutating func strike(
        midi: Int,
        velocity: Double,
        structure: Double,
        brightness: Double,
        damping: Double,
        position: Double,
        level: Double,
        pan: Double,
        rng: inout FastNoiseRNG,
        sampleRate: Double = 48_000.0
    ) {
        let f0 = AudioMath.railsbackHz(midi: midi, stretchAmount: 0.6)
        let drift = pow(2.0, ((rng.nextUnit() - 0.5) * 2.0) / 1200.0)
        let baseHz = f0 * drift

        // Inharmonic stiffness coefficient B derived continuously from `structure`
        let stiffB = 0.0001 + pow(max(0.0, min(1.0, structure)), 2.2) * 0.045
        let pos = max(0.07, min(0.49, position))
        let bright = max(0.1, min(1.0, brightness))

        for k in 0..<Self.modeCount {
            let n = Double(k + 1)
            // Physical bar/stiff-string dispersion equation: f_n = f_0 * n * sqrt(1 + B * n^2)
            let ratio = n * sqrt(1.0 + stiffB * n * n)
            let freq = baseHz * ratio
            // Physical strike position cancels modes with a node at `pos`
            let strikeWeight = max(0.12, abs(sin(n * Double.pi * pos)))
            // Higher modes naturally decay faster and roll off with brightness
            let amp = (strikeWeight / pow(n, 1.35 - 0.55 * bright)) * (k == 0 ? 1.25 : 0.90)
            let modeDecay = damping / pow(n, 0.82 - 0.25 * bright)
            modes[k].reset()
            modes[k].configure(freqHz: freq, decaySec: modeDecay, amplitude: amp, sampleRate: sampleRate)
        }

        exciterFilter.reset()
        exciterFilter.set(cutoffHz: min(6200.0, max(450.0, baseHz * (2.5 + 4.5 * bright))), q: 1.5, sampleRate: sampleRate)
        exciterAge = 0
        exciterAmp = Float(0.75 + 0.55 * velocity)

        active = true
        age = 0
        maxAge = damping * 3.4
        self.level = Float(level)

        let angle = Float((pan + 1.0) * 0.25 * Double.pi)
        panL = cos(angle)
        panR = sin(angle)
    }

    @inline(__always)
    mutating func step(dt: Double, noise: inout FastNoiseRNG) -> (Float, Float) {
        guard active else { return (0, 0) }
        age += dt
        if age >= maxAge {
            active = false
            return (0, 0)
        }

        // Physical mallet/plectrum exciter burst (8 ms soft woody noise impulse)
        var exc: Float = 0
        if exciterAge < 0.009 {
            let env = Float(sin((exciterAge / 0.009) * Double.pi)) * exciterAmp
            exc = exciterFilter.lowpass(noise.nextBipolar()) * env
            exciterAge += dt
        }

        var sum: Float = 0
        for k in 0..<Self.modeCount {
            sum += modes[k].tick(exc)
        }

        let tailFade: Float = age > (maxAge - 0.25) ? Float(AudioMath.smoothstep((maxAge - age) / 0.25)) : 1.0
        let out = sum * level * tailFade
        return (out * panL, out * panR)
    }
}

/// 4-voice pseudo-polyphonic Mutable Instruments Rings bank (56 simultaneous modal eigenmodes).
struct RingsModalBank: Sendable {
    private var voices: [RingsVoice]
    private var nextSlot: Int = 0

    init() {
        self.voices = (0..<4).map { _ in RingsVoice() }
    }

    mutating func strike(
        midi: Int,
        velocity: Double,
        structure: Double,
        brightness: Double,
        damping: Double,
        position: Double,
        level: Double,
        pan: Double,
        rng: inout FastNoiseRNG,
        sampleRate: Double = 48_000.0
    ) {
        voices[nextSlot].strike(
            midi: midi, velocity: velocity, structure: structure, brightness: brightness,
            damping: damping, position: position, level: level, pan: pan,
            rng: &rng, sampleRate: sampleRate
        )
        nextSlot = (nextSlot + 1) % voices.count
    }

    @inline(__always)
    mutating func step(dt: Double, noise: inout FastNoiseRNG) -> (Float, Float) {
        var outL: Float = 0, outR: Float = 0
        for i in 0..<voices.count where voices[i].active {
            let (vL, vR) = voices[i].step(dt: dt, noise: &noise)
            outL += vL
            outR += vR
        }
        return (outL, outR)
    }

    mutating func clear() {
        for i in 0..<voices.count { voices[i].active = false }
    }
}

// MARK: - 2. Mutable Instruments Beads / Clouds Live Stereo Granular Texture Cloud

private struct AudioGrain: Sendable {
    var active: Bool = false
    var readPos: Double = 0
    var rate: Double = 1.0      // Negative = reverse grain (Sakamoto / Frahm halo!)
    var ageSamples: Int = 0
    var lengthSamples: Int = 12000
    var gainL: Float = 0.5
    var gainR: Float = 0.5
}

/// Live 4-second stereo granular cloud synthesizer inspired by Mutable Instruments Beads:
/// continuously records incoming acoustic instruments into a circular stereo tape buffer
/// and spawns up to 14 concurrent Hann-windowed, Hermite-interpolated asynchronous grains
/// (+12st angel shimmer, 0st frozen cloud, -12st warm cello bed, and floating reverse grains).
struct BeadsGranularCloud: Sendable {
    // 262,144 samples = 5.46 seconds of stereo recording buffer at 48 kHz (power-of-two mask)
    private static let cap = 1 << 18
    private static let mask = cap - 1
    private static let maxGrains = 14

    private var bufL: [Float]
    private var bufR: [Float]
    private var writeIdx: Int = 0
    private var grains: [AudioGrain]
    private let hannTable: [Float]
    private var spawnCountdown: Int = 1200
    private var silkLpL = CytomicSVF(cutoffHz: 4200, q: 0.65)
    private var silkLpR = CytomicSVF(cutoffHz: 4200, q: 0.65)
    private var silkHpL = CytomicSVF(cutoffHz: 180, q: 0.707)
    private var silkHpR = CytomicSVF(cutoffHz: 180, q: 0.707)
    private var rng = FastNoiseRNG(seed: 0xBEAD5_C100D_2026)

    init() {
        self.bufL = [Float](repeating: 0, count: Self.cap)
        self.bufR = [Float](repeating: 0, count: Self.cap)
        self.grains = [AudioGrain](repeating: AudioGrain(), count: Self.maxGrains)
        self.hannTable = (0..<1024).map { i in
            Float(0.5 * (1.0 - cos(2.0 * Double.pi * Double(i) / 1024.0)))
        }
    }

    @inline(__always)
    private func readHermite(_ buf: [Float], pos: Double) -> Float {
        let base = Int(floor(pos))
        let frac = Float(pos - floor(pos))
        return AudioMath.hermite(
            buf[(base - 1) & Self.mask],
            buf[base & Self.mask],
            buf[(base + 1) & Self.mask],
            buf[(base + 2) & Self.mask],
            frac: frac
        )
    }

    private mutating func spawnGrain(
        shimmerProb: Double,
        reverseProb: Double,
        subProb: Double,
        sampleRate: Double
    ) {
        // Find an inactive grain slot
        var slot = -1
        for i in 0..<Self.maxGrains where !grains[i].active {
            slot = i
            break
        }
        guard slot >= 0 else { return }

        // Musical pitch choices: octave up (+12st), unison (0st), octave down (-12st)
        let u = rng.nextUnit()
        let speed: Double
        if u < shimmerProb {
            speed = 2.0        // +12st luminous angel shimmer
        } else if u < shimmerProb + subProb {
            speed = 0.5        // -12st warm deep sub-bed
        } else {
            speed = 1.0        // Unison lush time-stretched cloud
        }

        let isReverse = rng.nextUnit() < reverseProb
        let detune = pow(2.0, ((rng.nextUnit() - 0.5) * 8.0) / 1200.0) // ±4 cents chorus bloom
        let rate = (isReverse ? -1.0 : 1.0) * speed * detune

        // Grain duration 200ms .. 560ms (long enough for lush liquid smoothness, never glitchy)
        let durSec = 0.20 + rng.nextUnit() * 0.36
        let lenSamp = max(4096, Int(durSec * sampleRate))

        // Safe lookback into circular buffer so neither forward (+2x) nor reverse (-2x) crosses write head
        let safety = Double(lenSamp) * abs(rate) + 2048.0
        let lookbackSec = 0.28 + rng.nextUnit() * 2.85
        let lookbackSamp = max(safety, min(Double(Self.cap - 8192), lookbackSec * sampleRate))
        let startPos = Double(writeIdx) - lookbackSamp

        let pan = (rng.nextUnit() * 2.0 - 1.0) * 0.78
        let angle = Float((pan + 1.0) * 0.25 * Double.pi)
        let amp: Float = (speed > 1.5) ? 0.22 : 0.30

        grains[slot] = AudioGrain(
            active: true,
            readPos: startPos,
            rate: rate,
            ageSamples: 0,
            lengthSamples: lenSamp,
            gainL: cos(angle) * amp,
            gainR: sin(angle) * amp
        )
    }

    /// Records `(inL, inR)` into the live granular buffer and returns the wet stereo cloud `(cloudL, cloudR)`.
    @inline(__always)
    mutating func process(
        _ inL: Float,
        _ inR: Float,
        densityHz: Double = 7.5,
        shimmerProb: Double = 0.28,
        reverseProb: Double = 0.35,
        subProb: Double = 0.16,
        sampleRate: Double = 48_000.0
    ) -> (Float, Float) {
        // Record gently saturated stereo input into the 5.4s tape buffer
        bufL[writeIdx] = tanh(inL * 1.15) * 0.87
        bufR[writeIdx] = tanh(inR * 1.15) * 0.87
        writeIdx = (writeIdx + 1) & Self.mask

        spawnCountdown -= 1
        if spawnCountdown <= 0 {
            spawnGrain(shimmerProb: shimmerProb, reverseProb: reverseProb, subProb: subProb, sampleRate: sampleRate)
            let meanInterval = sampleRate / max(1.0, densityHz)
            // Asynchronous jittered scheduling (prevents robotic periodic grain pulsing)
            let jitter = 0.55 + rng.nextUnit() * 0.90
            spawnCountdown = max(256, Int(meanInterval * jitter))
        }

        var sumL: Float = 0
        var sumR: Float = 0

        for i in 0..<Self.maxGrains where grains[i].active {
            let age = grains[i].ageSamples
            let len = grains[i].lengthSamples
            if age >= len {
                grains[i].active = false
                continue
            }

            // Fast table-lookup Hann window (zero cos() calls per grain per sample)
            let hIdx = min(1023, (age &* 1024) / len)
            let win = hannTable[hIdx]

            let sL = readHermite(bufL, pos: grains[i].readPos)
            let sR = readHermite(bufR, pos: grains[i].readPos)
            let mono = 0.5 * (sL + sR)

            // Blend stereo buffer content with per-grain spatial placement
            sumL += (sL * 0.45 + mono * grains[i].gainL) * win
            sumR += (sR * 0.45 + mono * grains[i].gainR) * win

            grains[i].readPos += grains[i].rate
            grains[i].ageSamples = age + 1
        }

        // Warm cassette/silk band shaping keeps the cloud velvety behind the dry acoustic instruments
        let outL = silkHpL.highpass(silkLpL.lowpass(sumL)) * 0.62
        let outR = silkHpR.highpass(silkLpR.lowpass(sumR)) * 0.62
        return (outL, outR)
    }

    mutating func clear() {
        for i in 0..<Self.cap { bufL[i] = 0; bufR[i] = 0 }
        for i in 0..<Self.maxGrains { grains[i].active = false }
        silkLpL.reset(); silkLpR.reset()
        silkHpL.reset(); silkHpR.reset()
        writeIdx = 0
    }
}

// MARK: - 3. 3D Binaural Spatializer (Woodworth ITD + Contralateral Head-Shadow ILD — Wata Igarashi / Dozzy)

/// Places a stereo or mono musical layer in 3D azimuth space using real head physics:
/// - Woodworth spherical-head Interaural Time Difference (ITD) up to ±0.64 ms (fractional delay)
/// - Contralateral ear head-shadow Cytomic lowpass ILD filter (~2.2 kHz at 90°)
/// Creates a holographic, outside-the-head stereo orbit on headphones while remaining phase-safe.
struct BinauralOrbitBus: Sendable {
    private static let cap = 128
    private static let mask = 127

    private var bufL: [Float]
    private var bufR: [Float]
    private var wIdx: Int = 0
    private var shadowL = CytomicSVF(cutoffHz: 12000, q: 0.707)
    private var shadowR = CytomicSVF(cutoffHz: 12000, q: 0.707)
    private var orbitPhase: Double = 0
    private var sampleCounter: Int = 0

    init() {
        self.bufL = [Float](repeating: 0, count: Self.cap)
        self.bufR = [Float](repeating: 0, count: Self.cap)
    }

    @inline(__always)
    private func readFrac(_ buf: [Float], delay: Double) -> Float {
        let pos = Double(wIdx) - delay
        let i0 = Int(floor(pos)) & Self.mask
        let i1 = (i0 + 1) & Self.mask
        let frac = Float(pos - floor(pos))
        return buf[i0] + (buf[i1] - buf[i0]) * frac
    }

    /// Orbits `(inL, inR)` smoothly across azimuth `[-maxAngle, +maxAngle]` at `orbitHz` (e.g. 0.045 Hz = 22s full revolution).
    @inline(__always)
    mutating func process(
        _ inL: Float,
        _ inR: Float,
        orbitHz: Double = 0.045,
        maxAzimuthRad: Double = 1.15,
        dt: Double = 1.0 / 48_000.0,
        sampleRate: Double = 48_000.0
    ) -> (Float, Float) {
        bufL[wIdx] = inL
        bufR[wIdx] = inR

        orbitPhase += orbitHz * dt
        if orbitPhase >= 1.0 { orbitPhase -= 1.0 }

        // Smooth azimuth angle θ ∈ [-maxAzimuthRad, +maxAzimuthRad] (+ = right ear closer)
        let theta = sin(orbitPhase * 2.0 * Double.pi) * maxAzimuthRad
        // Woodworth spherical head ITD formula: τ = (r / c) * (θ + sin θ), r=0.0875m, c=343m/s -> ~0.255ms*(θ+sinθ)
        let itdSec = 0.000255 * (abs(theta) + abs(sin(theta)))
        let itdSamp = min(34.0, itdSec * sampleRate)

        let delayL = theta > 0 ? (2.0 + itdSamp) : 2.0
        let delayR = theta < 0 ? (2.0 + itdSamp) : 2.0

        // Update contralateral head-shadow ILD filters every 16 samples (3 kHz control rate)
        if (sampleCounter & 15) == 0 {
            let shadowCut = 11500.0 - (abs(sin(theta)) * 8800.0) // drops smoothly to ~2.7 kHz on the far ear
            shadowL.set(cutoffHz: theta > 0 ? shadowCut : 14000.0, q: 0.707, sampleRate: sampleRate)
            shadowR.set(cutoffHz: theta < 0 ? shadowCut : 14000.0, q: 0.707, sampleRate: sampleRate)
        }
        sampleCounter &+= 1

        let rawL = readFrac(bufL, delay: delayL)
        let rawR = readFrac(bufR, delay: delayR)
        wIdx = (wIdx + 1) & Self.mask

        // Subtle contralateral ILD attenuation (~-2.4 dB max) + acoustic head shadow
        let attenFar = Float(1.0 - 0.24 * abs(sin(theta)))
        let outL = shadowL.lowpass(rawL) * (theta > 0 ? attenFar : 1.0)
        let outR = shadowR.lowpass(rawR) * (theta < 0 ? attenFar : 1.0)
        return (outL, outR)
    }

    mutating func clear() {
        for i in 0..<Self.cap { bufL[i] = 0; bufR[i] = 0 }
        shadowL.reset()
        shadowR.reset()
    }
}
