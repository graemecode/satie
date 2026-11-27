import Foundation

/// Furniture Music: new music composed endlessly in Erik Satie's language.
///
/// Nothing here is one of his pieces. The rules and weights were measured from his scores
/// (Gymnopédies 1–3 and the 3 Sarabandes; see Lab/tools/analyze_satie.py):
/// - one chord per bar, roots usually a fourth or fifth apart: the Gymnopédie sway;
/// - close voicings an octave and more above the bass (G2 under B3 D4 F♯4);
/// - a continuous floor: bass on beat 1 and a held chord on beat 2, or the Sarabande rhythm;
/// - melodies of mostly steps with leaps of a fourth or fifth, in quarters, halves and whole bars,
///   chord tones on about 60% of strong beats, phrases of four bars that tend to fall at the end.
/// For focus: no climaxes, steady dynamics, the melody rests every few phrases while the floor
/// continues, and any six-note run that matches a phrase of his real pieces is rejected and rewritten.
enum SatieLanguage {
    // MARK: Measured weights

    /// Root motion between consecutive chords, as diatonic degree steps, with weights from the corpus
    /// (up a fourth and up a fifth dominate, then steps, then thirds).
    static let degreeMotion: [(Int, Double)] = [(3, 0.27), (4, 0.25), (1, 0.13), (-1, 0.13), (2, 0.08), (-2, 0.08), (5, 0.03), (0, 0.03)]
    /// Melodic steps in scale degrees (repeat, step, third, fourth, fifth), from the interval histogram.
    static let melodyMotion: [(Int, Double)] = [(0, 0.10), (1, 0.21), (-1, 0.26), (2, 0.07), (-2, 0.08), (3, 0.08), (-3, 0.09), (4, 0.05), (-4, 0.06)]
    /// Bar rhythms of the melody as (beat, length in beats), with weights.
    static let melodyRhythms: [([(Double, Double)], Double)] = [
        ([(0, 3)], 0.30),
        ([(0, 1), (1, 1), (2, 1)], 0.27),
        ([(1, 1), (2, 1)], 0.10),
        ([(0, 2), (2, 1)], 0.10),
        ([(0, 1), (1, 2)], 0.08),
        ([(0, 1.5), (1.5, 0.5), (2, 1)], 0.05),
        ([(2, 1)], 0.05),
        ([(0, 2)], 0.05),
    ]

    // Modes: major with a Lydian lean (Gymnopédie No. 1), Dorian and Aeolian (No. 3, the Sarabandes)
    static let modes: [[Int]] = [
        [0, 2, 4, 6, 7, 9, 11],   // Lydian
        [0, 2, 4, 5, 7, 9, 11],   // Ionian
        [0, 2, 3, 5, 7, 9, 10],   // Dorian
        [0, 2, 3, 5, 7, 8, 10],   // Aeolian
    ]

    // MARK: Anti-quotation

    /// Six-note melodic interval runs from Satie's real pieces; generated phrases must not contain them.
    static let quotedRuns: Set<[Int]> = {
        var runs = Set<[Int]>()
        for piece in SatieRepertoire.pieces where piece.composer == "Satie" {
            var line: [Int] = []
            for bar in piece.bars {
                for n in bar.filter({ $0.role == 1 }).sorted(by: { $0.at < $1.at }) where n.dur >= 0.25 { line.append(n.midi) }
            }
            guard line.count > 6 else { continue }
            for i in 0...(line.count - 6) {
                runs.insert((1..<6).map { line[i + $0] - line[i + $0 - 1] })
            }
        }
        return runs
    }()

    static func containsQuote(_ midis: [Int]) -> Bool {
        guard midis.count >= 6 else { return false }
        for i in 0...(midis.count - 6) where quotedRuns.contains((1..<6).map { midis[i + $0] - midis[i + $0 - 1] }) {
            return true
        }
        return false
    }

    // MARK: Helpers

    static func pick<T>(_ options: [(T, Double)], _ rng: inout SeededRNG) -> T {
        let total = options.reduce(0) { $0 + $1.1 }
        var u = rng.nextUnit() * total
        for (v, w) in options { u -= w; if u <= 0 { return v } }
        return options[options.count - 1].0
    }

    /// Pitch classes of the 7th chord on a scale degree, stacked in thirds within the mode.
    static func chordPCs(degree: Int, tonic: Int, mode: [Int], ninth: Bool) -> [Int] {
        var pcs: [Int] = []
        for k in ninth ? [0, 2, 4, 6, 8] : [0, 2, 4, 6] {
            let d = (degree + k) % 7
            pcs.append((tonic + mode[d]) % 12)
        }
        return pcs
    }

    static func isHalfDiminished(degree: Int, tonic: Int, mode: [Int]) -> Bool {
        let p = chordPCs(degree: degree, tonic: tonic, mode: mode, ninth: false)
        return (p[2] - p[0] + 12) % 12 == 6
    }

    /// Nearest MIDI note with pitch class `pc` to `target`.
    static func nearest(_ pc: Int, to target: Int) -> Int {
        var best = target
        var dist = 99
        for o in -2...2 {
            let m = (target / 12 + o) * 12 + pc
            if abs(m - target) < dist { dist = abs(m - target); best = m }
        }
        return best
    }

    // MARK: Composer

    static func composeBar(barIndex: Int, intensity: SoundIntensity, rng: inout SeededRNG, state s: inout FurnitureState) -> ComposedBar {
        if barIndex == 0 || !s.started { s = FurnitureState(); s.started = true }

        // New period every 8 bars: a sway between two chords, or a short turn through several
        if s.barInPeriod == 0 {
            s.periodCount += 1
            // Every ~6 minutes (16 periods of 8 bars at 66 BPM), move the tonal center by a fourth or fifth
            if s.periodCount % 16 == 0 {
                // a fourth or fifth mostly, now and then a whole step
                s.tonic = (s.tonic + pick([(5, 0.4), (7, 0.4), (2, 0.1), (10, 0.1)], &rng)) % 12
                if rng.nextUnit() < 0.35 { s.modeIndex = rng.nextInt(modes.count) }
            }
            s.sway = s.periodCount <= 2 || rng.nextUnit() < 0.6
            s.sarabandeTexture = s.periodCount > 3 && rng.nextUnit() < 0.22
            let mode = modes[s.modeIndex]
            var a = s.degree
            if !s.sway || rng.nextUnit() < 0.5 { a = (a + pick(degreeMotion, &rng) + 7) % 7 }
            var b = (a + (rng.nextUnit() < 0.5 ? 3 : 4)) % 7  // the sway partner, a fourth or fifth away
            if isHalfDiminished(degree: a, tonic: s.tonic, mode: mode) { a = (a + 1) % 7 }
            if isHalfDiminished(degree: b, tonic: s.tonic, mode: mode) { b = (b + 1) % 7 }
            s.swayPair = (a, b)
        }

        let mode = modes[s.modeIndex]
        // Choose this bar's chord
        if s.sway {
            s.degree = s.barInPeriod % 2 == 0 ? s.swayPair.0 : s.swayPair.1
        } else if s.barInPeriod > 0 {
            var next = (s.degree + pick(degreeMotion, &rng) + 7) % 7
            if isHalfDiminished(degree: next, tonic: s.tonic, mode: mode) { next = (next + 3) % 7 }
            s.degree = s.barInPeriod >= 6 ? s.swayPair.0 : next // turns settle back home by the period's end
        } else {
            s.degree = s.swayPair.0
        }
        let ninth = s.sarabandeTexture || rng.nextUnit() < 0.18
        let pcs = chordPCs(degree: s.degree, tonic: s.tonic, mode: mode, ninth: ninth)
        let rootPC = pcs[0]

        // Bass: root near G2, moving as little as possible
        var bass = nearest(rootPC, to: s.lastBass)
        while bass < 33 { bass += 12 }  // keep the bass between A1 and D3 by whole octaves
        while bass > 50 { bass -= 12 }
        s.lastBass = bass

        // Upper voicing: three or four chord tones (no root doubling at the bottom) in A3–G4, smooth from last bar
        let colors = Array(pcs.dropFirst())
        var voicing: [Int] = []
        let center = s.lastVoicing.isEmpty ? 62 : s.lastVoicing.reduce(0, +) / s.lastVoicing.count
        for pc in colors.prefix(s.sarabandeTexture ? 4 : 3) {
            var m = nearest(pc, to: center)
            while m < 55 { m += 12 }
            while m > 70 { m -= 12 }
            voicing.append(m)
        }
        voicing = Array(Set(voicing)).sorted()
        s.lastVoicing = voicing

        let spb = 60.0 / 66.0
        let posInPhrase = s.barInPeriod % 4
        let broaden = posInPhrase == 3 ? 1.04 : 1.0
        let barLen = 3 * spb * broaden
        var bells: [ScoredBellEvent] = []
        var sustained: [ScoredSustainEvent] = []

        // The floor (never stops)
        bells.append(ScoredBellEvent(kind: .bass, at: 0, midi: bass, duration: barLen + 0.3,
                                     velocity: rng.between(0.5, 0.58), level: 0.24, pan: 0))
        let chordHits: [(Double, Double)] = s.sarabandeTexture ? [(0, 1), (1, 2)] : [(1, 2)]
        for (beat, len) in chordHits {
            for (k, m) in voicing.enumerated() {
                bells.append(ScoredBellEvent(kind: .figure, at: beat * spb * broaden + Double(k) * 0.003, midi: m,
                                             duration: (len * spb + 0.2) * broaden,
                                             velocity: rng.between(0.34, 0.42) * (beat == 0 ? 0.9 : 1.0), level: 0.11,
                                             pan: m < 60 ? -0.12 : 0.1))
            }
        }
        sustained.append(ScoredSustainEvent(kind: .bass, at: 0, midi: bass, duration: barLen + 0.6, level: 0.05, pan: 0))
        for m in voicing where m >= 55 {
            sustained.append(ScoredSustainEvent(kind: .pad, at: 0, midi: m, duration: barLen + 1.2, level: 0.0075, pan: 0))
        }

        // Melody: composed a phrase (4 bars) at a time; every third or fourth phrase rests
        if posInPhrase == 0 {
            s.phraseCount += 1
            let rest = barIndex < 4 || s.phraseCount % (intensity == .still ? 2 : 4) == 0 || (s.phraseCount > 2 && rng.nextUnit() < 0.12)
            s.phrase = rest ? [] : composePhrase(&s, mode: mode, rng: &rng)
        }
        for n in s.phrase where n.bar == posInPhrase {
            bells.append(ScoredBellEvent(kind: .melody, at: n.at * spb * broaden + rng.between(0.004, 0.016), midi: n.midi,
                                         duration: max(0.5, n.dur * spb * broaden),
                                         velocity: (0.6 + 0.08 * sin(Double(posInPhrase) / 4 * .pi)) * rng.between(0.94, 1.0),
                                         level: 0.17, pan: 0.14))
        }

        var allowed = Set(pcs)
        for n in s.phrase { allowed.insert(n.midi % 12) }
        let composed = ComposedBar(
            barIndex: barIndex, barInForm: barIndex % SatieScore.barsPerForm, pass: barIndex / SatieScore.barsPerForm,
            chordName: "", rootMidi: bass, secondsPerBeat: spb, secondsPerBar: barLen,
            bells: bells, sustained: sustained, didSwapFigure: false, didOracleJump: false, corpusIndex: s.degree,
            allowedPitchClasses: allowed, macroFilterHorizon: 0.8, macroSpaceBloom: 0.5 + 0.3 * sin(Double(barIndex) / 11.0),
            macroResonance: 0.45
        )
        s.barInPeriod = (s.barInPeriod + 1) % 8
        return composed
    }

    /// One four-bar phrase, planned against the chords the period will play.
    private static func composePhrase(_ s: inout FurnitureState, mode: [Int], rng: inout SeededRNG) -> [FurnitureNote] {
        // The chords for the next four bars: the sway is predictable; for turns, use this bar's chord as the guide
        let degrees: [Int] = (0..<4).map { k in s.sway ? ((s.barInPeriod + k) % 2 == 0 ? s.swayPair.0 : s.swayPair.1) : s.degree }
        let scale = mode.map { (s.tonic + $0) % 12 }
        func scaleIndex(of midi: Int) -> Int { scale.firstIndex(of: ((midi % 12) + 12) % 12) ?? 0 }
        func step(_ midi: Int, by d: Int) -> Int {
            var idx = scaleIndex(of: midi)
            var m = midi
            let dir = d >= 0 ? 1 : -1
            for _ in 0..<abs(d) {
                let next = (idx + dir + 7) % 7
                var delta = (scale[next] - scale[idx] + 12) % 12
                if dir < 0 { delta = delta - 12 }
                m += delta
                idx = next
            }
            return m
        }

        for _ in 0..<6 {
            var notes: [FurnitureNote] = []
            // Start on a chord tone of the first chord near the tessitura (E5)
            let first = chordPCs(degree: degrees[0], tonic: s.tonic, mode: mode, ninth: false)
            var pitch = nearest(first[1 + rng.nextInt(3)], to: s.lastMelody ?? 76)
            pitch = max(69, min(81, pitch))
            var lastLeap = 0
            for bar in 0..<4 {
                let rhythm = bar == 3 ? (rng.nextUnit() < 0.7 ? [(0.0, 3.0)] : [(0.0, 2.0)]) : pick(melodyRhythms, &rng)
                for (beat, len) in rhythm {
                    if !notes.isEmpty {
                        var d = pick(melodyMotion, &rng)
                        if abs(lastLeap) >= 3 { d = lastLeap > 0 ? -1 : 1 }    // after a leap, step back
                        if bar >= 2 && d > 0 && rng.nextUnit() < 0.45 { d = -d } // phrases tend to fall
                        // At the edges of the range, turn around rather than jump an octave
                        if pitch <= 69 && d < 0 { d = -d }
                        if pitch >= 81 && d > 0 { d = -d }
                        pitch = step(pitch, by: d)
                        lastLeap = d
                    }
                    // Strong beats lean to chord tones (about 60% in his melodies)
                    if beat == 0 && rng.nextUnit() < 0.6 {
                        let tones = chordPCs(degree: degrees[bar], tonic: s.tonic, mode: mode, ninth: false)
                        let candidate = tones.map { nearest($0, to: pitch) }.min { abs($0 - pitch) < abs($1 - pitch) } ?? pitch
                        if abs(candidate - pitch) <= 4 { pitch = candidate }
                    }
                    if pitch < 64 { pitch += 12 }
                    if pitch > 86 { pitch -= 12 }
                    notes.append(FurnitureNote(bar: bar, at: beat, dur: len, midi: pitch))
                }
            }
            // Check across the join with the previous phrase too
            if !containsQuote(s.recentMelody + notes.map(\.midi)) {
                s.recentMelody = Array((s.recentMelody + notes.map(\.midi)).suffix(5))
                s.lastMelody = notes.last?.midi
                return notes
            }
        }
        return [] // could not avoid a quote: let the floor carry this phrase
    }
}

struct FurnitureNote: Sendable {
    let bar: Int
    let at: Double
    let dur: Double
    let midi: Int
}

/// Where the Furniture Music composer is: key, mode, period plan, voicing and the current phrase.
public struct FurnitureState: Sendable {
    var started = false
    var tonic = 2            // D: Gymnopédie No. 1's center
    var modeIndex = 0        // Lydian
    var degree = 0
    var swayPair = (3, 0)    // IV and I, the opening sway
    var sway = true
    var sarabandeTexture = false
    var barInPeriod = 0
    var periodCount = 0
    var phraseCount = 0
    var lastBass = 43
    var lastVoicing: [Int] = []
    var lastMelody: Int? = nil
    var recentMelody: [Int] = []
    var phrase: [FurnitureNote] = []
    public init() {}
}
