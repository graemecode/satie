import AcousticCore
import Foundation
import Testing

@Suite("Focus session rounds, breaks & listening stats")
struct FocusSessionTests {
    @Test("Plan alternates focus and break and ends on a focus round")
    func planSegments() {
        let plan = FocusSessionPlan(focusMinutes: 25, breakMinutes: 5, rounds: 3)
        let kinds = plan.segments.map(\.kind)
        #expect(kinds == [.focus, .rest, .focus, .rest, .focus])
        #expect(plan.segments.map(\.round) == [1, 1, 2, 2, 3])
        #expect(plan.totalMinutes == 85)
        #expect(plan.hasBreaks)
        #expect(plan.summary == "3 × 25M FOCUS · 5M BREAK · 85M TOTAL")
    }

    @Test("Single round and break-off plans have no break segments")
    func planWithoutBreaks() {
        let single = FocusSessionPlan(focusMinutes: 45, breakMinutes: 5, rounds: 1)
        #expect(single.segments.count == 1)
        #expect(!single.hasBreaks)
        #expect(single.totalMinutes == 45)

        let backToBack = FocusSessionPlan(focusMinutes: 20, breakMinutes: 0, rounds: 2)
        #expect(backToBack.segments.map(\.kind) == [.focus, .focus])
        #expect(backToBack.totalMinutes == 40)
    }

    @Test("Open-ended plan has no segments and no clock; inputs are clamped")
    func openEndedAndClamping() {
        let open = FocusSessionPlan(focusMinutes: 0, breakMinutes: 5, rounds: 4)
        #expect(!open.isTimed)
        #expect(open.segments.isEmpty)
        #expect(FocusSessionClock(plan: open) == nil)

        let wild = FocusSessionPlan(focusMinutes: 999, breakMinutes: -3, rounds: 50)
        #expect(wild.focusMinutes == 120)
        #expect(wild.breakMinutes == 0)
        #expect(wild.rounds == FocusSessionPlan.maxRounds)
    }

    @Test("Clock walks focus → break → focus → finished with correct events")
    func clockTransitions() throws {
        let plan = FocusSessionPlan(focusMinutes: 5, breakMinutes: 5, rounds: 2)
        var clock = try #require(FocusSessionClock(plan: plan))
        #expect(clock.current?.kind == .focus)
        #expect(clock.segmentProgress == 0)

        var events: [FocusSessionClock.Event] = []
        var ticks = 0
        while !clock.isFinished && ticks < 10_000 {
            let e = clock.tick(1.0)
            if e != .running { events.append(e) }
            ticks += 1
        }
        #expect(ticks == 15 * 60)
        #expect(events.count == 3)
        #expect(events[0] == .segmentEnded(next: SessionSegment(kind: .rest, round: 1, seconds: 300)))
        #expect(events[1] == .segmentEnded(next: SessionSegment(kind: .focus, round: 2, seconds: 300)))
        #expect(events[2] == .finished)
        #expect(clock.tick(1.0) == .finished)
    }

    @Test("Clock reports break state and mid-segment progress")
    func clockProgress() throws {
        var clock = try #require(FocusSessionClock(plan: FocusSessionPlan(focusMinutes: 10, breakMinutes: 5, rounds: 2)))
        for _ in 0..<300 { _ = clock.tick(1.0) }
        #expect(abs(clock.segmentProgress - 0.5) < 0.001)
        #expect(!clock.isOnBreak)
        for _ in 0..<300 { _ = clock.tick(1.0) }
        #expect(clock.isOnBreak)
        #expect(clock.remaining == 300)
    }

    @Test("Listening stats total, days, last-7-days window and favorite")
    func listeningStats() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try #require(TimeZone(identifier: "UTC"))
        let now = try #require(cal.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 12)))
        let tenDaysAgo = try #require(cal.date(byAdding: .day, value: -10, to: now))
        let twoDaysAgo = try #require(cal.date(byAdding: .day, value: -2, to: now))

        var stats = ListeningStats()
        #expect(stats.favorite == nil)
        stats.record(seconds: 600, mode: .drift, date: tenDaysAgo, calendar: cal)
        stats.record(seconds: 900, mode: .focus, date: twoDaysAgo, calendar: cal)
        stats.record(seconds: 300, mode: .focus, date: now, calendar: cal)
        stats.record(seconds: 0, mode: .rain, date: now, calendar: cal)

        #expect(stats.totalSeconds == 1800)
        #expect(stats.daysUsed == 3)
        #expect(stats.lastSevenDaysSeconds(now: now, calendar: cal) == 1200)
        #expect(stats.favorite == .focus)
        #expect(ListeningStats.dayKey(for: now, calendar: cal) == "2026-11-21")
        #expect(ListeningStats.formatDuration(1800) == "30M")
        #expect(ListeningStats.formatDuration(3 * 3600 + 5 * 60) == "3H 05M")
    }

    @Test("Settings persist rounds, break, intention and listening stats")
    func settingsRoundTrip() throws {
        let suite = "satie.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)

        #expect(store.breakMinutes == 5)
        #expect(store.sessionRounds == 1)
        #expect(store.sessionIntention.isEmpty)

        store.breakMinutes = 10
        store.sessionRounds = 99
        store.sessionIntention = String(repeating: "x", count: 200)
        #expect(store.breakMinutes == 10)
        #expect(store.sessionRounds == FocusSessionPlan.maxRounds)
        #expect(store.sessionIntention.count == 80)

        var stats = store.listeningStats
        stats.record(seconds: 120, mode: .still)
        store.listeningStats = stats
        #expect(store.listeningStats.totalSeconds == 120)
        #expect(store.listeningStats.favorite == .still)
    }

    @Test("Every soundscape has a one-line promise")
    func soundscapePromises() {
        for mode in FocusSoundscape.allCases {
            #expect(!mode.promise.isEmpty)
            #expect(mode.promise.count <= 64)
        }
    }
}
