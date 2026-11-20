import AVFoundation
import Foundation
import Synchronization

public enum FocusSoundscape: String, CaseIterable, Identifiable, Sendable {
    case focus
    case pulse
    case rain
    case drift
    case still

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .focus: return "Soft Light"
        case .pulse: return "Kinetic Pulse"
        case .rain: return "Rain & Glass"
        case .drift: return "Gymnopédie"
        case .still: return "Still"
        }
    }

    public var shortLabel: String {
        switch self {
        case .focus: return "FOCUS"
        case .pulse: return "PULSE"
        case .rain: return "RAIN"
        case .drift: return "DRIFT"
        case .still: return "STILL"
        }
    }

    public var subtitle: String {
        switch self {
        case .focus: return "Felt Piano · Vibraphone · Halo"
        case .pulse: return "Hypnotic Analog · 3D Rings"
        case .rain: return "Kyoto Rain · Wine Glasses"
        case .drift: return "Nocturnal Piano · Cello"
        case .still: return "Zero-Ego Study · Suspended"
        }
    }
}

/// Live cognitive-load / modulation-depth control (real-time atomic modulation).
public enum SoundIntensity: String, CaseIterable, Identifiable, Sendable {
    case still
    case flow
    case deep

    public var id: String { rawValue }

    public var rawIndex: Int {
        switch self {
        case .still: return 0
        case .flow: return 1
        case .deep: return 2
        }
    }

    public var label: String {
        switch self {
        case .still: return "STILL"
        case .flow: return "FLOW"
        case .deep: return "DEEP"
        }
    }
}

/// Optional independent acoustic speech-masking layer underneath any soundscape.
public enum MaskingBed: String, CaseIterable, Identifiable, Sendable {
    case off
    case rain
    case brown

    public var id: String { rawValue }

    public var rawIndex: Int {
        switch self {
        case .off: return 0
        case .rain: return 1
        case .brown: return 2
        }
    }

    public var label: String {
        switch self {
        case .off: return "OFF"
        case .rain: return "RAIN"
        case .brown: return "BROWN"
        }
    }
}

/// Optional user override for circadian tone voicing (Auto follows local biological clock).
public enum CircadianOverride: String, CaseIterable, Identifiable, Sendable {
    case auto
    case crisp
    case warm

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .auto: return "AUTO"
        case .crisp: return "CRISP"
        case .warm: return "WARM"
        }
    }

    public func resolvedPhase(date: Date = Date()) -> CircadianPhase {
        switch self {
        case .auto: return CircadianPhase.current(date: date)
        case .crisp: return .morning
        case .warm: return .night
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

    public var detailedLabel: String {
        switch self {
        case .morning: return "MORNING RISE"
        case .afternoon: return "DAY FLOW"
        case .night: return "NOCTURNAL · WARM"
        }
    }

    /// Normalized biological alertness curve ∈ [0, 1] across a 24-hour day (for hairline circadian graph).
    public static func energyCurve(hour: Double) -> Double {
        // Classic two-peak human circadian alertness wave: rise 7-11am, gentle dip 2-3pm, evening wind-down 9pm+
        let h = ((hour.truncatingRemainder(dividingBy: 24.0)) + 24.0).truncatingRemainder(dividingBy: 24.0)
        let morningPeak = exp(-pow((h - 10.5) / 3.8, 2.0)) * 0.92
        let lateAfternoon = exp(-pow((h - 17.5) / 3.2, 2.0)) * 0.76
        let baseline = 0.14
        return max(0.08, min(1.0, baseline + max(morningPeak, lateAfternoon)))
    }
}

public struct ScoreTelemetry: Equatable, Sendable {
    public let barInForm: Int       // 0 ..< 32
    public let pass: Int            // 0 = Pass 1, 1 = Pass 2, ...
    public let chordIndex: Int
    public let didSwapFigure: Bool
    public let barProgress: Float   // 0 .. 1 within current bar

    public static let empty = ScoreTelemetry(barInForm: 0, pass: 0, chordIndex: 0, didSwapFigure: false, barProgress: 0)

    public static let chordLabels: [String] = [
        "A MAJ", "F# MIN", "D MAJ", "E SUS", "E MAJ", "B MIN", "C# MIN", "E 6", "A 6",
        "D MIN9", "F MAJ7", "C ADD9", "G 6", "A MIN7",
        "G MAJ7", "D MAJ7", "E MIN9", "A 9SUS"
    ]

    public var chordLabel: String {
        guard chordIndex >= 0 && chordIndex < Self.chordLabels.count else { return "A MAJ" }
        return Self.chordLabels[chordIndex]
    }

    public static func chordIndex(for name: String) -> Int {
        switch name {
        case "A":     return 0
        case "F#m":   return 1
        case "D":     return 2
        case "Esus":  return 3
        case "E":     return 4
        case "Bm":    return 5
        case "C#m":   return 6
        case "E6":    return 7
        case "A6":    return 8
        case "Dm9":   return 9
        case "Fmaj7": return 10
        case "Cadd9": return 11
        case "G6":    return 12
        case "Am7":   return 13
        case "Gmaj7": return 14
        case "Dmaj7": return 15
        case "Em9":   return 16
        case "A9sus": return 17
        default:      return 0
        }
    }
}

// MARK: - Lock-Free SPSC Pre-Composed Bar Ring Buffer (Zero Heap Allocations on Core Audio Thread)

/// Pre-allocated fixed-capacity bar event slot stored inline so the audio render thread
/// reads upcoming bars with zero Swift Array/Set allocations, zero locks, and zero sorting.
struct PrecomposedBarSlot: Sendable {
    static let maxBells = 32
    static let maxSustained = 16

    var barIndex: Int = 0
    var barInForm: Int = 0
    var pass: Int = 0
    var chordIndex: Int = 0
    var rootMidi: Int = 45
    var didSwapFigure: Bool = false
    var secondsPerBeat: Double = 0.8333
    var secondsPerBar: Double = 3.3333
    var macroFilterHorizon: Double = 0.75
    var macroSpaceBloom: Double = 0.55
    var macroResonance: Double = 0.45

    var bellCount: Int = 0
    var bells: [ScoredBellEvent]
    var sustainCount: Int = 0
    var sustained: [ScoredSustainEvent]

    init() {
        let emptyBell = ScoredBellEvent(kind: .figure, at: 0, midi: 60, duration: 0.5, velocity: 0.5, level: 0, pan: 0)
        let emptySus = ScoredSustainEvent(kind: .pad, at: 0, midi: 60, duration: 2.0, level: 0, pan: 0)
        self.bells = [ScoredBellEvent](repeating: emptyBell, count: Self.maxBells)
        self.sustained = [ScoredSustainEvent](repeating: emptySus, count: Self.maxSustained)
    }

    mutating func populate(from composed: ComposedBar) {
        barIndex = composed.barIndex
        barInForm = composed.barInForm
        pass = composed.pass
        chordIndex = ScoreTelemetry.chordIndex(for: composed.chordName)
        rootMidi = composed.rootMidi
        didSwapFigure = composed.didSwapFigure
        secondsPerBeat = composed.secondsPerBeat
        secondsPerBar = composed.secondsPerBar
        macroFilterHorizon = composed.macroFilterHorizon
        macroSpaceBloom = composed.macroSpaceBloom
        macroResonance = composed.macroResonance

        let sortedBells = composed.bells.sorted { $0.at < $1.at }
        bellCount = min(Self.maxBells, sortedBells.count)
        for i in 0..<bellCount { bells[i] = sortedBells[i] }

        let sortedSus = composed.sustained.sorted { $0.at < $1.at }
        sustainCount = min(Self.maxSustained, sortedSus.count)
        for i in 0..<sustainCount { sustained[i] = sortedSus[i] }
    }
}

/// Lock-free Single-Producer / Single-Consumer ring of 16 pre-composed bars (~35–65 seconds of lookahead).
/// Producer runs on a utility background queue; audio thread only loads/stores acquire/release atomics.
final class LockFreeBarQueue: @unchecked Sendable {
    private static let capacity = 16
    private static let mask = 15

    private let writeIdx = Atomic<Int>(0)
    private let readIdx = Atomic<Int>(0)
    private var slots: [PrecomposedBarSlot]

    init() {
        self.slots = (0..<Self.capacity).map { _ in PrecomposedBarSlot() }
    }

    var availableCount: Int {
        let w = writeIdx.load(ordering: .acquiring)
        let r = readIdx.load(ordering: .acquiring)
        return max(0, w - r)
    }

    /// Producer-only: clears queue by advancing read index to write index before refilling.
    func clearProducerSide() {
        let w = writeIdx.load(ordering: .acquiring)
        readIdx.store(w, ordering: .releasing)
    }

    /// Producer-only: writes next composed bar into ring if space remains.
    @discardableResult
    func enqueue(_ bar: ComposedBar) -> Bool {
        let w = writeIdx.load(ordering: .relaxed)
        let r = readIdx.load(ordering: .acquiring)
        guard (w - r) < Self.capacity - 1 else { return false }
        slots[w & Self.mask].populate(from: bar)
        writeIdx.store(w + 1, ordering: .releasing)
        return true
    }

    /// Audio-thread-only (zero allocations, zero locks): copies next pre-composed bar into `dest`.
    func dequeue(into dest: inout PrecomposedBarSlot) -> Bool {
        let r = readIdx.load(ordering: .relaxed)
        let w = writeIdx.load(ordering: .acquiring)
        guard r < w else { return false }
        let src = slots[r & Self.mask]
        dest.barIndex = src.barIndex
        dest.barInForm = src.barInForm
        dest.pass = src.pass
        dest.chordIndex = src.chordIndex
        dest.rootMidi = src.rootMidi
        dest.didSwapFigure = src.didSwapFigure
        dest.secondsPerBeat = src.secondsPerBeat
        dest.secondsPerBar = src.secondsPerBar
        dest.macroFilterHorizon = src.macroFilterHorizon
        dest.macroSpaceBloom = src.macroSpaceBloom
        dest.macroResonance = src.macroResonance
        dest.bellCount = src.bellCount
        for i in 0..<src.bellCount { dest.bells[i] = src.bells[i] }
        dest.sustainCount = src.sustainCount
        for i in 0..<src.sustainCount { dest.sustained[i] = src.sustained[i] }
        readIdx.store(r + 1, ordering: .releasing)
        return true
    }
}

// MARK: - FocusSoundEngine (Satie Audio Engine v3)

/// Studio-grade procedural furniture-music synthesizer (`AVAudioEngine` + zero-allocation `AVAudioSourceNode`).
/// Satie Audio Engine v3:
/// - 4 distinct physical instruments: Vactrol Glassy Bell (Soft Light), Karplus-Strong Felt Piano (Gymnopédie),
///   PolyBLEP ZDF Analog + 3:4 Buchla Plucks + Sidechain Sub-Groove (Kinetic Pulse),
///   3-Layer Minnaert Physical Rain + Chladni Singing Bowls (Rain & Glass)
/// - Roland RE-201-inspired wow/flutter saturating Tape Space Echo + Dual-LFO Stereo Chorus
/// - Studio Acoustic Space: Pre-delay + 8-tap Early Reflections + 4-stage Allpass Diffuser + 8x8 Modulated FDN
/// - Audiophile Master Bus: <130 Hz strict mono sub-bass, M/S upper-air bloom, even-order transformer warmth,
///   35 ms RMS optical glue compressor, and 2.5 ms lookahead true-peak limiter
/// - Eno prime-length (5, 7, 11, 13 bar) macro evolution + lock-free off-thread bar pre-composer
public final class FocusSoundEngine: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let ringBuffer: StereoRingBuffer

    private let renderState = FocusRenderState()
    private let lifecycleLock = NSLock()
    private var isEngineRunning = false

    // Background utility producer that keeps LockFreeBarQueue topped up off the Core Audio thread
    private let producerQueue = DispatchQueue(label: "com.strangechances.satie.score-producer", qos: .utility)
    private var producerTimer: DispatchSourceTimer?
    private var producerRNG = SeededRNG(seed: 42)
    private var producerSeed: UInt32 = 42
    private var producerNextBarIndex: Int = 0
    private var producerMode: FocusSoundscape = .focus
    private var producerCircadian: CircadianPhase = .afternoon
    private var producerIntensity: SoundIntensity = .flow

    public var isPlaying: Bool {
        renderState.isActiveAtom.load(ordering: .acquiring) != 0
    }

    public static var loadedAcousticSampleCount: Int {
        StudioSampleBank.shared.loadedZoneCount
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

    public var scoreTelemetry: ScoreTelemetry {
        let packed = renderState.telemetryPackedAtom.load(ordering: .acquiring)
        let bar = Int(packed & 0x3F)
        let pass = Int((packed >> 6) & 0x3FF)
        let chordIdx = Int((packed >> 16) & 0x3F)
        let swapped = ((packed >> 22) & 1) != 0
        let progQ = Float((packed >> 24) & 0xFF) / 255.0
        return ScoreTelemetry(barInForm: bar, pass: pass, chordIndex: chordIdx, didSwapFigure: swapped, barProgress: progQ)
    }

    public init(ringBuffer: StereoRingBuffer) {
        self.ringBuffer = ringBuffer
        let phase = CircadianPhase.current()
        self.producerCircadian = phase
        renderState.circadianAtom.store(phase.rawValue, ordering: .releasing)
        // Warm CC0 studio sample bank off the audio thread so first Play has zero latency
        producerQueue.async {
            _ = StudioSampleBank.shared.loadedZoneCount
        }
    }

    deinit {
        stopImmediately()
    }

    /// Re-anchors the audio graph cleanly after macOS system wake so Core Audio never glitches or piles up bars.
    public func handleSystemWake() {
        guard isPlaying else { return }
        refillScoreQueueFromStart(mode: currentMode, circadian: .current())
        renderState.wakeResetAtom.store(1, ordering: .releasing)
        lifecycleLock.lock()
        let needsRestart = isEngineRunning && !engine.isRunning
        lifecycleLock.unlock()
        if needsRestart {
            start(mode: currentMode)
        }
    }

    public func setVolume(_ value: Float) {
        let clamped = max(0.0, min(1.0, value))
        renderState.volumeBitsAtom.store(clamped.bitPattern, ordering: .releasing)
    }

    public func setMode(_ mode: FocusSoundscape) {
        let previous = currentMode
        if let idx = FocusSoundscape.allCases.firstIndex(of: mode) {
            renderState.modeAtom.store(idx, ordering: .releasing)
        }
        if previous != mode {
            refillScoreQueueFromStart(mode: mode, circadian: CircadianPhase(rawValue: renderState.circadianAtom.load(ordering: .acquiring)) ?? .afternoon)
            renderState.scoreResetAtom.store(1, ordering: .releasing)
        }
    }

    public func setCircadianPhase(_ phase: CircadianPhase) {
        let prev = renderState.circadianAtom.load(ordering: .acquiring)
        renderState.circadianAtom.store(phase.rawValue, ordering: .releasing)
        if prev != phase.rawValue {
            refillScoreQueueFromStart(mode: currentMode, circadian: phase)
            renderState.scoreResetAtom.store(1, ordering: .releasing)
        }
    }

    public func setDucked(_ ducked: Bool) {
        renderState.isDuckedAtom.store(ducked ? 1 : 0, ordering: .releasing)
    }

    public func setIntensity(_ intensity: SoundIntensity) {
        let prev = renderState.intensityAtom.load(ordering: .acquiring)
        renderState.intensityAtom.store(intensity.rawIndex, ordering: .releasing)
        if prev != intensity.rawIndex {
            let phase = CircadianPhase(rawValue: renderState.circadianAtom.load(ordering: .acquiring)) ?? .afternoon
            refillScoreQueueFromStart(mode: currentMode, circadian: phase, intensity: intensity, seed: producerSeed, startBar: nil)
        }
    }

    public func setMaskingBed(_ bed: MaskingBed) {
        renderState.maskingBedAtom.store(bed.rawIndex, ordering: .releasing)
    }

    /// Pass `nil` for infinite sessions, or normalized progress ∈ [0, 1] for timed session-arc audio choreography.
    public func setSessionProgress(_ progress: Float?) {
        let val: Float = progress.map { max(0.0, min(1.0, $0)) } ?? -1.0
        renderState.sessionProgressBitsAtom.store(val.bitPattern, ordering: .releasing)
    }

    /// Smoothly shifts to a fresh deterministic harmonic phrase & seed without interrupting playback.
    public func reseedPhrase() {
        let newSeed = UInt32.random(in: 100...999_999)
        let phase = CircadianPhase(rawValue: renderState.circadianAtom.load(ordering: .acquiring)) ?? .afternoon
        let intensity = SoundIntensity.allCases[max(0, min(SoundIntensity.allCases.count - 1, renderState.intensityAtom.load(ordering: .acquiring)))]
        // Jump into Pass 2+ on a fresh section boundary so the room refreshes organically immediately
        let freshStartBar = 32 + Int.random(in: 0..<4) * 8
        refillScoreQueueFromStart(mode: currentMode, circadian: phase, intensity: intensity, seed: newSeed, startBar: freshStartBar)
        renderState.softReseedAtom.store(1, ordering: .releasing)
    }

    public func triggerSessionChime() {
        renderState.chimeTriggerAtom.store(1, ordering: .releasing)
    }

    private func refillScoreQueueFromStart(
        mode: FocusSoundscape,
        circadian: CircadianPhase,
        intensity: SoundIntensity? = nil,
        seed: UInt32 = 42,
        startBar: Int? = 0
    ) {
        producerQueue.sync {
            producerMode = mode
            producerCircadian = circadian
            if let intensity { producerIntensity = intensity }
            producerSeed = seed
            if let startBar { producerNextBarIndex = startBar }
            producerRNG = SeededRNG(seed: seed)
            renderState.barQueue.clearProducerSide()
            for _ in 0..<10 {
                let composed = SatieScore.composeBar(
                    mode: producerMode,
                    barIndex: producerNextBarIndex,
                    circadian: producerCircadian,
                    intensity: producerIntensity,
                    rng: &producerRNG
                )
                if renderState.barQueue.enqueue(composed) {
                    producerNextBarIndex += 1
                }
            }
        }
    }

    private func startProducerTimerLocked() {
        guard producerTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: producerQueue)
        timer.schedule(deadline: .now() + .milliseconds(300), repeating: .milliseconds(300))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            while self.renderState.barQueue.availableCount < 10 {
                let composed = SatieScore.composeBar(
                    mode: self.producerMode,
                    barIndex: self.producerNextBarIndex,
                    circadian: self.producerCircadian,
                    intensity: self.producerIntensity,
                    rng: &self.producerRNG
                )
                if self.renderState.barQueue.enqueue(composed) {
                    self.producerNextBarIndex += 1
                } else {
                    break
                }
            }
        }
        timer.resume()
        producerTimer = timer
    }

    private func stopProducerTimerLocked() {
        producerTimer?.cancel()
        producerTimer = nil
    }

    public func start(mode: FocusSoundscape? = nil) {
        let targetMode = mode ?? currentMode
        let targetPhase = CircadianPhase.current()
        if let idx = FocusSoundscape.allCases.firstIndex(of: targetMode) {
            renderState.modeAtom.store(idx, ordering: .releasing)
        }
        renderState.circadianAtom.store(targetPhase.rawValue, ordering: .releasing)
        setDucked(false)

        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        if !isEngineRunning || !engine.isRunning {
            refillScoreQueueFromStart(mode: targetMode, circadian: targetPhase)
            renderState.scoreResetAtom.store(1, ordering: .releasing)
        } else if targetMode != producerMode || targetPhase != producerCircadian {
            refillScoreQueueFromStart(mode: targetMode, circadian: targetPhase)
            renderState.scoreResetAtom.store(1, ordering: .releasing)
        }

        startProducerTimerLocked()
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
                state.render(outL: outL, outR: outR, frames: frames, sampleRate: 48_000, allowSyncFallback: false)
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
            Log.audio.info("Satie Audio Engine v3 started (mode=\(self.currentMode.shortLabel, privacy: .public), circadian=\(targetPhase.label, privacy: .public))")
        } catch {
            renderState.isActiveAtom.store(0, ordering: .releasing)
            stopProducerTimerLocked()
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
                self.stopProducerTimerLocked()
                self.isEngineRunning = false
            }
        }
    }

    public func stopImmediately() {
        renderState.isActiveAtom.store(0, ordering: .releasing)
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        stopProducerTimerLocked()
        if isEngineRunning {
            engine.stop()
            isEngineRunning = false
        }
    }

    /// Deterministic offline synthesis helper used by unit tests & audiophile psychoacoustic benchmarks.
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
        state.scoreResetAtom.store(1, ordering: .releasing)

        var warmL = [Float](repeating: 0, count: 512)
        var warmR = [Float](repeating: 0, count: 512)
        let warmBlocks = max(1, warmupFrames / 512)
        for _ in 0..<warmBlocks {
            warmL.withUnsafeMutableBufferPointer { lb in
                warmR.withUnsafeMutableBufferPointer { rb in
                    state.render(outL: lb.baseAddress!, outR: rb.baseAddress!, frames: 512, sampleRate: 48_000, allowSyncFallback: true)
                }
            }
        }

        var l = [Float](repeating: 0, count: frames)
        var r = [Float](repeating: 0, count: frames)
        l.withUnsafeMutableBufferPointer { lb in
            r.withUnsafeMutableBufferPointer { rb in
                state.render(outL: lb.baseAddress!, outR: rb.baseAddress!, frames: frames, sampleRate: 48_000, allowSyncFallback: true)
            }
        }
        return (l, r)
    }
}

// MARK: - Dual-LFO Stereo Analog Chorus (Juno-60 / Soft Light Depth)

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

        phase1 += 0.48 * dt; if phase1 >= 1.0 { phase1 -= 1.0 }
        phase2 += 0.67 * dt; if phase2 >= 1.0 { phase2 -= 1.0 }

        let d1 = (0.0125 + depthSec * sin(phase1 * 2.0 * Double.pi)) * sampleRate
        let d2 = (0.0172 + depthSec * sin(phase2 * 2.0 * Double.pi)) * sampleRate

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

// MARK: - Lock-Free Real-Time Audio Render State (Zero Allocations in Live Render)

private final class FocusRenderState: @unchecked Sendable {
    let isActiveAtom = Atomic<Int>(0)
    let isDuckedAtom = Atomic<Int>(0)
    let modeAtom = Atomic<Int>(0)
    let circadianAtom = Atomic<Int>(1)
    let intensityAtom = Atomic<Int>(1)        // 0 = still, 1 = flow, 2 = deep
    let maskingBedAtom = Atomic<Int>(0)       // 0 = off, 1 = rain, 2 = brown
    let sessionProgressBitsAtom = Atomic<UInt32>(Float(-1.0).bitPattern)
    let volumeBitsAtom = Atomic<UInt32>(Float(0.65).bitPattern)
    let chimeTriggerAtom = Atomic<Int>(0)
    let wakeResetAtom = Atomic<Int>(0)
    let scoreResetAtom = Atomic<Int>(0)
    let softReseedAtom = Atomic<Int>(0)
    let telemetryPackedAtom = Atomic<UInt64>(0)

    let barQueue = LockFreeBarQueue()

    private let bank = TimbreBank()
    private let sampleBank = StudioSampleBank.shared
    private var noiseRNG: FastNoiseRNG
    private var offlineScoreRNG: SeededRNG
    private var offlineNextBarIndex: Int = 0

    // Pre-allocated instrument voice pools (zero heap allocations during rendering)
    private var samplerVoices: [AcousticSamplerVoice]
    private var nextSamplerSlot = 0

    private var bells = [VactrolBellVoice](repeating: VactrolBellVoice(), count: 16)
    private var nextBellSlot = 0

    private var feltPianos: [FeltPianoVoice]
    private var nextPianoSlot = 0

    private var analogs = [AnalogHypnoticVoice](repeating: AnalogHypnoticVoice(), count: 16)
    private var nextAnalogSlot = 0

    private var glassBowls = [CrystalGlassBowlVoice](repeating: CrystalGlassBowlVoice(), count: 10)
    private var nextBowlSlot = 0

    private var strings = [EnsembleStringVoice](repeating: EnsembleStringVoice(), count: 10)
    private var nextStringSlot = 0

    private var pads = [JustIntonationPadBassVoice](repeating: JustIntonationPadBassVoice(), count: 16)
    private var nextPadSlot = 0

    // Active bar slot (copied in place from LockFreeBarQueue — zero allocations)
    private var hasCurrentBar: Bool = false
    private var currentBar = PrecomposedBarSlot()
    private var currentBarStartSec: Double = 0
    private var barBellCursor: Int = 0
    private var barSustainCursor: Int = 0
    private var clockSec: Double = 0
    private var activeModeIdx: Int = -1
    private var activeCircadianRaw: Int = -1

    // Studio modular, granular, binaural & acoustic chamber buses
    private var rings = RingsModalBank()
    private var beads = BeadsGranularCloud()
    private var binauralOrbit = BinauralOrbitBus()
    private var figureTapeEcho = TapeSpaceEcho()
    private var melodyTapeEcho = TapeSpaceEcho()
    private var figureChorus = StereoChorus()
    private var melodyChorus = StereoChorus()
    private var stringChorus = StereoChorus()
    private var space = StudioAcousticSpace()
    private var studioRain = StudioRainPlayer()
    private var velvetBrown = VelvetBrownNoise()
    private var rainEngine = PhysicalRainEngine()
    private var grooveEngine = HypnoticGrooveEngine()
    private var masterBus = AudiophileMasterBus()

    // ZDF bus tone shapers
    private var strHpL = CytomicSVF(cutoffHz: 250, q: 0.707)
    private var strHpR = CytomicSVF(cutoffHz: 250, q: 0.707)
    private var strLpL = CytomicSVF(cutoffHz: 5800, q: 0.65)
    private var strLpR = CytomicSVF(cutoffHz: 5800, q: 0.65)
    private var padLpL = CytomicSVF(cutoffHz: 1850, q: 0.72)
    private var padLpR = CytomicSVF(cutoffHz: 1850, q: 0.72)
    private var lastPadCutHz: Double = 1850

    // Session completion chime
    private var chimeVoiceA = VactrolBellVoice()
    private var chimeVoiceB = VactrolBellVoice()

    // Smooth gains
    private var activeGain: Float = 0
    private var duckGain: Float = 1
    private var smoothVol: Float = 0.65
    private(set) var isAudibleOutput: Bool = false

    init(seed: UInt32 = 42) {
        self.noiseRNG = FastNoiseRNG(seed: UInt64(seed) &* 0x9E3779B97F4A7C15 ^ 0xA5A5_5A5A)
        self.offlineScoreRNG = SeededRNG(seed: seed)
        self.samplerVoices = (0..<24).map { _ in AcousticSamplerVoice() }
        self.feltPianos = (0..<8).map { _ in FeltPianoVoice() }
    }

    private func resetVoicesAndBuses() {
        for i in 0..<samplerVoices.count { samplerVoices[i].active = false }
        for i in 0..<bells.count { bells[i].active = false }
        for i in 0..<feltPianos.count { feltPianos[i].active = false }
        for i in 0..<analogs.count { analogs[i].active = false }
        for i in 0..<glassBowls.count { glassBowls[i].active = false }
        for i in 0..<strings.count { strings[i].active = false }
        for i in 0..<pads.count { pads[i].active = false }

        rings.clear()
        beads.clear()
        binauralOrbit.clear()
        figureTapeEcho.clear()
        melodyTapeEcho.clear()
        figureChorus.clear()
        melodyChorus.clear()
        stringChorus.clear()
        space.clear()
        studioRain.reset()
        velvetBrown.reset()
        grooveEngine.reset()
        masterBus.clear()
        strHpL.reset(); strHpR.reset()
        strLpL.reset(); strLpR.reset()
        padLpL.reset(); padLpR.reset()

        clockSec = 0
        currentBarStartSec = 0
        barBellCursor = 0
        barSustainCursor = 0
        hasCurrentBar = false
        offlineNextBarIndex = 0
    }

    @inline(__always)
    private func pullNextBar(mode: FocusSoundscape, circadian: CircadianPhase, allowSyncFallback: Bool) {
        if barQueue.dequeue(into: &currentBar) {
            hasCurrentBar = true
            barBellCursor = 0
            barSustainCursor = 0
            return
        }
        if allowSyncFallback {
            let composed = SatieScore.composeBar(
                mode: mode,
                barIndex: offlineNextBarIndex,
                circadian: circadian,
                rng: &offlineScoreRNG
            )
            offlineNextBarIndex += 1
            currentBar.populate(from: composed)
            hasCurrentBar = true
            barBellCursor = 0
            barSustainCursor = 0
        }
    }

    func render(
        outL: UnsafeMutablePointer<Float>,
        outR: UnsafeMutablePointer<Float>,
        frames: Int,
        sampleRate: Double,
        allowSyncFallback: Bool
    ) {
        let wantActive = isActiveAtom.load(ordering: .acquiring) != 0
        let wantDucked = isDuckedAtom.load(ordering: .acquiring) != 0
        let modeIdx = max(0, min(FocusSoundscape.allCases.count - 1, modeAtom.load(ordering: .acquiring)))
        let mode = FocusSoundscape.allCases[modeIdx]
        let circadianRaw = circadianAtom.load(ordering: .acquiring)
        let circadian = CircadianPhase(rawValue: circadianRaw) ?? .afternoon
        let intensityRaw = max(0, min(2, intensityAtom.load(ordering: .acquiring)))
        let intensity: SoundIntensity = intensityRaw == 0 ? .still : (intensityRaw == 2 ? .deep : .flow)
        let maskingRaw = max(0, min(2, maskingBedAtom.load(ordering: .acquiring)))
        let maskingBed: MaskingBed = maskingRaw == 1 ? .rain : (maskingRaw == 2 ? .brown : .off)
        let sessionProg = Float(bitPattern: sessionProgressBitsAtom.load(ordering: .acquiring))
        let targetVol = Float(bitPattern: volumeBitsAtom.load(ordering: .acquiring))

        // Session-Arc Audio Choreography: Arrival (0..12%) -> Deep Lock (12..88%) -> Soft Landing (88..100%)
        let arcBrightness: Double
        let arcGainScale: Float
        if sessionProg >= 0.0 && sessionProg <= 1.0 {
            let p = Double(sessionProg)
            if p < 0.12 {
                let t = AudioMath.smoothstep(p / 0.12)
                arcBrightness = 0.72 + 0.28 * t
                arcGainScale = Float(0.84 + 0.16 * t)
            } else if p > 0.88 {
                let t = AudioMath.smoothstep((1.0 - p) / 0.12)
                arcBrightness = 0.50 + 0.50 * t
                arcGainScale = Float(0.76 + 0.24 * t)
            } else {
                arcBrightness = 1.0
                arcGainScale = 1.0
            }
        } else {
            arcBrightness = 1.0
            arcGainScale = 1.0
        }

        // Intensity / Modulation-Depth live multipliers (STILL / FLOW / DEEP)
        let intBrightScale: Double = intensity == .still ? 0.68 : (intensity == .deep ? 1.24 : 1.0)
        let intCloudScale: Float   = intensity == .still ? 0.62 : (intensity == .deep ? 1.28 : 1.0)
        let intGrooveScale: Float  = intensity == .still ? 0.45 : (intensity == .deep ? 1.22 : 1.0)

        if chimeTriggerAtom.exchange(0, ordering: .acquiring) != 0 {
            chimeVoiceA.trigger(
                event: ScoredBellEvent(kind: .melody, at: 0, midi: 69, duration: 2.4, velocity: 0.72, level: 0.16, pan: -0.18),
                rng: &noiseRNG,
                sampleRate: sampleRate
            )
            chimeVoiceB.trigger(
                event: ScoredBellEvent(kind: .melody, at: 0, midi: 76, duration: 2.8, velocity: 0.66, level: 0.14, pan: 0.18),
                rng: &noiseRNG,
                sampleRate: sampleRate
            )
        }

        if wakeResetAtom.exchange(0, ordering: .acquiring) != 0 && wantActive {
            activeGain = 0
            resetVoicesAndBuses()
            activeModeIdx = modeIdx
            activeCircadianRaw = circadianRaw
            pullNextBar(mode: mode, circadian: circadian, allowSyncFallback: allowSyncFallback)
        }

        if softReseedAtom.exchange(0, ordering: .acquiring) != 0 && wantActive {
            // Smooth musical phrase pivot: keeps reverb & granular tails blooming while loading fresh seed bar
            currentBarStartSec = clockSec
            pullNextBar(mode: mode, circadian: circadian, allowSyncFallback: allowSyncFallback)
        }

        if scoreResetAtom.exchange(0, ordering: .acquiring) != 0 || (wantActive && (modeIdx != activeModeIdx || circadianRaw != activeCircadianRaw)) {
            activeModeIdx = modeIdx
            activeCircadianRaw = circadianRaw
            resetVoicesAndBuses()
            pullNextBar(mode: mode, circadian: circadian, allowSyncFallback: allowSyncFallback)
        }

        if wantActive && !hasCurrentBar {
            pullNextBar(mode: mode, circadian: circadian, allowSyncFallback: allowSyncFallback)
        }

        let targetActiveGain: Float = wantActive ? 1.0 : 0.0
        let targetDuckGain: Float = wantDucked ? 0.0 : 1.0
        let dt = 1.0 / sampleRate
        let spb = SatieScore.secondsPerBeat(for: mode)

        // Eno prime-cycle macro modulation parameters (smoothed per block)
        let filterHorizon = hasCurrentBar ? currentBar.macroFilterHorizon : 0.75
        let spaceBloom    = hasCurrentBar ? currentBar.macroSpaceBloom : 0.55
        let resBoost      = hasCurrentBar ? currentBar.macroResonance : 0.45

        let targetPadCut = (mode == .pulse ? 1100.0 : 1450.0) + filterHorizon * (mode == .pulse ? 1350.0 : 1100.0)
        if abs(targetPadCut - lastPadCutHz) > 25.0 {
            lastPadCutHz = targetPadCut
            let padQ = (mode == .pulse) ? (0.85 + 0.55 * resBoost) : 0.72
            padLpL.set(cutoffHz: targetPadCut, q: padQ, sampleRate: sampleRate)
            padLpR.set(cutoffHz: targetPadCut, q: padQ, sampleRate: sampleRate)
        }

        // Mode-calibrated studio acoustic chamber & tape echo parameters
        let preDelayMs: Double
        let roomDecay: Float
        let roomDampLP: Float
        let roomWet: Float
        let erMix: Float
        let tapeToneHz: Double
        let tapeWowMs: Double
        let figEchoSend: Float
        let melEchoSend: Float

        switch mode {
        case .focus:
            preDelayMs = 18.0
            roomDecay = Float(0.83 + 0.03 * spaceBloom)
            roomDampLP = 0.38
            roomWet = 0.34
            erMix = 0.30
            tapeToneHz = 3600.0
            tapeWowMs = 1.15
            figEchoSend = 0.22
            melEchoSend = 0.24
        case .pulse:
            preDelayMs = 12.0
            roomDecay = Float(0.76 + 0.04 * spaceBloom)
            roomDampLP = 0.42
            roomWet = 0.24
            erMix = 0.24
            tapeToneHz = 3200.0
            tapeWowMs = 0.85
            figEchoSend = 0.24
            melEchoSend = 0.26
        case .rain:
            preDelayMs = 24.0
            roomDecay = Float(0.86 + 0.03 * spaceBloom)
            roomDampLP = 0.32
            roomWet = 0.38
            erMix = 0.34
            tapeToneHz = 2800.0
            tapeWowMs = 1.35
            figEchoSend = 0.16
            melEchoSend = 0.28
        case .drift:
            preDelayMs = 26.0
            roomDecay = Float(0.88 + 0.03 * spaceBloom)
            roomDampLP = 0.30
            roomWet = 0.42
            erMix = 0.42 // Rich Tokyo wooden listening hall early reflections
            tapeToneHz = 2300.0
            tapeWowMs = 1.45
            figEchoSend = 0.14
            melEchoSend = 0.20
        case .still:
            preDelayMs = 28.0
            roomDecay = Float(0.89 + 0.03 * spaceBloom)
            roomDampLP = 0.28
            roomWet = 0.44
            erMix = 0.38
            tapeToneHz = 2100.0
            tapeWowMs = 1.20
            figEchoSend = 0.12
            melEchoSend = 0.18
        }

        let baseAirHz: Double
        switch circadian {
        case .morning:   baseAirHz = 7800.0
        case .afternoon: baseAirHz = 6800.0
        case .night:     baseAirHz = 5000.0
        }
        let airCeilingHz = max(2600.0, min(9200.0, baseAirHz * intBrightScale * arcBrightness))

        let figDelayL = 0.75 * spb
        let figDelayR = 0.75 * spb * 1.014 // Slight stereo head offset for natural width
        let melDelayL = 1.50 * spb
        let melDelayR = 1.50 * spb * 0.986

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

            // 0. Sample-accurate zero-allocation event dispatch from pre-composed bar slot
            if hasCurrentBar {
                let relTime = clockSec - currentBarStartSec
                while barBellCursor < currentBar.bellCount && currentBar.bells[barBellCursor].at <= relTime {
                    let ev = currentBar.bells[barBellCursor]
                    let root = currentBar.rootMidi
                    switch mode {
                    case .focus:
                        // Kankyō Acoustic: Real CC0 Soft Vibraphone + Velvet Felt Piano + Concert Harp glints
                        if sampleBank.isAvailable {
                            let inst: AcousticInstrumentID
                            let felt: Bool
                            let scale: Double
                            switch ev.kind {
                            case .figure:
                                inst = (barBellCursor % 3 == 0) ? .piano : .vibe
                                felt = (inst == .piano)
                                scale = (inst == .piano) ? 1.55 : 1.35
                            case .melody:
                                inst = .piano
                                felt = false
                                scale = 1.65
                            case .glint:
                                inst = .harp
                                felt = false
                                scale = 1.95
                            }
                            _ = samplerVoices[nextSamplerSlot].trigger(
                                bank: sampleBank, instrument: inst, midi: ev.midi, rootMidi: root,
                                velocity: ev.velocity, duration: ev.duration,
                                level: ev.level * scale, pan: ev.pan,
                                feltMuffle: felt, justSweeten: false, sustainedLayer: false,
                                rng: &noiseRNG, sampleRate: sampleRate
                            )
                            nextSamplerSlot = (nextSamplerSlot + 1) % samplerVoices.count
                            // Subtle Buchla vactrol shimmer layered underneath melody notes for hybrid depth
                            if ev.kind == .melody {
                                let hybridEv = ScoredBellEvent(kind: .melody, at: ev.at, midi: ev.midi, duration: ev.duration, velocity: ev.velocity * 0.7, level: ev.level * 0.24, pan: ev.pan)
                                bells[nextBellSlot].trigger(event: hybridEv, rng: &noiseRNG, sampleRate: sampleRate)
                                nextBellSlot = (nextBellSlot + 1) % bells.count
                            }
                        } else {
                            bells[nextBellSlot].trigger(event: ev, rng: &noiseRNG, sampleRate: sampleRate)
                            nextBellSlot = (nextBellSlot + 1) % bells.count
                        }

                    case .pulse:
                        // Donato Dozzy × Wata Igarashi: PolyBLEP ZDF Analog + 3:4 Mutable Rings in 3D Binaural Orbit
                        if ev.kind == .glint {
                            if sampleBank.isAvailable {
                                _ = samplerVoices[nextSamplerSlot].trigger(
                                    bank: sampleBank, instrument: .harp, midi: ev.midi, rootMidi: root,
                                    velocity: ev.velocity, duration: 0.9, level: ev.level * 2.1, pan: ev.pan,
                                    rng: &noiseRNG, sampleRate: sampleRate
                                )
                                nextSamplerSlot = (nextSamplerSlot + 1) % samplerVoices.count
                            } else {
                                bells[nextBellSlot].trigger(event: ev, rng: &noiseRNG, sampleRate: sampleRate)
                                nextBellSlot = (nextBellSlot + 1) % bells.count
                            }
                        } else if ev.kind == .melody {
                            // Polyrhythmic 3-against-4 physical modal resonator (Mutable Instruments Rings)
                            let structure = 0.16 + 0.28 * currentBar.macroResonance
                            let position = 0.18 + 0.24 * currentBar.macroSpaceBloom
                            rings.strike(
                                midi: ev.midi, velocity: ev.velocity,
                                structure: structure, brightness: 0.45 + 0.35 * currentBar.macroFilterHorizon,
                                damping: 0.75 + 0.55 * currentBar.macroSpaceBloom, position: position,
                                level: ev.level * 1.95, pan: ev.pan,
                                rng: &noiseRNG, sampleRate: sampleRate
                            )
                        } else {
                            analogs[nextAnalogSlot].trigger(
                                event: ev,
                                filterHorizon: currentBar.macroFilterHorizon,
                                resonanceBoost: currentBar.macroResonance,
                                isPluck: false,
                                rng: &noiseRNG,
                                sampleRate: sampleRate
                            )
                            nextAnalogSlot = (nextAnalogSlot + 1) % analogs.count
                        }

                    case .rain:
                        // Hiroshi Yoshimura 'Green': Real CC0 Vibraphone, Friction Wine Glasses & Concert Harp in Rain
                        if sampleBank.isAvailable {
                            let inst: AcousticInstrumentID = (ev.kind == .glint) ? .harp : ((barBellCursor % 2 == 0) ? .vibe : .glass)
                            let scale: Double = (inst == .glass) ? 1.55 : (inst == .harp ? 2.1 : 1.45)
                            _ = samplerVoices[nextSamplerSlot].trigger(
                                bank: sampleBank, instrument: inst, midi: ev.midi, rootMidi: root,
                                velocity: ev.velocity, duration: ev.duration,
                                level: ev.level * scale, pan: ev.pan,
                                feltMuffle: false, justSweeten: inst == .glass, sustainedLayer: false,
                                rng: &noiseRNG, sampleRate: sampleRate
                            )
                            nextSamplerSlot = (nextSamplerSlot + 1) % samplerVoices.count
                        } else {
                            glassBowls[nextBowlSlot].trigger(event: ev, rng: &noiseRNG)
                            nextBowlSlot = (nextBowlSlot + 1) % glassBowls.count
                        }

                    case .drift:
                        // Ryuichi Sakamoto '12' × Nils Frahm: Real CC0 Velvet Felt Upright Piano + Bowed Wine Glass
                        if sampleBank.isAvailable {
                            let inst: AcousticInstrumentID = (ev.kind == .glint) ? .glass : .piano
                            _ = samplerVoices[nextSamplerSlot].trigger(
                                bank: sampleBank, instrument: inst, midi: ev.midi, rootMidi: root,
                                velocity: ev.velocity, duration: ev.duration,
                                level: ev.level * (inst == .piano ? 1.95 : 1.75), pan: ev.pan,
                                feltMuffle: inst == .piano, justSweeten: inst == .glass, sustainedLayer: false,
                                rng: &noiseRNG, sampleRate: sampleRate
                            )
                            nextSamplerSlot = (nextSamplerSlot + 1) % samplerVoices.count
                        } else if ev.kind == .glint {
                            glassBowls[nextBowlSlot].trigger(event: ev, rng: &noiseRNG)
                            nextBowlSlot = (nextBowlSlot + 1) % glassBowls.count
                        } else {
                            feltPianos[nextPianoSlot].trigger(event: ev, rng: &noiseRNG, sampleRate: sampleRate)
                            nextPianoSlot = (nextPianoSlot + 1) % feltPianos.count
                        }

                    case .still:
                        // Zero-Ego Study: Friction-Bowed Wine Glasses + Whisper Felt Piano (no melody hook, pure suspended field)
                        if sampleBank.isAvailable {
                            let inst: AcousticInstrumentID = (ev.kind == .glint) ? .glass : ((barBellCursor % 2 == 0) ? .piano : .glass)
                            _ = samplerVoices[nextSamplerSlot].trigger(
                                bank: sampleBank, instrument: inst, midi: ev.midi, rootMidi: root,
                                velocity: ev.velocity * 0.82, duration: ev.duration * 1.2,
                                level: ev.level * (inst == .piano ? 1.45 : 1.65), pan: ev.pan,
                                feltMuffle: true, justSweeten: true, sustainedLayer: false,
                                rng: &noiseRNG, sampleRate: sampleRate
                            )
                            nextSamplerSlot = (nextSamplerSlot + 1) % samplerVoices.count
                        } else {
                            glassBowls[nextBowlSlot].trigger(event: ev, rng: &noiseRNG)
                            nextBowlSlot = (nextBowlSlot + 1) % glassBowls.count
                        }
                    }
                    barBellCursor += 1
                }

                while barSustainCursor < currentBar.sustainCount && currentBar.sustained[barSustainCursor].at <= relTime {
                    let ev = currentBar.sustained[barSustainCursor]
                    if ev.kind == .strings {
                        if sampleBank.isAvailable {
                            // Real CC0 Cello Section sustained vibrato (octave-clamped into cello sweet spot)
                            let celloMidi = ev.midi > 64 ? ev.midi - 12 : ev.midi
                            let susInst: AcousticInstrumentID = (mode == .rain && barSustainCursor % 2 == 1) ? .glass : .cello
                            _ = samplerVoices[nextSamplerSlot].trigger(
                                bank: sampleBank, instrument: susInst, midi: celloMidi, rootMidi: currentBar.rootMidi,
                                velocity: 0.72, duration: ev.duration,
                                level: ev.level * (susInst == .cello ? 2.4 : 1.7), pan: ev.pan,
                                feltMuffle: false, justSweeten: true, sustainedLayer: true,
                                rng: &noiseRNG, sampleRate: sampleRate
                            )
                            nextSamplerSlot = (nextSamplerSlot + 1) % samplerVoices.count
                        }
                        // Layer subtle soft ensemble harmonic air underneath for seamless legato overlap
                        let airEv = ScoredSustainEvent(kind: .strings, at: ev.at, midi: ev.midi, duration: ev.duration, level: ev.level * (sampleBank.isAvailable ? 0.35 : 1.0), pan: ev.pan)
                        strings[nextStringSlot].trigger(event: airEv, rootMidi: currentBar.rootMidi, rng: &noiseRNG, sampleRate: sampleRate)
                        nextStringSlot = (nextStringSlot + 1) % strings.count
                    } else {
                        pads[nextPadSlot].trigger(event: ev, rootMidi: currentBar.rootMidi, rng: &noiseRNG)
                        nextPadSlot = (nextPadSlot + 1) % pads.count
                    }
                    barSustainCursor += 1
                }

                if relTime >= currentBar.secondsPerBar {
                    currentBarStartSec += currentBar.secondsPerBar
                    pullNextBar(mode: mode, circadian: circadian, allowSyncFallback: allowSyncFallback)
                }
            }
            clockSec += dt

            // 1. Render Primary Acoustic & Modular Voices
            var figL: Float = 0, figR: Float = 0
            var melL: Float = 0, melR: Float = 0
            var celloL: Float = 0, celloR: Float = 0

            for sv in 0..<samplerVoices.count where samplerVoices[sv].active {
                let (vL, vR) = samplerVoices[sv].step(dt: dt)
                if samplerVoices[sv].isSustainedLayer {
                    celloL += vL; celloR += vR
                } else if samplerVoices[sv].instrument == .vibe {
                    figL += vL; figR += vR
                } else {
                    melL += vL; melR += vR
                }
            }
            for b in 0..<bells.count where bells[b].active {
                let (sL, sR) = bells[b].step(dt: dt, sampleRate: sampleRate, sineTable: bank.sineTable, noise: &noiseRNG)
                if bells[b].isFigure { figL += sL; figR += sR } else { melL += sL; melR += sR }
            }
            for p in 0..<feltPianos.count where feltPianos[p].active {
                let (sL, sR) = feltPianos[p].step(dt: dt, noise: &noiseRNG)
                melL += sL; melR += sR
            }
            for a in 0..<analogs.count where analogs[a].active {
                let (sL, sR) = analogs[a].step(dt: dt, sampleRate: sampleRate, sineTable: bank.sineTable)
                if analogs[a].isPluck { melL += sL; melR += sR } else { figL += sL; figR += sR }
            }
            for g in 0..<glassBowls.count where glassBowls[g].active {
                let (sL, sR) = glassBowls[g].step(dt: dt, sineTable: bank.sineTable)
                melL += sL; melR += sR
            }

            // Mutable Instruments Rings 56-mode physical resonator -> 3D Binaural Sonic Gyroscope!
            let (ringRawL, ringRawR) = rings.step(dt: dt, noise: &noiseRNG)
            let (ringBinL, ringBinR) = binauralOrbit.process(
                ringRawL, ringRawR,
                orbitHz: mode == .pulse ? 0.055 : 0.032,
                maxAzimuthRad: mode == .pulse ? 1.20 : 0.85,
                dt: dt, sampleRate: sampleRate
            )
            melL += ringBinL
            melR += ringBinR

            // Subtle warm pickup/console saturation on figure bus
            let bias: Float = 0.119427 // tanh(0.12)
            figL = (tanh(1.85 * figL + 0.12) - bias) / 1.85
            figR = (tanh(1.85 * figR + 0.12) - bias) / 1.85

            // Roland RE-201 Tape Space Echo + Dual-LFO Stereo Chorus
            let (feL, feR) = figureTapeEcho.process(
                figL, figR,
                delaySecL: figDelayL, delaySecR: figDelayR,
                send: figEchoSend, feedback: 0.36,
                toneHz: tapeToneHz, wowDepthMs: tapeWowMs,
                dt: dt, sampleRate: sampleRate
            )
            let (fcL, fcR) = figureChorus.process(feL, feR, dt: dt, sampleRate: sampleRate, depthSec: 0.0016, amount: mode == .pulse ? 0.14 : 0.22)

            let (meL, meR) = melodyTapeEcho.process(
                melL, melR,
                delaySecL: melDelayL, delaySecR: melDelayR,
                send: melEchoSend, feedback: 0.35,
                toneHz: tapeToneHz * 0.92, wowDepthMs: tapeWowMs * 1.15,
                dt: dt, sampleRate: sampleRate
            )
            let (mcL, mcR) = melodyChorus.process(meL, meR, dt: dt, sampleRate: sampleRate, depthSec: 0.0011, amount: mode == .drift ? 0.10 : 0.14)

            // Mutable Instruments Beads Live Granular Cloud (feeds on real acoustic piano / vibe / harp / rings!)
            let cloudInL = melL + figL * 0.65
            let cloudInR = melR + figR * 0.65
            let cloudDens: Double = (mode == .drift || mode == .still) ? 5.8 : (mode == .rain ? 7.2 : 6.5)
            let cloudShim: Double = (mode == .rain) ? 0.36 : (mode == .pulse ? 0.12 : (mode == .drift ? 0.18 : (mode == .still ? 0.14 : 0.28)))
            let cloudRev: Double  = (mode == .drift || mode == .still) ? 0.48 : (mode == .focus ? 0.34 : 0.28)
            let cloudSub: Double  = (mode == .pulse) ? 0.36 : ((mode == .drift || mode == .still) ? 0.30 : 0.14)
            let baseCloudWet: Float = (mode == .drift || mode == .still) ? 0.34 : (mode == .rain ? 0.30 : (mode == .pulse ? 0.16 : 0.24))
            let cloudWet: Float = baseCloudWet * intCloudScale
            let (beadsL, beadsR) = beads.process(
                cloudInL, cloudInR,
                densityHz: cloudDens,
                shimmerProb: cloudShim,
                reverseProb: cloudRev,
                subProb: cloudSub,
                sampleRate: sampleRate
            )

            // 2. Render Real CC0 Bowed Cello Section + Ensemble Strings (ZDF band cleaning)
            var sL: Float = celloL, sR: Float = celloR
            for st in 0..<strings.count where strings[st].active {
                let (vL, vR) = strings[st].step(dt: dt, bank: bank, noise: &noiseRNG)
                sL += vL; sR += vR
            }
            let strCleanL = strHpL.highpass(strLpL.lowpass(sL))
            let strCleanR = strHpR.highpass(strLpR.lowpass(sR))
            let (scL, scR) = stringChorus.process(strCleanL, strCleanR, dt: dt, sampleRate: sampleRate, depthSec: 0.0032, amount: 0.28)

            // 3. Render Just-Intonation Wide Pad + Acoustic Bass
            var pL: Float = 0, pR: Float = 0
            var bsL: Float = 0, bsR: Float = 0
            for k in 0..<pads.count where pads[k].active {
                let (vL, vR) = pads[k].step(dt: dt, bank: bank)
                if pads[k].isBass { bsL += vL; bsR += vR } else { pL += vL; pR += vR }
            }
            var filtPadL = padLpL.lowpass(pL)
            var filtPadR = padLpR.lowpass(pR)

            // 4. Mode-specific Groove (Kinetic Pulse) or 3-Layer Physical Rain (Rain & Glass)
            var pulseSub: Float = 0
            var percL: Float = 0, percR: Float = 0
            var sidechainGain: Float = 1.0
            if mode == .pulse {
                let grv = grooveEngine.step(
                    clockSec: clockSec, spb: spb, dt: dt, sampleRate: sampleRate,
                    sineTable: bank.sineTable, noise: &noiseRNG
                )
                pulseSub = grv.sub * intGrooveScale
                percL = grv.percL * intGrooveScale
                percR = grv.percR * intGrooveScale
                sidechainGain = 1.0 - (1.0 - grv.sidechainGain) * intGrooveScale
                // Pad & cello gently breathe around the analog sub-kick
                filtPadL *= sidechainGain
                filtPadR *= sidechainGain
            }

            // Independent Acoustic Masking Bed:
            // - Rain & Glass always includes Kyoto velvet rain (unless user switches bed to Brown)
            // - Any other mode can layer Kyoto Rain or Velvet Brown speech masking seamlessly underneath!
            var rainTexL: Float = 0, rainTexR: Float = 0
            let wantRainBed = (mode == .rain && maskingBed != .brown) || (maskingBed == .rain)
            let wantBrownBed = (maskingBed == .brown) || (mode == .still && maskingBed == .off)
            if wantRainBed {
                let rainGain: Float = (mode == .rain) ? 1.0 : 0.78
                if studioRain.isAvailable {
                    let (rL, rR) = studioRain.step(clockSec: clockSec, spaceBloom: spaceBloom, sampleRate: sampleRate)
                    rainTexL += rL * rainGain
                    rainTexR += rR * rainGain
                } else {
                    let (rL, rR) = rainEngine.step(clockSec: clockSec, dt: dt, sampleRate: sampleRate, sineTable: bank.sineTable)
                    rainTexL += rL * 0.30 * rainGain
                    rainTexR += rR * 0.30 * rainGain
                }
            }
            if wantBrownBed {
                let brownScale: Float = (maskingBed == .brown) ? 1.0 : 0.42 // subtle cozy cocoon on Still by default
                let (bL, bR) = velvetBrown.step(clockSec: clockSec, brightnessScale: intBrightScale * arcBrightness, sampleRate: sampleRate)
                rainTexL += bL * brownScale
                rainTexR += bR * brownScale
            }

            // 5. Studio Acoustic Space (Pre-Delay + Early Reflections + 4-Stage Allpass + 8x8 Modulated FDN)
            let dryL = fcL + mcL + scL * sidechainGain + filtPadL + bsL + pulseSub + percL + rainTexL + beadsL * cloudWet * sidechainGain
            let dryR = fcR + mcR + scR * sidechainGain + filtPadR + bsR + pulseSub + percR + rainTexR + beadsR * cloudWet * sidechainGain

            // Keep sub-bass & close rain sheet mostly out of the reverb tank for crystalline clarity
            let revInL = fcL + mcL + strCleanL * 0.95 + filtPadL * 0.65 + beadsL * (cloudWet * 0.65) + percL * 0.40 + rainTexL * 0.20
            let revInR = fcR + mcR + strCleanR * 0.95 + filtPadR * 0.65 + beadsR * (cloudWet * 0.65) + percR * 0.40 + rainTexR * 0.20
            let (wetL, wetR) = space.process(
                revInL, revInR,
                preDelayMs: preDelayMs,
                decay: roomDecay,
                dampLP: roomDampLP,
                dampHP: 0.022,
                erMix: erMix,
                modScale: 0.90 + 0.30 * spaceBloom,
                dt: dt,
                sampleRate: sampleRate
            )

            let mixL = dryL + wetL * roomWet * sidechainGain
            let mixR = dryR + wetR * roomWet * sidechainGain

            // 6. Audiophile Master Bus (24dB/oct Elliptical Sub-Monoizer + M/S Air + Tube Polish + RMS Optical Glue + Lookahead Limiter)
            // Mode-matched gain calibration (~ -18.5 to -16.0 dBFS RMS across all 4 modes at 75% volume)
            let modeMakeup: Float
            switch mode {
            case .focus: modeMakeup = 4.1
            case .pulse: modeMakeup = 5.4
            case .rain:  modeMakeup = 7.4
            case .drift: modeMakeup = 6.2
            case .still: modeMakeup = 7.1
            }
            var (finalL, finalR) = masterBus.process(
                mixL, mixR,
                airCeilingHz: airCeilingHz,
                stereoWidthBoost: (mode == .drift || mode == .still) ? 0.15 : 0.11,
                outputGain: modeMakeup * masterEnv * smoothVol * arcGainScale,
                sampleRate: sampleRate
            )

            if chimeVoiceA.active || chimeVoiceB.active {
                let (cAL, cAR) = chimeVoiceA.step(dt: dt, sampleRate: sampleRate, sineTable: bank.sineTable, noise: &noiseRNG)
                let (cBL, cBR) = chimeVoiceB.step(dt: dt, sampleRate: sampleRate, sineTable: bank.sineTable, noise: &noiseRNG)
                finalL = tanh((finalL + (cAL + cBL) * 1.25) / 0.94) * 0.94
                finalR = tanh((finalR + (cAR + cBR) * 1.25) / 0.94) * 0.94
            }

            outL[i] = finalL
            outR[i] = finalR
            blockPeak = max(blockPeak, abs(finalL), abs(finalR))
        }

        if hasCurrentBar {
            let rel = max(0.0, min(1.0, (clockSec - currentBarStartSec) / max(0.01, currentBar.secondsPerBar)))
            let packed: UInt64 = UInt64(currentBar.barInForm & 0x3F)
                | (UInt64(min(1023, currentBar.pass)) << 6)
                | (UInt64(currentBar.chordIndex & 0x3F) << 16)
                | (UInt64(currentBar.didSwapFigure ? 1 : 0) << 22)
                | (UInt64(Int(rel * 255.0) & 0xFF) << 24)
            telemetryPackedAtom.store(packed, ordering: .releasing)
        }

        isAudibleOutput = blockPeak > 0.0008
    }
}
