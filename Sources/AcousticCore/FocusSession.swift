import Foundation

/// One stretch of a focus session: either a focus round or the short break between two rounds.
public struct SessionSegment: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case focus
        case rest
    }

    public let kind: Kind
    /// 1-based focus round this segment belongs to (a break belongs to the round it follows).
    public let round: Int
    public let seconds: Double

    public init(kind: Kind, round: Int, seconds: Double) {
        self.kind = kind
        self.round = round
        self.seconds = seconds
    }
}

/// A focus session as rounds of focus separated by short breaks.
/// `focusMinutes == 0` means open-ended playback with no timer at all.
public struct FocusSessionPlan: Equatable, Sendable {
    public static let maxRounds = 8
    public static let breakChoices: [Int] = [0, 5, 10, 15]

    public var focusMinutes: Int
    public var breakMinutes: Int
    public var rounds: Int

    public init(focusMinutes: Int, breakMinutes: Int = 0, rounds: Int = 1) {
        self.focusMinutes = max(0, min(120, focusMinutes))
        self.breakMinutes = max(0, min(30, breakMinutes))
        self.rounds = max(1, min(Self.maxRounds, rounds))
    }

    public var isTimed: Bool { focusMinutes > 0 }

    /// Breaks only exist between rounds, so a single round never has one.
    public var hasBreaks: Bool { isTimed && rounds > 1 && breakMinutes > 0 }

    /// Focus, break, focus, … ending on a focus round (no trailing break).
    public var segments: [SessionSegment] {
        guard isTimed else { return [] }
        var out: [SessionSegment] = []
        for round in 1...rounds {
            out.append(SessionSegment(kind: .focus, round: round, seconds: Double(focusMinutes * 60)))
            if round < rounds && breakMinutes > 0 {
                out.append(SessionSegment(kind: .rest, round: round, seconds: Double(breakMinutes * 60)))
            }
        }
        return out
    }

    public var totalMinutes: Int {
        guard isTimed else { return 0 }
        let breaks = hasBreaks ? (rounds - 1) * breakMinutes : 0
        return rounds * focusMinutes + breaks
    }

    /// Compact one-line description for the timer drawer, e.g. "2 × 25M FOCUS · 5M BREAK · 55M TOTAL".
    public var summary: String {
        guard isTimed else { return "OPEN-ENDED · NO TIMER" }
        if rounds == 1 { return "1 × \(focusMinutes)M FOCUS" }
        if hasBreaks {
            return "\(rounds) × \(focusMinutes)M FOCUS · \(breakMinutes)M BREAK · \(totalMinutes)M TOTAL"
        }
        return "\(rounds) × \(focusMinutes)M FOCUS · \(totalMinutes)M TOTAL"
    }
}

/// Walks a `FocusSessionPlan` forward in time. Pure value type: the caller feeds it elapsed seconds.
public struct FocusSessionClock: Equatable, Sendable {
    public enum Event: Equatable, Sendable {
        /// Still inside the same segment.
        case running
        /// The previous segment ended and `next` has just begun.
        case segmentEnded(next: SessionSegment)
        /// The last focus round ended; the session is complete.
        case finished
    }

    public let plan: FocusSessionPlan
    public private(set) var index: Int = 0
    public private(set) var remaining: Double

    private let segments: [SessionSegment]

    /// Returns nil for an open-ended plan, which has nothing to count down.
    public init?(plan: FocusSessionPlan) {
        let segs = plan.segments
        guard let first = segs.first else { return nil }
        self.plan = plan
        self.segments = segs
        self.remaining = first.seconds
    }

    public var current: SessionSegment? {
        index < segments.count ? segments[index] : nil
    }

    public var isFinished: Bool { index >= segments.count }

    public var isOnBreak: Bool { current?.kind == .rest }

    /// 0 at the start of the current segment, 1 at its end.
    public var segmentProgress: Double {
        guard let seg = current, seg.seconds > 0 else { return 1.0 }
        return max(0.0, min(1.0, (seg.seconds - remaining) / seg.seconds))
    }

    /// Advances by `dt` seconds. At most one segment boundary is crossed per call.
    public mutating func tick(_ dt: Double) -> Event {
        guard !isFinished else { return .finished }
        remaining -= dt
        if remaining > 0 { return .running }
        index += 1
        guard let next = current else {
            remaining = 0
            return .finished
        }
        remaining = next.seconds
        return .segmentEnded(next: next)
    }
}

/// Listening history kept locally (never leaves the Mac): seconds per day and per soundscape.
public struct ListeningStats: Equatable, Sendable {
    public var secondsByDay: [String: Double]
    public var secondsByMode: [String: Double]

    public init(secondsByDay: [String: Double] = [:], secondsByMode: [String: Double] = [:]) {
        self.secondsByDay = secondsByDay
        self.secondsByMode = secondsByMode
    }

    public static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public mutating func record(seconds: Double, mode: FocusSoundscape, date: Date = Date(), calendar: Calendar = .current) {
        guard seconds > 0 else { return }
        secondsByDay[Self.dayKey(for: date, calendar: calendar), default: 0] += seconds
        secondsByMode[mode.rawValue, default: 0] += seconds
    }

    public var totalSeconds: Double {
        secondsByDay.values.reduce(0, +)
    }

    public var daysUsed: Int {
        secondsByDay.values.filter { $0 > 0 }.count
    }

    /// Seconds listened today and over the six days before it.
    public func lastSevenDaysSeconds(now: Date = Date(), calendar: Calendar = .current) -> Double {
        var sum = 0.0
        for offset in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            sum += secondsByDay[Self.dayKey(for: day, calendar: calendar)] ?? 0
        }
        return sum
    }

    /// The soundscape with the most listening time, or nil before anything has been played.
    public var favorite: FocusSoundscape? {
        let best = secondsByMode
            .filter { $0.value > 0 }
            .max { a, b in a.value == b.value ? a.key > b.key : a.value < b.value }
        return best.flatMap { FocusSoundscape(rawValue: $0.key) }
    }

    /// "42M", "3H 05M" — compact duration for the stats strip.
    public static func formatDuration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60.0)
        if minutes < 60 { return "\(minutes)M" }
        return String(format: "%dH %02dM", minutes / 60, minutes % 60)
    }
}
