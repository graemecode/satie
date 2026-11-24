import AcousticCore
import ActivityKit
import Foundation
import WidgetKit

/// Coordinates iOS Dynamic Island, Lock Screen, and iPhone StandBy Live Activities
/// at zero background CPU cost (uses native system timerInterval rendering).
@MainActor
final class SatieLiveActivityManager {
    func sync(
        mode: FocusSoundscape,
        isPlaying: Bool,
        endDate: Date?,
        breathBPM: Double = 5.5
    ) {
        let snapshot = SatieWidgetSnapshot(
            soundscapeRaw: mode.rawValue,
            soundscapeTitle: mode.title,
            isPlaying: isPlaying,
            endDate: endDate,
            updatedAt: Date()
        )
        snapshot.save()
        WidgetCenter.shared.reloadAllTimelines()

        if !isPlaying {
            endAll()
            return
        }

        let isNight = CircadianPhase.current() == .night
        let contentState = SatieSessionAttributes.ContentState(
            soundscapeRaw: mode.rawValue,
            soundscapeTitle: mode.title,
            subtitle: mode == .dive ? String(format: "%.1f bpm breath", breathBPM) : mode.subtitle,
            isPlaying: isPlaying,
            endDate: endDate,
            breathBPM: breathBPM,
            isNight: isNight
        )
        let staleDate = endDate ?? Date().addingTimeInterval(3600 * 4)

        Task.detached(priority: .utility) {
            await Self.upsertActivity(state: contentState, staleDate: staleDate)
        }
    }

    func endAll() {
        Task.detached(priority: .utility) {
            await Self.endAllActivities()
        }
    }

    private nonisolated static func upsertActivity(
        state: SatieSessionAttributes.ContentState,
        staleDate: Date
    ) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let content = ActivityContent(state: state, staleDate: staleDate)
        if let active = Activity<SatieSessionAttributes>.activities.first {
            await active.update(content)
        } else {
            let attrs = SatieSessionAttributes(sessionID: UUID().uuidString)
            do {
                _ = try Activity.request(attributes: attrs, content: content, pushType: nil)
            } catch {
                Log.app.warning("Live Activity request skipped: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private nonisolated static func endAllActivities() async {
        for act in Activity<SatieSessionAttributes>.activities {
            await act.end(nil, dismissalPolicy: .immediate)
        }
    }
}
