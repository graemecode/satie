import Foundation

/// A playing Satie session, as handed between a Mac and an iPhone or iPad with Apple's Handoff.
///
/// Handoff travels over the devices' own Bluetooth and iCloud link, managed by the system: Satie makes no network
/// request and needs no permission for it. The payload is only the soundscape and the timer.
public struct SatieHandoff: Equatable, Sendable {
    /// Must also be listed under `NSUserActivityTypes` in every app that sends or continues it.
    public static let activityType = "com.strangechances.Satie.playing"
    private static let version = 1

    public let mode: FocusSoundscape
    /// The timer length in minutes, or 0 for no limit.
    public let flowMinutes: Int
    /// When the timer ends, or nil for no limit. Absolute, so the other device resumes at the same moment.
    public let endDate: Date?

    public init(mode: FocusSoundscape, flowMinutes: Int, endDate: Date?) {
        self.mode = mode
        self.flowMinutes = max(0, flowMinutes)
        self.endDate = flowMinutes > 0 ? endDate : nil
    }

    public var userInfo: [String: Any] {
        var info: [String: Any] = ["v": Self.version, "mode": mode.rawValue, "minutes": flowMinutes]
        if let endDate { info["end"] = endDate.timeIntervalSince1970 }
        return info
    }

    public init?(userInfo: [AnyHashable: Any]?) {
        guard let info = userInfo,
              let raw = info["mode"] as? String,
              let mode = FocusSoundscape(rawValue: raw) else { return nil }
        let minutes = (info["minutes"] as? Int) ?? 0
        let end = (info["end"] as? Double).map { Date(timeIntervalSince1970: $0) }
        self.init(mode: mode, flowMinutes: minutes, endDate: end)
    }

    /// A session whose timer has already run out is over; there is nothing to continue.
    public func isFinished(at now: Date = Date()) -> Bool {
        guard let endDate else { return false }
        return endDate <= now
    }
}

/// Advertises the current session for Handoff, and reports when another device has continued it.
@MainActor
public final class SatieHandoffPublisher: NSObject, NSUserActivityDelegate {
    private var activity: NSUserActivity?
    private var session: SatieHandoff?

    /// Called on this device after another device picks up the session, so this one can fade out.
    public var onContinuedElsewhere: (() -> Void)?

    public override init() { super.init() }

    /// Pass the session while playing, or nil when stopped.
    public func update(_ next: SatieHandoff?) {
        guard next != session else { return }
        session = next
        guard let next else {
            activity?.invalidate()
            activity = nil
            return
        }
        let current = activity ?? makeActivity()
        current.title = "Satie · \(next.mode.title)"
        current.userInfo = next.userInfo
        current.becomeCurrent()
        activity = current
    }

    private func makeActivity() -> NSUserActivity {
        let a = NSUserActivity(activityType: SatieHandoff.activityType)
        a.isEligibleForHandoff = true
        a.isEligibleForSearch = false
        #if os(iOS)
        a.isEligibleForPrediction = false
        #endif
        a.delegate = self
        return a
    }

    public nonisolated func userActivityWasContinued(_ userActivity: NSUserActivity) {
        Task { @MainActor [weak self] in
            self?.onContinuedElsewhere?()
        }
    }
}
