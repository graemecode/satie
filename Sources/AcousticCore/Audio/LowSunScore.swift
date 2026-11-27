import Foundation

/// Low Sun: the groove world's bar composer.
///
/// Rules (from the research brief):
/// - 88 BPM, 16th swing at 58% (MPC-style), applied as swing, never random jitter.
/// - Each instrument keeps a fixed micro-offset (snare and keys sit late), plus a slow
///   pink-ish drift shared by the whole band, so the feel is consistent rather than noisy.
/// - Something changes every 8 bars (drum and comp pattern), harmony moves every 2–16 bars.
/// - Energy arc of four 32-bar passes (~5.8 min); a beatless 16-bar breakdown every 12 passes (~17 min).
/// - Hats drop out in the second half of every 8th bar to reset attention.
/// - No voice-like sounds; one sparse, hook-free electric-piano motif at most.
extension SatieScore {
    // 16th-step hat accents: strong 8ths, softer off-16ths (a generic shaker feel)
    private static let hatAccent: [Double] = [0.92, 0.55, 0.78, 0.60, 0.95, 0.52, 0.76, 0.58, 0.90, 0.50, 0.75, 0.60, 0.97, 0.55, 0.78, 0.62]

    // Kick patterns (16th steps). Picked per 8-bar section, so each holds long enough to groove.
    private static let kickPatterns: [[Int]] = [
        [0, 10],
        [0, 7, 10],
        [0, 6, 10, 15],
        [0, 3, 10],
    ]
    // Electric-piano comp rhythms: (step, length in 16ths, velocity scale)
    private static let compPatterns: [[(Int, Int, Double)]] = [
        [(0, 6, 1.0), (6, 2, 0.72), (10, 4, 0.86)],
        [(2, 4, 0.92), (10, 6, 0.88)],
        [(0, 3, 0.95), (3, 2, 0.70), (8, 2, 0.80), (11, 5, 0.86)],
        [(0, 8, 1.0), (14, 2, 0.74)],
    ]
    // Bass patterns: (step, length in 16ths, degree) where degree 0 = root, 7 = fifth, 12 = octave, 10 = flat seventh
    private static let bassPatterns: [[(Int, Int, Int)]] = [
        [(0, 5, 0), (6, 2, 0), (10, 3, 7), (14, 2, 12)],
        [(0, 3, 0), (3, 2, 12), (8, 4, 0), (13, 2, 10)],
        [(0, 7, 0), (8, 2, 7), (11, 4, 0)],
        [(0, 2, 0), (2, 3, 0), (7, 2, 7), (10, 4, 0), (14, 2, 10)],
    ]

    static func lowSunBar(
        barIndex: Int,
        bar: Int,
        pass: Int,
        section: Int,
        spb: Double,
        barLen: Double,
        chord: ChordDef,
        shift: Int,
        glints: [Int],
        intensity: SoundIntensity,
        cyc5: Double,
        cyc7: Double,
        cyc13: Double,
        rng: inout SeededRNG,
        bells: inout [ScoredBellEvent]
    ) {
        let sixteenth = spb * 0.25
        let swing = 0.16 * sixteenth // 58% swing: off-16ths land 16% of a 16th late
        func stepTime(_ step: Int) -> Double { Double(step) * sixteenth + (step % 2 == 1 ? swing : 0) }

        // Shared slow drift (about ±4 ms), so the band breathes together.
        let drift = 0.004 * sin(Double(barIndex) * 0.37 + 0.6 * sin(Double(barIndex) * 0.11))
        let snareLate = 0.012
        let keysLate = 0.009
        let bassLate = 0.005

        // Energy: 0 = beatless, 1 = light, 2 = full
        let sectionSerial = barIndex / 8
        let arcPass = pass % 4
        var energy: Int
        if barIndex < 8 {
            energy = barIndex < 4 ? 0 : 1 // intro: keys and bass first, then a light kit
        } else if pass % 12 == 11 && section >= 2 {
            energy = 0 // beatless breakdown, 16 bars every ~17 minutes
        } else if SoundCandidate.isOn && pass % 12 == 5 && section == 3 {
            energy = 0 // New: a second, shorter beatless stretch (8 bars) halfway between breakdowns
        } else if arcPass == 0 || (arcPass == 3 && section == 3) {
            energy = 1
        } else {
            energy = 2
        }
        if intensity == .still { energy = min(energy, 1) }
        let deep = intensity == .deep

        let patternSeed = (sectionSerial &* 2654435761) & 0x7fffffff
        let kick = kickPatterns[patternSeed % kickPatterns.count]
        let comp = compPatterns[(patternSeed / 7) % compPatterns.count]
        let bassPattern = bassPatterns[(patternSeed / 31) % bassPatterns.count]
        let barInSection = bar % 8
        let isResetBar = barInSection == 7
        let lastBarOfChord = bar % 2 == 1

        // Drums
        if energy > 0 {
            for step in kick {
                let v = step == 0 ? 0.92 : 0.74
                bells.append(ScoredBellEvent(kind: .drum, at: max(0, stepTime(step) + drift), midi: GrooveDrum.kick.rawValue,
                                             duration: 0.3, velocity: v * rng.between(0.92, 1.0), level: 1.0, pan: 0))
            }
            let backbeat: GrooveDrum = energy == 2 ? .snare : .rim
            for step in [4, 12] {
                bells.append(ScoredBellEvent(kind: .drum, at: stepTime(step) + snareLate + drift, midi: backbeat.rawValue,
                                             duration: 0.2, velocity: rng.between(0.78, 0.9), level: 1.0, pan: 0.08))
            }
            if energy == 2 {
                // Ghost notes before the backbeat, varied per bar
                for step in [3, 11, 15] where rng.nextUnit() < (step == 15 ? 0.25 : 0.45) {
                    bells.append(ScoredBellEvent(kind: .drum, at: stepTime(step) + snareLate + drift, midi: GrooveDrum.ghostSnare.rawValue,
                                                 duration: 0.12, velocity: rng.between(0.2, 0.32), level: 1.0, pan: 0.1))
                }
            }
            // Hats: shaker 16ths at full energy, 8ths when light; drop the back half of every 8th bar
            // New: after ~20 minutes, every other full section plays 8th-note hats instead of 16ths
            let longSessionLighten = SoundCandidate.isOn && barIndex >= 440 && sectionSerial % 2 == 1
            let hatSteps = (energy == 2 && !longSessionLighten) ? Array(0..<16) : [0, 2, 4, 6, 8, 10, 12, 14]
            for step in hatSteps {
                if isResetBar && step >= 8 { continue }
                let accent = hatAccent[step]
                let v = accent * rng.between(0.82, 1.0) * (energy == 2 ? 0.8 : 0.7)
                let kind: GrooveDrum = (step % 4 == 2 && energy == 2 && deep) ? .tightHat : .shaker
                bells.append(ScoredBellEvent(kind: .drum, at: stepTime(step) + drift, midi: kind.rawValue,
                                             duration: 0.08, velocity: v, level: 1.0, pan: step % 2 == 0 ? -0.42 : 0.44))
            }
            if energy == 2 && bar % 2 == 1 && !isResetBar {
                bells.append(ScoredBellEvent(kind: .drum, at: stepTime(14) + drift, midi: GrooveDrum.openHat.rawValue,
                                             duration: 0.2, velocity: 0.55, level: 1.0, pan: 0.36))
            }
        }

        // Bass: enters after the first four bars; long roots in the breakdown
        if barIndex >= 2 {
            var root = chord.root + shift
            while root < 33 { root += 12 }
            while root > 44 { root -= 12 }
            if energy == 0 {
                bells.append(ScoredBellEvent(kind: .bass, at: bassLate, midi: root, duration: barLen * 0.9,
                                             velocity: 0.62, level: 1.0, pan: 0))
            } else {
                for (step, len, degree) in bassPattern {
                    // On the chord's second bar, the last note leans toward the next harmony
                    var deg = degree
                    if lastBarOfChord && step >= 13 { deg = (barIndex / 2) % 2 == 0 ? 7 : 10 }
                    if energy == 1 && step % 2 == 1 { continue } // simpler line when light
                    // Stay in D Dorian: a flat seventh that leaves the mode (over F and C) becomes the fifth
                    let dorian: Set<Int> = [2, 4, 5, 7, 9, 11, 0]
                    if !dorian.contains(((root + deg - shift) % 12 + 12) % 12) { deg = 7 }
                    let midi = root + deg
                    bells.append(ScoredBellEvent(kind: .bass, at: stepTime(step) + bassLate + drift, midi: midi,
                                                 duration: Double(len) * sixteenth * 0.82,
                                                 velocity: (step == 0 ? 0.9 : 0.74) * rng.between(0.9, 1.0), level: 1.0, pan: 0))
                }
            }
        }

        // Electric piano comping: rootless voicing, inversion moves every 8 bars
        // Lift the lowest notes an octave: the comp sits around middle C, where it reads clearly
        var voicing = chord.held.map { ($0 < 58 ? $0 + 12 : $0) + shift }.sorted()
        if (sectionSerial % 3) == 1, let top = voicing.last { voicing.removeLast(); voicing.insert(top - 12, at: 0) }
        if (sectionSerial % 3) == 2, let low = voicing.first { voicing.removeFirst(); voicing.append(low + 12) }
        let compRhythm = energy == 0 ? [(0, 14, 0.8)] : comp
        for (hitIdx, hit) in compRhythm.enumerated() {
            let (step, len, vScale) = hit
            let vel = 0.62 * vScale * rng.between(0.9, 1.0) * (energy == 0 ? 0.85 : 1.0)
            for (n, midi) in voicing.enumerated() {
                // A few milliseconds of spread low to high, like a hand landing on the keys
                let at = stepTime(step) + keysLate + drift + Double(n) * 0.004
                bells.append(ScoredBellEvent(kind: .comp, at: max(0, at), midi: midi,
                                             duration: Double(len) * sixteenth * 0.9,
                                             velocity: vel * (n == voicing.count - 1 ? 1.0 : 0.9), level: 1.0,
                                             pan: -0.48 + 0.32 * Double(n) + (hitIdx % 2 == 0 ? 0 : 0.06)))
            }
        }

        // Kalimba-like harp ostinato on a 5-bar cycle (incommensurate with the 8-bar phrases)
        if energy >= 1 && (barIndex % 5) < 3 && !isResetBar {
            let tones = [chord.figure[2], chord.figure[3], chord.figure[4], chord.figure[3]].map { $0 + 12 + shift }
            for (k, step) in [0, 3, 6, 9].enumerated() {
                bells.append(ScoredBellEvent(kind: .glint, at: stepTime(step) + keysLate + drift, midi: tones[k],
                                             duration: 0.5, velocity: 0.48, level: 0.03 * (0.7 + 0.3 * cyc7),
                                             pan: k % 2 == 0 ? -0.45 : 0.45))
            }
        }

        // Sparse electric-piano motif: two or three chord tones, every other 4-bar phrase, never a hook
        if energy == 2 && (bar / 4) % 2 == 1 && bar % 4 == 1 && rng.nextUnit() < 0.7 {
            let pool = chord.figure.map { $0 + 12 + shift }.filter { $0 >= 69 && $0 <= 84 }
            if !pool.isEmpty {
                let count = 2 + rng.nextInt(2)
                var step = 2 + 2 * rng.nextInt(3)
                for _ in 0..<count where step < 16 {
                    bells.append(ScoredBellEvent(kind: .melody, at: stepTime(step) + keysLate + drift,
                                                 midi: pool[rng.nextInt(pool.count)], duration: 2.0 * sixteenth * 2,
                                                 velocity: rng.between(0.55, 0.7), level: 0.07 * (0.8 + 0.2 * cyc13),
                                                 pan: 0.22))
                    step += 3 + rng.nextInt(3)
                }
            }
        }

        // Occasional high glint
        if energy >= 1 && rng.nextUnit() < 0.22 + 0.12 * cyc5 {
            bells.append(ScoredBellEvent(kind: .glint, at: rng.between(0.0, barLen * 0.9), midi: glints[rng.nextInt(glints.count)] + shift,
                                         duration: 0.3, velocity: 0.3, level: 0.014, pan: rng.between(-0.7, 0.7)))
        }
    }
}
