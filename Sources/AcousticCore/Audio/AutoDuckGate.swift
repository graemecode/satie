import Foundation

/// Notification-immune auto-ducking state machine.
/// Prevents short notification pings (Slack, Ando, Messages, macOS system sounds) and idle
/// silent browser/Electron audio streams from interrupting focus music, while reliably ducking
/// for sustained calls, videos, and music playback.
public struct AutoDuckGate: Sendable {
    public struct Decision: Equatable, Sendable {
        public let isDucked: Bool
        public let duckedByAppName: String?

        public init(isDucked: Bool, duckedByAppName: String?) {
            self.isDucked = isDucked
            self.duckedByAppName = duckedByAppName
        }
    }

    /// System daemons, notification centers, and developer/chat alert apps that should never
    /// duck focus music for short alert sounds.
    private static let ignoredBundlePrefixes: [String] = [
        "com.apple.systemsoundserver",
        "com.apple.notificationcenter",
        "com.apple.usernotificationcenter",
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.controlcenter",
        "com.apple.systemuiserver",
        "com.apple.mail",
        "com.apple.ical",
        "com.apple.reminders",
        "com.apple.notes",
        "com.apple.mobilesms",
        "com.apple.terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "com.apple.dt.xcode",
        "com.microsoft.vscode",
        "com.todesktop.230313mzl4w4u92", // Cursor
    ]

    private static let ignoredAppNames: Set<String> = [
        "systemsoundserverd",
        "notificationcenter",
        "usernotificationcenter",
        "finder",
        "dock",
        "controlcenter",
        "systemuiserver",
        "mail",
        "calendar",
        "reminders",
        "notes",
        "messages",
        "terminal",
        "iterm2",
        "ghostty",
        "xcode",
        "cursor",
        "visual studio code",
        "code",
    ]

    /// Dedicated media/call apps whose sustained playback can duck slightly faster (0.9s)
    /// vs general browsers/chat apps (1.6s) where short notification chimes happen often.
    private static let dedicatedMediaOrCallNames: Set<String> = [
        "spotify",
        "music",
        "apple music",
        "zoom.us",
        "zoom",
        "facetime",
        "loom",
        "vlc",
        "quicktime player",
        "iina",
        "podcasts",
        "tidal",
        "soundcloud",
    ]

    public static let audioEnergyThreshold: Float = 0.0035 // ~-49 dBFS
    public static let dedicatedDuckDelay: Double = 0.90
    public static let generalDuckDelay: Double = 1.60
    public static let unduckSilenceDelay: Double = 3.00

    private var activeSince: Double?
    private var silentSince: Double?
    private(set) public var isDucked: Bool = false
    private(set) public var duckedByAppName: String?

    public init() {}

    public mutating func reset() {
        activeSince = nil
        silentSince = nil
        isDucked = false
        duckedByAppName = nil
    }

    public static func isIgnoredProcess(name: String, bundleID: String) -> Bool {
        let lowerName = name.lowercased()
        let lowerBundle = bundleID.lowercased()
        if ignoredAppNames.contains(lowerName) { return true }
        if ignoredBundlePrefixes.contains(where: { lowerBundle.hasPrefix($0) }) { return true }
        return false
    }

    /// Evaluates one tick of auto-ducking.
    /// - Parameters:
    ///   - now: Monotonic timestamp in seconds.
    ///   - activeProcesses: Processes currently reporting `isRunningOutput == true`.
    ///   - externalRMS: Real RMS measured from the Satie-excluded system audio tap (`nil` if tap unavailable).
    public mutating func evaluate(
        now: Double,
        activeProcesses: [AudioProcessInfo],
        externalRMS: Float?
    ) -> Decision {
        let eligible = activeProcesses.filter {
            $0.isRunningOutput && !Self.isIgnoredProcess(name: $0.name, bundleID: $0.bundleID ?? "")
        }

        // If our Core Audio tap is active, require real audible energy so idle Electron/Chrome streams never ghost-duck.
        let hasRealAudio: Bool
        if let rms = externalRMS {
            hasRealAudio = !eligible.isEmpty && rms >= Self.audioEnergyThreshold
        } else {
            hasRealAudio = !eligible.isEmpty
        }

        if hasRealAudio, let primary = eligible.first {
            silentSince = nil
            if isDucked {
                duckedByAppName = primary.name
                return Decision(isDucked: true, duckedByAppName: duckedByAppName)
            }

            if let since = activeSince {
                let required = Self.dedicatedMediaOrCallNames.contains(primary.name.lowercased())
                    ? Self.dedicatedDuckDelay
                    : Self.generalDuckDelay
                if now - since >= required {
                    isDucked = true
                    duckedByAppName = primary.name
                }
            } else {
                activeSince = now
            }
            return Decision(isDucked: isDucked, duckedByAppName: duckedByAppName)
        } else {
            activeSince = nil
            if isDucked {
                if let since = silentSince {
                    if now - since >= Self.unduckSilenceDelay {
                        isDucked = false
                        duckedByAppName = nil
                        silentSince = nil
                    }
                } else {
                    silentSince = now
                }
            }
            return Decision(isDucked: isDucked, duckedByAppName: duckedByAppName)
        }
    }
}
