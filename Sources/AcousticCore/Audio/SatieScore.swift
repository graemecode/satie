import Foundation

/// Deterministic Mulberry32 PRNG matching the exact seeded variation behavior of Soft Light.
public struct SeededRNG: Sendable {
    private var state: UInt32

    public init(seed: UInt32) {
        self.state = seed
    }

    public mutating func nextUnit() -> Double {
        state &+= 0x6D2B79F5
        var t = state
        t = (t ^ (t >> 15)) &* (t | 1)
        t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
        let out = t ^ (t >> 14)
        return Double(out) / 4_294_967_296.0
    }

    public mutating func between(_ low: Double, _ high: Double) -> Double {
        low + (high - low) * nextUnit()
    }

    public mutating func nextInt(_ upperBound: Int) -> Int {
        guard upperBound > 1 else { return 0 }
        return min(upperBound - 1, Int(nextUnit() * Double(upperBound)))
    }
}

public enum ScoredBellKind: Sendable, Equatable {
    case figure
    case melody
    case glint
}

public enum ScoredSustainKind: Sendable, Equatable {
    case bass
    case pad
    case strings
}

public struct ScoredBellEvent: Sendable, Equatable {
    public let kind: ScoredBellKind
    public let at: Double        // seconds from bar start
    public let midi: Int
    public let duration: Double  // seconds
    public let velocity: Double
    public let level: Double
    public let pan: Double       // -1 ... +1

    public init(kind: ScoredBellKind, at: Double, midi: Int, duration: Double, velocity: Double, level: Double, pan: Double) {
        self.kind = kind
        self.at = at
        self.midi = midi
        self.duration = duration
        self.velocity = velocity
        self.level = level
        self.pan = pan
    }
}

public struct ScoredSustainEvent: Sendable, Equatable {
    public let kind: ScoredSustainKind
    public let at: Double        // seconds from bar start (may be slightly negative for legato lead-in)
    public let midi: Int
    public let duration: Double  // seconds
    public let level: Double
    public let pan: Double

    public init(kind: ScoredSustainKind, at: Double, midi: Int, duration: Double, level: Double, pan: Double) {
        self.kind = kind
        self.at = at
        self.midi = midi
        self.duration = duration
        self.level = level
        self.pan = pan
    }
}

public struct ComposedBar: Sendable, Equatable {
    public let barIndex: Int
    public let barInForm: Int
    public let pass: Int
    public let chordName: String
    public let rootMidi: Int
    public let secondsPerBeat: Double
    public let secondsPerBar: Double
    public let bells: [ScoredBellEvent]
    public let sustained: [ScoredSustainEvent]
    public let didSwapFigure: Bool
    public let allowedPitchClasses: Set<Int>
    /// Eno incommensurate prime-length (5, 7, 11, 13 bar) macro evolution curves ∈ [0, 1]
    public let macroFilterHorizon: Double
    public let macroSpaceBloom: Double
    public let macroResonance: Double
}

/// Pure, deterministic, audio-free score generator for Satie's four work soundscapes.
/// Inspired directly by Soft Light's two-file score/engine separation: 32-bar harmonic forms,
/// section fullness/string-swell arcs, Pass 2+ harmony-preserving figure swaps, sparse melody
/// dropouts & octave lifts, pentatonic water glints, and sleep-safe `stillDue` filtering.
public enum SatieScore {
    public struct ChordDef: Sendable {
        public let name: String
        public let root: Int
        public let figure: [Int]
        public let held: [Int]
    }

    public static let barsPerForm = 32
    public static let shortestLateNoteSeconds = 0.5

    // MARK: - Soft Light (Focus: 32-bar A Major, 72 BPM — exact progression & voicings)

    private static let chordA    = ChordDef(name: "A",    root: 45, figure: [57, 64, 71, 64, 73, 64, 71, 68], held: [57, 64, 68, 73])
    private static let chordFsm  = ChordDef(name: "F#m",  root: 42, figure: [54, 61, 69, 61, 71, 64, 69, 61], held: [54, 61, 64, 69])
    private static let chordD    = ChordDef(name: "D",    root: 50, figure: [50, 57, 66, 64, 73, 64, 66, 57], held: [57, 62, 66, 73])
    private static let chordEsus = ChordDef(name: "Esus", root: 52, figure: [52, 59, 64, 69, 73, 69, 64, 59], held: [59, 64, 69, 73])
    private static let chordE    = ChordDef(name: "E",    root: 52, figure: [52, 59, 64, 68, 71, 68, 64, 59], held: [59, 64, 68, 71])
    private static let chordBm   = ChordDef(name: "Bm",   root: 47, figure: [59, 66, 69, 66, 74, 66, 73, 69], held: [59, 62, 66, 73])
    private static let chordCsm  = ChordDef(name: "C#m",  root: 49, figure: [56, 64, 68, 64, 71, 68, 64, 59], held: [56, 59, 64, 68])
    private static let chordE6   = ChordDef(name: "E6",   root: 52, figure: [52, 59, 64, 68, 73, 68, 64, 61], held: [59, 64, 68, 73])
    private static let chordA6   = ChordDef(name: "A6",   root: 45, figure: [57, 64, 69, 64, 73, 66, 69, 64], held: [57, 64, 66, 73])

    private static let softLightForm: [ChordDef] = [
        chordA, chordA, chordFsm, chordFsm, chordD, chordD, chordEsus, chordE,
        chordA, chordA, chordFsm, chordFsm, chordD, chordD, chordEsus, chordE,
        chordBm, chordBm, chordCsm, chordCsm, chordD, chordD, chordE6, chordEsus,
        chordA, chordA, chordFsm, chordFsm, chordD, chordE, chordA6, chordA,
    ]

    private static let softLightMelody: [[(Double, Int, Double)]] = [
        [], [], [], [(2, 76, 2)], [], [(1, 73, 3)], [], [(1, 68, 3)],
        [(0, 76, 3)], [(1, 80, 1), (2, 78, 2)], [(0, 73, 3)], [(2, 76, 2)],
        [(0, 78, 2), (2, 76, 2)], [(1, 73, 3)], [(0, 71, 3)], [(0, 71, 1), (1, 68, 3)],
        [(0, 78, 3)], [(1, 81, 1), (2, 78, 2)], [(0, 76, 3)], [(1, 80, 1), (2, 76, 2)],
        [(0, 81, 2), (2, 78, 2)], [(1, 85, 3)], [(0, 83, 2), (2, 80, 2)], [(0, 81, 3)],
        [(0, 81, 3)], [(1, 85, 1), (2, 83, 2)], [(0, 81, 2), (2, 76, 2)], [(2, 73, 2)],
        [(0, 78, 1.5), (1.5, 81, 2.5)], [(1, 76, 1), (2, 71, 2)], [(0, 73, 4)], [],
    ]

    public static let fullnessCurve: [Double] = [
        0.80, 0.80, 0.80, 0.80, 0.80, 0.80, 0.80, 0.80,
        0.92, 0.92, 0.92, 0.92, 0.92, 0.92, 0.92, 0.92,
        1.00, 1.00, 1.00, 1.00, 1.00, 1.00, 1.00, 1.00,
        0.95, 0.95, 0.92, 0.90, 0.88, 0.86, 0.82, 0.80,
    ]
    private static let softLightFullness = fullnessCurve

    private static let softLightStringSwell: [Double] = [
        0.22, 0.22, 0.22, 0.22, 0.22, 0.22, 0.22, 0.22,
        0.45, 0.50, 0.55, 0.60, 0.66, 0.72, 0.78, 0.84,
        0.92, 0.96, 1.00, 1.00, 1.00, 0.96, 0.92, 0.86,
        0.74, 0.66, 0.58, 0.50, 0.42, 0.34, 0.28, 0.22,
    ]

    // A major pentatonic glints (E6, F#6, A6, B6, C#7, E7)
    private static let softLightGlints: [Int] = [88, 90, 93, 95, 97, 100]

    // MARK: - Kinetic Pulse (104 BPM D Dorian / F Lydian driving arpeggios)

    private static let chordDm9  = ChordDef(name: "Dm9",   root: 38, figure: [50, 57, 60, 64, 69, 64, 60, 57], held: [50, 57, 60, 64])
    private static let chordFmaj = ChordDef(name: "Fmaj7", root: 41, figure: [53, 60, 64, 67, 72, 67, 64, 60], held: [53, 57, 60, 64])
    private static let chordCadd = ChordDef(name: "Cadd9", root: 48, figure: [55, 60, 62, 67, 72, 67, 62, 60], held: [55, 60, 62, 67])
    private static let chordG6   = ChordDef(name: "G6",    root: 43, figure: [55, 59, 62, 64, 67, 64, 62, 59], held: [55, 59, 62, 64])
    private static let chordAm7  = ChordDef(name: "Am7",   root: 45, figure: [57, 60, 64, 67, 72, 67, 64, 60], held: [57, 60, 64, 67])

    private static let pulseForm: [ChordDef] = [
        chordDm9, chordDm9, chordFmaj, chordFmaj, chordCadd, chordCadd, chordG6, chordG6,
        chordDm9, chordDm9, chordFmaj, chordFmaj, chordAm7, chordAm7, chordCadd, chordG6,
        chordFmaj, chordFmaj, chordG6, chordG6, chordAm7, chordAm7, chordCadd, chordG6,
        chordDm9, chordDm9, chordFmaj, chordCadd, chordG6, chordAm7, chordDm9, chordDm9,
    ]
    private static let dorianGlints: [Int] = [81, 84, 86, 88, 91, 93]

    // MARK: - Rain & Glass (60 BPM Hiroshi Yoshimura 'Green' F Lydian / C Major9 kankyō ongaku)

    private static let chordFmaj9 = ChordDef(name: "Fmaj7", root: 41, figure: [53, 60, 64, 67, 72, 69, 64, 60], held: [53, 60, 64, 67])
    private static let chordCmaj9 = ChordDef(name: "Cadd9", root: 48, figure: [55, 60, 62, 67, 71, 67, 64, 60], held: [55, 60, 62, 67])
    private static let chordDm11  = ChordDef(name: "Dm9",   root: 38, figure: [50, 57, 60, 64, 67, 64, 60, 57], held: [50, 57, 60, 64])
    private static let chordAm9   = ChordDef(name: "Am7",   root: 45, figure: [57, 60, 64, 67, 71, 67, 64, 60], held: [57, 60, 64, 67])

    private static let rainForm: [ChordDef] = [
        chordFmaj9, chordFmaj9, chordCmaj9, chordCmaj9, chordFmaj9, chordFmaj9, chordAm9, chordAm9,
        chordDm11, chordDm11, chordCmaj9, chordCmaj9, chordFmaj9, chordFmaj9, chordCmaj9, chordCmaj9,
        chordAm9, chordAm9, chordFmaj9, chordFmaj9, chordDm11, chordDm11, chordCmaj9, chordCmaj9,
        chordFmaj9, chordFmaj9, chordAm9, chordAm9, chordDm11, chordCmaj9, chordFmaj9, chordFmaj9,
    ]
    private static let rainGlints: [Int] = [79, 81, 84, 86, 88, 91]

    // MARK: - Gymnopédie / Drift (54 BPM Gmaj7 <-> Dmaj7 nocturnal spaciousness)

    private static let chordGmaj7 = ChordDef(name: "Gmaj7", root: 43, figure: [55, 59, 62, 66, 71, 66, 62, 59], held: [55, 59, 62, 66])
    private static let chordDmaj7 = ChordDef(name: "Dmaj7", root: 38, figure: [50, 57, 61, 66, 69, 66, 61, 57], held: [50, 57, 61, 66])
    private static let chordEm9   = ChordDef(name: "Em9",   root: 40, figure: [52, 59, 62, 66, 71, 66, 62, 59], held: [52, 59, 62, 66])
    private static let chordA9sus = ChordDef(name: "A9sus", root: 45, figure: [57, 62, 64, 67, 71, 67, 64, 62], held: [57, 62, 64, 67])

    private static let driftForm: [ChordDef] = [
        chordGmaj7, chordGmaj7, chordDmaj7, chordDmaj7, chordGmaj7, chordGmaj7, chordDmaj7, chordDmaj7,
        chordEm9, chordEm9, chordA9sus, chordA9sus, chordDmaj7, chordDmaj7, chordGmaj7, chordGmaj7,
        chordEm9, chordEm9, chordGmaj7, chordGmaj7, chordA9sus, chordA9sus, chordDmaj7, chordDmaj7,
        chordGmaj7, chordGmaj7, chordDmaj7, chordDmaj7, chordEm9, chordA9sus, chordGmaj7, chordDmaj7,
    ]
    private static let driftGlints: [Int] = [83, 86, 88, 90, 93, 95]

    // MARK: - Still (58 BPM Zero-Ego Study: Non-Resolving Pentatonic & Suspended 9ths — Dmitry Evgrafov / Endel Study)

    private static let stillForm: [ChordDef] = [
        chordCmaj9, chordCmaj9, chordG6, chordG6, chordAm9, chordAm9, chordFmaj9, chordFmaj9,
        chordDm11, chordDm11, chordAm9, chordAm9, chordCmaj9, chordCmaj9, chordG6, chordG6,
        chordFmaj9, chordFmaj9, chordCmaj9, chordCmaj9, chordAm9, chordAm9, chordG6, chordG6,
        chordDm11, chordDm11, chordFmaj9, chordFmaj9, chordCmaj9, chordCmaj9, chordG6, chordCmaj9,
    ]
    private static let stillGlints: [Int] = [72, 74, 76, 79, 81, 84]

    // MARK: - Timing

    public static func tempoBPM(for mode: FocusSoundscape) -> Double {
        switch mode {
        case .focus: return 72.0
        case .pulse: return 104.0
        case .rain:  return 60.0
        case .drift: return 54.0
        case .still: return 58.0
        }
    }

    public static func secondsPerBeat(for mode: FocusSoundscape) -> Double {
        60.0 / tempoBPM(for: mode)
    }

    public static func secondsPerBar(for mode: FocusSoundscape) -> Double {
        4.0 * secondsPerBeat(for: mode)
    }

    // Gentle circadian transposition (keeps Soft Light in pure A major during daytime,
    // shifts gently +2 semitones in bright Morning for Pulse/Drift, -2 semitones at Night for warm calm).
    private static func circadianShift(mode: FocusSoundscape, phase: CircadianPhase) -> Int {
        switch (mode, phase) {
        case (.focus, .night): return -2 // G major warmth at night
        case (.focus, _):      return 0  // Exact A major Soft Light
        case (.pulse, .morning): return 2
        case (.pulse, .night):   return -2
        case (.drift, .night):   return -2
        case (.still, .night):   return -2
        default:               return 0
        }
    }

    private static func stringNotes(for chord: ChordDef, inMiddle: Bool) -> (Int, Int) {
        let top = chord.held.last ?? (chord.root + 24)
        let below = chord.held.count >= 2 ? chord.held[chord.held.count - 2] : (chord.root + 19)
        let high = (top >= 68 ? top : top + 12) + (inMiddle ? 12 : 0)
        let low = below >= 61 ? below : below + 12
        return (high, low)
    }

    // MARK: - Compose Bar

    public static func composeBar(
        mode: FocusSoundscape,
        barIndex: Int,
        circadian: CircadianPhase = .afternoon,
        intensity: SoundIntensity = .flow,
        rng: inout SeededRNG
    ) -> ComposedBar {
        let bar = ((barIndex % barsPerForm) + barsPerForm) % barsPerForm
        let pass = max(0, barIndex / barsPerForm)
        let section = bar / 8
        let spb = secondsPerBeat(for: mode)
        let barLen = 4.0 * spb
        let shift = circadianShift(mode: mode, phase: circadian)

        let form: [ChordDef]
        let glints: [Int]
        switch mode {
        case .focus:
            form = softLightForm
            glints = softLightGlints
        case .pulse:
            form = pulseForm
            glints = dorianGlints
        case .rain:
            form = rainForm
            glints = rainGlints
        case .drift:
            form = driftForm
            glints = driftGlints
        case .still:
            form = stillForm
            glints = stillGlints
        }

        // Brian Eno incommensurate prime-length macro cycles (5, 7, 11, 13 bars -> 5,005-bar non-repeating arc)
        let bD = Double(barIndex)
        let cyc5  = 0.5 + 0.5 * sin(2.0 * Double.pi * bD / 5.0)
        let cyc7  = 0.5 + 0.5 * sin(2.0 * Double.pi * bD / 7.0 + 0.9)
        let cyc11 = 0.5 + 0.5 * sin(2.0 * Double.pi * bD / 11.0 + 1.8)
        let cyc13 = 0.5 + 0.5 * sin(2.0 * Double.pi * bD / 13.0 + 2.7)
        let macroFilterHorizon = 0.55 + 0.45 * (0.6 * cyc5 + 0.4 * cyc13)
        let macroSpaceBloom    = 0.35 + 0.65 * cyc7
        let macroResonance     = 0.25 + 0.75 * (0.5 * cyc11 + 0.5 * cyc5)
        let maSilenceWindow    = (barIndex > 1 && cyc11 > 0.88) // Authentic Japanese Ma (間) breathing rest

        let chord = form[bar]
        let fullness = softLightFullness[bar]
        let partner = form[bar % 2 == 0 ? min(bar + 1, barsPerForm - 1) : max(bar - 1, 0)]
        let pairChanges = partner.held != chord.held

        var allowed = Set<Int>()
        allowed.insert((chord.root + shift) % 12)
        for m in chord.figure { allowed.insert(((m + shift) % 12 + 12) % 12) }
        for m in chord.held { allowed.insert(((m + shift) % 12 + 12) % 12) }
        for g in glints { allowed.insert(((g + shift) % 12 + 12) % 12) }

        var bells: [ScoredBellEvent] = []
        var sustained: [ScoredSustainEvent] = []
        var figure = chord.figure
        var didSwap = false

        // Odd-bar gentle inversion (from Soft Light)
        if bar % 2 == 1 && figure.count >= 6 {
            let second = figure[1] + 12
            let third = figure[3]
            figure[3] = figure[5]
            figure[5] = second <= 76 ? second : third
        }

        // Pass 2+: harmony-preserving intra-bar figure swap (30% chance)
        if pass > 0 && rng.nextUnit() < 0.30 && figure.count >= 8 {
            let first = 1 + rng.nextInt(7)
            let other = 1 + rng.nextInt(7)
            if first != other {
                figure.swapAt(first, other)
                didSwap = true
            }
        }

        // Mode-specific rhythmic & textural orchestration (modulated live by SoundIntensity)
        let extraSparse = (intensity == .still)
        let extraDeep   = (intensity == .deep)
        switch mode {
        case .focus:
            for (step, rawMidi) in figure.enumerated() {
                if (section == 0 || section == 3) && (step == 2 || step == 5) { continue }
                if extraSparse && (step == 1 || step == 4 || step == 7) { continue }
                let accent = (step == 0 || step == 3 || step == 6) ? 1.0 : 0.68
                let velocity = accent * rng.between(0.86, 1.0)
                let at = max(0.0, Double(step) * 0.5 * spb + rng.between(-0.004, 0.008))
                let midi = rawMidi + shift
                bells.append(ScoredBellEvent(
                    kind: .figure,
                    at: at,
                    midi: midi,
                    duration: 0.60,
                    velocity: velocity,
                    level: 0.145 * velocity * fullness,
                    pan: -0.38 + 0.11 * Double(step % 4)
                ))
                if section == 2 && step % 2 == 0 {
                    bells.append(ScoredBellEvent(
                        kind: .figure,
                        at: at + 0.012,
                        midi: midi + 12,
                        duration: 0.40,
                        velocity: 0.55,
                        level: 0.038,
                        pan: 0.50
                    ))
                }
                if section == 3 && bar < 30 && (step == 1 || step == 5) {
                    bells.append(ScoredBellEvent(
                        kind: .figure,
                        at: at + 0.25 * spb,
                        midi: midi - 12,
                        duration: 0.50,
                        velocity: 0.50,
                        level: 0.034,
                        pan: 0.30
                    ))
                }
            }

            // Sparse lyrical melody (20% dropout and 12% octave lift on Pass 2+)
            if pass == 0 || rng.nextUnit() >= 0.20 {
                for (beat, written, beats) in softLightMelody[bar] {
                    let lifted = (pass > 0 && written < 80 && rng.nextUnit() < 0.12) ? written + 12 : written
                    let midi = lifted + shift
                    allowed.insert(((midi % 12) + 12) % 12)
                    let velocity = rng.between(0.88, 1.0)
                    bells.append(ScoredBellEvent(
                        kind: .melody,
                        at: beat * spb + rng.between(0.0, 0.012),
                        midi: midi,
                        duration: beats * spb,
                        velocity: velocity,
                        level: 0.185 * velocity,
                        pan: 0.16
                    ))
                }
            }

            // Water-glint pentatonic sparkle (50% of bars)
            if rng.nextUnit() < 0.50 {
                let midi = glints[rng.nextInt(glints.count)] + shift
                bells.append(ScoredBellEvent(
                    kind: .glint,
                    at: rng.between(0.0, barLen),
                    midi: midi,
                    duration: 0.22,
                    velocity: 0.30,
                    level: rng.between(0.014, 0.026),
                    pan: rng.between(-0.70, 0.70)
                ))
            }

        case .pulse:
            // Donato Dozzy / Floating Points hypnotic arpeggio + polyrhythmic 3:4 Buchla vactrol counter-plucks
            for (step, rawMidi) in figure.enumerated() {
                if section == 0 && step == 7 { continue }
                let accent = (step == 0 || step == 3 || step == 6) ? 1.0 : 0.62
                let velocity = accent * rng.between(0.84, 1.0)
                // Subtle micro-swing (+10ms on odd 8ths) gives warm analog groove
                let swingOffset = (step % 2 == 1) ? 0.010 : 0.0
                let at = max(0.0, Double(step) * 0.5 * spb + swingOffset + rng.between(-0.002, 0.004))
                let midi = rawMidi + shift
                bells.append(ScoredBellEvent(
                    kind: .figure,
                    at: at,
                    midi: midi,
                    duration: 0.42,
                    velocity: velocity,
                    level: 0.145 * velocity * fullness,
                    pan: -0.36 + 0.12 * Double(step % 4)
                ))
            }
            // Polyrhythmic 3-against-4 Buchla LPG counter-plucks (displaced across the 4-beat bar)
            let polyOffsets: [Double] = [0.0, 1.3333, 2.6667]
            for (idx, beatPos) in polyOffsets.enumerated() {
                if section == 0 && idx == 2 { continue }
                if pass > 0 && rng.nextUnit() < 0.25 { continue }
                let rawMidi = figure[(idx * 2 + (bar % 3)) % figure.count]
                let midi = rawMidi + 12 + shift
                bells.append(ScoredBellEvent(
                    kind: .melody,
                    at: beatPos * spb + 0.006,
                    midi: midi,
                    duration: 0.34,
                    velocity: rng.between(0.55, 0.85),
                    level: 0.068 * fullness * (0.75 + 0.25 * cyc13),
                    pan: idx == 1 ? -0.48 : 0.48
                ))
            }
            if rng.nextUnit() < 0.35 {
                let midi = glints[rng.nextInt(glints.count)] + shift
                bells.append(ScoredBellEvent(
                    kind: .glint,
                    at: rng.between(0.0, barLen),
                    midi: midi,
                    duration: 0.20,
                    velocity: 0.26,
                    level: rng.between(0.012, 0.022),
                    pan: rng.between(-0.65, 0.65)
                ))
            }

        case .rain:
            // Hiroshi Yoshimura 'Green': sparse resonant crystal singing bowls floating inside 3-layer rainfall
            if !maSilenceWindow && (bar % 2 == 0 || rng.nextUnit() < 0.42) {
                let idx = rng.nextInt(min(5, figure.count))
                let midi = figure[idx] + shift
                bells.append(ScoredBellEvent(
                    kind: .melody,
                    at: rng.between(0.15, barLen * 0.62),
                    midi: midi,
                    duration: 1.85,
                    velocity: rng.between(0.58, 0.82),
                    level: 0.095 * fullness,
                    pan: rng.between(-0.48, 0.48)
                ))
            }
            if rng.nextUnit() < 0.55 {
                let midi = glints[rng.nextInt(glints.count)] + shift
                bells.append(ScoredBellEvent(
                    kind: .glint,
                    at: rng.between(0.0, barLen),
                    midi: midi,
                    duration: 0.34,
                    velocity: 0.28,
                    level: rng.between(0.015, 0.026),
                    pan: rng.between(-0.75, 0.75)
                ))
            }

        case .drift:
            // Gymnopédie / Sakamoto '12' felt piano: authentic Japanese Ma (間) negative space + luminous phrases
            if !maSilenceWindow {
                let stepsToPlay = (section == 0 || section == 3) ? [0, 4] : [0, 3, 6]
                for step in stepsToPlay where step < figure.count {
                    if pass > 0 && rng.nextUnit() < 0.24 { continue }
                    let velocity = rng.between(0.62, 0.88)
                    let at = Double(step) * 0.5 * spb + rng.between(-0.010, 0.022)
                    let octaveLift = (pass > 0 && step > 0 && rng.nextUnit() < 0.16) ? 12 : 0
                    let midi = figure[step] + shift + octaveLift
                    bells.append(ScoredBellEvent(
                        kind: .melody,
                        at: max(0, at),
                        midi: midi,
                        duration: 1.95,
                        velocity: velocity,
                        level: 0.140 * velocity * fullness,
                        pan: step == 0 ? -0.24 : 0.28
                    ))
                }
            }
            if rng.nextUnit() < 0.42 {
                let midi = glints[rng.nextInt(glints.count)] + shift
                bells.append(ScoredBellEvent(
                    kind: .glint,
                    at: rng.between(0.0, barLen),
                    midi: midi,
                    duration: 0.35,
                    velocity: 0.26,
                    level: rng.between(0.010, 0.019),
                    pan: rng.between(-0.72, 0.72)
                ))
            }

        case .still:
            // Zero-ego Study / Deep Reading: strictly non-resolving suspended pentatonic clouds,
            // zero melody hook, ultra-gentle harmonic presence so prefrontal cortex stays 100% on text/code
            if !maSilenceWindow && (bar % 2 == 0 || extraDeep) {
                let noteCount = extraSparse ? 1 : (extraDeep ? 2 : 1)
                for n in 0..<noteCount {
                    let idx = rng.nextInt(min(4, figure.count))
                    let midi = figure[idx] + shift
                    let at = (n == 0 ? rng.between(0.15, 0.85) : rng.between(barLen * 0.48, barLen * 0.75))
                    bells.append(ScoredBellEvent(
                        kind: .melody,
                        at: at,
                        midi: midi,
                        duration: 2.2,
                        velocity: rng.between(0.42, 0.65),
                        level: 0.088 * fullness,
                        pan: n == 0 ? -0.26 : 0.26
                    ))
                }
            }
            if rng.nextUnit() < (extraSparse ? 0.25 : 0.45) {
                let midi = glints[rng.nextInt(glints.count)] + shift
                bells.append(ScoredBellEvent(
                    kind: .glint,
                    at: rng.between(0.2, barLen * 0.85),
                    midi: midi,
                    duration: 0.45,
                    velocity: 0.22,
                    level: rng.between(0.010, 0.018),
                    pan: rng.between(-0.62, 0.62)
                ))
            }
        }

        // Sustained layers: warm bass, wide stereo pad, and 3-player wooden-body strings
        if bar % 2 == 0 {
            let bassScale: Double = (mode == .rain) ? 0.55 : (mode == .pulse ? 1.15 : 1.0)
            sustained.append(ScoredSustainEvent(
                kind: .bass,
                at: 0.0,
                midi: chord.root + shift,
                duration: 5.0 * spb,
                level: 0.105 * fullness * bassScale,
                pan: 0.0
            ))
        }

        let padScale: Double = (mode == .rain) ? 0.85 : (mode == .drift ? 1.15 : 1.0)
        for rawMidi in chord.held {
            sustained.append(ScoredSustainEvent(
                kind: .pad,
                at: 0.0,
                midi: rawMidi + shift,
                duration: barLen + 1.5,
                level: 0.016 * fullness * padScale,
                pan: 0.0
            ))
        }

        let inMiddle = (section == 1 || section == 2)
        if bar % 2 == 0 || pairChanges {
            let pairStart = bar - (bar % 2)
            let swell = 0.5 * (softLightStringSwell[pairStart] + softLightStringSwell[min(pairStart + 1, barsPerForm - 1)])
            let (high, low) = stringNotes(for: chord, inMiddle: inMiddle)
            let strDur = Double(pairChanges ? 1 : 2) * barLen
            let strScale: Double = (mode == .rain) ? 0.55 : (mode == .drift ? 1.25 : 1.0)
            sustained.append(ScoredSustainEvent(
                kind: .strings,
                at: 0.0,
                midi: high + shift,
                duration: strDur,
                level: 0.056 * swell * 0.72 * strScale,
                pan: 0.35
            ))
            if inMiddle {
                sustained.append(ScoredSustainEvent(
                    kind: .strings,
                    at: 0.0,
                    midi: low + shift,
                    duration: strDur,
                    level: 0.044 * swell * 0.72 * 0.42 * strScale,
                    pan: -0.35
                ))
            }
        }

        return ComposedBar(
            barIndex: barIndex,
            barInForm: bar,
            pass: pass,
            chordName: chord.name,
            rootMidi: chord.root + shift,
            secondsPerBeat: spb,
            secondsPerBar: barLen,
            bells: bells,
            sustained: sustained,
            didSwapFigure: didSwap,
            allowedPitchClasses: allowed,
            macroFilterHorizon: macroFilterHorizon,
            macroSpaceBloom: macroSpaceBloom,
            macroResonance: macroResonance
        )
    }

    /// Sleep-safe wake guard (exact `stillDue` design from Soft Light):
    /// skips ended bars, drops late bells, and trims active held notes so waking from sleep
    /// never dumps missed chords simultaneously or clicks.
    public static func stillDue(_ bar: ComposedBar, barStart: Double, now: Double) -> ComposedBar {
        if barStart + bar.secondsPerBar <= now {
            return ComposedBar(
                barIndex: bar.barIndex,
                barInForm: bar.barInForm,
                pass: bar.pass,
                chordName: bar.chordName,
                rootMidi: bar.rootMidi,
                secondsPerBeat: bar.secondsPerBeat,
                secondsPerBar: bar.secondsPerBar,
                bells: [],
                sustained: [],
                didSwapFigure: bar.didSwapFigure,
                allowedPitchClasses: bar.allowedPitchClasses,
                macroFilterHorizon: bar.macroFilterHorizon,
                macroSpaceBloom: bar.macroSpaceBloom,
                macroResonance: bar.macroResonance
            )
        }
        let late = max(0.0, now - barStart)
        let keptBells = bar.bells.filter { $0.at >= late }
        let keptSustained: [ScoredSustainEvent] = bar.sustained.compactMap { note in
            if note.at >= late { return note }
            let remaining = note.duration - (late - note.at)
            guard remaining >= shortestLateNoteSeconds else { return nil }
            return ScoredSustainEvent(
                kind: note.kind,
                at: late,
                midi: note.midi,
                duration: remaining,
                level: note.level,
                pan: note.pan
            )
        }
        return ComposedBar(
            barIndex: bar.barIndex,
            barInForm: bar.barInForm,
            pass: bar.pass,
            chordName: bar.chordName,
            rootMidi: bar.rootMidi,
            secondsPerBeat: bar.secondsPerBeat,
            secondsPerBar: bar.secondsPerBar,
            bells: keptBells,
            sustained: keptSustained,
            didSwapFigure: bar.didSwapFigure,
            allowedPitchClasses: bar.allowedPitchClasses,
            macroFilterHorizon: bar.macroFilterHorizon,
            macroSpaceBloom: bar.macroSpaceBloom,
            macroResonance: bar.macroResonance
        )
    }
}
