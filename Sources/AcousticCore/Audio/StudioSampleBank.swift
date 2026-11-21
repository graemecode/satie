@preconcurrency import AVFoundation
import Foundation

public enum AcousticInstrumentID: String, CaseIterable, Sendable {
    case piano  // CC0 Versilian Upright Nr1 (pp) -> Velvet Felt Piano
    case vibe   // CC0 VCSL Soft-Mallet Vibraphone
    case harp   // CC0 Versilian Concert Harp
    case cello  // CC0 Versilian Cello Section (susvib)
    case glass  // CC0 VCSL Bowed Vibraphone + Friction Wine Glasses
}

/// Immutable decoded 48 kHz stereo Int16 PCM zone for zero-allocation real-time playback (half the RAM of Float32, 96 dB dynamic range).
final class DecodedSampleZone: @unchecked Sendable {
    static let int16ToFloat: Float = 1.0 / 32767.0

    let midi: Int
    let frameCount: Int
    let left: [Int16]
    let right: [Int16]

    init(midi: Int, left: [Int16], right: [Int16]) {
        self.midi = midi
        self.frameCount = min(left.count, right.count)
        self.left = left
        self.right = right
    }

    @inline(__always)
    func sampleL(_ index: Int) -> Float {
        Float(left[index]) * Self.int16ToFloat
    }

    @inline(__always)
    func sampleR(_ index: Int) -> Float {
        Float(right[index]) * Self.int16ToFloat
    }
}

/// Loads our bundled CC0-1.0 Versilian Studios / VCSL multi-sampled acoustic library once at startup
/// into contiguous 48 kHz stereo Float buffers. Zero disk I/O or heap allocation ever happens on the audio thread.
final class StudioSampleBank: @unchecked Sendable {
    static let shared = StudioSampleBank()

    private let zonesByInstrument: [AcousticInstrumentID: [DecodedSampleZone]]
    let rainBed: DecodedSampleZone?
    let loadedZoneCount: Int

    private init() {
        let baseDirs = Self.candidateSampleDirectories()
        var foundDir: URL?
        let fm = FileManager.default
        for dir in baseDirs {
            if fm.fileExists(atPath: dir.appendingPathComponent("piano_60.m4a").path) {
                foundDir = dir
                break
            }
        }

        guard let samplesDir = foundDir else {
            self.zonesByInstrument = [:]
            self.rainBed = nil
            self.loadedZoneCount = 0
            return
        }

        let specs: [(AcousticInstrumentID, [Int])] = [
            (.piano, [36, 43, 48, 55, 60, 67, 72, 79, 84, 91]),
            (.vibe,  [41, 45, 48, 52, 55, 59, 62, 65, 69, 72, 76]),
            (.harp,  [38, 45, 48, 52, 59, 62, 65, 69, 72, 76]),
            (.cello, [31, 38, 41, 45, 48, 52, 55, 62]),
            (.glass, [52, 55, 63, 66, 70, 74]),
        ]

        // Flatten tasks and decode in parallel so startup stays ~60–100 ms on Apple Silicon
        let flatSpecs: [(AcousticInstrumentID, Int, URL)] = specs.flatMap { inst, notes in
            notes.map { midi in
                (inst, midi, samplesDir.appendingPathComponent("\(inst.rawValue)_\(midi).m4a"))
            }
        }

        final class DecodeCollector: @unchecked Sendable {
            let lock = NSLock()
            var decoded: [AcousticInstrumentID: [DecodedSampleZone]] = [:]
            var count = 0
        }
        let collector = DecodeCollector()

        DispatchQueue.concurrentPerform(iterations: flatSpecs.count) { idx in
            let (inst, midi, url) = flatSpecs[idx]
            if let zone = Self.decodeStereo48k(url: url, midi: midi) {
                collector.lock.lock()
                collector.decoded[inst, default: []].append(zone)
                collector.count += 1
                collector.lock.unlock()
            }
        }

        var decoded = collector.decoded
        for key in decoded.keys {
            decoded[key]?.sort { $0.midi < $1.midi }
        }
        self.zonesByInstrument = decoded
        self.rainBed = Self.decodeStereo48k(url: samplesDir.appendingPathComponent("rain_bed.m4a"), midi: 0)
        self.loadedZoneCount = collector.count
    }

    var isAvailable: Bool { loadedZoneCount >= 20 }

    @inline(__always)
    func nearestZone(instrument: AcousticInstrumentID, midi: Int) -> DecodedSampleZone? {
        guard let list = zonesByInstrument[instrument], !list.isEmpty else { return nil }
        var best = list[0]
        var bestDist = abs(best.midi - midi)
        for z in list.dropFirst() {
            let d = abs(z.midi - midi)
            if d < bestDist {
                best = z
                bestDist = d
            }
        }
        return best
    }

    private static func candidateSampleDirectories() -> [URL] {
        var urls: [URL] = []
        if let res = Bundle.main.resourceURL {
            urls.append(res.appendingPathComponent("Samples", isDirectory: true))
        }
        #if SWIFT_PACKAGE
        if let mod = Bundle.module.resourceURL {
            urls.append(mod.appendingPathComponent("Samples", isDirectory: true))
            urls.append(mod)
        }
        #endif
        // Source-tree fallback for Xcode / CLI test runs
        let sourceDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Audio
            .deletingLastPathComponent() // AcousticCore
            .appendingPathComponent("Resources/Samples", isDirectory: true)
        urls.append(sourceDir)
        return urls
    }

    private static func decodeStereo48k(url: URL, midi: Int) -> DecodedSampleZone? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return autoreleasepool {
            do {
                let file = try AVAudioFile(forReading: url)
                let targetFmt = AVAudioFormat(standardFormatWithSampleRate: 48_000.0, channels: 2)!
                let srcFmt = file.processingFormat
                let estFrames = AVAudioFrameCount(max(1024, Int(Double(file.length) * (48_000.0 / max(1.0, srcFmt.sampleRate))) + 2048))

                guard let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFmt, frameCapacity: AVAudioFrameCount(file.length) + 1024) else {
                    return nil
                }
                try file.read(into: srcBuf)

                let finalBuf: AVAudioPCMBuffer
                if srcFmt.sampleRate == 48_000.0 && srcFmt.channelCount == 2 && srcFmt.commonFormat == .pcmFormatFloat32 && !srcFmt.isInterleaved {
                    finalBuf = srcBuf
                } else {
                    guard let converter = AVAudioConverter(from: srcFmt, to: targetFmt),
                          let outBuf = AVAudioPCMBuffer(pcmFormat: targetFmt, frameCapacity: estFrames) else {
                        return nil
                    }
                    nonisolated(unsafe) var provided = false
                    var convError: NSError?
                    converter.convert(to: outBuf, error: &convError) { _, outStatus in
                        if provided {
                            outStatus.pointee = .endOfStream
                            return nil
                        }
                        provided = true
                        outStatus.pointee = .haveData
                        return srcBuf
                    }
                    if convError != nil || outBuf.frameLength == 0 { return nil }
                    finalBuf = outBuf
                }

                let frames = Int(finalBuf.frameLength)
                guard frames > 64, let chData = finalBuf.floatChannelData else { return nil }
                let srcL = chData[0]
                let srcR = chData[1]
                var left = [Int16](repeating: 0, count: frames)
                var right = [Int16](repeating: 0, count: frames)
                for i in 0..<frames {
                    let clL = max(-1.0 as Float, min(1.0 as Float, srcL[i]))
                    let clR = max(-1.0 as Float, min(1.0 as Float, srcR[i]))
                    left[i] = Int16(clL * 32767.0)
                    right[i] = Int16(clR * 32767.0)
                }
                return DecodedSampleZone(midi: midi, left: left, right: right)
            } catch {
                return nil
            }
        }
    }
}

// MARK: - Zero-Allocation Hermite Cubic Multi-Sample Voice with Acoustic Felt Damper

struct AcousticSamplerVoice: @unchecked Sendable {
    var active: Bool = false
    var instrument: AcousticInstrumentID = .piano
    var isSustainedLayer: Bool = false
    private var zone: DecodedSampleZone?
    private var readPos: Double = 0
    private var rate: Double = 1.0
    private var age: Double = 0
    private var attackSec: Double = 0.004
    private var releaseAt: Double = 3.0
    private var releaseTau: Double = 1.2
    private var level: Float = 0
    private var panL: Float = 0.707
    private var panR: Float = 0.707
    private var lpL = CytomicSVF(cutoffHz: 4200, q: 0.707)
    private var lpR = CytomicSVF(cutoffHz: 4200, q: 0.707)
    private var bodyL = CytomicSVF(cutoffHz: 320, q: 1.1)
    private var bodyR = CytomicSVF(cutoffHz: 320, q: 1.1)
    private var feltWarmthMix: Float = 0.0

    mutating func trigger(
        bank: StudioSampleBank,
        instrument: AcousticInstrumentID,
        midi: Int,
        rootMidi: Int,
        velocity: Double,
        duration: Double,
        level: Double,
        pan: Double,
        feltMuffle: Bool = false,
        justSweeten: Bool = false,
        sustainedLayer: Bool = false,
        rng: inout FastNoiseRNG,
        sampleRate: Double = 48_000.0
    ) -> Bool {
        guard let z = bank.nearestZone(instrument: instrument, midi: midi) else {
            return false
        }
        self.zone = z
        self.instrument = instrument
        self.isSustainedLayer = sustainedLayer
        self.active = true
        self.age = 0
        self.readPos = 0

        let zoneHz = 440.0 * pow(2.0, Double(z.midi - 69) / 12.0)
        let targetHz: Double
        if justSweeten {
            targetHz = AudioMath.justSweetenedHz(midi: midi, rootMidi: rootMidi, blend: 0.60)
        } else if instrument == .piano {
            targetHz = AudioMath.railsbackHz(midi: midi, stretchAmount: 0.85)
        } else {
            targetHz = 440.0 * pow(2.0, Double(midi - 69) / 12.0)
        }
        // Subtle ±1.2c organic tuning breath
        let drift = pow(2.0, ((rng.nextUnit() - 0.5) * 2.2) / 1200.0)
        self.rate = (targetHz * drift) / zoneHz

        switch instrument {
        case .piano:
            self.attackSec = feltMuffle ? 0.008 : 0.004
            self.releaseAt = max(0.9, duration * 1.45)
            self.releaseTau = feltMuffle ? 1.55 : 1.15
            let cut = feltMuffle
                ? (640.0 + velocity * 1450.0)   // Intimate Sakamoto / Nils Frahm velvet felt damper
                : (1800.0 + velocity * 3400.0)  // Luminous open upright
            lpL.reset(); lpR.reset()
            lpL.set(cutoffHz: cut, q: 0.68, sampleRate: sampleRate)
            lpR.set(cutoffHz: cut, q: 0.68, sampleRate: sampleRate)
            bodyL.reset(); bodyR.reset()
            bodyL.set(cutoffHz: 260.0, q: 1.15, sampleRate: sampleRate)
            bodyR.set(cutoffHz: 260.0, q: 1.15, sampleRate: sampleRate)
            self.feltWarmthMix = feltMuffle ? 0.28 : 0.12

        case .vibe:
            self.attackSec = 0.004
            self.releaseAt = max(0.8, duration * 1.35)
            self.releaseTau = 1.25
            let cut = 1400.0 + velocity * 3600.0
            lpL.reset(); lpR.reset()
            lpL.set(cutoffHz: cut, q: 0.70, sampleRate: sampleRate)
            lpR.set(cutoffHz: cut, q: 0.70, sampleRate: sampleRate)
            self.feltWarmthMix = 0.0

        case .harp:
            self.attackSec = 0.003
            self.releaseAt = max(1.0, duration * 1.6)
            self.releaseTau = 1.45
            let cut = 2200.0 + velocity * 4200.0
            lpL.reset(); lpR.reset()
            lpL.set(cutoffHz: cut, q: 0.70, sampleRate: sampleRate)
            lpR.set(cutoffHz: cut, q: 0.70, sampleRate: sampleRate)
            self.feltWarmthMix = 0.0

        case .cello:
            self.attackSec = min(1.35, max(0.55, duration * 0.35))
            self.releaseAt = max(1.2, duration * 0.85)
            self.releaseTau = 1.35
            let cut = 1900.0 + velocity * 2200.0
            lpL.reset(); lpR.reset()
            lpL.set(cutoffHz: cut, q: 0.68, sampleRate: sampleRate)
            lpR.set(cutoffHz: cut, q: 0.68, sampleRate: sampleRate)
            self.feltWarmthMix = 0.0

        case .glass:
            self.attackSec = 0.38
            self.releaseAt = max(1.5, duration * 1.1)
            self.releaseTau = 1.6
            lpL.reset(); lpR.reset()
            lpL.set(cutoffHz: 4600.0, q: 0.70, sampleRate: sampleRate)
            lpR.set(cutoffHz: 4600.0, q: 0.70, sampleRate: sampleRate)
            self.feltWarmthMix = 0.0
        }

        self.level = Float(level)
        let angle = Float((pan + 1.0) * 0.25 * Double.pi)
        self.panL = cos(angle)
        self.panR = sin(angle)
        return true
    }

    @inline(__always)
    mutating func step(dt: Double) -> (Float, Float) {
        guard active, let z = zone else { return (0, 0) }
        let idx = Int(readPos)
        if idx >= z.frameCount - 3 {
            active = false
            return (0, 0)
        }

        // 4-point Hermite cubic interpolation (zero pitch-shift zippering or graininess)
        let frac = Float(readPos - floor(readPos))
        let iM1 = max(0, idx - 1)
        let i1 = idx + 1
        let i2 = min(z.frameCount - 1, idx + 2)

        let rawL = AudioMath.hermite(z.sampleL(iM1), z.sampleL(idx), z.sampleL(i1), z.sampleL(i2), frac: frac)
        let rawR = AudioMath.hermite(z.sampleR(iM1), z.sampleR(idx), z.sampleR(i1), z.sampleR(i2), frac: frac)

        readPos += rate
        age += dt

        // Smooth S-curve attack & exponential damper tail
        var env: Float = 1.0
        if age < attackSec {
            env = Float(AudioMath.smoothstep(age / max(0.001, attackSec)))
        } else if age > releaseAt {
            env = Float(exp(-(age - releaseAt) / releaseTau))
            if env < 0.00025 {
                active = false
                return (0, 0)
            }
        }

        // Preserve natural stereo mic image while nudging smoothly toward desired pan
        var fL = lpL.lowpass(rawL)
        var fR = lpR.lowpass(rawR)
        if feltWarmthMix > 0.001 {
            fL += bodyL.bandpass(fL) * feltWarmthMix
            fR += bodyR.bandpass(fR) * feltWarmthMix
        }

        let gain = env * level
        // Blend 55% natural stereo recording width + 45% panned center placement
        let mono = 0.5 * (fL + fR)
        let outL = (fL * 0.55 + mono * panL * 0.65) * gain
        let outR = (fR * 0.55 + mono * panR * 0.65) * gain
        return (outL, outR)
    }
}

// MARK: - Seamless Real-Time Crossfaded Studio Rain Field-Recording Player

/// Plays our CC0-1.0 real 48 kHz studio rain recording (`rain_bed.m4a`) with:
/// - 2400-sample AAC priming trim on both ends (zero encoder-padding clicks)
/// - Live 3.0-second equal-power cosine/sine crossfade loop (zero audible seam forever)
/// - Gentle slow-breathing Cytomic velvet lowpass (2.6 kHz .. 4.8 kHz) so rain sits cozily
///   behind the vibraphone, harp, and friction wine glasses like a Kyoto courtyard window.
struct StudioRainPlayer: @unchecked Sendable {
    private let bed: DecodedSampleZone?
    private let trimStart: Int
    private let loopLength: Int
    private let xfadeLength: Int
    private var cursor: Int = 0
    private var lpL = CytomicSVF(cutoffHz: 3600, q: 0.62)
    private var lpR = CytomicSVF(cutoffHz: 3600, q: 0.62)
    private var sampleCounter: Int = 0

    var isAvailable: Bool { bed != nil && loopLength > xfadeLength * 2 }

    init(bank: StudioSampleBank = .shared) {
        self.bed = bank.rainBed
        let total = bank.rainBed?.frameCount ?? 0
        let trim = 2400 // skip AAC encoder priming/padding cleanly
        let usable = max(0, total - trim * 2)
        let xfade = min(144_000, usable / 4) // 3.0s equal-power crossfade at 48 kHz
        self.trimStart = trim
        self.xfadeLength = max(4096, xfade)
        self.loopLength = max(0, usable - self.xfadeLength)
    }

    mutating func reset() {
        cursor = 0
        lpL.reset()
        lpR.reset()
    }

    @inline(__always)
    mutating func step(clockSec: Double, spaceBloom: Double, sampleRate: Double = 48_000.0) -> (Float, Float) {
        guard let z = bed, loopLength > xfadeLength else { return (0, 0) }

        if (sampleCounter & 127) == 0 {
            // Subtle organic weather breath (distant velvet rain opens and softens slowly)
            let breath = 0.5 + 0.5 * sin(clockSec * 0.11) * cos(clockSec * 0.047)
            let cutHz = 2500.0 + (0.6 * breath + 0.4 * spaceBloom) * 2300.0
            lpL.set(cutoffHz: cutHz, q: 0.62, sampleRate: sampleRate)
            lpR.set(cutoffHz: cutHz, q: 0.62, sampleRate: sampleRate)
        }
        sampleCounter &+= 1

        let idxA = trimStart + cursor
        var outL = z.sampleL(idxA)
        var outR = z.sampleR(idxA)

        // Seamless equal-power cosine/sine overlap at loop boundary
        if cursor < xfadeLength {
            let t = Double(cursor) / Double(xfadeLength)
            let gIn = Float(sin(0.5 * Double.pi * t))
            let gOut = Float(cos(0.5 * Double.pi * t))
            let idxB = trimStart + loopLength + cursor
            outL = outL * gIn + z.sampleL(idxB) * gOut
            outR = outR * gIn + z.sampleR(idxB) * gOut
        }

        cursor += 1
        if cursor >= loopLength { cursor = 0 }

        // Tucked softly (~ -29 dBFS in final mix) so real rain cradles the music without ever sounding noisy
        return (lpL.lowpass(outL) * 0.082, lpR.lowpass(outR) * 0.082)
    }
}
