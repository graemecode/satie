import Foundation

/// Functional harmonic role used by the Symbolic Constraint Grammar during Factor Oracle traversal.
public enum HarmonicRole: String, Sendable, Equatable {
    case tonic
    case subdominant
    case mediant
    case dominant
    case suspended
}

/// Linear-time O(m) Factor Oracle automaton (Allauzen, Crochemore & Raffinot 1999;
/// IRCAM OMax / Somax2 architecture) built over a curated multi-climate chord corpus.
///
/// Forward transitions preserve local musical phrasing, while suffix and reverse-suffix links
/// create harmonically coherent recombination portals so multi-hour sessions wander endlessly
/// with nostalgic callbacks and zero 32-bar loop fatigue.
public struct HarmonicFactorOracle: Sendable {
    public let symbols: [String]
    public let transitions: [[String: Int]]
    public let suffixLink: [Int]
    public let reverseSuffix: [[Int]]
    public let lrs: [Int]

    public var length: Int { symbols.count }

    public init(symbols: [String]) {
        let m = symbols.count
        self.symbols = symbols
        var trans = Array(repeating: [String: Int](), count: m + 1)
        var sLink = Array(repeating: -1, count: m + 1)
        var rev = Array(repeating: [Int](), count: m + 1)
        var lrsArr = Array(repeating: 0, count: m + 1)

        func commonSuffixLen(_ p1: Int, _ p2: Int) -> Int {
            var a = p1 - 1
            var b = p2 - 1
            var len = 0
            while a >= 0 && b >= 0 && symbols[a] == symbols[b] {
                len += 1
                a -= 1
                b -= 1
            }
            return len
        }

        for i in 0..<m {
            let sym = symbols[i]
            let nextState = i + 1
            trans[i][sym] = nextState

            var k = sLink[i]
            while k >= 0 && trans[k][sym] == nil {
                trans[k][sym] = nextState
                k = sLink[k]
            }

            let targetSuffix: Int
            if k < 0 {
                targetSuffix = 0
            } else {
                targetSuffix = trans[k][sym]!
            }
            sLink[nextState] = targetSuffix
            rev[targetSuffix].append(nextState)
            lrsArr[nextState] = targetSuffix == 0 ? 0 : commonSuffixLen(nextState, targetSuffix)
        }

        self.transitions = trans
        self.suffixLink = sLink
        self.reverseSuffix = rev
        self.lrs = lrsArr
    }

    /// Returns all corpus indices `0..<length` reachable in one step from `state` via
    /// suffix links, reverse-suffix links, and non-trivial forward factor transitions.
    public func recombinationTargets(from state: Int) -> [Int] {
        guard length > 0 else { return [] }
        let s = max(0, min(length, state))
        var out: [Int] = []
        out.reserveCapacity(12)

        func appendValid(_ idx: Int) {
            let wrapped = ((idx % length) + length) % length
            if !out.contains(wrapped) {
                out.append(wrapped)
            }
        }

        // 1. Backward nostalgic recall via suffix link (continue from s(state))
        let suf = suffixLink[s]
        if suf > 0 && suf < length {
            appendValid(suf)
            // Also include sibling states sharing the same harmonic suffix anchor
            for sib in reverseSuffix[suf] where sib != s && sib < length {
                appendValid(sib)
            }
        }

        // 2. Forward / parallel climate jump via reverse-suffix links
        for r in reverseSuffix[s] where r < length {
            appendValid(r)
        }

        // 3. Non-sequential forward factor edges from current state
        let linearNext = (s < length) ? s : 0
        for (_, dstState) in transitions[s] {
            let idx = dstState - 1
            if idx >= 0 && idx < length && idx != linearNext {
                appendValid(idx)
            }
        }

        // Deterministic ascending order so RNG selection is 100% seed-reproducible
        out.sort()
        return out
    }
}

/// Stateful Factor Oracle improviser governed by a Symbolic Constraint Grammar:
/// - Pass 0 (bars 0..<32): faithful iconic canonical form.
/// - Pass 1+ (bars >= 32): infinite grammar-constrained recombination across primary and
///   secondary harmonic climates with strict anti-stall, anti-short-loop, and phrase-cadence rules.
public struct ScoreOracleNavigator: Sendable {
    public private(set) var mode: FocusSoundscape?
    public private(set) var state: Int = 0
    public private(set) var barsSinceJump: Int = 0
    public private(set) var consecutiveSameChord: Int = 0
    public private(set) var totalJumps: Int = 0
    private var recentChords: [String] = []
    private var recentIndices: [Int] = []
    /// Position in a Satie repertoire world (Gymnopédies, Gnossiennes)
    public var repertoire = RepertoireCursor()

    public init() {}

    public mutating func reset(mode: FocusSoundscape? = nil) {
        self.mode = mode
        self.state = 0
        self.barsSinceJump = 0
        self.consecutiveSameChord = 0
        self.totalJumps = 0
        self.recentChords.removeAll(keepingCapacity: true)
        self.recentIndices.removeAll(keepingCapacity: true)
        self.repertoire = RepertoireCursor()
    }

    public mutating func nextCorpusIndex(
        mode: FocusSoundscape,
        barIndex: Int,
        oracle: HarmonicFactorOracle,
        roles: [HarmonicRole],
        rng: inout SeededRNG
    ) -> (corpusIndex: Int, didJump: Bool) {
        let m = oracle.length
        guard m > 0 else { return (0, false) }

        if self.mode != mode || barIndex == 0 {
            reset(mode: mode)
        }

        // Pass 0 plays the iconic 32-bar canonical composition verbatim while priming history
        if barIndex < SatieScore.barsPerForm {
            let idx = barIndex % m
            recordSelection(idx, symbol: oracle.symbols[idx], jumped: false, corpusLength: m)
            return (idx, false)
        }

        let linearIdx = state % m
        let prevChord = recentChords.last
        let prevRole: HarmonicRole = {
            guard let lastIdx = recentIndices.last, lastIdx < roles.count else { return .tonic }
            return roles[lastIdx]
        }()

        // Max allowed identical consecutive chord bars (slower modes allow up to 3; active modes 2)
        let maxChordHold = (mode == .rain || mode == .drift || mode == .still || mode == .dive) ? 3 : 2
        let isPhraseBoundary = (barIndex % 4 == 0)
        let isHarmonicPairBoundary = (barIndex % 2 == 0)

        // Symbolic Constraint Grammar validator
        func violatesGrammar(_ candIdx: Int) -> Bool {
            let sym = oracle.symbols[candIdx]
            // C1: Anti-stall — never hold one chord indefinitely
            if sym == prevChord && consecutiveSameChord >= maxChordHold {
                return true
            }
            // C2: Anti-short-loop — forbid reproducing an identical 4-bar chord subsequence within the last 16 bars
            if recentChords.count >= 6 {
                let n = recentChords.count
                let a = recentChords[n - 3]
                let b = recentChords[n - 2]
                let c = recentChords[n - 1]
                for i in 0..<(n - 3) {
                    if recentChords[i] == a && recentChords[i + 1] == b && recentChords[i + 2] == c && recentChords[i + 3] == sym {
                        return true
                    }
                }
            }
            // C3: Dominant tension resolution — don't stall on dominant across a 4-bar phrase boundary
            if isPhraseBoundary && prevRole == .dominant && roles[candIdx] == .dominant {
                return true
            }
            return false
        }

        func grammarScore(_ candIdx: Int) -> Double {
            var score = 1.0
            let sym = oracle.symbols[candIdx]
            let role = roles[candIdx]
            // Strongly discourage visiting the exact same corpus index within the last 8 bars
            if recentIndices.suffix(8).contains(candIdx) {
                score *= 0.18
            }
            // Phrase boundaries favor tonic, mediant, or subdominant anchors
            if isPhraseBoundary {
                switch role {
                case .tonic:       score *= 1.65
                case .mediant:     score *= 1.35
                case .subdominant: score *= 1.25
                case .suspended:   score *= 1.05
                case .dominant:    score *= 0.55
                }
            }
            // Smooth voice-leading: dominant -> tonic / mediant / suspended
            if prevRole == .dominant && (role == .tonic || role == .mediant || role == .suspended) {
                score *= 1.55
            }
            // Encourage stepping into secondary harmonic climate (32..<m) for multi-hour evolution
            if candIdx >= SatieScore.barsPerForm {
                score *= 1.25
            }
            // Mild preference for harmonic motion on 2-bar pair boundaries
            if isHarmonicPairBoundary && sym != prevChord {
                score *= 1.30
            }
            return score
        }

        // Gather Factor Oracle recombination candidates (suffix links, reverse suffix links, factor edges)
        var oracleTargets = oracle.recombinationTargets(from: state)
        // Always include one deterministic suffix-link neighbor from the paired climate if sparse
        if oracleTargets.isEmpty {
            let mirror = (linearIdx + SatieScore.barsPerForm) % m
            oracleTargets.append(mirror)
        }

        // Decide whether to follow a Factor Oracle jump vs continue linearly
        // Jump probability rises smoothly with barsSinceJump so we never loop 32 bars verbatim
        let baseJumpProb: Double = isHarmonicPairBoundary ? 0.34 : 0.10
        let pressureBoost: Double = min(0.50, Double(max(0, barsSinceJump - 3)) * 0.09)
        let linearViolates = violatesGrammar(linearIdx)
        let wantJump = linearViolates || (rng.nextUnit() < (baseJumpProb + pressureBoost))

        if wantJump {
            let validJumps = oracleTargets.filter { !violatesGrammar($0) }
            let pool: [Int]
            if !validJumps.isEmpty {
                pool = validJumps
            } else {
                // Fallback: scan full corpus for any grammar-compliant chord pivot
                let fallback = (0..<m).filter { $0 != linearIdx && !violatesGrammar($0) }
                pool = fallback.isEmpty ? oracleTargets : fallback
            }

            if !pool.isEmpty {
                let weights = pool.map { grammarScore($0) }
                let totalW = weights.reduce(0, +)
                var pick = rng.nextUnit() * max(1e-9, totalW)
                var chosen = pool[0]
                for (i, w) in weights.enumerated() {
                    pick -= w
                    if pick <= 0 {
                        chosen = pool[i]
                        break
                    }
                }
                let actuallyJumped = (chosen != linearIdx)
                recordSelection(chosen, symbol: oracle.symbols[chosen], jumped: actuallyJumped, corpusLength: m)
                return (chosen, actuallyJumped)
            }
        }

        recordSelection(linearIdx, symbol: oracle.symbols[linearIdx], jumped: false, corpusLength: m)
        return (linearIdx, false)
    }

    private mutating func recordSelection(_ corpusIndex: Int, symbol: String, jumped: Bool, corpusLength: Int) {
        if recentChords.last == symbol {
            consecutiveSameChord += 1
        } else {
            consecutiveSameChord = 1
        }
        recentChords.append(symbol)
        if recentChords.count > 16 {
            recentChords.removeFirst(recentChords.count - 16)
        }
        recentIndices.append(corpusIndex)
        if recentIndices.count > 12 {
            recentIndices.removeFirst(recentIndices.count - 12)
        }
        if jumped {
            totalJumps += 1
            barsSinceJump = 0
        } else {
            barsSinceJump += 1
        }
        state = (corpusIndex + 1) % max(1, corpusLength)
    }
}
