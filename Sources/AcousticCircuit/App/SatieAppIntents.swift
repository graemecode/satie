import AcousticCore
import AppIntents
import Foundation

/// AppIntents representation of Satie's six audiovisual worlds for Shortcuts, Siri, Spotlight,
/// Action Button, and Apple Focus Filters on macOS 15+ and iOS 18+.
enum SoundscapeAppEnum: String, AppEnum, CaseIterable, Sendable {
    case focus
    case pulse
    case rain
    case still
    case dive
    case drift

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Soundscape")

    static let caseDisplayRepresentations: [SoundscapeAppEnum: DisplayRepresentation] = [
        .focus: DisplayRepresentation(title: "Soft Light", subtitle: "Deep work · felt piano & vibe"),
        .pulse: DisplayRepresentation(title: "Kinetic Pulse", subtitle: "Flow momentum · silky analog"),
        .rain:  DisplayRepresentation(title: "Rain & Glass", subtitle: "Kyoto rain · singing glass"),
        .still: DisplayRepresentation(title: "Still", subtitle: "Deep reading · zero melody"),
        .dive:  DisplayRepresentation(title: "Deep Dive", subtitle: "Meditation · breath & bowls"),
        .drift: DisplayRepresentation(title: "Gymnopédie", subtitle: "Late night · piano & cello")
    ]

    var soundscape: FocusSoundscape {
        switch self {
        case .focus: return .focus
        case .pulse: return .pulse
        case .rain:  return .rain
        case .still: return .still
        case .dive:  return .dive
        case .drift: return .drift
        }
    }
}

/// Start playing any Satie soundscape directly from Shortcuts, Siri, Spotlight, or iPhone Action Button.
struct PlaySatieSoundscapeIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Satie Soundscape"
    static let description = IntentDescription("Start playing a generative Satie soundscape with an optional session timer.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Soundscape", default: .focus)
    var soundscape: SoundscapeAppEnum

    @Parameter(
        title: "Timer (Minutes)",
        description: "Set 0 for continuous playback, or 1–120 minutes for a timed session arc.",
        inclusiveRange: (0, 120)
    )
    var durationMinutes: Int?

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$soundscape) in Satie") {
            \.$durationMinutes
        }
    }

    init() {}

    init(soundscape: SoundscapeAppEnum, durationMinutes: Int? = nil) {
        self.soundscape = soundscape
        self.durationMinutes = durationMinutes
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let mode = soundscape.soundscape
        #if os(macOS)
        AppState.shared.startFocusSound(mode, durationMinutes: durationMinutes)
        #elseif os(iOS) && !SATIE_WIDGET_EXTENSION
        SatieiOSState.shared.startFocusSound(mode, durationMinutes: durationMinutes)
        #endif

        if let mins = durationMinutes, mins > 0 {
            return .result(dialog: "Playing \(mode.title) for \(mins) minutes.")
        }
        return .result(dialog: "Playing \(mode.title).")
    }
}

/// Pause active Satie playback without opening the app window.
struct PauseSatieIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Pause Satie"
    static let description = IntentDescription("Fade out and pause Satie's active soundscape.")
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        #if os(macOS)
        AppState.shared.stopFocusSound()
        #elseif os(iOS) && !SATIE_WIDGET_EXTENSION
        SatieiOSState.shared.stopFocusSound()
        #endif
        return .result(dialog: "Paused Satie.")
    }
}

/// Toggle Satie playback on/off — ideal for iPhone Action Button, Control Center, and macOS Shortcuts.
struct ToggleSatiePlaybackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Toggle Satie Playback"
    static let description = IntentDescription("Play or pause Satie's current soundscape.")
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        #if os(macOS)
        AppState.shared.togglePlayOrStartFocus()
        let playing = AppState.shared.isFocusPlaying
        let title = AppState.shared.focusMode.title
        #elseif os(iOS) && !SATIE_WIDGET_EXTENSION
        SatieiOSState.shared.togglePlayOrPause()
        let playing = SatieiOSState.shared.isFocusPlaying
        let title = SatieiOSState.shared.focusMode.title
        #else
        let playing = true
        let title = "Satie"
        #endif
        return .result(dialog: playing ? "Playing \(title)." : "Paused Satie.")
    }
}

/// Native Apple Focus Filter — lets users bind Work Focus -> Soft Light / Kinetic Pulse,
/// Reading Focus -> Still, or Sleep Focus -> Deep Dive (30m) directly in System Settings.
struct SatieFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Set Satie Soundscape"
    static let description = IntentDescription("Automatically align Satie's soundscape and session timer with your active Apple Focus mode.")

    @Parameter(title: "Soundscape")
    var soundscape: SoundscapeAppEnum?

    @Parameter(title: "Start Playing Automatically", default: true)
    var autoPlay: Bool

    @Parameter(
        title: "Session Timer (Minutes)",
        description: "Optional countdown timer (0 for continuous, 1–120 minutes).",
        inclusiveRange: (0, 120)
    )
    var durationMinutes: Int?

    @Parameter(title: "Nocturnal Low-Melanopic Mode", default: false)
    var nocturnalOverride: Bool

    var displayRepresentation: DisplayRepresentation {
        guard let sc = soundscape else {
            return DisplayRepresentation(title: "Satie", subtitle: "Keep current soundscape")
        }
        let timerTag: String
        if let mins = durationMinutes, mins > 0 {
            timerTag = "\(mins)m"
        } else {
            timerTag = "Continuous"
        }
        let actionTag = autoPlay ? "Play" : "Select"
        return DisplayRepresentation(
            title: "\(sc.soundscape.title)",
            subtitle: "\(actionTag) · \(timerTag)"
        )
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if os(macOS)
        let state = AppState.shared
        state.circadianOverride = nocturnalOverride ? .warm : .auto
        if let sc = soundscape {
            if autoPlay {
                state.startFocusSound(sc.soundscape, durationMinutes: durationMinutes)
            } else {
                state.focusMode = sc.soundscape
                if let mins = durationMinutes {
                    state.setFlowMinutes(mins)
                }
            }
        }
        #elseif os(iOS) && !SATIE_WIDGET_EXTENSION
        let state = SatieiOSState.shared
        if let sc = soundscape {
            if autoPlay {
                state.startFocusSound(sc.soundscape, durationMinutes: durationMinutes)
            } else {
                state.focusMode = sc.soundscape
                if let mins = durationMinutes {
                    state.setFlowMinutes(mins)
                }
            }
        }
        #endif
        return .result()
    }
}

/// Zero-configuration Siri, Spotlight, and Shortcuts App Shortcuts bundled with Satie.
struct SatieAppShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor { .navy }

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlaySatieSoundscapeIntent(),
            phrases: [
                "Play \(\.$soundscape) in \(.applicationName)",
                "Start \(\.$soundscape) with \(.applicationName)",
                "Open \(\.$soundscape) in \(.applicationName)"
            ],
            shortTitle: "Play Soundscape",
            systemImageName: "waveform.circle"
        )
        AppShortcut(
            intent: ToggleSatiePlaybackIntent(),
            phrases: [
                "Toggle \(.applicationName)",
                "Start \(.applicationName)"
            ],
            shortTitle: "Play or Pause",
            systemImageName: "playpause.circle"
        )
        AppShortcut(
            intent: PauseSatieIntent(),
            phrases: [
                "Pause \(.applicationName)",
                "Stop \(.applicationName)"
            ],
            shortTitle: "Pause Satie",
            systemImageName: "pause.circle"
        )
    }
}
