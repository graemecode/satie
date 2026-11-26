import Foundation

/// Visual/telemetry event emitted whenever a bronze bowl, singing bowl, or Zen rin bell speaks.
struct MeditationStrikeEvent: Sendable {
    let midi: Int
    let pan: Float
    let velocity: Float
    let isRinBell: Bool
}

// MARK: - 1. Subconscious Resonance-Frequency Breath Pacer (8.5 -> 5.5 breaths/min)

/// Smoothly decelerates from a relaxed resting breath (~8.5 bpm / 7.06s cycle)
/// down to physiological HRV resonance frequency (~5.5 bpm / 10.91s cycle) over 10 minutes.
/// Asymmetric 42% inhale / 58% exhale raised-cosine contour (zero derivative discontinuities).
struct ResonanceBreathPacer: Sendable {
    private var phase: Double = 0.0
    private(set) var currentBPM: Double = 8.5
    private(set) var value: Double = 0.0 // 0 = end of exhale, 1 = peak of inhale

    mutating func reset() {
        phase = 0.0
        currentBPM = 8.5
        value = 0.0
    }

    @inline(__always)
    mutating func step(elapsedSec: Double, dt: Double, targetBPMOverride: Double? = nil) -> Double {
        let descendT = AudioMath.smoothstep(elapsedSec / 600.0) // 10-minute imperceptible deceleration
        let autoBPM = 8.5 - 3.0 * descendT // 8.5 -> 5.5 breaths/min
        if let override = targetBPMOverride, override >= 4.2 && override <= 9.0 {
            let alpha = 1.0 - exp(-dt / 14.0)
            currentBPM += (override - currentBPM) * alpha
        } else {
            currentBPM = autoBPM
        }
        let cycleSec = 60.0 / currentBPM
        phase += dt / cycleSec
        if phase >= 1.0 { phase -= floor(phase) }

        let inhaleFrac = 0.42
        if phase < inhaleFrac {
            let u = phase / inhaleFrac
            value = 0.5 - 0.5 * cos(Double.pi * u)
        } else {
            let v = (phase - inhaleFrac) / (1.0 - inhaleFrac)
            value = 0.5 + 0.5 * cos(Double.pi * v)
        }
        return value
    }
}

// MARK: - 2. Living Bowed-Cello & Friction-Glass Breathing Acoustic Drone

/// Dual-head equal-power asynchronous granular looper over real CC0 acoustic recordings
/// (`cello` and `glass` from StudioSampleBank). Zero heap allocations during render;
/// preserves real rosin-on-string vibrato, wooden body resonance, and glass air without loop seams.
private struct OrganicSampleDroneVoice: @unchecked Sendable {
    private let zone: DecodedSampleZone?
    private let zoneHz: Double
    private let startFrame: Double
    private let sustainSpan: Double
    private var posA: Double = 0
    private var posB: Double = 0
    private var ageA: Double = 0
    private var ageB: Double = 0
    private var durSamples: Double = 163_200 // ~3.4s smooth Hann grain

    init(bank: StudioSampleBank, instrument: AcousticInstrumentID, targetMidi: Int, durSec: Double) {
        let z = bank.nearestZone(instrument: instrument, midi: targetMidi)
        self.zone = z
        let midi = z?.midi ?? targetMidi
        self.zoneHz = 440.0 * pow(2.0, Double(midi - 69) / 12.0)
        let fc = Double(z?.frameCount ?? 0)
        // Stay inside the lush steady sustain belly (18% .. 76% of recording) — skip attack & fade tail
        self.startFrame = fc * 0.18
        self.sustainSpan = max(1.0, fc * 0.58)
        self.durSamples = max(48_000.0, durSec * 48_000.0)
        reset(phaseOffset: 0.0)
    }

    mutating func reset(phaseOffset: Double = 0.0) {
        let maxStart = max(1.0, sustainSpan * 0.45)
        ageA = durSamples * phaseOffset
        ageB = durSamples * ((phaseOffset + 0.5).truncatingRemainder(dividingBy: 1.0))
        posA = startFrame + maxStart * 0.15
        posB = startFrame + maxStart * 0.55
    }

    @inline(__always)
    private func readInterp(_ z: DecodedSampleZone, pos: Double) -> (Float, Float) {
        let maxIdx = z.frameCount - 2
        guard maxIdx > 2 else { return (0, 0) }
        // Wrap gracefully inside sustain belly if playback exceeds span
        var p = pos
        let endFrame = startFrame + sustainSpan - 4.0
        if p >= endFrame {
            p = startFrame + (p - startFrame).truncatingRemainder(dividingBy: max(1.0, sustainSpan - 8.0))
        }
        let i0 = max(0, min(maxIdx, Int(p)))
        let frac = Float(p - floor(p))
        let l0 = z.sampleL(i0), l1 = z.sampleL(i0 + 1)
        let r0 = z.sampleR(i0), r1 = z.sampleR(i0 + 1)
        return (l0 + (l1 - l0) * frac, r0 + (r1 - r0) * frac)
    }

    @inline(__always)
    mutating func step(targetHz: Double, rng: inout FastNoiseRNG) -> (Float, Float) {
        guard let z = zone, z.frameCount > 16_000 else { return (0, 0) }
        let rate = max(0.35, min(2.2, targetHz / zoneHz))

        if ageA >= durSamples {
            ageA = 0
            let spanNeeded = durSamples * rate
            let headroom = max(1.0, sustainSpan - spanNeeded - 64.0)
            posA = startFrame + rng.nextUnit() * headroom
        }
        if ageB >= durSamples {
            ageB = 0
            let spanNeeded = durSamples * rate
            let headroom = max(1.0, sustainSpan - spanNeeded - 64.0)
            posB = startFrame + rng.nextUnit() * headroom
        }

        let wA = Float(sin(Double.pi * (ageA / durSamples)))
        let wB = Float(sin(Double.pi * (ageB / durSamples)))
        let norm = 1.0 / sqrt(max(0.25, wA * wA + wB * wB))

        let (aL, aR) = readInterp(z, pos: posA)
        let (bL, bR) = readInterp(z, pos: posB)

        posA += rate
        posB += rate
        ageA += 1.0
        ageB += 1.0

        return ((aL * wA + bL * wB) * norm, (aR * wA + bR * wB) * norm)
    }
}

/// Replaces flat static sine drones with a living, breathing acoustic sanctuary bed:
/// - Real CC0 bowed cello root (fRoot/2) & pure fifth (fRoot * 0.75) breathing with ResonanceBreathPacer
/// - Real CC0 friction-glass harmonic halo (2x fRoot) emerging on a slow 5-minute macro wave
/// - Gentle sub-fundamental warmth anchor so speakers and headphones alike feel grounded
struct OrganicHarmonicBed: @unchecked Sendable {
    private var celloRoot: OrganicSampleDroneVoice
    private var celloFifth: OrganicSampleDroneVoice
    private var glassHalo: OrganicSampleDroneVoice
    private var subPhase: Double = 0
    private var lpL = CytomicSVF(cutoffHz: 420.0, q: 0.65)
    private var lpR = CytomicSVF(cutoffHz: 420.0, q: 0.65)
    private var glassBpL = CytomicSVF(cutoffHz: 780.0, q: 0.80)
    private var glassBpR = CytomicSVF(cutoffHz: 780.0, q: 0.80)
    private var tick: Int = 0

    init(bank: StudioSampleBank) {
        self.celloRoot  = OrganicSampleDroneVoice(bank: bank, instrument: .cello, targetMidi: 38, durSec: 3.4) // D2
        self.celloFifth = OrganicSampleDroneVoice(bank: bank, instrument: .cello, targetMidi: 45, durSec: 3.9) // A2
        self.glassHalo  = OrganicSampleDroneVoice(bank: bank, instrument: .glass, targetMidi: 62, durSec: 4.3) // D4
    }

    mutating func reset() {
        celloRoot.reset(phaseOffset: 0.0)
        celloFifth.reset(phaseOffset: 0.37)
        glassHalo.reset(phaseOffset: 0.61)
        subPhase = 0
        lpL.reset(); lpR.reset()
        glassBpL.reset(); glassBpR.reset()
        tick = 0
    }

    @inline(__always)
    mutating func step(
        elapsedSec: Double,
        rootHz: Double,
        depth01: Double,
        breath01: Double,
        dt: Double,
        sampleRate: Double,
        sineTable: [Float],
        rng: inout FastNoiseRNG
    ) -> (Float, Float) {
        if (tick & 127) == 0 {
            // Bowed cello warmth opens gently on inhale and darkens softly as depth deepens
            let cut = (275.0 + breath01 * 175.0) * (1.0 - 0.24 * depth01)
            lpL.set(cutoffHz: cut, q: 0.64, sampleRate: sampleRate)
            lpR.set(cutoffHz: cut * 0.96, q: 0.64, sampleRate: sampleRate)
            let gCut = max(360.0, min(1450.0, rootHz * 2.8 + breath01 * 260.0))
            glassBpL.set(cutoffHz: gCut, q: 0.72, sampleRate: sampleRate)
            glassBpR.set(cutoffHz: gCut * 1.03, q: 0.72, sampleRate: sampleRate)
        }
        tick &+= 1

        // Organic string-section micro-detune drift (+/- 1.8 cents) so the harmonic field breathes like real bows
        let driftA = pow(2.0, (1.6 * sin(elapsedSec * 0.071)) / 1200.0)
        let driftB = pow(2.0, (1.9 * cos(elapsedSec * 0.053 + 1.1)) / 1200.0)

        let (c1L, c1R) = celloRoot.step(targetHz: rootHz * 0.5 * driftA, rng: &rng)
        let (c2L, c2R) = celloFifth.step(targetHz: rootHz * 0.75 * driftB, rng: &rng)
        let (gL, gR)   = glassHalo.step(targetHz: rootHz * 2.0 * driftA, rng: &rng)

        // Subtle warm sub-chest anchor (guarantees tactile low end even if sample bank unavailable)
        subPhase += (rootHz * 0.5) * dt
        if subPhase >= 1.0 { subPhase -= floor(subPhase) }
        let sub = TimbreBank.lookup(sineTable, phase01: subPhase) * 0.011

        // Slow 5.5-minute macro wave brings the friction-glass halo in and out like mist over water
        let glassMacro = Float(0.32 + 0.68 * (0.5 + 0.5 * sin(elapsedSec * 0.019 - 0.8)))
        let breathSwell = Float(0.76 + 0.44 * breath01)
        let fadeIn = Float(AudioMath.smoothstep(elapsedSec / 4.8))

        // Natural orchestral stereo spread (root slightly center-left, fifth slightly center-right)
        let celloL = lpL.lowpass((c1L * 0.82 + c1R * 0.18) * 0.084 + (c2L * 0.38 + c2R * 0.62) * 0.056 * breathSwell)
        let celloR = lpR.lowpass((c1R * 0.82 + c1L * 0.18) * 0.084 + (c2R * 0.38 + c2L * 0.62) * 0.056 * breathSwell)

        let veilL = glassBpL.lowpass(gL) * 0.046 * glassMacro * breathSwell
        let veilR = glassBpR.lowpass(gR) * 0.046 * glassMacro * breathSwell

        return ((celloL + veilL + sub) * fadeIn, (celloR + veilR + sub) * fadeIn)
    }
}

// MARK: - 3. Mathematically Non-Repeating 3D Spatial Rain & Cedar-Wind Breath Field

/// Resynthesizes our real 48 kHz studio courtyard rain recording (`rain_bed.m4a`) with:
/// - 4 asynchronous long grains (2.25..4.80s) + live 1/sqrt(sum(w^2)) equal-power norm (r < 0.10 non-repeating)
/// - 5th crisp exterior micro-drop accent grain (0.9..1.6s) preserving natural raindrop micro-transients
/// - Living cedar-wind breath veil (220..680 Hz stereo-drifting air) carrying the 8.5 -> 5.5 bpm
///   subconscious respiratory wave audibly enough for eyes-closed entrainment without LFO artifacts
/// - -7.5 dB ear-canal alarm band scoop at 3.1 kHz + ultra-sparse close wooden-eave Minnaert drops
struct StochasticRainField: @unchecked Sendable {
    private struct RainGrain {
        var posL: Double = 0
        var posR: Double = 0
        var rate: Double = 1.0
        var ageSamples: Int = 0
        var durationSamples: Int = 144_000
    }

    private struct EaveDrop {
        var active: Bool = false
        var age: Double = 0
        var freq: Double = 1200
        var phase: Double = 0
        var tau: Double = 0.005
        var amp: Float = 0
        var panL: Float = 0.707
        var panR: Float = 0.707
    }

    private let bed: DecodedSampleZone?
    private let trimStart: Int
    private let usableLength: Int
    private var grains: [RainGrain]       // 4 long velvet sheet grains
    private var detailGrain: RainGrain    // 5th short exterior transient-preserving rain grain
    private var drops: [EaveDrop]
    private var nextDropSlot: Int = 0
    private var rng = FastNoiseRNG(seed: 0x5A71_E9A1_4B01_CAFE)

    // Cedar-room spectral hygiene filters
    private var hpL = CytomicSVF(cutoffHz: 85.0, q: 0.707)
    private var hpR = CytomicSVF(cutoffHz: 85.0, q: 0.707)
    private var scoopL = CytomicSVF(cutoffHz: 3100.0, q: 0.62)
    private var scoopR = CytomicSVF(cutoffHz: 3100.0, q: 0.62)
    private var lpL = CytomicSVF(cutoffHz: 4800.0, q: 0.60)
    private var lpR = CytomicSVF(cutoffHz: 4800.0, q: 0.60)

    // Exterior micro-drop detail bandpass
    private var detBpL = CytomicSVF(cutoffHz: 1450.0, q: 0.75)
    private var detBpR = CytomicSVF(cutoffHz: 1450.0, q: 0.75)

    // Living cedar-wind / temple-porch breath veil (subtle organic eyes-closed respiratory anchor)
    private var windBrownL: Float = 0
    private var windBrownR: Float = 0
    private var windBpL = CytomicSVF(cutoffHz: 340.0, q: 1.10)
    private var windBpR = CytomicSVF(cutoffHz: 370.0, q: 1.10)

    // Warm enclosed room floor
    private var brownL: Float = 0
    private var brownR: Float = 0
    private var brownLpL = CytomicSVF(cutoffHz: 390.0, q: 0.65)
    private var brownLpR = CytomicSVF(cutoffHz: 380.0, q: 0.65)
    private var sampleCounter: Int = 0

    var isStudioSampleAvailable: Bool { bed != nil && usableLength > 260_000 }

    init(bank: StudioSampleBank = .shared, seed: UInt64 = 0x5A71_E9A1_4B01_CAFE) {
        self.bed = bank.rainBed
        let total = bank.rainBed?.frameCount ?? 0
        let trim = 2400
        self.trimStart = trim
        self.usableLength = max(0, total - trim * 2)
        self.rng = FastNoiseRNG(seed: seed)
        self.grains = [RainGrain](repeating: RainGrain(), count: 4)
        self.detailGrain = RainGrain()
        self.drops = [EaveDrop](repeating: EaveDrop(), count: 4)
        initializeGrains()
    }

    mutating func reset(seed: UInt64? = nil) {
        if let seed { rng = FastNoiseRNG(seed: seed) }
        hpL.reset(); hpR.reset()
        scoopL.reset(); scoopR.reset()
        lpL.reset(); lpR.reset()
        detBpL.reset(); detBpR.reset()
        windBpL.reset(); windBpR.reset()
        brownLpL.reset(); brownLpR.reset()
        windBrownL = 0; windBrownR = 0
        brownL = 0; brownR = 0
        sampleCounter = 0
        for i in 0..<drops.count { drops[i].active = false }
        initializeGrains()
    }

    private mutating func initializeGrains() {
        for i in 0..<grains.count {
            spawnGrain(at: i, initialPhaseFraction: Double(i) / Double(grains.count))
        }
        spawnDetailGrain()
    }

    private mutating func spawnGrain(at index: Int, initialPhaseFraction: Double = 0.0) {
        let durSec = 2.25 + rng.nextUnit() * 2.55
        let durSamples = max(48_000, Int(durSec * 48_000.0))
        let rate = 0.976 + rng.nextUnit() * 0.048
        let span = Int(Double(durSamples) * rate) + 64
        let maxStart = max(1, usableLength - span)

        let startL = Double(trimStart) + rng.nextUnit() * Double(maxStart)
        let minSep = min(72_000.0, Double(maxStart) * 0.35)
        var startR = Double(trimStart) + rng.nextUnit() * Double(maxStart)
        if abs(startR - startL) < minSep && maxStart > Int(minSep * 2.0) {
            let shifted = (startL - Double(trimStart) + minSep + rng.nextUnit() * Double(maxStart) * 0.4)
                .truncatingRemainder(dividingBy: Double(maxStart))
            startR = Double(trimStart) + shifted
        }

        let initialAge = Int(Double(durSamples) * initialPhaseFraction)
        grains[index] = RainGrain(
            posL: startL + Double(initialAge) * rate,
            posR: startR + Double(initialAge) * rate,
            rate: rate,
            ageSamples: initialAge,
            durationSamples: durSamples
        )
    }

    private mutating func spawnDetailGrain() {
        let durSec = 0.95 + rng.nextUnit() * 0.85
        let durSamples = max(24_000, Int(durSec * 48_000.0))
        let rate = 0.985 + rng.nextUnit() * 0.030
        let span = Int(Double(durSamples) * rate) + 64
        let maxStart = max(1, usableLength - span)
        let startL = Double(trimStart) + rng.nextUnit() * Double(maxStart)
        let startR = Double(trimStart) + rng.nextUnit() * Double(maxStart)
        detailGrain = RainGrain(posL: startL, posR: startR, rate: rate, ageSamples: 0, durationSamples: durSamples)
    }

    @inline(__always)
    private func readInterpL(_ zone: DecodedSampleZone, pos: Double) -> Float {
        let i0 = max(trimStart, min(zone.frameCount - 2, Int(pos)))
        let frac = Float(pos - floor(pos))
        let a = zone.sampleL(i0)
        let b = zone.sampleL(i0 + 1)
        return a + (b - a) * frac
    }

    @inline(__always)
    private func readInterpR(_ zone: DecodedSampleZone, pos: Double) -> Float {
        let i0 = max(trimStart, min(zone.frameCount - 2, Int(pos)))
        let frac = Float(pos - floor(pos))
        let a = zone.sampleR(i0)
        let b = zone.sampleR(i0 + 1)
        return a + (b - a) * frac
    }

    @inline(__always)
    mutating func step(
        elapsedSec: Double,
        depth01: Double,
        return01: Double,
        breath01: Double,
        dt: Double,
        sampleRate: Double,
        sineTable: [Float]
    ) -> (Float, Float) {
        // Slow incommensurate macro-weather drift (period > 15 min): rain softens & swells like real weather
        let weather = 0.5
            + 0.24 * sin(elapsedSec * 0.0257)
            + 0.16 * sin(elapsedSec * 0.0421 + 1.3)
            + 0.10 * cos(elapsedSec * 0.0709 + 2.7)

        if (sampleCounter & 127) == 0 {
            let baseCut = (5000.0 - 1850.0 * depth01) * (1.0 - return01) + 5400.0 * return01
            let breathCut = (breath01 - 0.5) * 760.0
            let weatherCut = (weather - 0.5) * 580.0
            let cutHz = max(2000.0, min(6200.0, baseCut + breathCut + weatherCut))
            lpL.set(cutoffHz: cutHz, q: 0.60, sampleRate: sampleRate)
            lpR.set(cutoffHz: cutHz * 0.97, q: 0.60, sampleRate: sampleRate)
            hpL.set(cutoffHz: 85.0, q: 0.707, sampleRate: sampleRate)
            hpR.set(cutoffHz: 85.0, q: 0.707, sampleRate: sampleRate)
            scoopL.set(cutoffHz: 3100.0, q: 0.62, sampleRate: sampleRate)
            scoopR.set(cutoffHz: 3100.0, q: 0.62, sampleRate: sampleRate)
            detBpL.set(cutoffHz: 1120.0 + weather * 260.0, q: 0.90, sampleRate: sampleRate)
            detBpR.set(cutoffHz: 1180.0 + weather * 240.0, q: 0.90, sampleRate: sampleRate)

            // Cedar-wind breath formant glides softly 260 Hz (exhale) <-> 560 Hz (inhale) with slow stereo drift
            let windCenter = 250.0 + breath01 * 310.0 + (weather - 0.5) * 80.0
            let stereoDrift = 1.0 + 0.08 * sin(elapsedSec * 0.133)
            windBpL.set(cutoffHz: windCenter * stereoDrift, q: 1.12, sampleRate: sampleRate)
            windBpR.set(cutoffHz: windCenter / stereoDrift, q: 1.12, sampleRate: sampleRate)

            brownLpL.set(cutoffHz: 350.0 + breath01 * 110.0, q: 0.65, sampleRate: sampleRate)
            brownLpR.set(cutoffHz: 340.0 + breath01 * 110.0, q: 0.65, sampleRate: sampleRate)
        }
        sampleCounter &+= 1

        var rawL: Float = 0
        var rawR: Float = 0
        var detL: Float = 0
        var detR: Float = 0

        if let z = bed, usableLength > 260_000 {
            var sumWinSq: Float = 0
            for i in 0..<4 {
                if grains[i].ageSamples >= grains[i].durationSamples {
                    spawnGrain(at: i, initialPhaseFraction: 0.0)
                }
                let p = Double(grains[i].ageSamples) / Double(grains[i].durationSamples)
                let w = Float(sin(Double.pi * p))
                sumWinSq += w * w

                let sL = readInterpL(z, pos: grains[i].posL)
                let sR = readInterpR(z, pos: grains[i].posR)
                if (i & 1) == 0 {
                    rawL += sL * w
                    rawR += sR * w
                } else {
                    rawL += sR * w
                    rawR += sL * w
                }

                grains[i].posL += grains[i].rate
                grains[i].posR += grains[i].rate
                grains[i].ageSamples &+= 1
            }
            let norm = 1.0 / sqrt(max(0.45, sumWinSq))
            rawL *= norm
            rawR *= norm

            // 5th exterior micro-drop transient accent grain (keeps natural raindrop texture crisp!)
            if detailGrain.ageSamples >= detailGrain.durationSamples {
                spawnDetailGrain()
            }
            let dp = Double(detailGrain.ageSamples) / Double(detailGrain.durationSamples)
            let dw = Float(sin(Double.pi * dp))
            detL = detBpL.bandpass(readInterpL(z, pos: detailGrain.posL)) * dw * 0.024 * Float(0.75 + 0.5 * weather)
            detR = detBpR.bandpass(readInterpR(z, pos: detailGrain.posR)) * dw * 0.024 * Float(0.75 + 0.5 * weather)
            detailGrain.posL += detailGrain.rate
            detailGrain.posR += detailGrain.rate
            detailGrain.ageSamples &+= 1
        }

        // Living cedar-wind breath veil + warm enclosed wooden-room floor
        let wL = rng.nextBipolar()
        let wR = rng.nextBipolar()
        brownL = brownL * 0.988 + wL * 0.040
        brownR = brownR * 0.988 + wR * 0.040
        let floorL = brownLpL.lowpass(brownL) * 0.12
        let floorR = brownLpR.lowpass(brownR) * 0.12

        // Independent cedar wind passing gently across the porch on the 8.5 -> 5.5 bpm breath curve
        let wwL = rng.nextBipolar()
        let wwR = rng.nextBipolar()
        windBrownL = windBrownL * 0.94 + wwL * 0.08
        windBrownR = windBrownR * 0.94 + wwR * 0.08
        let windPan = 0.5 + 0.22 * sin(elapsedSec * 0.133)
        let windEnv = Float((0.020 + 0.036 * breath01) * (0.72 + 0.45 * weather))
        let windL = windBpL.bandpass(windBrownL) * windEnv * Float(1.15 - windPan * 0.35)
        let windR = windBpR.bandpass(windBrownR) * windEnv * Float(0.80 + windPan * 0.35)

        // Ultra-sparse wooden-eave close Minnaert droplets (~0.24 drops/sec)
        let dropRate = (0.18 + 0.26 * weather) * (1.0 - 0.30 * depth01)
        if rng.nextUnit() < dropRate * dt {
            var d = EaveDrop()
            d.active = true
            d.freq = 760.0 + rng.nextUnit() * 1120.0
            d.tau = 0.0038 + rng.nextUnit() * 0.0046
            d.amp = Float(0.013 + rng.nextUnit() * 0.018)
            let pan = Float(rng.nextUnit() * 1.44 - 0.72)
            let ang = (pan + 1.0) * 0.25 * Float.pi
            d.panL = cos(ang)
            d.panR = sin(ang)
            drops[nextDropSlot] = d
            nextDropSlot = (nextDropSlot + 1) & 3
        }

        var dropL: Float = 0
        var dropR: Float = 0
        for i in 0..<4 where drops[i].active {
            drops[i].age += dt
            let env = Float(exp(-drops[i].age / drops[i].tau))
            if env < 0.002 {
                drops[i].active = false
                continue
            }
            let f = drops[i].freq * (1.0 + 0.28 * (drops[i].age / drops[i].tau))
            drops[i].phase += f * dt
            if drops[i].phase >= 1.0 { drops[i].phase -= floor(drops[i].phase) }
            let s = TimbreBank.lookup(sineTable, phase01: drops[i].phase) * env * drops[i].amp
            dropL += s * drops[i].panL
            dropR += s * drops[i].panR
        }

        // Apply spectral hygiene to BOTH velvet sheet AND exterior detail grain:
        // 85 Hz HP -> -9.5 dB scoop at 3.1 kHz -> breathing velvet LP (zero 2-5 kHz ear-canal hiss!)
        let rainGain: Float = Float(0.096 * (0.86 + 0.20 * weather) * (0.88 + 0.24 * breath01))
        var outL = hpL.highpass(rawL * rainGain + detL)
        var outR = hpR.highpass(rawR * rainGain + detR)
        outL = lpL.lowpass(scoopL.bell(outL, linearGain: 0.34))
        outR = lpR.lowpass(scoopR.bell(outR, linearGain: 0.34))

        // Subtle breath stereo aperture expansion on inhale, inward settling on exhale
        let mid = 0.5 * (outL + outR)
        let side = 0.5 * (outL - outR) * Float(0.92 + 0.20 * breath01)
        outL = mid + side + windL + floorL + dropL
        outR = mid - side + windR + floorR + dropR

        return (outL, outR)
    }
}

// MARK: - 4. Hybrid Real-Acoustic + Nonlinear Coupled Bronze Bowl / Singing Bowl / Zen Rin Family

enum SanctuaryBowlArchetype: Sendable {
    case templeBonsho    // Deep thick-walled Himalayan bronze strike + nonlinear bloom + real vibe mallet transient
    case singingFriction // Bowed / rim-circled singing bowl fusing real CC0 friction glass + split modal warmth
    case zenRinBell      // Crystalline high Japanese rin bell for rare mindfulness glints & session return
}

/// Physical + real-sample hybrid meditation bowl resonator:
/// - Fuses pitch-matched CC0 acoustic strike/bowed samples (`vibe` mallet transient or `glass` rim shimmer)
///   with 5-mode asymmetric split-doublet bronze physics + nonlinear energy-transfer throat bloom
struct HybridSanctuaryBowlVoice: @unchecked Sendable {
    var active: Bool = false
    private var archetype: SanctuaryBowlArchetype = .templeBonsho
    private var age: Double = 0
    private var maxAge: Double = 30.0
    private var f0: Double = 146.83
    private var droopRatio: Double = 0.0036
    private var tau0: Double = 12.0
    private var bloomSec: Double = 0.045
    private var level: Float = 0.14

    // Eigenmode ratios (vary by archetype so temple bowls, singing bowls & rin bells sound genuinely distinct!)
    private var r2: Double = 2.712
    private var r3: Double = 4.980
    private var r4: Double = 7.680

    // Asymmetric rim split-mode doublets (Hz)
    private var df1: Double = 1.10
    private var df2: Double = 2.30
    private var df3: Double = 3.60

    // Per-strike modal weights
    private var w1a: Float = 0.55, w1b: Float = 0.45
    private var w2a: Float = 0.16, w2b: Float = 0.14
    private var w3a: Float = 0.055, w3b: Float = 0.045
    private var w4: Float = 0.016
    private var wSub: Float = 0.10
    private var couplingBloom: Float = 0.34 // Nonlinear bronze energy transfer swell 0.6..2.0s after impact

    // Phases
    private var pSub: Double = 0
    private var p1a: Double = 0, p1b: Double = 0
    private var p2a: Double = 0, p2b: Double = 0
    private var p3a: Double = 0, p3b: Double = 0
    private var p4: Double = 0

    // Real CC0 acoustic layer (soft-mallet vibe strike for Bonsho/Rin, real friction glass for Singing Bowl!)
    private var sampleZone: DecodedSampleZone? = nil
    private var samplePos: Double = 0
    private var sampleRateRatio: Double = 1.0
    private var sampleGain: Float = 0.0
    private var sampleTau: Double = 0.35
    private var sampleLpL = CytomicSVF(cutoffHz: 1100.0, q: 0.68)
    private var sampleLpR = CytomicSVF(cutoffHz: 1100.0, q: 0.68)

    // Stereo panning for orthogonal doublet pair
    private var panAL: Float = 0.76, panAR: Float = 0.65
    private var panBL: Float = 0.65, panBR: Float = 0.76

    mutating func trigger(
        archetype: SanctuaryBowlArchetype,
        freqHz: Double,
        pan: Float,
        velocity: Float,
        malletSoftness: Double,
        bank: StudioSampleBank,
        rng: inout FastNoiseRNG,
        sampleRate: Double
    ) {
        self.active = true
        self.archetype = archetype
        self.age = 0
        self.f0 = freqHz * pow(2.0, ((rng.nextUnit() - 0.5) * 5.5) / 1200.0)

        switch archetype {
        case .templeBonsho:
            r2 = 2.695 + rng.nextUnit() * 0.055 // Real thick-walled bronze partial spread
            r3 = 4.940 + rng.nextUnit() * 0.140
            r4 = 7.620 + rng.nextUnit() * 0.250
            droopRatio = 0.0032 + rng.nextUnit() * 0.0020
            bloomSec = 0.032 + malletSoftness * 0.038
            tau0 = 10.2 + rng.nextUnit() * 5.0
            level = velocity * 0.150
            couplingBloom = Float(0.32 + rng.nextUnit() * 0.22)
            df1 = 0.68 + rng.nextUnit() * 1.05
            df2 = df1 * (1.85 + rng.nextUnit() * 0.60)
            df3 = df2 * (1.45 + rng.nextUnit() * 0.45)

        case .singingFriction:
            r2 = 2.756 + rng.nextUnit() * 0.030
            r3 = 5.120 + rng.nextUnit() * 0.090
            r4 = 8.150
            droopRatio = 0.0005 // Bowed/circled rim has almost zero impact droop
            bloomSec = 1.15 + rng.nextUnit() * 0.85 // Slow organic wooden-rim friction swell!
            tau0 = 9.0 + rng.nextUnit() * 3.8
            level = velocity * 0.115
            couplingBloom = 0.18
            df1 = 0.95 + rng.nextUnit() * 1.10
            df2 = df1 * 1.95
            df3 = df2 * 1.50

        case .zenRinBell:
            r2 = 2.820 + rng.nextUnit() * 0.035
            r3 = 5.420 + rng.nextUnit() * 0.060
            r4 = 8.850
            droopRatio = 0.0020
            bloomSec = 0.016
            tau0 = 6.8 + rng.nextUnit() * 2.4
            level = velocity * 0.098
            couplingBloom = 0.20
            df1 = 1.9 + rng.nextUnit() * 1.3
            df2 = df1 * 1.75
            df3 = df2 * 1.40
        }
        maxAge = bloomSec + tau0 * 5.0

        // Rim strike angle theta varies orthogonal doublet balance & partial richness every time
        let theta = rng.nextUnit() * Double.pi
        let cos2 = Float(0.36 + 0.28 * abs(cos(2.0 * theta)))
        let sin2 = Float(0.36 + 0.28 * abs(sin(2.0 * theta)))
        let norm1 = 1.0 / (cos2 + sin2)
        w1a = cos2 * norm1
        w1b = sin2 * norm1

        let bright = Float(1.0 - 0.56 * malletSoftness)
        let rimExc = Float(0.78 + 0.36 * abs(sin(3.0 * theta)))
        w2a = 0.21 * bright * rimExc * w1a
        w2b = 0.21 * bright * rimExc * w1b
        w3a = (f0 * r3 < 6100.0) ? (0.078 * bright * bright * w1a) : 0
        w3b = (f0 * r3 < 6100.0) ? (0.078 * bright * bright * w1b) : 0
        w4  = (f0 * r4 < 6600.0) ? (0.024 * bright * bright) : 0
        wSub = (archetype == .templeBonsho && f0 < 270.0) ? Float(0.12 * malletSoftness) : 0

        pSub = 0
        p1a = 0; p1b = 0.08 + rng.nextUnit() * 0.18
        p2a = 0; p2b = 0.12 + rng.nextUnit() * 0.22
        p3a = 0; p3b = 0.05 + rng.nextUnit() * 0.25
        p4 = 0

        // Attach pitch-matched real CC0 acoustic sample layer (soft-mallet vibe attack or bowed friction glass!)
        let targetMidi = Int(round(69.0 + 12.0 * log2(max(40.0, f0) / 440.0)))
        if archetype == .singingFriction {
            if let gz = bank.nearestZone(instrument: .glass, midi: targetMidi) {
                sampleZone = gz
                let zHz = 440.0 * pow(2.0, Double(gz.midi - 69) / 12.0)
                sampleRateRatio = max(0.45, min(2.0, f0 / zHz))
                samplePos = Double(gz.frameCount) * 0.08 // skip silence, ride into real bowed glass body
                sampleGain = velocity * 0.22
                sampleTau = tau0 * 0.62
                sampleLpL.reset(); sampleLpR.reset()
                sampleLpL.set(cutoffHz: min(2600.0, f0 * 5.2), q: 0.65, sampleRate: sampleRate)
                sampleLpR.set(cutoffHz: min(2600.0, f0 * 5.2), q: 0.65, sampleRate: sampleRate)
            } else {
                sampleZone = nil
            }
        } else {
            // Real soft-mallet vibraphone impact fused cleanly into bronze attack transient (zero white-noise fizz!)
            let vibeMidi = max(41, min(76, targetMidi + (f0 < 170.0 ? 12 : 0)))
            if let vz = bank.nearestZone(instrument: .vibe, midi: vibeMidi) {
                sampleZone = vz
                let zHz = 440.0 * pow(2.0, Double(vz.midi - 69) / 12.0)
                let targetSampleHz = (f0 < 170.0) ? (f0 * 2.0) : f0
                sampleRateRatio = max(0.5, min(1.8, targetSampleHz / zHz))
                samplePos = 0
                sampleGain = velocity * (archetype == .zenRinBell ? 0.14 : 0.19)
                sampleTau = archetype == .zenRinBell ? 0.45 : 0.34
                sampleLpL.reset(); sampleLpR.reset()
                let cut = archetype == .zenRinBell ? 3200.0 : (720.0 + (1.0 - malletSoftness) * 780.0)
                sampleLpL.set(cutoffHz: cut, q: 0.68, sampleRate: sampleRate)
                sampleLpR.set(cutoffHz: cut, q: 0.68, sampleRate: sampleRate)
            } else {
                sampleZone = nil
            }
        }

        let spread: Float = archetype == .zenRinBell ? 0.14 : 0.25
        let panA = max(-0.92, min(0.92, pan - spread))
        let panB = max(-0.92, min(0.92, pan + spread))
        let angA = (panA + 1.0) * 0.25 * Float.pi
        let angB = (panB + 1.0) * 0.25 * Float.pi
        panAL = cos(angA); panAR = sin(angA)
        panBL = cos(angB); panBR = sin(angB)
    }

    @inline(__always)
    mutating func step(dt: Double, sineTable: [Float]) -> (Float, Float) {
        guard active else { return (0, 0) }
        age += dt
        if age >= maxAge {
            active = false
            return (0, 0)
        }

        let bloom: Float = age < bloomSec ? Float(AudioMath.smoothstep(age / bloomSec)) : 1.0
        let decayAge = max(0.0, age - bloomSec * 0.45)
        let e1 = bloom * Float(exp(-decayAge / tau0))
        if e1 < 0.00012 && age > bloomSec {
            active = false
            return (0, 0)
        }

        // Authentic nonlinear bronze mode-coupling swell (overtones bloom warmly 0.7..1.8s after strike!)
        let swellT = age / 1.35
        let nlBloom = 1.0 + couplingBloom * Float(swellT * exp(-swellT))
        let e2 = bloom * Float(exp(-decayAge / (tau0 * 0.56))) * nlBloom
        let e3 = bloom * Float(exp(-decayAge / (tau0 * 0.26))) * (0.85 + 0.15 * nlBloom)
        let e4 = bloom * Float(exp(-decayAge / (tau0 * 0.10)))
        let eSub = bloom * Float(exp(-decayAge / (tau0 * 0.74)))

        let droop = age < 1.2 ? (1.0 + droopRatio * exp(-age / 0.18)) : 1.0
        let f = f0 * droop

        p1a += f * dt;               if p1a >= 1.0 { p1a -= floor(p1a) }
        p1b += (f + df1) * dt;       if p1b >= 1.0 { p1b -= floor(p1b) }
        p2a += (f * r2) * dt;        if p2a >= 1.0 { p2a -= floor(p2a) }
        p2b += (f * r2 + df2) * dt;  if p2b >= 1.0 { p2b -= floor(p2b) }

        var sigA = TimbreBank.lookup(sineTable, phase01: p1a) * w1a * e1
                 + TimbreBank.lookup(sineTable, phase01: p2a) * w2a * e2
        var sigB = TimbreBank.lookup(sineTable, phase01: p1b) * w1b * e1
                 + TimbreBank.lookup(sineTable, phase01: p2b) * w2b * e2

        if w3a > 0 && e3 > 0.0005 {
            p3a += (f * r3) * dt;       if p3a >= 1.0 { p3a -= floor(p3a) }
            p3b += (f * r3 + df3) * dt; if p3b >= 1.0 { p3b -= floor(p3b) }
            sigA += TimbreBank.lookup(sineTable, phase01: p3a) * w3a * e3
            sigB += TimbreBank.lookup(sineTable, phase01: p3b) * w3b * e3
        }
        if w4 > 0 && e4 > 0.0008 {
            p4 += (f * r4) * dt; if p4 >= 1.0 { p4 -= floor(p4) }
            let s4 = TimbreBank.lookup(sineTable, phase01: p4) * w4 * e4
            sigA += s4 * 0.5; sigB += s4 * 0.5
        }
        if wSub > 0 && eSub > 0.0005 {
            pSub += (f * 0.5) * dt; if pSub >= 1.0 { pSub -= floor(pSub) }
            let sub = TimbreBank.lookup(sineTable, phase01: pSub) * wSub * eSub
            sigA += sub * 0.5; sigB += sub * 0.5
        }

        // Fuse real CC0 acoustic mallet attack / friction-glass body
        var accL: Float = 0
        var accR: Float = 0
        if let z = sampleZone {
            let idx = Int(samplePos)
            if idx >= 0 && idx < z.frameCount - 2 {
                let frac = Float(samplePos - floor(samplePos))
                let rawL = z.sampleL(idx) + (z.sampleL(idx + 1) - z.sampleL(idx)) * frac
                let rawR = z.sampleR(idx) + (z.sampleR(idx + 1) - z.sampleR(idx)) * frac
                let sEnv = bloom * Float(exp(-decayAge / sampleTau)) * sampleGain
                if sEnv > 0.00015 {
                    let fL = sampleLpL.lowpass(rawL) * sEnv
                    let fR = sampleLpR.lowpass(rawR) * sEnv
                    let mono = 0.5 * (fL + fR)
                    let midPanL = 0.5 * (panAL + panBL)
                    let midPanR = 0.5 * (panAR + panBR)
                    accL = fL * 0.45 + mono * midPanL * 0.55
                    accR = fR * 0.45 + mono * midPanR * 0.55
                }
                samplePos += sampleRateRatio
            }
        }

        let outL = (sigA * panAL + sigB * panBL) * level + accL
        let outR = (sigA * panAR + sigB * panBR) * level + accR
        return (outL, outR)
    }
}

// MARK: - 5. Complete Deep Meditation Engine (3D Rain + Cello/Glass Drone + Hybrid Bowls + Post-Matrix Binaural)

struct DeepMeditationStepOutput {
    let dryL: Float
    let dryR: Float
    let revInL: Float
    let revInR: Float
    let postMatrixL: Float
    let postMatrixR: Float
    let breath01: Float
    let depth01: Float
    let binauralDeltaHz: Float
    let strike: MeditationStrikeEvent?
}

struct DeepMeditationEngine: @unchecked Sendable {
    private let sampleBank: StudioSampleBank
    private var rainField: StochasticRainField
    private var harmonicBed: OrganicHarmonicBed
    private var bowls: [HybridSanctuaryBowlVoice]
    private var nextBowlSlot: Int = 0
    private var breathPacer = ResonanceBreathPacer()
    private var rng: FastNoiseRNG

    // Eno self-listening Ma silence gate
    private var bowlTailRmsSq: Float = 0
    private var nextAllowedStrikeSec: Double = 1.65
    private var lastIntervalIdx: Int = -1
    private var hasPlayedReturnBell: Bool = false

    // Post-matrix pure binaural stereo carrier (bypassed around 185 Hz elliptical Side high-pass!)
    private var binPhaseL: Double = 0
    private var binPhaseR: Double = 0
    private var binHarmPhaseL: Double = 0
    private var binHarmPhaseR: Double = 0

    // Diagnostic telemetry for offline proofs
    private(set) var currentCarrierRootHz: Double = 146.83
    private(set) var currentBinauralDeltaHz: Double = 8.0
    private(set) var currentBreathBPM: Double = 8.5
    private(set) var strikeCount: Int = 0

    // Pure Just-Intonation intervals over the active root (zero melody / chord cliches)
    private static let jiRatios: [Double] = [
        1.0,       // Fundamental deep temple bonsho bowl
        1.5,       // Pure fifth (3:2) temple bowl
        2.0,       // Octave singing friction bowl
        2.25,      // Warm ninth (9:4) singing friction bowl
        3.0,       // Twelfth luminous bowl
        4.0        // High Zen rin overtone (rare + closing bell)
    ]

    init(bank: StudioSampleBank = .shared, seed: UInt64 = 0xD1AE_5A71_E001_0042) {
        self.sampleBank = bank
        self.rainField = StochasticRainField(bank: bank, seed: seed ^ 0x5A71_E9A1)
        self.harmonicBed = OrganicHarmonicBed(bank: bank)
        self.bowls = [HybridSanctuaryBowlVoice](repeating: HybridSanctuaryBowlVoice(), count: 6)
        self.rng = FastNoiseRNG(seed: seed)
    }

    mutating func reset(seed: UInt64? = nil) {
        if let seed {
            rng = FastNoiseRNG(seed: seed)
            rainField.reset(seed: seed ^ 0x5A71_E9A1)
        } else {
            rainField.reset()
        }
        harmonicBed.reset()
        for i in 0..<bowls.count { bowls[i].active = false }
        nextBowlSlot = 0
        breathPacer.reset()
        bowlTailRmsSq = 0
        nextAllowedStrikeSec = 1.65
        lastIntervalIdx = -1
        hasPlayedReturnBell = false
        binPhaseL = 0; binPhaseR = 0; binHarmPhaseL = 0; binHarmPhaseR = 0
        strikeCount = 0
    }

    @inline(__always)
    mutating func step(
        elapsedSec: Double,
        circadian: CircadianPhase,
        intensity: SoundIntensity,
        sessionProgress: Float, // < 0 if open-ended, else 0..1
        biofeedbackBreathBPM: Double? = nil,
        masterScale: Float,
        dt: Double,
        sampleRate: Double,
        sineTable: [Float]
    ) -> DeepMeditationStepOutput {
        // 1. Physiological Session Arc: Arrival (0..5m) -> Depth (5..25m+) -> Gentle Return (timed >90%)
        let depth01 = AudioMath.smoothstep((elapsedSec - 60.0) / 1080.0)
        let return01: Double = (sessionProgress >= 0.90 && sessionProgress <= 1.0)
            ? AudioMath.smoothstep(Double(sessionProgress - 0.90) / 0.10)
            : 0.0

        // 2. Subconscious Resonance Breath Pacer (8.5 -> 5.5 bpm auto, or Apple Watch HRV closed-loop target)
        let breath = breathPacer.step(elapsedSec: elapsedSec, dt: dt, targetBPMOverride: biofeedbackBreathBPM)
        currentBreathBPM = breathPacer.currentBPM

        // 3. Harmonic Root (circadian-voiced, glacial -1 fourth shift at minute 14..15)
        let baseRootHz: Double
        switch circadian {
        case .morning:   baseRootHz = 164.81 // E3
        case .afternoon: baseRootHz = 146.83 // D3
        case .night:     baseRootHz = 130.81 // C3
        }
        let rootShiftT = AudioMath.smoothstep((elapsedSec - 840.0) / 45.0) * (1.0 - return01)
        let rootHz = baseRootHz * (1.0 - 0.25 * rootShiftT)
        currentCarrierRootHz = rootHz

        // 4. Binaural Beat Descent Curve: Alpha 8.0 Hz -> Theta 4.2 Hz (and gentle Return to 8.5 Hz)
        let alphaToTheta = 8.0 - 3.8 * AudioMath.smoothstep(elapsedSec / 1080.0)
        let deltaHz = alphaToTheta * (1.0 - return01) + 8.5 * return01
        currentBinauralDeltaHz = deltaHz

        // 5. 3D Non-Repeating Rain & Cedar-Wind Breath Field
        let (rainL, rainR) = rainField.step(
            elapsedSec: elapsedSec,
            depth01: depth01,
            return01: return01,
            breath01: breath,
            dt: dt,
            sampleRate: sampleRate,
            sineTable: sineTable
        )

        // 6. Living Bowed-Cello & Friction-Glass Acoustic Harmonic Bed (zero static organ sines!)
        let (bedL, bedR) = harmonicBed.step(
            elapsedSec: elapsedSec,
            rootHz: rootHz,
            depth01: depth01,
            breath01: breath,
            dt: dt,
            sampleRate: sampleRate,
            sineTable: sineTable,
            rng: &rng
        )

        // 7. Eno Self-Listening Ma Gate + 3-Archetype Hybrid Bowl Conductor
        var strikeEvent: MeditationStrikeEvent? = nil
        let bowlTailRms = sqrt(max(0.0, bowlTailRmsSq))

        if sessionProgress >= 0.97 && sessionProgress <= 1.0 && !hasPlayedReturnBell {
            hasPlayedReturnBell = true
            let freq = rootHz * 4.0
            bowls[nextBowlSlot].trigger(
                archetype: .zenRinBell,
                freqHz: freq,
                pan: 0.0,
                velocity: 0.68,
                malletSoftness: 0.35,
                bank: sampleBank,
                rng: &rng,
                sampleRate: sampleRate
            )
            nextBowlSlot = (nextBowlSlot + 1) % bowls.count
            strikeCount &+= 1
            let midi = max(36, min(96, Int(round(69.0 + 12.0 * log2(freq / 440.0)))))
            strikeEvent = MeditationStrikeEvent(midi: midi, pan: 0.0, velocity: 0.68, isRinBell: true)
        } else if elapsedSec >= nextAllowedStrikeSec && bowlTailRms < 0.0068 && return01 < 0.4 {
            var idx = 0
            if strikeCount == 0 {
                idx = 0 // Welcoming warm deep temple bowl opens the sanctuary
            } else {
                for _ in 0..<4 {
                    let u = rng.nextUnit()
                    let cand: Int
                    if depth01 > 0.55 {
                        cand = u < 0.34 ? 0 : (u < 0.64 ? 1 : (u < 0.86 ? 2 : (u < 0.96 ? 3 : 4)))
                    } else {
                        cand = u < 0.24 ? 0 : (u < 0.48 ? 1 : (u < 0.72 ? 2 : (u < 0.87 ? 3 : (u < 0.96 ? 4 : 5))))
                    }
                    if cand != lastIntervalIdx {
                        idx = cand
                        break
                    }
                }
            }
            lastIntervalIdx = idx
            let ratio = Self.jiRatios[idx]
            let freq = rootHz * ratio

            // Timbral variety: deep strikes = Temple Bonsho, mid registers alternate Bonsho & Singing Friction Bowl, top = Zen Rin
            let archetype: SanctuaryBowlArchetype
            if idx == 5 {
                archetype = .zenRinBell
            } else if (idx == 2 || idx == 3) && (strikeCount % 2 == 1 || rng.nextUnit() < 0.58) {
                archetype = .singingFriction
            } else {
                archetype = .templeBonsho
            }

            let pan = Float((rng.nextUnit() - 0.5) * 0.88)
            let softness = (archetype == .zenRinBell) ? 0.38 : (0.56 + 0.28 * depth01 + rng.nextUnit() * 0.12)
            let vel = Float((0.64 + rng.nextUnit() * 0.22) * (1.0 - 0.16 * depth01))

            bowls[nextBowlSlot].trigger(
                archetype: archetype,
                freqHz: freq,
                pan: pan,
                velocity: vel,
                malletSoftness: min(0.92, softness),
                bank: sampleBank,
                rng: &rng,
                sampleRate: sampleRate
            )
            nextBowlSlot = (nextBowlSlot + 1) % bowls.count
            strikeCount &+= 1

            let midi = max(36, min(96, Int(round(69.0 + 12.0 * log2(freq / 440.0)))))
            strikeEvent = MeditationStrikeEvent(midi: midi, pan: pan, velocity: vel, isRinBell: archetype == .zenRinBell)

            let intensityScale: Double = intensity == .still ? 1.25 : (intensity == .deep ? 0.85 : 1.0)
            let minGap = (12.5 + 11.5 * depth01) * intensityScale
            let spanGap = (9.5 + 18.0 * depth01) * intensityScale
            nextAllowedStrikeSec = elapsedSec + minGap + rng.nextUnit() * spanGap
        }

        // Render active hybrid bowls & update Eno self-listening RMS envelope
        var bowlL: Float = 0
        var bowlR: Float = 0
        for i in 0..<bowls.count where bowls[i].active {
            let (bL, bR) = bowls[i].step(dt: dt, sineTable: sineTable)
            bowlL += bL
            bowlR += bR
        }
        let bowlSq = 0.5 * (bowlL * bowlL + bowlR * bowlR)
        bowlTailRmsSq += (bowlSq - bowlTailRmsSq) * 0.000085

        // 8. Post-Matrix Pure Binaural Carrier Pair (bypassed around 185 Hz elliptical Side high-pass!)
        let fadeIn = Float(AudioMath.smoothstep(elapsedSec / 4.2))
        let fL = rootHz - deltaHz * 0.5
        let fR = rootHz + deltaHz * 0.5
        binPhaseL += fL * dt; if binPhaseL >= 1.0 { binPhaseL -= floor(binPhaseL) }
        binPhaseR += fR * dt; if binPhaseR >= 1.0 { binPhaseR -= floor(binPhaseR) }

        let fhL = rootHz * 1.5 - deltaHz * 0.5
        let fhR = rootHz * 1.5 + deltaHz * 0.5
        binHarmPhaseL += fhL * dt; if binHarmPhaseL >= 1.0 { binHarmPhaseL -= floor(binHarmPhaseL) }
        binHarmPhaseR += fhR * dt; if binHarmPhaseR >= 1.0 { binHarmPhaseR -= floor(binHarmPhaseR) }

        let binGain = Float(0.056 * (0.90 + 0.18 * breath)) * fadeIn * masterScale
        let postL = (TimbreBank.lookup(sineTable, phase01: binPhaseL)
                   + TimbreBank.lookup(sineTable, phase01: binHarmPhaseL) * 0.18) * binGain
        let postR = (TimbreBank.lookup(sineTable, phase01: binPhaseR)
                   + TimbreBank.lookup(sineTable, phase01: binHarmPhaseR) * 0.18) * binGain

        // Spatial dry vs hall balance: keep exterior rain mostly dry, bowls & cello/glass deeply seated in warm cedar hall
        let dryL = rainL + bowlL * 0.70 + bedL * 0.85
        let dryR = rainR + bowlR * 0.70 + bedR * 0.85
        let revInL = bowlL * 1.08 + bedL * 0.72 + rainL * 0.12
        let revInR = bowlR * 1.08 + bedR * 0.72 + rainR * 0.12

        return DeepMeditationStepOutput(
            dryL: dryL,
            dryR: dryR,
            revInL: revInL,
            revInR: revInR,
            postMatrixL: postL,
            postMatrixR: postR,
            breath01: Float(breath),
            depth01: Float(depth01 * (1.0 - return01 * 0.85)),
            binauralDeltaHz: Float(deltaHz),
            strike: strikeEvent
        )
    }
}
