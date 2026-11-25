import AcousticCore
import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Shared Braun / Turrell Visual Tokens

private struct OculusEmblem: View {
    let soundscapeRaw: String
    let isNight: Bool
    let accent: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(accent.opacity(0.28), lineWidth: 1.0)
            Circle()
                .stroke(accent.opacity(0.50), lineWidth: 1.1)
                .padding(3.5)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [accent.opacity(0.95), accent.opacity(0.22), .clear],
                        center: .center,
                        startRadius: 1,
                        endRadius: 12
                    )
                )
                .padding(7)
        }
        .accessibilityLabel(soundscapeRaw)
    }

    static func accentColor(for raw: String, isNight: Bool) -> Color {
        if isNight || raw == FocusSoundscape.dive.rawValue {
            return Color(red: 0.90, green: 0.52, blue: 0.22) // Low-melanopic Turrell ember
        }
        switch raw {
        case FocusSoundscape.pulse.rawValue:
            return Color(red: 0.36, green: 0.92, blue: 0.62) // P31 CRT emerald
        case FocusSoundscape.rain.rawValue:
            return Color(red: 0.56, green: 0.78, blue: 0.72) // Courtyard jade
        case FocusSoundscape.drift.rawValue:
            return Color(red: 0.84, green: 0.62, blue: 0.38) // Nocturne candlelight amber
        default:
            return Color(red: 0.72, green: 0.84, blue: 0.98) // Soft Light silver-sky
        }
    }
}

// MARK: - iPhone StandBy, Lock Screen & Home Screen Widget

struct SatieWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: SatieWidgetSnapshot
    let isNight: Bool
}

struct SatieWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> SatieWidgetEntry {
        SatieWidgetEntry(
            date: Date(),
            snapshot: SatieWidgetSnapshot(soundscapeRaw: FocusSoundscape.dive.rawValue, soundscapeTitle: FocusSoundscape.dive.title, isPlaying: true),
            isNight: CircadianPhase.current() == .night
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (SatieWidgetEntry) -> Void) {
        completion(SatieWidgetEntry(date: Date(), snapshot: .load(), isNight: CircadianPhase.current() == .night))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SatieWidgetEntry>) -> Void) {
        let now = Date()
        let entry = SatieWidgetEntry(date: now, snapshot: .load(), isNight: CircadianPhase.current() == .night)
        // Refresh gently every 30 minutes for circadian day/night palette sync
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: now) ?? now.addingTimeInterval(1800)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct SatieStandByWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SatieWidgetEntry

    private var accent: Color {
        OculusEmblem.accentColor(for: entry.snapshot.soundscapeRaw, isNight: entry.isNight)
    }

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                OculusEmblem(soundscapeRaw: entry.snapshot.soundscapeRaw, isNight: entry.isNight, accent: .white)
                    .padding(6)
            }
            .containerBackground(.black, for: .widget)

        case .accessoryRectangular:
            HStack(spacing: 10) {
                OculusEmblem(soundscapeRaw: entry.snapshot.soundscapeRaw, isNight: entry.isNight, accent: .white)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("SATIE")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .opacity(0.65)
                    Text(entry.snapshot.soundscapeTitle.uppercased())
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .containerBackground(.black, for: .widget)

        case .systemMedium:
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(accent)
                            .frame(width: 6, height: 6)
                        Text("SATIE")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .tracking(1.6)
                            .foregroundStyle(.white.opacity(0.60))
                    }
                    Text(entry.snapshot.soundscapeTitle)
                        .font(.system(size: 18, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                    Spacer(minLength: 0)
                    HStack(spacing: 8) {
                        Button(intent: PlaySatieSoundscapeIntent(soundscape: .focus)) {
                            Text(FocusSoundscape.focus.shortLabel)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.white.opacity(0.10), in: Capsule())
                        }
                        .buttonStyle(.plain)

                        Button(intent: PlaySatieSoundscapeIntent(soundscape: .dive, durationMinutes: 20)) {
                            Text(SatieL10n.string("widget.dive_20m"))
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(accent.opacity(0.24), in: Capsule())
                        }
                        .buttonStyle(.plain)

                        Button(intent: ToggleSatiePlaybackIntent()) {
                            Image(systemName: entry.snapshot.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 10, weight: .bold))
                                .padding(7)
                                .background(.white.opacity(0.14), in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    .foregroundStyle(.white)
                }

                Spacer(minLength: 0)

                // Sculptural Turrell Oculus aperture designed for OLED & iPhone StandBy Night Mode
                OculusEmblem(soundscapeRaw: entry.snapshot.soundscapeRaw, isNight: entry.isNight, accent: accent)
                    .frame(width: 74, height: 74)
            }
            .padding(4)
            .containerBackground(.black, for: .widget)

        default:
            // systemSmall — Ideal for iPhone StandBy bedside clock pairing (pure OLED obsidian + ember oculus)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("SATIE")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(1.8)
                        .foregroundStyle(.white.opacity(0.55))
                    Spacer()
                    Button(intent: ToggleSatiePlaybackIntent()) {
                        Image(systemName: entry.snapshot.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(.white.opacity(0.14), in: Circle())
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 0)

                HStack {
                    Spacer()
                    OculusEmblem(soundscapeRaw: entry.snapshot.soundscapeRaw, isNight: entry.isNight, accent: accent)
                        .frame(width: 58, height: 58)
                    Spacer()
                }

                Spacer(minLength: 0)

                HStack(alignment: .firstTextBaseline) {
                    Text(entry.snapshot.soundscapeTitle.uppercased())
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(1.1)
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(1)
                    Spacer()
                    Button(intent: PlaySatieSoundscapeIntent(soundscape: .dive, durationMinutes: 20)) {
                        Text(FocusSoundscape.dive.shortLabel)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .containerBackground(.black, for: .widget)
        }
    }
}

struct SatieStandByWidget: Widget {
    let kind: String = "SatieStandByWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SatieWidgetProvider()) { entry in
            SatieStandByWidgetView(entry: entry)
        }
        .configurationDisplayName(SatieL10n.string("widget.display_name"))
        .description(SatieL10n.string("widget.description"))
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

// MARK: - Dynamic Island, Lock Screen & StandBy Live Activity

struct SatieSessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SatieSessionAttributes.self) { context in
            let accent = OculusEmblem.accentColor(for: context.state.soundscapeRaw, isNight: context.state.isNight)
            HStack(spacing: 14) {
                OculusEmblem(
                    soundscapeRaw: context.state.soundscapeRaw,
                    isNight: context.state.isNight,
                    accent: accent
                )
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 2) {
                    Text("SATIE · \(context.state.soundscapeTitle.uppercased())")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(1.0)
                        .foregroundStyle(.white)
                    Text(context.state.subtitle)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.white.opacity(0.65))
                }

                Spacer()

                if let end = context.state.endDate, end > Date() {
                    Text(timerInterval: Date()...end, countsDown: true)
                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                        .foregroundStyle(accent)
                        .monospacedDigit()
                        .frame(minWidth: 52, alignment: .trailing)
                } else {
                    Text("∞")
                        .font(.system(size: 16, weight: .medium, design: .monospaced))
                        .foregroundStyle(accent.opacity(0.85))
                }

                Button(intent: PauseSatieIntent()) {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(.white.opacity(0.14), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .activityBackgroundTint(.black)
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let accent = OculusEmblem.accentColor(for: context.state.soundscapeRaw, isNight: context.state.isNight)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    OculusEmblem(
                        soundscapeRaw: context.state.soundscapeRaw,
                        isNight: context.state.isNight,
                        accent: accent
                    )
                    .frame(width: 32, height: 32)
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let end = context.state.endDate, end > Date() {
                        Text(timerInterval: Date()...end, countsDown: true)
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundStyle(accent)
                            .monospacedDigit()
                            .padding(.trailing, 4)
                    } else {
                        Text(SatieL10n.string("common.live"))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(accent)
                            .padding(.trailing, 4)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.soundscapeTitle)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(context.state.subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(SatieL10n.string("widget.instrument_tagline"))
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .tracking(1.2)
                            .foregroundStyle(.white.opacity(0.45))
                        Spacer()
                        Button(intent: PauseSatieIntent()) {
                            Label(SatieL10n.string("common.pause"), systemImage: "pause.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(.white.opacity(0.14), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 4)
                }
            } compactLeading: {
                OculusEmblem(
                    soundscapeRaw: context.state.soundscapeRaw,
                    isNight: context.state.isNight,
                    accent: accent
                )
                .frame(width: 18, height: 18)
            } compactTrailing: {
                if let end = context.state.endDate, end > Date() {
                    Text(timerInterval: Date()...end, countsDown: true)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(accent)
                        .monospacedDigit()
                        .frame(maxWidth: 44)
                } else {
                    Text((FocusSoundscape(rawValue: context.state.soundscapeRaw)?.shortLabel ?? context.state.soundscapeRaw.uppercased()))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(accent)
                }
            } minimal: {
                OculusEmblem(
                    soundscapeRaw: context.state.soundscapeRaw,
                    isNight: context.state.isNight,
                    accent: accent
                )
                .frame(width: 18, height: 18)
            }
            .keylineTint(accent)
        }
    }
}

@main
struct SatieWidgetsBundle: WidgetBundle {
    var body: some Widget {
        SatieStandByWidget()
        SatieSessionLiveActivity()
    }
}
