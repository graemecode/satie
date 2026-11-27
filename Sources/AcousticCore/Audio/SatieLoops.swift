import Foundation

/// Loops: furniture music made the way Brian Eno made ambient music from Satie's idea.
///
/// A handful of short, hand-written piano phrases, each repeating on its own loop length
/// (17, 19.5, 23, 29, 31 and 37 seconds). Because the lengths never line up, the phrases drift
/// into new combinations for hours. Every note comes from one consonant set in Satie's harmony
/// (D, E, F♯, A, B, C♯: the major-seventh and ninth color of his sway), so any overlap sounds
/// right. Underneath, a soft chord floor sways between Dmaj9 and Bm11 over about a minute and a
/// half and never stops. Every few minutes one loop swaps to an alternate phrase, so even hours
/// in it keeps freshening. Beauty comes from the phrases, which are curated by ear in Satie Lab;
/// endlessness comes from the process.
enum SatieLoops {
    struct Phrase {
        /// (seconds from the loop start, MIDI note in D, ring in seconds, velocity)
        let notes: [(Double, Int, Double, Double)]
    }

    struct Loop {
        let period: Double
        let offset: Double
        let kind: ScoredBellKind   // .melody = upper piano, .figure = lower piano
        let pan: Double
        let level: Double
        let phrases: [Phrase]      // the first is the opening phrase; others rotate in over time
    }

    // MARK: The phrase bank (all in D: D E F♯ A B C♯)

    static let loops: [Loop] = [
        Loop(period: 17.0, offset: 4.0, kind: .melody, pan: -0.28, level: 0.16, phrases: [
            Phrase(notes: [(0.0, 78, 5.0, 0.56), (1.7, 76, 5.0, 0.50), (3.4, 74, 7.0, 0.52)]),            // F♯5 E5 D5
            Phrase(notes: [(0.0, 78, 5.0, 0.54), (1.4, 81, 4.0, 0.50), (2.9, 76, 7.0, 0.50)]),            // F♯5 A5 E5
            Phrase(notes: [(0.0, 73, 5.0, 0.52), (1.6, 74, 7.0, 0.54)]),                                  // C♯5 D5
        ]),
        Loop(period: 19.5, offset: 9.0, kind: .melody, pan: 0.26, level: 0.15, phrases: [
            Phrase(notes: [(0.0, 69, 5.0, 0.52), (1.3, 73, 5.0, 0.48), (2.9, 71, 7.0, 0.50)]),            // A4 C♯5 B4
            Phrase(notes: [(0.0, 71, 5.0, 0.50), (1.5, 69, 7.0, 0.50)]),                                  // B4 A4
            Phrase(notes: [(0.0, 69, 4.0, 0.50), (1.2, 71, 4.0, 0.46), (2.4, 73, 4.0, 0.46), (3.8, 76, 7.0, 0.50)]), // A4 B4 C♯5 E5
        ]),
        Loop(period: 23.0, offset: 14.0, kind: .melody, pan: 0.05, level: 0.14, phrases: [
            Phrase(notes: [(0.0, 74, 6.0, 0.50), (2.3, 81, 8.0, 0.46)]),                                  // D5 A5
            Phrase(notes: [(0.0, 76, 6.0, 0.48), (2.1, 83, 8.0, 0.44)]),                                  // E5 B5
            Phrase(notes: [(0.0, 81, 5.0, 0.46), (1.8, 78, 8.0, 0.48)]),                                  // A5 F♯5
        ]),
        Loop(period: 29.0, offset: 1.0, kind: .figure, pan: -0.12, level: 0.13, phrases: [
            Phrase(notes: [(0.0, 50, 9.0, 0.48), (0.02, 57, 9.0, 0.44)]),                                 // D3 + A3
            Phrase(notes: [(0.0, 47, 9.0, 0.48), (0.02, 54, 9.0, 0.44)]),                                 // B2 + F♯3
            Phrase(notes: [(0.0, 45, 9.0, 0.46), (0.02, 52, 9.0, 0.44)]),                                 // A2 + E3
        ]),
        Loop(period: 31.0, offset: 18.0, kind: .figure, pan: 0.12, level: 0.12, phrases: [
            Phrase(notes: [(0.0, 47, 7.0, 0.46), (1.6, 54, 8.0, 0.42)]),                                  // B2 F♯3
            Phrase(notes: [(0.0, 50, 7.0, 0.46), (1.8, 57, 8.0, 0.42)]),                                  // D3 A3
            Phrase(notes: [(0.0, 54, 7.0, 0.44), (1.4, 61, 8.0, 0.42)]),                                  // F♯3 C♯4
        ]),
        Loop(period: 37.0, offset: 26.0, kind: .melody, pan: 0.34, level: 0.10, phrases: [
            Phrase(notes: [(0.0, 85, 4.0, 0.40), (0.9, 88, 6.0, 0.38)]),                                  // C♯6 E6
            Phrase(notes: [(0.0, 86, 5.0, 0.40)]),                                                        // D6
            Phrase(notes: [(0.0, 83, 4.0, 0.40), (1.1, 85, 6.0, 0.38)]),                                  // B5 C♯6
        ]),
    ]

    /// The floor: two chords that cross over about every 45 seconds (held notes, MIDI in D).
    static let floorChords: [[Int]] = [
        [38, 57, 61, 64, 66],  // Dmaj9: D2 A3 C♯4 E4 F♯4
        [35, 54, 57, 62, 64],  // Bm11: B1 F♯3 A3 D4 E4
    ]
    static let floorPeriod = 45.0
    static let barSeconds = 4.0
    /// How often one loop swaps to its next phrase (seconds), and which loop goes next.
    static let swapEvery = 210.0

    static func phraseIndex(loop: Int, at time: Double) -> Int {
        let swaps = Int(time / swapEvery)
        // Swap loops in a fixed rotation (2, 0, 4, 1, 5, 3), so each loop changes about every 21 minutes
        let order = [2, 0, 4, 1, 5, 3]
        var count = 0
        for k in 0..<swaps where order[k % order.count] == loop { count += 1 }
        return count % loops[loop].phrases.count
    }

    static func composeBar(barIndex: Int, shift: Int, rng: inout SeededRNG) -> ComposedBar {
        let start = Double(barIndex) * barSeconds
        let end = start + barSeconds
        var bells: [ScoredBellEvent] = []
        var sustained: [ScoredSustainEvent] = []

        for (li, loop) in loops.enumerated() {
            // Loop repetitions that begin in this bar or earlier and still have notes landing in it
            let first = Int(floor((start - loop.offset - 10) / loop.period))
            let last = Int(floor((end - loop.offset) / loop.period))
            guard last >= max(0, first) else { continue }
            for rep in max(0, first)...last {
                let repStart = loop.offset + Double(rep) * loop.period
                let phrase = loop.phrases[phraseIndex(loop: li, at: repStart)]
                for (t, midi, ring, vel) in phrase.notes {
                    let at = repStart + t
                    guard at >= start && at < end else { continue }
                    bells.append(ScoredBellEvent(kind: loop.kind, at: at - start + rng.between(0.0, 0.01), midi: midi + shift,
                                                 duration: ring, velocity: vel * rng.between(0.95, 1.0), level: loop.level,
                                                 pan: loop.pan))
                }
            }
        }

        // The floor: whichever chord is current, re-struck softly every bar so it never decays away
        let floorIdx = Int(start / floorPeriod) % floorChords.count
        for (k, midi) in floorChords[floorIdx].enumerated() {
            sustained.append(ScoredSustainEvent(kind: k == 0 ? .bass : .pad, at: 0, midi: midi + shift,
                                                duration: barSeconds + 1.6, level: k == 0 ? 0.06 : 0.022, pan: 0))
        }

        var allowed = Set<Int>()
        for pc in [2, 4, 6, 9, 11, 1] { allowed.insert((pc + shift + 12) % 12) }
        return ComposedBar(
            barIndex: barIndex, barInForm: barIndex % SatieScore.barsPerForm, pass: barIndex / SatieScore.barsPerForm,
            chordName: "", rootMidi: floorChords[floorIdx][0] + shift, secondsPerBeat: 1.0, secondsPerBar: barSeconds,
            bells: bells, sustained: sustained, didSwapFigure: false, didOracleJump: false, corpusIndex: floorIdx,
            allowedPitchClasses: allowed, macroFilterHorizon: 0.8,
            macroSpaceBloom: 0.55 + 0.25 * sin(start / 97.0), macroResonance: 0.45
        )
    }
}
