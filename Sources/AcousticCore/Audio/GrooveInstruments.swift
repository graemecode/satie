import Foundation

// Synthesized groove voices for Low Sun: a drum kit, a flatwound electric bass and a suitcase
// electric piano. Ported from satie-engine (Rust). All three are physical/modal models, so they
// need no samples, and every voice pool is allocated up front so the audio thread never allocates.

// MARK: - RBJ biquad (peaking and shelving EQ)

struct GrooveBiquad: Sendable {
    private var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    private var z1: Float = 0, z2: Float = 0

    static func peaking(_ hz: Double, gainDB: Double, q: Double, sampleRate: Double) -> GrooveBiquad {
        let a = pow(10.0, gainDB / 40.0)
        let w = 2.0 * Double.pi * hz / sampleRate
        let alpha = sin(w) / (2.0 * q)
        return GrooveBiquad(
            b0: 1 + alpha * a, b1: -2 * cos(w), b2: 1 - alpha * a,
            a0: 1 + alpha / a, a1: -2 * cos(w), a2: 1 - alpha / a
        )
    }

    static func shelf(_ hz: Double, gainDB: Double, high: Bool, sampleRate: Double) -> GrooveBiquad {
        let a = pow(10.0, gainDB / 40.0)
        let w = 2.0 * Double.pi * hz / sampleRate
        let cw = cos(w)
        let alpha = sin(w) / 2.0 * sqrt(2.0)
        let sa = 2.0 * sqrt(a) * alpha
        if high {
            return GrooveBiquad(
                b0: a * ((a + 1) + (a - 1) * cw + sa), b1: -2 * a * ((a - 1) + (a + 1) * cw), b2: a * ((a + 1) + (a - 1) * cw - sa),
                a0: (a + 1) - (a - 1) * cw + sa, a1: 2 * ((a - 1) - (a + 1) * cw), a2: (a + 1) - (a - 1) * cw - sa
            )
        }
        return GrooveBiquad(
            b0: a * ((a + 1) - (a - 1) * cw + sa), b1: 2 * a * ((a - 1) - (a + 1) * cw), b2: a * ((a + 1) - (a - 1) * cw - sa),
            a0: (a + 1) + (a - 1) * cw + sa, a1: -2 * ((a - 1) + (a + 1) * cw), a2: (a + 1) + (a - 1) * cw - sa
        )
    }

    init() {}

    private init(b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) {
        self.b0 = Float(b0 / a0); self.b1 = Float(b1 / a0); self.b2 = Float(b2 / a0)
        self.a1 = Float(a1 / a0); self.a2 = Float(a2 / a0)
    }

    @inline(__always)
    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    mutating func reset() { z1 = 0; z2 = 0 }
}

// MARK: - Drum kit

/// Drum sounds are scheduled as score events whose MIDI note follows General MIDI percussion.
public enum GrooveDrum: Int, Sendable, CaseIterable {
    case kick = 36
    case rim = 37
    case snare = 38
    case ghostSnare = 40
    case shaker = 42
    case openHat = 46
    case tightHat = 44
}

private let besselRatios: [Double] = [1.000, 1.594, 2.136, 2.296, 2.653, 2.917]
private let besselGains: [Float] = [1.00, 0.52, 0.34, 0.28, 0.19, 0.14]
private let woodRatios: [Double] = [1.0, 2.756, 4.18, 5.404]
private let hatRingHz: [Double] = [205.3, 304.4, 369.6, 522.7, 540.0, 800.0]

struct GrooveDrumHit: Sendable {
    var active = false
    var kind: GrooveDrum = .kick
    var age: Double = 0
    var maxAge: Double = 0.1
    var p0: Double = 0, p1: Double = 0, p2: Double = 0, p3: Double = 0, p4: Double = 0, p5: Double = 0
    var baseHz: Double = 50
    var dropHz: Double = 90
    var dropTau: Double = 0.02
    var vel: Float = 0.8
    var gain: Float = 0
    var panL: Float = 0.707
    var panR: Float = 0.707
    var bp = CytomicSVF(cutoffHz: 1200, q: 1.5)
    var hp = CytomicSVF(cutoffHz: 5000, q: 0.707)
    var wire = CytomicSVF(cutoffHz: 3400, q: 1.2)

    @inline(__always)
    mutating func phase(_ m: Int, _ inc: Double) -> Double {
        switch m {
        case 0: p0 += inc; if p0 >= 1 { p0 -= floor(p0) }; return p0
        case 1: p1 += inc; if p1 >= 1 { p1 -= floor(p1) }; return p1
        case 2: p2 += inc; if p2 >= 1 { p2 -= floor(p2) }; return p2
        case 3: p3 += inc; if p3 >= 1 { p3 -= floor(p3) }; return p3
        case 4: p4 += inc; if p4 >= 1 { p4 -= floor(p4) }; return p4
        default: p5 += inc; if p5 >= 1 { p5 -= floor(p5) }; return p5
        }
    }
}

struct GrooveDrumKit: Sendable {
    private var hits = [GrooveDrumHit](repeating: GrooveDrumHit(), count: 20)
    /// Kick envelope follower, used to duck the pad and reverb a little on each kick.
    private(set) var kickEnv: Float = 0

    mutating func reset() {
        for i in 0..<hits.count { hits[i].active = false }
        kickEnv = 0
    }

    mutating func trigger(_ kind: GrooveDrum, velocity: Double, gain: Float, pan: Double, rng: inout FastNoiseRNG, sampleRate: Double) {
        var slot = 0
        var oldest = -1.0
        for i in 0..<hits.count {
            if !hits[i].active { slot = i; oldest = .infinity; break }
            if hits[i].age > oldest { oldest = hits[i].age; slot = i }
        }
        let pitchJit = 0.96 + 0.08 * rng.nextUnit()
        let filtJit = 0.88 + 0.26 * rng.nextUnit()
        let angle = Float((max(-0.85, min(0.85, pan)) + 1.0) * 0.25 * Double.pi)
        var h = GrooveDrumHit()
        h.active = true
        h.kind = kind
        h.vel = Float(max(0.15, min(1.0, velocity)))
        h.gain = gain * (0.45 + 0.55 * h.vel)
        h.panL = cos(angle)
        h.panR = sin(angle)
        let v = Double(h.vel)
        switch kind {
        case .kick:
            h.maxAge = 0.34
            h.baseHz = 47.0 * pitchJit
            h.dropHz = (84.0 + 36.0 * v) * pitchJit
            h.dropTau = 0.019
            h.bp.set(cutoffHz: 175.0 * filtJit, q: 1.1, sampleRate: sampleRate)
            h.wire.set(cutoffHz: 1300.0 * filtJit, q: 1.4, sampleRate: sampleRate)
        case .snare, .ghostSnare:
            h.maxAge = kind == .ghostSnare ? 0.16 : 0.25
            h.baseHz = 182.0 * pitchJit
            h.dropHz = 44.0 * pitchJit
            h.dropTau = 0.014
            h.bp.set(cutoffHz: 1850.0 * filtJit, q: 0.8, sampleRate: sampleRate)
            h.hp.set(cutoffHz: 480.0, q: 0.707, sampleRate: sampleRate)
            h.wire.set(cutoffHz: 3900.0 * filtJit, q: 1.3, sampleRate: sampleRate)
        case .rim:
            h.maxAge = 0.11
            h.baseHz = 710.0 * pitchJit
            h.dropHz = 120.0
            h.dropTau = 0.005
            h.bp.set(cutoffHz: 1320.0 * filtJit, q: 2.8, sampleRate: sampleRate)
        case .shaker:
            h.maxAge = 0.085
            h.bp.set(cutoffHz: (6200.0 + 1900.0 * v) * filtJit, q: 1.25, sampleRate: sampleRate)
            h.hp.set(cutoffHz: 3900.0, q: 0.707, sampleRate: sampleRate)
            h.wire.set(cutoffHz: 9200.0 * filtJit, q: 1.8, sampleRate: sampleRate)
        case .tightHat:
            h.maxAge = 0.075
            h.bp.set(cutoffHz: (8200.0 + 1600.0 * v) * filtJit, q: 1.6, sampleRate: sampleRate)
            h.hp.set(cutoffHz: 6200.0, q: 0.707, sampleRate: sampleRate)
            h.wire.set(cutoffHz: 10400.0 * filtJit, q: 1.8, sampleRate: sampleRate)
        case .openHat:
            h.maxAge = 0.24
            h.bp.set(cutoffHz: 7400.0 * filtJit, q: 0.95, sampleRate: sampleRate)
            h.hp.set(cutoffHz: 4300.0, q: 0.707, sampleRate: sampleRate)
            h.wire.set(cutoffHz: 10400.0 * filtJit, q: 1.6, sampleRate: sampleRate)
        }
        hits[slot] = h
    }

    /// Returns (kick, mono) and (tops, stereo).
    @inline(__always)
    mutating func step(dt: Double, rng: inout FastNoiseRNG) -> (kick: Float, topL: Float, topR: Float) {
        var kick: Float = 0
        var topL: Float = 0
        var topR: Float = 0
        for i in 0..<hits.count where hits[i].active {
            let t = hits[i].age
            hits[i].age += dt
            if t >= hits[i].maxAge { hits[i].active = false; continue }
            let n = rng.nextBipolar()
            switch hits[i].kind {
            case .kick:
                let f = hits[i].baseHz + hits[i].dropHz * exp(-t / hits[i].dropTau)
                var membrane: Float = 0
                for m in 0..<4 {
                    let ph = hits[i].phase(m, f * besselRatios[m] * dt)
                    let tau = 0.095 / (1.0 + 1.8 * Double(m))
                    membrane += Float(sin(ph * 2.0 * Double.pi) * exp(-t / tau)) * besselGains[m]
                }
                let wool = hits[i].bp.bandpass(n) * Float(exp(-t / 0.016)) * 0.45
                let slap = hits[i].wire.bandpass(n) * Float(exp(-t / 0.006)) * 0.16 * hits[i].vel
                let att = Float(1.0 - exp(-t / 0.0022))
                kick += tanh((membrane * 0.78 + wool + slap) * att * 1.35) * hits[i].gain
            case .snare, .ghostSnare:
                let f = hits[i].baseHz + hits[i].dropHz * exp(-t / hits[i].dropTau)
                var shell: Float = 0
                for m in 0..<6 {
                    let ph = hits[i].phase(m, f * besselRatios[m] * dt)
                    let tau = 0.055 / (1.0 + 0.9 * Double(m))
                    shell += Float(sin(ph * 2.0 * Double.pi) * exp(-t / tau)) * besselGains[m]
                }
                let wireEnv = Float((1.0 - exp(-t / 0.005)) * exp(-t / 0.072))
                let rattle = (0.45 + 0.55 * min(1.0, abs(shell))) * wireEnv
                let wires = hits[i].hp.highpass(hits[i].bp.bandpass(n) * 0.75 + hits[i].wire.bandpass(n) * 0.55) * rattle
                let s = (shell * 0.34 + wires * 0.85) * hits[i].gain
                topL += s * hits[i].panL; topR += s * hits[i].panR
            case .rim:
                var wood: Float = 0
                let f = hits[i].baseHz + hits[i].dropHz * exp(-t / hits[i].dropTau)
                for m in 0..<4 {
                    let ph = hits[i].phase(m, f * woodRatios[m] * dt)
                    let tau = 0.018 / (1.0 + 0.85 * Double(m))
                    wood += Float(sin(ph * 2.0 * Double.pi) * exp(-t / tau)) * (0.8 / Float(1 + m))
                }
                let click = hits[i].bp.bandpass(n) * Float(exp(-t / 0.007)) * 0.5
                let s = (wood + click) * hits[i].gain
                topL += s * hits[i].panL; topR += s * hits[i].panR
            case .shaker:
                let e1 = (1.0 - exp(-t / 0.006)) * exp(-t / 0.016)
                let e2 = t > 0.012 ? exp(-(t - 0.012) / 0.022) * 0.45 : 0.0
                let body = hits[i].hp.highpass(hits[i].bp.bandpass(n) * 0.8 + hits[i].wire.bandpass(n) * 0.35)
                let s = body * Float(e1 + e2) * hits[i].gain
                topL += s * hits[i].panL; topR += s * hits[i].panR
            case .tightHat:
                var metal: Float = 0
                for m in 0..<6 { metal += hits[i].phase(m, hatRingHz[m] * dt) < 0.5 ? 1 : -1 }
                let src = metal * 0.14 + n * 0.35
                let env = Float((1.0 - exp(-t / 0.0012)) * exp(-t / 0.022))
                let s = hits[i].hp.highpass(hits[i].bp.bandpass(src) * 0.75 + hits[i].wire.bandpass(src) * 0.55) * env * hits[i].gain
                topL += s * hits[i].panL; topR += s * hits[i].panR
            case .openHat:
                let env = Float((1.0 - exp(-t / 0.005)) * exp(-t / 0.068))
                let s = hits[i].hp.highpass(hits[i].bp.bandpass(n) * 0.72 + hits[i].wire.bandpass(n) * 0.48) * env * hits[i].gain
                topL += s * hits[i].panL; topR += s * hits[i].panR
            }
        }
        let a = abs(kick)
        kickEnv += (a - kickEnv) * (a > kickEnv ? 0.02 : 0.00035)
        return (kick, topL, topR)
    }
}

// MARK: - Flatwound electric bass (modal string)

private let bassModes = 20
private let bassVoiceCount = 4

/// Per-voice scalars. The modal filter coefficients and states live in flat buffers on
/// `FlatwoundBass`, read through raw pointers, so the per-sample loop does no array bookkeeping.
struct FlatwoundBassVoice: Sendable {
    var active = false
    var modeCount = 0
    var exc: Float = 0
    var vel: Float = 0.8
    var gain: Float = 0
    var age = 0
    var holdSamples = 0
    var releaseSamples = 1
    var thump: Float = 0
    var dynLp: Float = 0
    var dynCoeff: Float = 0.9
}

struct FlatwoundBass: Sendable {
    private var voices = [FlatwoundBassVoice](repeating: FlatwoundBassVoice(), count: bassVoiceCount)
    // [voice * bassModes + mode]
    private var coefB = [Float](repeating: 0, count: bassVoiceCount * bassModes)
    private var coefA1 = [Float](repeating: 0, count: bassVoiceCount * bassModes)
    private var coefA2 = [Float](repeating: 0, count: bassVoiceCount * bassModes)
    private var stY1 = [Float](repeating: 0, count: bassVoiceCount * bassModes)
    private var stY2 = [Float](repeating: 0, count: bassVoiceCount * bassModes)
    private var pickupRes = GrooveBiquad()
    private var subShelf = GrooveBiquad()
    private var pickupLp = CytomicSVF(cutoffHz: 1350, q: 0.72)
    private var hpSub = CytomicSVF(cutoffHz: 32, q: 0.707)
    private var configuredRate: Double = 0

    mutating func reset() {
        for i in 0..<voices.count { voices[i].active = false }
        pickupRes.reset(); subShelf.reset(); pickupLp.reset(); hpSub.reset()
    }

    mutating func pluck(midi: Int, duration: Double, velocity: Double, gain: Float, rng: inout FastNoiseRNG, sampleRate: Double) {
        if configuredRate != sampleRate {
            configuredRate = sampleRate
            pickupRes = .peaking(740, gainDB: 1.4, q: 2.2, sampleRate: sampleRate)
            subShelf = .shelf(95, gainDB: 3.2, high: false, sampleRate: sampleRate)
            pickupLp.set(cutoffHz: 1350, q: 0.72, sampleRate: sampleRate)
            hpSub.set(cutoffHz: 32, q: 0.707, sampleRate: sampleRate)
        }
        // Keep the line mono and clean: notes already ringing are released when a new one starts.
        for i in 0..<voices.count where voices[i].active && Double(voices[i].age) > 0.04 * sampleRate {
            voices[i].holdSamples = min(voices[i].holdSamples, voices[i].age)
        }
        var slot = 0
        var oldest = -1
        for i in 0..<voices.count {
            if !voices[i].active { slot = i; oldest = Int.max; break }
            if voices[i].age > oldest { oldest = voices[i].age; slot = i }
        }

        let det = (rng.nextUnit() - 0.5) * 3.0
        let f0 = Float(440.0 * pow(2.0, (Double(midi - 69) + det / 100.0) / 12.0))
        let sr = Float(sampleRate)
        let v = Float(max(0.2, min(1.0, velocity)))
        let tension = f0 * f0 * 4.0
        let stiffness = (0.045 / max(100, tension)) * 9.869604
        let pluckPos: Float = 0.23
        let pickupPos: Float = 0.27
        let fingerWidth: Float = 0.075 + 0.045 * (1 - v)
        let baseDecay: Float = 1.65
        let hfDamping: Float = 0.0028

        var count = 0
        let base = slot * bassModes
        for i in 0..<bassModes {
            let n = Float(i + 1)
            let freq = f0 * n * (1 + stiffness * stiffness * n * n).squareRoot()
            if freq >= sr * 0.44 || freq >= 6500 { break }
            var amp = (2 / (Float.pi * Float.pi * n * n * pluckPos * (1 - pluckPos)))
                * sin(Float.pi * n * pluckPos)
                * max(0.12, abs(sin(Float.pi * n * pickupPos)))
            if n >= 2 / (Float.pi * fingerWidth) { amp *= 2 / (Float.pi * fingerWidth * n) }
            if i == 0 { amp *= 1.55 } else if i == 1 { amp *= 1.25 }
            let decay = baseDecay + hfDamping * freq * 2 * Float.pi
            let radius = exp(-decay / sr)
            let omega = 2 * Float.pi * freq / sr
            coefB[base + i] = amp * radius * sin(omega)
            coefA1[base + i] = -2 * radius * cos(omega)
            coefA2[base + i] = radius * radius
            stY1[base + i] = 0
            stY2[base + i] = 0
            count += 1
        }
        voices[slot].active = true
        voices[slot].modeCount = count
        voices[slot].exc = 1
        voices[slot].vel = v
        voices[slot].gain = gain * 0.55
        voices[slot].age = 0
        voices[slot].holdSamples = Int(max(0.10, duration) * sampleRate)
        voices[slot].releaseSamples = max(64, Int(0.085 * sampleRate))
        voices[slot].thump = 0.22 * v
        voices[slot].dynLp = 0
        voices[slot].dynCoeff = exp(-2 * Float.pi * (f0 * 2.2) / sr)
    }

    @inline(__always)
    mutating func step(rng: inout FastNoiseRNG, sampleRate: Double) -> Float {
        var sum: Float = 0
        let maxAge = Int(6.0 * sampleRate)
        coefB.withUnsafeBufferPointer { cb in
        coefA1.withUnsafeBufferPointer { ca1 in
        coefA2.withUnsafeBufferPointer { ca2 in
        stY1.withUnsafeMutableBufferPointer { y1 in
        stY2.withUnsafeMutableBufferPointer { y2 in
        voices.withUnsafeMutableBufferPointer { vs in
            for k in 0..<bassVoiceCount where vs[k].active {
                var s: Float = 0
                let exc = vs[k].exc
                let base = k * bassModes
                for i in base..<(base + vs[k].modeCount) {
                    let y = exc * cb[i] - ca1[i] * y1[i] - ca2[i] * y2[i]
                    y2[i] = y1[i]
                    y1[i] = y
                    s += y
                }
                vs[k].exc = 0
                vs[k].dynLp = (1 - vs[k].dynCoeff) * s + vs[k].dynCoeff * vs[k].dynLp
                var out = s * vs[k].vel + (1 - vs[k].vel) * 1.35 * vs[k].dynLp
                if vs[k].thump > 0.002 {
                    vs[k].thump *= 0.992
                    out += rng.nextBipolar() * vs[k].thump * 0.10
                }
                var env: Float = 1
                if vs[k].age > vs[k].holdSamples {
                    let ra = vs[k].age - vs[k].holdSamples
                    if ra >= vs[k].releaseSamples { vs[k].active = false; continue }
                    let u = 1 - Float(ra) / Float(vs[k].releaseSamples)
                    env = u * u
                }
                sum += out * env * vs[k].gain * (0.55 + 0.45 * vs[k].vel)
                vs[k].age += 1
                if vs[k].age > maxAge { vs[k].active = false }
            }
        }}}}}}
        let p = pickupLp.lowpass(pickupRes.process(hpSub.highpass(sum)))
        return tanh(subShelf.process(p) * 1.45) * 0.85
    }
}

// MARK: - Suitcase electric piano (modal tine)

private let tineRatios: [Double] = [1.000, 2.001, 3.004, 6.267, 17.548]
private let tineModes = 5

/// Per-voice scalars. Oscillators are rotating phasors and envelopes are one-pole multipliers
/// held in flat buffers on `SuitcaseElectricPiano`, so a sample costs a few multiplies per mode.
struct SuitcaseTineVoice: Sendable {
    var active = false
    var att: Double = 0
    var attCoeff: Double = 0.01
    var rel: Double = 1
    var relCoeff: Double = 1
    var bark: Double = 1.35
    var barkExtra: Double = 0
    var barkDecay: Double = 1
    var thumpEnv: Double = 0
    var thumpDecay: Double = 1
    var age: Double = 0
    var dur: Double = 1
    var vel: Double = 0.7
    var gain: Float = 0
    var panL: Float = 0.7
    var panR: Float = 0.7
    var lp = CytomicSVF(cutoffHz: 3200, q: 0.707)
    var hammer = CytomicSVF(cutoffHz: 420, q: 1.6)
}

struct SuitcaseElectricPiano: Sendable {
    private static let voiceCount = 16
    private var voices = [SuitcaseTineVoice](repeating: SuitcaseTineVoice(), count: voiceCount)
    // [voice * tineModes + mode]: phasor (re, im), rotation (cw, sw), amplitude and its decay
    private var re = [Double](repeating: 0, count: voiceCount * tineModes)
    private var im = [Double](repeating: 0, count: voiceCount * tineModes)
    private var cw = [Double](repeating: 1, count: voiceCount * tineModes)
    private var sw = [Double](repeating: 0, count: voiceCount * tineModes)
    private var env = [Double](repeating: 0, count: voiceCount * tineModes)
    private var decay = [Double](repeating: 1, count: voiceCount * tineModes)
    private var lowL = GrooveBiquad(), lowR = GrooveBiquad(), hiL = GrooveBiquad(), hiR = GrooveBiquad()
    private var configuredRate: Double = 0
    private var tremPhase: Double = 0

    mutating func reset() {
        for i in 0..<voices.count { voices[i].active = false }
        lowL.reset(); lowR.reset(); hiL.reset(); hiR.reset()
    }

    mutating func trigger(midi: Int, duration: Double, velocity: Double, gain: Float, pan: Double, rng: inout FastNoiseRNG, sampleRate: Double) {
        if configuredRate != sampleRate {
            configuredRate = sampleRate
            lowL = .shelf(135, gainDB: 0.0, high: false, sampleRate: sampleRate)
            lowR = .shelf(135, gainDB: 0.0, high: false, sampleRate: sampleRate)
            hiL = .shelf(3800, gainDB: -1.0, high: true, sampleRate: sampleRate)
            hiR = .shelf(3800, gainDB: -1.0, high: true, sampleRate: sampleRate)
        }
        var slot = 0
        var oldest = -1.0
        for i in 0..<voices.count {
            if !voices[i].active { slot = i; oldest = .infinity; break }
            if voices[i].age > oldest { oldest = voices[i].age; slot = i }
        }
        let dt = 1.0 / sampleRate
        let det = (rng.nextUnit() - 0.5) * 3.6
        let f0 = 440.0 * pow(2.0, (Double(midi - 69) + det / 100.0) / 12.0)
        let vel = max(0.15, min(1.0, velocity))
        let tau1 = max(1.1, min(4.2, 3.8 - (log2(f0) - 6.5) * 0.45))
        // Upper modes are stronger than the Rust original: there the tone was close to a sine
        let taus = [tau1, tau1 * 0.45, tau1 * 0.26, 0.24, 0.05]
        let amps = [0.86, 0.44 * pow(vel, 0.9), 0.24 * pow(vel, 1.2), 0.30 * pow(vel, 1.3), 0.12 * pow(vel, 1.5)]
        let startPhase = [0.0, 0.12, 0.29, 0.0, 0.0]
        let nyq = sampleRate * 0.44
        for m in 0..<tineModes {
            let f = f0 * tineRatios[m]
            let w = 2.0 * Double.pi * f * dt
            let j = slot * tineModes + m
            cw[j] = cos(w)
            sw[j] = sin(w)
            re[j] = cos(2.0 * Double.pi * startPhase[m])
            im[j] = sin(2.0 * Double.pi * startPhase[m])
            env[j] = f < nyq ? amps[m] : 0
            decay[j] = exp(-dt / taus[m])
        }
        let angle = Float((max(-0.85, min(0.85, pan)) + 1.0) * 0.25 * Double.pi)
        voices[slot].active = true
        voices[slot].att = 0
        voices[slot].attCoeff = 1.0 - exp(-dt / (0.003 + 0.0025 * (1.0 - vel)))
        voices[slot].rel = 1
        voices[slot].relCoeff = exp(-dt / 0.36)
        voices[slot].bark = 1.9
        voices[slot].barkExtra = 1.25 * vel * vel
        voices[slot].barkDecay = exp(-dt / 0.18)
        voices[slot].thumpEnv = 0.14 * vel
        voices[slot].thumpDecay = exp(-dt / 0.008)
        voices[slot].age = 0
        voices[slot].dur = max(0.16, duration)
        voices[slot].vel = vel
        voices[slot].gain = gain
        voices[slot].panL = cos(angle)
        voices[slot].panR = sin(angle)
        voices[slot].lp.reset()
        voices[slot].lp.set(cutoffHz: 2600.0 + 6000.0 * pow(vel, 1.2), q: 0.72, sampleRate: sampleRate)
        voices[slot].hammer.reset()
        voices[slot].hammer.set(cutoffHz: 320.0 + 260.0 * vel, q: 1.5, sampleRate: sampleRate)
    }

    @inline(__always)
    mutating func step(dt: Double, tremHz: Double, tremDepth: Float, rng: inout FastNoiseRNG, sampleRate: Double) -> (Float, Float) {
        var sumL: Float = 0
        var sumR: Float = 0
        let offset = 0.085
        let tanhOffset = tanh(offset)
        re.withUnsafeMutableBufferPointer { re in
        im.withUnsafeMutableBufferPointer { im in
        env.withUnsafeMutableBufferPointer { env in
        cw.withUnsafeBufferPointer { cw in
        sw.withUnsafeBufferPointer { sw in
        decay.withUnsafeBufferPointer { decay in
        voices.withUnsafeMutableBufferPointer { vs in
            for k in 0..<Self.voiceCount where vs[k].active {
                vs[k].age += dt
                let t = vs[k].age
                if t > vs[k].dur + 2.4 { vs[k].active = false; continue }
                var modal = 0.0
                let base = k * tineModes
                for j in base..<(base + tineModes) {
                    let r = re[j] * cw[j] - im[j] * sw[j]
                    let i = re[j] * sw[j] + im[j] * cw[j]
                    re[j] = r
                    im[j] = i
                    modal += i * env[j]
                    env[j] *= decay[j]
                }
                var thump = 0.0
                if vs[k].thumpEnv > 1e-5 && t < 0.025 {
                    thump = Double(vs[k].hammer.bandpass(rng.nextBipolar())) * vs[k].thumpEnv
                    vs[k].thumpEnv *= vs[k].thumpDecay
                }
                vs[k].att += (1.0 - vs[k].att) * vs[k].attCoeff
                if t > vs[k].dur {
                    vs[k].rel *= vs[k].relCoeff
                    if vs[k].rel < 0.001 { vs[k].active = false; continue } // -60 dB: done
                }
                vs[k].barkExtra *= vs[k].barkDecay
                let disp = (modal + thump) * vs[k].att * vs[k].rel
                let bark = vs[k].bark + vs[k].barkExtra
                let pickup = Float((tanh(disp * bark + offset) - tanhOffset) / pow(bark, 0.55))
                let shaped = vs[k].lp.lowpass(pickup) * vs[k].gain * (0.52 + 0.48 * Float(vs[k].vel))
                sumL += shaped * vs[k].panL
                sumR += shaped * vs[k].panR
            }
        }}}}}}}
        let eqL = hiL.process(lowL.process(sumL))
        let eqR = hiR.process(lowR.process(sumR))
        tremPhase += tremHz * dt
        if tremPhase >= 1 { tremPhase -= floor(tremPhase) }
        let lfo = Float(sin(tremPhase * 2 * .pi))
        let td = max(0, min(0.45, tremDepth))
        return (eqL * (1 - td + td * lfo), eqR * (1 - td - td * lfo))
    }
}
