import Foundation

#if os(iOS) && canImport(ActivityKit)
import ActivityKit

/// Shared ActivityKit attributes for Satie's Dynamic Island, Lock Screen, and iPhone StandBy Live Activity.
public struct SatieSessionAttributes: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        public var soundscapeRaw: String
        public var soundscapeTitle: String
        public var subtitle: String
        public var isPlaying: Bool
        public var endDate: Date?
        public var breathBPM: Double
        public var isNight: Bool

        public init(
            soundscapeRaw: String,
            soundscapeTitle: String,
            subtitle: String,
            isPlaying: Bool,
            endDate: Date?,
            breathBPM: Double,
            isNight: Bool
        ) {
            self.soundscapeRaw = soundscapeRaw
            self.soundscapeTitle = soundscapeTitle
            self.subtitle = subtitle
            self.isPlaying = isPlaying
            self.endDate = endDate
            self.breathBPM = breathBPM
            self.isNight = isNight
        }
    }

    public var sessionID: String

    public init(sessionID: String) {
        self.sessionID = sessionID
    }
}
#endif

/// Lightweight snapshot for Satie's iPhone StandBy / Lock Screen Widget timeline.
public struct SatieWidgetSnapshot: Codable, Sendable, Equatable {
    public var soundscapeRaw: String
    public var soundscapeTitle: String
    public var isPlaying: Bool
    public var endDate: Date?
    public var updatedAt: Date

    public init(
        soundscapeRaw: String = FocusSoundscape.dive.rawValue,
        soundscapeTitle: String = FocusSoundscape.dive.title,
        isPlaying: Bool = false,
        endDate: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.soundscapeRaw = soundscapeRaw
        self.soundscapeTitle = soundscapeTitle
        self.isPlaying = isPlaying
        self.endDate = endDate
        self.updatedAt = updatedAt
    }

    private static let key = "satie.widget.snapshot.v1"

    public static func load() -> SatieWidgetSnapshot {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode(SatieWidgetSnapshot.self, from: data) {
            return decoded
        }
        return SatieWidgetSnapshot()
    }

    public func save() {
        if let encoded = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(encoded, forKey: Self.key)
        }
    }
}
