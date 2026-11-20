import Accelerate
import Foundation

public struct AcousticSnapshot: Sendable {
    public static let pitchNames = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
    public static let fifthsOrder = [0, 7, 2, 9, 4, 11, 6, 1, 8, 3, 10, 5]
    public static let roomCBandOrder = [10, 6, 5, 9, 4, 3, 8, 2, 1, 7, 11, 12, 15, 19, 20, 16, 21, 22, 17, 23, 24, 18, 13, 14]

    public var bands24: [Float]          // 24 log-spaced perceptual levels [0...1]
    public var impulses24: [Float]       // 24 per-band transient spikes [0...1]
    public var chroma12: [Float]         // 12 semitone chromagram [0...1]
    public var waveL: [Float]            // 256 stereo left samples [-1...1]
    public var waveR: [Float]            // 256 stereo right samples [-1...1]
    public var tileHistory: [[Float]]    // 24 x 25 rolling sensor mosaic
    public var heatHistory: [[Float]]    // 48 x 24 scrolling thermal spectrogram

    public var bass: Float
    public var mid: Float
    public var treble: Float
    public var energy: Float
    public var flux: Float
    public var beat: Float
    public var tension: Float
    public var stereoCorrelation: Float
    public var centroid: Float
    public var rawRMS: Float
    public var isSilent: Bool
    public var detectedKey: String
    public var shortKey: String
    public var sampleRate: Double
    public var time: Double

    public static let empty = AcousticSnapshot(
        bands24: [Float](repeating: 0, count: 24),
        impulses24: [Float](repeating: 0, count: 24),
        chroma12: [Float](repeating: 0, count: 12),
        waveL: [Float](repeating: 0, count: 256),
        waveR: [Float](repeating: 0, count: 256),
        tileHistory: Array(repeating: [Float](repeating: 0, count: 25), count: 24),
        heatHistory: Array(repeating: [Float](repeating: 0, count: 24), count: 48),
        bass: 0,
        mid: 0,
        treble: 0,
        energy: 0,
        flux: 0,
        beat: 0,
        tension: 0,
        stereoCorrelation: 1,
        centroid: 0.35,
        rawRMS: 0,
        isSilent: true,
        detectedKey: "STANDBY",
        shortKey: "—",
        sampleRate: 48_000,
        time: 0
    )
}

/// Real-time Apple Accelerate (vDSP) DSP pipeline producing 24-band FFT, chromagram, key, flux & stereo waveform.
public final class AcousticDSP {
    private let fftSize = 4096
    private let log2n: vDSP_Length = 12 // 2^12 = 4096 (11.7 Hz bin resolution @ 48kHz)
    private let halfSize = 2048

    private let fftSetup: FFTSetup
    private var window: [Float]
    private var rawL: [Float]
    private var rawR: [Float]
    private var mono: [Float]
    private var realBuf: [Float]
    private var imagBuf: [Float]
    private var mags: [Float]

    private var bands24 = [Float](repeating: 0, count: 24)
    private var prevBands24 = [Float](repeating: 0, count: 24)
    private var impulses24 = [Float](repeating: 0, count: 24)
    private var chroma = [Float](repeating: 0, count: 12)
    private var chromaSmooth = [Float](repeating: 0, count: 12)
    private var waveL = [Float](repeating: 0, count: 256)
    private var waveR = [Float](repeating: 0, count: 256)
    private var tileHistory = Array(repeating: [Float](repeating: 0, count: 25), count: 24)
    private var heatHistory = Array(repeating: [Float](repeating: 0, count: 24), count: 48)

    private var agcPeak: Float = 0.25
    private var prevBass: Float = 0
    private var beat: Float = 0
    private var fluxSmooth: Float = 0
    private var silenceTimer: Double = 0
    private var tileTick: Double = 0
    private var heatTick: Double = 0
    private var time: Double = 0
    private var detectedKey = "STANDBY"
    private var shortKey = "—"

    // Zero-mean, unit-L2-normalized Krumhansl-Schmuckler key correlation profiles (true Pearson correlation)
    private let majorProfileNorm: [Float]
    private let minorProfileNorm: [Float]

    public init() {
        func normalizeProfile(_ raw: [Float]) -> [Float] {
            let mean = raw.reduce(0, +) / Float(raw.count)
            let centered = raw.map { $0 - mean }
            let norm = sqrt(centered.reduce(0) { $0 + $1 * $1 })
            return centered.map { $0 / max(1e-6, norm) }
        }
        self.majorProfileNorm = normalizeProfile([6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88])
        self.minorProfileNorm = normalizeProfile([6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17])

        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        self.window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&self.window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        self.rawL = [Float](repeating: 0, count: fftSize)
        self.rawR = [Float](repeating: 0, count: fftSize)
        self.mono = [Float](repeating: 0, count: fftSize)
        self.realBuf = [Float](repeating: 0, count: halfSize)
        self.imagBuf = [Float](repeating: 0, count: halfSize)
        self.mags = [Float](repeating: 0, count: halfSize)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    public func process(
        ringBuffer: StereoRingBuffer,
        sampleRate: Double,
        dt: Double,
        demoMode: Bool,
        sensitivity: SensitivityMode = .balanced
    ) -> AcousticSnapshot {
        let clampedDt = max(0.001, min(0.05, dt))
        time += clampedDt

        if demoMode {
            return processDemo(dt: clampedDt, sampleRate: sampleRate, sensitivity: sensitivity)
        }

        rawL.withUnsafeMutableBufferPointer { lPtr in
            rawR.withUnsafeMutableBufferPointer { rPtr in
                _ = ringBuffer.readLatest(count: fftSize, intoLeft: lPtr.baseAddress!, intoRight: rPtr.baseAddress!)
            }
        }

        var rmsL: Float = 0
        var rmsR: Float = 0
        vDSP_rmsqv(rawL, 1, &rmsL, vDSP_Length(fftSize))
        vDSP_rmsqv(rawR, 1, &rmsR, vDSP_Length(fftSize))
        let rawRMS = 0.5 * (rmsL + rmsR)

        var dotLR: Float = 0
        var energyL: Float = 0
        var energyR: Float = 0
        vDSP_dotpr(rawL, 1, rawR, 1, &dotLR, vDSP_Length(fftSize))
        vDSP_svesq(rawL, 1, &energyL, vDSP_Length(fftSize))
        vDSP_svesq(rawR, 1, &energyR, vDSP_Length(fftSize))
        let denom = sqrt(max(1e-9, energyL * energyR))
        let stereoCorr = rawRMS > 0.0005 ? max(-1.0, min(1.0, dotLR / denom)) : 1.0

        let waveGain = min(4.5, 0.42 / max(0.04, agcPeak)) * sensitivity.transientScale
        let startOffset = fftSize - 512
        for i in 0..<256 {
            let idx = startOffset + i * 2
            waveL[i] = max(-1.2, min(1.2, rawL[idx] * waveGain))
            waveR[i] = max(-1.2, min(1.2, rawR[idx] * waveGain))
        }

        if rawRMS < 0.00045 {
            silenceTimer += clampedDt
        } else {
            silenceTimer = 0
        }
        let isSilent = silenceTimer > 1.8

        var half: Float = 0.5
        vDSP_vadd(rawL, 1, rawR, 1, &mono, 1, vDSP_Length(fftSize))
        vDSP_vsmul(mono, 1, &half, &mono, 1, vDSP_Length(fftSize))
        vDSP_vmul(mono, 1, window, 1, &mono, 1, vDSP_Length(fftSize))

        realBuf.withUnsafeMutableBufferPointer { rPtr in
            imagBuf.withUnsafeMutableBufferPointer { iPtr in
                var split = DSPSplitComplex(realp: rPtr.baseAddress!, imagp: iPtr.baseAddress!)
                mono.withUnsafeBytes { rawBytes in
                    let complexPtr = rawBytes.bindMemory(to: DSPComplex.self)
                    vDSP_ctoz(complexPtr.baseAddress!, 2, &split, 1, vDSP_Length(halfSize))
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(halfSize))
            }
        }

        var invScale: Float = 1.0 / Float(fftSize * fftSize)
        vDSP_vsmul(mags, 1, &invScale, &mags, 1, vDSP_Length(halfSize))

        var frameMax: Float = 0
        vDSP_maxv(mags, 1, &frameMax, vDSP_Length(halfSize))
        let ampPeak = sqrt(frameMax)
        if ampPeak > agcPeak {
            agcPeak += (ampPeak - agcPeak) * Float(min(1.0, clampedDt * 14.0))
        } else {
            agcPeak = max(0.06, agcPeak - Float(clampedDt * 0.08))
        }

        let sr = max(16_000, sampleRate)
        let binHz = sr / Double(fftSize)
        var bSum: Float = 0
        var mSum: Float = 0
        var hSum: Float = 0
        var weighted: Float = 0
        var totalSpec: Float = 0.0001
        let gainDB = sensitivity.gainOffsetDB

        for i in 0..<24 {
            let fLo = 35.0 * pow(14_000.0 / 35.0, Double(i) / 24.0)
            let fHi = 35.0 * pow(14_000.0 / 35.0, Double(i + 1) / 24.0)
            let bLo = max(1, Int(floor(fLo / binHz)))
            let bHi = min(halfSize - 1, max(bLo + 1, Int(ceil(fHi / binHz))))

            var bandPower: Float = 0
            for k in bLo..<bHi { bandPower += mags[k] }
            let rmsBin = sqrt(bandPower / Float(max(1, bHi - bLo)))

            let tilt = 1.0 + Float(i) * 0.14
            let db = 20.0 * log10(max(1e-7, rmsBin * tilt)) + gainDB
            let agcOffset = max(-8.0, min(14.0, -20.0 * log10(max(0.05, agcPeak)) - 14.0))
            let norm = max(0, min(1, (db + 64.0 + agcOffset * 0.55) / 52.0))
            let target = isSilent ? 0 : pow(norm, 1.15)

            let rate = target > bands24[i] ? 24.0 : 9.5
            bands24[i] += (target - bands24[i]) * Float(min(1.0, clampedDt * rate))

            if i < 6 { bSum += bands24[i] }
            else if i < 15 { mSum += bands24[i] }
            else { hSum += bands24[i] }
            weighted += bands24[i] * (Float(i) / 23.0)
            totalSpec += bands24[i]
        }

        let bass = bSum / 6.0
        let mid = mSum / 9.0
        let treble = hSum / 9.0
        let energy = bass * 0.45 + mid * 0.35 + treble * 0.20
        let centroid = weighted / totalSpec

        let bassDelta = max(0, bass - prevBass)
        prevBass = bass
        if bassDelta > 0.055 {
            beat = min(1.0, beat + bassDelta * 5.2 * sensitivity.transientScale)
        }
        beat *= pow(0.045, Float(clampedDt))

        var fluxAcc: Float = 0
        for i in 0..<24 {
            let diff = max(0, bands24[i] - prevBands24[i])
            fluxAcc += diff
            if diff > 0.065 {
                impulses24[i] = min(1.0, impulses24[i] + diff * 4.8 * sensitivity.transientScale)
            }
            impulses24[i] *= pow(0.07, Float(clampedDt))
            prevBands24[i] = bands24[i]
        }
        fluxSmooth += (min(1.0, fluxAcc * 1.45) - fluxSmooth) * Float(min(1.0, clampedDt * 14.0))

        for i in 0..<12 { chroma[i] = 0 }
        if !isSilent {
            for k in 3..<halfSize {
                let hz = Double(k) * binHz
                if hz < 65.0 || hz > 2200.0 { continue }
                let power = mags[k]
                if power < 1e-8 { continue }
                let midi = Int(round(69.0 + 12.0 * log2(hz / 440.0)))
                let pc = ((midi % 12) + 12) % 12
                // Accumulate power (not sqrt) to preserve Hann window sidelobe rejection between semitones
                chroma[pc] += power
            }
            let maxC = max(1e-9, chroma.max() ?? 1e-9)
            for i in 0..<12 { chroma[i] = sqrt(chroma[i] / maxC) }
        }

        for i in 0..<12 {
            chromaSmooth[i] += (chroma[i] - chromaSmooth[i]) * Float(min(1.0, clampedDt * 3.2))
        }
        updateKeyEstimate(isSilent: isSilent)
        updateHistories(dt: clampedDt)

        let tension = min(1.0, fluxSmooth * 1.2 + (1.0 - abs(stereoCorr)) * 0.45)

        return AcousticSnapshot(
            bands24: bands24,
            impulses24: impulses24,
            chroma12: chromaSmooth,
            waveL: waveL,
            waveR: waveR,
            tileHistory: tileHistory,
            heatHistory: heatHistory,
            bass: bass,
            mid: mid,
            treble: treble,
            energy: energy,
            flux: fluxSmooth,
            beat: beat,
            tension: tension,
            stereoCorrelation: stereoCorr,
            centroid: centroid,
            rawRMS: rawRMS,
            isSilent: isSilent,
            detectedKey: detectedKey,
            shortKey: shortKey,
            sampleRate: sr,
            time: time
        )
    }

    private func updateKeyEstimate(isSilent: Bool) {
        if isSilent {
            detectedKey = "STANDBY"
            shortKey = "—"
            return
        }
        let meanC = chromaSmooth.reduce(0, +) / 12.0
        var bestScore: Float = -1e9
        var bestRoot = 0
        var bestIsMajor = false
        for root in 0..<12 {
            var maj: Float = 0
            var minScore: Float = 0
            for i in 0..<12 {
                let c = chromaSmooth[(root + i) % 12] - meanC
                maj += c * majorProfileNorm[i]
                minScore += c * minorProfileNorm[i]
            }
            if maj > bestScore { bestScore = maj; bestRoot = root; bestIsMajor = true }
            if minScore > bestScore { bestScore = minScore; bestRoot = root; bestIsMajor = false }
        }
        let name = AcousticSnapshot.pitchNames[bestRoot]
        detectedKey = bestIsMajor ? "\(name) MAJOR" : "\(name) MINOR"
        shortKey = bestIsMajor ? "\(name) MAJ" : "\(name) MIN"
    }

    private func updateHistories(dt: Double) {
        tileTick += dt
        if tileTick >= 0.05 {
            tileTick = 0
            for i in 0..<24 {
                for j in stride(from: 24, through: 1, by: -1) {
                    tileHistory[i][j] = tileHistory[i][j - 1]
                }
                tileHistory[i][0] = bands24[i]
            }
        }
        heatTick += dt
        if heatTick >= 0.055 {
            heatTick = 0
            heatHistory.removeFirst()
            heatHistory.append(bands24)
        }
    }

    private func processDemo(dt: Double, sampleRate: Double, sensitivity: SensitivityMode) -> AcousticSnapshot {
        let t = time
        let beatPhase = (t * 116.0 / 60.0).truncatingRemainder(dividingBy: 1.0)
        let kick = Float(pow(max(0.0, 1.0 - beatPhase * 3.4), 2.3))
        let hat = Float(pow(max(0.0, 1.0 - abs(beatPhase - 0.5) * 9.5), 2.0))
        let sweep = Float(0.5 + 0.5 * sin(t * 0.65))
        let scale = sensitivity.transientScale

        var b: Float = 0, m: Float = 0, h: Float = 0
        for i in 0..<24 {
            let f = Float(i) / 23.0
            let sub = exp(-pow((f - 0.08) / 0.13, 2)) * (0.40 + 0.60 * kick)
            let mid = exp(-pow((f - (0.36 + 0.14 * Float(sin(t * 0.8)))) / 0.18, 2)) * (0.32 + 0.46 * sweep)
            let hi = exp(-pow((f - 0.82) / 0.16, 2)) * (0.14 + 0.58 * hat + 0.18 * Float(sin(t * 8.5 + Double(i))))
            let rib = 0.12 * (0.5 + 0.5 * Float(sin(Double(i) * 0.9 - t * 3.6)))
            let target = min(1.0, max(0.04, (sub + mid + hi + rib) * (0.85 + 0.15 * scale)))
            bands24[i] += (target - bands24[i]) * Float(min(1.0, dt * 16.0))
            if i < 6 { b += bands24[i] } else if i < 15 { m += bands24[i] } else { h += bands24[i] }
        }

        let bass = b / 6.0, mid = m / 9.0, treble = h / 9.0
        let energy = bass * 0.45 + mid * 0.35 + treble * 0.20
        beat = min(1.0, max(beat * pow(0.055, Float(dt)), kick * scale))

        var fluxAcc: Float = 0
        for i in 0..<24 {
            let diff = max(0, bands24[i] - prevBands24[i])
            fluxAcc += diff
            if diff > 0.055 { impulses24[i] = min(1.0, impulses24[i] + diff * 4.5 * scale) }
            impulses24[i] *= pow(0.08, Float(dt))
            prevBands24[i] = bands24[i]
        }
        fluxSmooth += (min(1.0, fluxAcc * 1.4) - fluxSmooth) * Float(min(1.0, dt * 14.0))

        let chordIdx = Int(floor(t / 7.0)) % 3
        let chords = [[1, 5, 8, 0], [6, 9, 1, 4], [0, 3, 7, 10]]
        let active = chords[max(0, chordIdx)]
        for i in 0..<12 {
            let target: Float = active.contains(i)
                ? Float(0.76 + 0.22 * sin(t * 2.8 + Double(i)))
                : Float(0.08 + 0.06 * sin(t * 2.0 + Double(i) * 1.7))
            chromaSmooth[i] += (target - chromaSmooth[i]) * Float(min(1.0, dt * 3.5))
        }
        updateKeyEstimate(isSilent: false)
        updateHistories(dt: dt)

        for i in 0..<256 {
            let u = (Double(i) / 255.0) * Double.pi * 2.0
            let amp = 0.42 + Double(bass) * 0.48
            waveL[i] = Float(amp * (0.58 * sin(u * 2.0 + t * 5.2) + 0.28 * sin(u * 3.0 - t * 3.6 + Double(kick) * 1.2) + 0.14 * sin(u * 7.0 + t * 10.5) * Double(0.4 + treble)))
            waveR[i] = Float(amp * (0.58 * cos(u * 2.0 + t * 5.2 + 0.36 * sin(t * 0.85)) + 0.28 * sin(u * 3.5 + t * 4.0) + 0.14 * cos(u * 6.0 - t * 9.8) * Double(0.4 + treble)))
        }

        let stereoCorr = Float(0.62 + 0.30 * sin(t * 0.5))
        let tension = Float(0.22 + 0.52 * (0.5 + 0.5 * sin(t * 0.35)))

        return AcousticSnapshot(
            bands24: bands24,
            impulses24: impulses24,
            chroma12: chromaSmooth,
            waveL: waveL,
            waveR: waveR,
            tileHistory: tileHistory,
            heatHistory: heatHistory,
            bass: bass,
            mid: mid,
            treble: treble,
            energy: energy,
            flux: fluxSmooth,
            beat: beat,
            tension: tension,
            stereoCorrelation: stereoCorr,
            centroid: 0.45,
            rawRMS: 0.24,
            isSilent: false,
            detectedKey: detectedKey,
            shortKey: shortKey,
            sampleRate: sampleRate,
            time: t
        )
    }
}
