import Foundation

/// Worlds made from public-domain compositions of the impressionist era (Satie, Debussy, Fauré,
/// Scriabin), played endlessly on Satie's synthesized instruments.
///
/// The notes are the composer's: accompaniment, bass and melody bar by bar, in order. To make a piece last
/// for hours without looping or stopping, the composer follows three rules taken from the music itself:
/// - The floor never stops. Rests happen only in the melody; the accompaniment always continues.
/// - At a phrase boundary it may jump to another phrase of the same piece whose accompaniment is
///   identical to what would come next, so the harmony carries straight on while the melody changes.
/// - Final cadences are skipped; at the end of a piece it moves to the start of the next one,
///   like playing the whole suite, and the opening bars (accompaniment only) make the handover.
public enum SatieRepertoire {
    struct RawPiece {
        let title: String
        let composer: String
        let collection: Int
        let bpm: Int
        let breathing: Bool
        let barTicks: [Int]
        let notes: String  // base64, little-endian Int16 quintuples
    }

    struct Note {
        let at: Double   // beats from the bar start
        let dur: Double  // beats
        let midi: Int
        let role: Int    // 0 accompaniment, 1 melody, 2 bass
    }

    struct Piece {
        let title: String
        let composer: String
        let collection: Int
        let barBeats: [Double]
        let breathing: Bool
        let bpm: Double
        let bars: [[Note]]
        let signature: [Int]   // accompaniment and bass harmony of each bar
        let phraseLength: Int
    }

    static let pieces: [Piece] = rawPieces.map { raw in
        let data = Data(base64Encoded: raw.notes) ?? Data()
        var v = [Int](repeating: 0, count: data.count / 2)
        data.withUnsafeBytes { buf in
            for k in 0..<v.count { v[k] = Int(Int16(littleEndian: buf.loadUnaligned(fromByteOffset: k * 2, as: Int16.self))) }
        }
        let barCount = raw.barTicks.count
        var bars = [[Note]](repeating: [], count: barCount)
        var i = 0
        while i + 4 < v.count {
            let bar = v[i]
            if bar < barCount {
                bars[bar].append(Note(at: Double(v[i + 1]) / 96, dur: Double(v[i + 2]) / 96, midi: v[i + 3], role: v[i + 4]))
            }
            i += 5
        }
        let signature = bars.map { notes -> Int in
            var mask = 0
            var bass = 127
            for n in notes where n.role != 1 {
                mask |= 1 << (n.midi % 12)
                bass = min(bass, n.midi)
            }
            return mask | ((bass % 12) << 12)
        }
        return Piece(title: raw.title, composer: raw.composer, collection: raw.collection,
                     barBeats: raw.barTicks.map { Double($0) / 96 }, breathing: raw.breathing, bpm: Double(raw.bpm),
                     bars: bars, signature: signature, phraseLength: 4)
    }

    /// 0 Gymnopédies, 1 Gnossiennes, 5 Sarabandes (Satie), 2 Debussy, 3 Fauré, 4 Scriabin.
    public static func collection(for mode: FocusSoundscape) -> Int? {
        switch mode {
        case .gymnopedies: return 0
        case .gnossiennes: return 1
        case .sarabandes: return 5
        case .debussy: return 2
        case .faure: return 3
        case .scriabin: return 4
        default: return nil
        }
    }

    static func pieceIndices(in collection: Int) -> [Int] {
        pieces.indices.filter { pieces[$0].collection == collection }
    }

    /// Where each piece begins in a straight walk through the world's suite, as (title, bar).
    public static func pieceStarts(for mode: FocusSoundscape) -> [(String, Int)] {
        guard let collection = collection(for: mode) else { return [] }
        var bar = 0
        return pieceIndices(in: collection).map { i in
            defer { bar += pieces[i].bars.count }
            return (pieces[i].title, bar)
        }
    }

    public static func pieceTitle(at index: Int) -> String {
        pieces.indices.contains(index) ? pieces[index].title : ""
    }

    // MARK: - Composer

    static func composeBar(
        mode: FocusSoundscape,
        collection: Int,
        barIndex: Int,
        intensity: SoundIntensity,
        rng: inout SeededRNG,
        cursor: inout RepertoireCursor
    ) -> ComposedBar {
        let order = pieceIndices(in: collection)
        if barIndex == 0 {
            cursor = RepertoireCursor()
            cursor.piece = order[0]
        } else if cursor.piece < 0 || !order.contains(cursor.piece) {
            // Starting mid-stream (e.g. Satie Lab jumping to a piece): place by a straight walk through the suite
            cursor = statelessCursor(collection: collection, barIndex: barIndex)
        }
        let piece = pieces[cursor.piece]
        let b = min(cursor.bar, piece.bars.count - 1)
        let notes = piece.bars[b]
        let beats = piece.barBeats[b]

        // Gentle rubato: phrases broaden slightly into their last bar
        let posInPhrase = b % piece.phraseLength
        let broaden = posInPhrase == piece.phraseLength - 1 ? 1.045 : (posInPhrase == 0 ? 0.99 : 1.0)
        let spb = 60.0 / piece.bpm * broaden
        let barLen = beats * spb

        let melodyOn = !piece.breathing || (cursor.floorBarsLeft == 0 && !(intensity == .still && cursor.phraseCount % 3 == 1))
        var bells: [ScoredBellEvent] = []
        var sustained: [ScoredSustainEvent] = []
        var allowed = Set<Int>()
        var bass = 127

        for n in notes {
            allowed.insert(n.midi % 12)
            switch n.role {
            case 2:
                bass = min(bass, n.midi)
                // Pedal: in the slow, sparse pieces the bass rings for the whole bar; elsewhere a light legato
                let pedalBeats = piece.breathing ? max(n.dur, beats - n.at) : n.dur * 1.25
                bells.append(ScoredBellEvent(kind: .bass, at: n.at * spb, midi: n.midi,
                                             duration: pedalBeats * spb + 0.3,
                                             velocity: rng.between(0.5, 0.58), level: 0.24, pan: 0))
            case 0:
                bass = min(bass, n.midi)
                let pedalBeats = piece.breathing ? max(n.dur, beats - n.at) : n.dur * 1.25
                bells.append(ScoredBellEvent(kind: .figure, at: n.at * spb + rng.between(0.0, 0.006), midi: n.midi,
                                             duration: pedalBeats * spb + 0.2,
                                             velocity: rng.between(0.34, 0.42), level: 0.11, pan: n.midi < 60 ? -0.12 : 0.1))
            default:
                guard melodyOn else { continue }
                // A singing line: slightly late and shaped across the phrase
                let shape = 0.62 + 0.08 * sin(Double(posInPhrase) / Double(piece.phraseLength) * .pi)
                let isGrace = n.dur < 0.2
                bells.append(ScoredBellEvent(kind: .melody, at: n.at * spb + rng.between(0.004, 0.018), midi: n.midi,
                                             duration: max(n.dur * spb, isGrace ? 0.12 : 0.5),
                                             velocity: (isGrace ? 0.4 : shape) * rng.between(0.94, 1.0),
                                             level: isGrace ? 0.09 : 0.17, pan: 0.14))
            }
        }

        // A soft synthetic halo under the accompaniment (held through the bar)
        // (only from G3 up: a wide pad on the low left hand would smear the bass)
        let haloPitches = Set(notes.filter { $0.role == 0 && $0.midi >= 55 }.map { $0.midi })
        for midi in haloPitches.sorted() {
            sustained.append(ScoredSustainEvent(kind: .pad, at: 0, midi: midi, duration: barLen + 1.2,
                                                level: 0.0075, pan: 0))
        }

        // A quiet, steady synthetic bass under his left hand, so the floor never thins as the piano decays
        // (in the denser pieces, only under long bass notes, so moving bass lines stay clean)
        let longBass = notes.contains { $0.role == 2 && $0.dur >= 2 }
        if bass < 60 && (piece.breathing || longBass) {
            sustained.append(ScoredSustainEvent(kind: .bass, at: 0, midi: bass, duration: barLen + 0.6, level: 0.05, pan: 0))
        }

        let composed = ComposedBar(
            barIndex: barIndex,
            barInForm: barIndex % SatieScore.barsPerForm,
            pass: barIndex / SatieScore.barsPerForm,
            chordName: piece.title,
            rootMidi: bass == 127 ? 45 : bass,
            secondsPerBeat: spb,
            secondsPerBar: barLen,
            bells: bells,
            sustained: sustained,
            didSwapFigure: false,
            didOracleJump: cursor.jumpedIntoThisBar,
            corpusIndex: (cursor.piece + 1) * 1000 + b,
            allowedPitchClasses: allowed,
            macroFilterHorizon: 0.8,
            macroSpaceBloom: 0.5 + 0.3 * sin(Double(barIndex) / 11.0),
            macroResonance: 0.45
        )

        advance(&cursor, piece: piece, order: order, rng: &rng)
        return composed
    }

    private static func advance(_ cursor: inout RepertoireCursor, piece: Piece, order: [Int], rng: inout SeededRNG) {
        cursor.barsInPiece += 1
        cursor.jumpedIntoThisBar = false
        if cursor.floorBarsLeft > 0 { cursor.floorBarsLeft -= 1 }
        var next = cursor.bar + 1
        let phrase = piece.phraseLength

        if next >= piece.bars.count {
            // End of the piece (its final cadence was dropped): the next piece begins
            let i = order.firstIndex(of: cursor.piece) ?? 0
            cursor.piece = order[(i + 1) % order.count]
            cursor.bar = 0
            cursor.barsInPiece = 0
            cursor.phraseCount = 0
            return
        }

        if next % phrase == 0 {
            cursor.phraseCount += 1
            // Every so often, a phrase with no melody: the floor keeps going underneath
            if piece.breathing && cursor.floorBarsLeft == 0 && cursor.phraseCount > 2 && rng.nextUnit() < 0.2 {
                cursor.floorBarsLeft = phrase
            }
            // Jump to another nearby phrase whose accompaniment is identical to the bar that would come
            // next. Staying within ~24 bars (and out of the last 8) keeps the piece's own arc instead of
            // skipping ahead, which matters in pieces whose harmony barely changes (Gnossienne No. 1).
            if cursor.barsInPiece > 8 && rng.nextUnit() < (piece.collection == 0 ? 0.32 : 0.24) {
                let target = piece.signature[next]
                var candidates: [Int] = []
                var c = phrase
                while c < piece.bars.count - 8 {
                    if c != next && abs(c - next) <= 24 && piece.signature[c] == target { candidates.append(c) }
                    c += phrase
                }
                if !candidates.isEmpty {
                    next = candidates[rng.nextInt(candidates.count)]
                    cursor.jumpedIntoThisBar = true
                }
            }
        }
        cursor.bar = next
    }

    /// Position for callers without a navigator (tests): a straight walk through the suite.
    static func statelessCursor(collection: Int, barIndex: Int) -> RepertoireCursor {
        let order = pieceIndices(in: collection)
        let lengths = order.map { pieces[$0].bars.count }
        var remaining = barIndex % max(1, lengths.reduce(0, +))
        var cursor = RepertoireCursor()
        for (k, len) in lengths.enumerated() {
            if remaining < len { cursor.piece = order[k]; cursor.bar = remaining; break }
            remaining -= len
        }
        cursor.barsInPiece = cursor.bar
        return cursor
    }
}

/// Where a Satie repertoire world is in its walk through the pieces.
public struct RepertoireCursor: Sendable {
    public internal(set) var piece = -1
    public internal(set) var bar = 0
    var barsInPiece = 0
    var phraseCount = 0
    var floorBarsLeft = 0
    var jumpedIntoThisBar = false
    public init() {}
}
