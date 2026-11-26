import AcousticCore
import AppKit
import SwiftUI

private struct MacBraunPressButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.93
    var reduceMotion: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect((configuration.isPressed && !reduceMotion) ? pressedScale : 1.0)
            .opacity(configuration.isPressed ? 0.84 : 1.0)
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

struct PopoverView: View {
    @ObservedObject var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onOpenMiniHUD: () -> Void
    let onOpenStudio: () -> Void
    let onOpenFullscreen: () -> Void
    let onQuit: () -> Void
    var onRequestResize: (() -> Void)? = nil
    var onContentHeightChange: ((CGFloat) -> Void)? = nil

    @State private var showOptions: Bool = false
    @State private var presetTransitionVeil: Double = 0.0

    private let timerPresets: [Int] = [0, 25, 45, 90]

    private let hair = Color.white.opacity(0.14)
    private let hairSoft = Color.white.opacity(0.08)
    private let inkSoft = Color.white.opacity(0.72)
    private let inkDim = Color.white.opacity(0.42)

    var body: some View {
        VStack(spacing: 13) {
            // 1. Pure Unobstructed Full-Bleed OLED Metal Stage
            ZStack {
                MetalVisualizerRepresentable(compactMode: true, isActive: state.isPopoverOpen)
                    .frame(height: 192)
                    .clipped()

                // Subtle dissolve veil on visual preset switch so transitions glide instead of snapping
                Color.black
                    .opacity(presetTransitionVeil)
                    .allowsHitTesting(false)

                // Whisper-subtle atmospheric light temperature matched to the active soundscape
                RadialGradient(
                    colors: [soundscapeAuraColor.opacity(0.22), Color.clear],
                    center: .center,
                    startRadius: 16,
                    endRadius: 185
                )
                .blendMode(.screen)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.9), value: state.focusMode)
                .allowsHitTesting(false)

                // Soft top vignette so floating typography reads cleanly over bright peaks
                VStack(spacing: 0) {
                    LinearGradient(
                        colors: [Color.black.opacity(0.74), Color.black.opacity(0.0)],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: 68)
                    Spacer()
                }
                .allowsHitTesting(false)

                VStack(spacing: 0) {
                    // Floating Header: Soundscape Title + Instruments on left, ONE quiet Studio expand button on right
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(heroTitle)
                                .font(.system(size: 17, weight: .medium))
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .truncationMode(.tail)

                            Text(heroSubtitle)
                                .font(.system(size: 9.2, weight: .regular, design: .monospaced))
                                .foregroundColor(inkSoft)
                                .lineLimit(1)
                        }
                        .allowsHitTesting(false)
                        .accessibilityElement(children: .combine)

                        Spacer(minLength: 4)

                        QuietIconButton(
                            systemName: "arrow.up.left.and.arrow.down.right",
                            help: SatieL10n.string("popover.open_studio_help"),
                            action: onOpenStudio
                        )
                        .accessibilityLabel(SatieL10n.string("popover.open_studio_a11y"))
                    }
                    .padding(.horizontal, 13)
                    .padding(.top, 11)

                    Spacer()

                }
            }
            .frame(height: 192)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(hairSoft, lineWidth: 1)
            )
            .onChange(of: state.preset) { _, _ in
                guard !reduceMotion else { return }
                presetTransitionVeil = 0.55
                withAnimation(.easeOut(duration: 0.26)) {
                    presetTransitionVeil = 0.0
                }
            }

            // 2. Five Iconic Circular Geometric Soundscape Worlds (FOCUS · PULSE · RAIN · STILL · NIGHT)
            HStack(spacing: 0) {
                ForEach(FocusSoundscape.allCases) { mode in
                    let isSelected = (state.focusMode == mode)
                    let isActive = state.isFocusPlaying && (state.focusMode == mode)
                    Button {
                        if isActive {
                            state.stopFocusSound()
                        } else {
                            state.toggleFocusSound(mode)
                        }
                    } label: {
                        VStack(spacing: 5) {
                            SoundscapeGlyph(mode: mode, isActive: isActive, isSelected: isSelected, size: 38)
                            Text(mode.shortLabel)
                                .font(.system(size: 8.6, weight: isActive ? .semibold : .regular, design: .monospaced))
                                .foregroundColor(isActive ? .white : (isSelected ? inkSoft : inkDim))
                                .tracking(0.4)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(MacBraunPressButtonStyle(pressedScale: 0.92, reduceMotion: reduceMotion))
                    .help("\(mode.title) — \(mode.subtitle)")
                    .accessibilityLabel("\(mode.title), \(mode.subtitle)")
                    .accessibilityHint(isActive ? SatieL10n.string("popover.press_to_pause") : SatieL10n.string("popover.press_to_play"))
                    .accessibilityAddTraits(isActive ? [.isSelected] : [])
                }
            }
            .padding(.top, 1)

            // 3. Pure Dead-Center Play / Pause + One Consolidated Options Button
            HStack(spacing: 16) {
                // Left wing: live timer pill ONLY when a sleep timer is counting down
                HStack(spacing: 10) {
                    if let countdown = compactCountdown {
                        Button {
                            toggleOptions()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "timer")
                                    .font(.system(size: 10.5, weight: .medium))
                                Text(countdown)
                                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .background(Color.white.opacity(0.11))
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(hairSoft, lineWidth: 1))
                        }
                        .buttonStyle(MacBraunPressButtonStyle(pressedScale: 0.94, reduceMotion: reduceMotion))
                        .help(SatieL10n.string("popover.timer_help"))
                        .accessibilityLabel(SatieL10n.format("common.timer_remaining_a11y", countdown))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)

                // Hero High-Contrast White Play / Pause Circle (100% dead-center beneath center glyph)
                Button {
                    state.togglePlayOrStartFocus()
                } label: {
                    Image(systemName: heroPlayIcon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.black)
                        .offset(x: heroPlayIcon == "play.fill" ? 1.5 : 0)
                        .frame(width: 46, height: 46)
                        .background(Color.white)
                        .clipShape(Circle())
                        .shadow(color: Color.white.opacity(state.isFocusPlaying ? 0.22 : 0.06), radius: 14)
                }
                .buttonStyle(MacBraunPressButtonStyle(pressedScale: 0.91, reduceMotion: reduceMotion))
                .help(state.isFocusPlaying ? SatieL10n.format("common.pause_mode_space", state.focusMode.title) : SatieL10n.format("common.play_mode_space", state.focusMode.title))
                .accessibilityLabel(state.isFocusPlaying ? SatieL10n.format("common.pause_mode", state.focusMode.title) : SatieL10n.format("common.play_mode", state.focusMode.title))

                // Right wing: One consolidated Options button (plus mute indicator only when Mac is muted)
                HStack(spacing: 10) {
                    CircularControlButton(
                        systemName: "slider.horizontal.3",
                        isActive: showOptions,
                        hasIndicatorDot: state.flowMinutes > 0,
                        reduceMotion: reduceMotion,
                        help: SatieL10n.string("popover.options")
                    ) {
                        toggleOptions()
                    }
                    .accessibilityLabel(SatieL10n.string("popover.options"))

                    if state.isSystemMuted {
                        CircularControlButton(
                            systemName: "speaker.slash.fill",
                            isActive: true,
                            tintWarning: true,
                            reduceMotion: reduceMotion,
                            help: SatieL10n.string("popover.unmute_mac")
                        ) {
                            state.toggleSystemMute()
                        }
                        .accessibilityLabel(SatieL10n.string("popover.unmute_mac"))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 2)

            // 4. Inline Volume Hairline (always 1 drag away when playing and options drawer is closed)
            if state.isFocusPlaying && !showOptions {
                volumeSliderRow
                    .padding(.horizontal, 4)
            }

            // 5. One Consolidated Options Drawer
            if showOptions {
                optionsDrawer
                    .transition(.opacity)
            }

            // Notch hint only when status bar icon is genuinely hidden behind the camera notch
            if state.isStatusItemBehindNotch {
                Text(SatieL10n.string("popover.notch_hint"))
                    .font(.system(size: 8.8, design: .monospaced))
                    .foregroundColor(inkDim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .frame(width: 392)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(red: 0.032, green: 0.036, blue: 0.044))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(hair, lineWidth: 1)
        )
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { newHeight in
            onContentHeightChange?(newHeight)
        }
    }

    // MARK: - Consolidated Options Drawer (Timer + Background Noise + Visual + Volume + Utility Footer)

    private var optionsDrawer: some View {
        VStack(spacing: 12) {
            // Focus / Sleep Timer
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(SatieL10n.string("options.timer"))
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(inkSoft)
                    Spacer()
                    Text(timerStatusLabel)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(state.flowMinutes > 0 ? inkSoft : inkDim)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                HStack(spacing: 4) {
                    ForEach(timerPresets, id: \.self) { mins in
                        let on = state.flowMinutes == mins
                        Button {
                            state.setFlowMinutes(mins)
                            state.performHaptic()
                        } label: {
                            Text(mins == 0 ? "∞" : SatieL10n.format("common.minutes_short", mins))
                                .font(.system(size: 10, weight: on ? .semibold : .regular, design: .monospaced))
                                .foregroundColor(on ? .black : inkSoft)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .frame(maxWidth: .infinity)
                                .frame(height: 25)
                                .background(on ? Color.white : Color.white.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(MacBraunPressButtonStyle(pressedScale: 0.95, reduceMotion: reduceMotion))
                        .accessibilityLabel(mins == 0 ? SatieL10n.string("common.timer_no_limit_a11y") : SatieL10n.format("common.timer_minutes_a11y", mins))
                        .accessibilityAddTraits(on ? [.isSelected] : [])
                    }
                }
            }

            Divider().background(hairSoft)

            volumeSliderRow

            // Quiet 1-line utility footer
            HStack(spacing: 10) {
                Button(SatieL10n.string("options.footer_mini_hud")) { onOpenMiniHUD() }
                    .buttonStyle(QuietTextLinkStyle())
                Button(SatieL10n.string("options.footer_fullscreen")) { onOpenFullscreen() }
                    .buttonStyle(QuietTextLinkStyle())
                Button(SatieL10n.string("options.footer_privacy")) {
                    if let privacyPolicyURL = URL(string: "https://strangechances.com/satie/privacy/") {
                        NSWorkspace.shared.open(privacyPolicyURL)
                    }
                }
                .buttonStyle(QuietTextLinkStyle())
                Spacer()
                Button(SatieL10n.string("options.footer_quit")) { onQuit() }
                    .buttonStyle(QuietTextLinkStyle())
            }
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.top, 2)
        }
        .padding(12)
        .background(Color.white.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.11), lineWidth: 1)
        )
    }

    private func visualOptionChip(label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: selected ? .semibold : .regular))
                .foregroundColor(selected ? .black : inkSoft)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .background(selected ? Color.white : Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(MacBraunPressButtonStyle(pressedScale: 0.95, reduceMotion: reduceMotion))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var volumeSliderRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.wave.2")
                .font(.system(size: 9.5))
                .foregroundColor(inkDim)
                .frame(width: 12)
            Slider(
                value: Binding(
                    get: { Double(state.focusVolume) },
                    set: { state.focusVolume = Float($0) }
                ),
                in: 0.05...1.0
            )
            .controlSize(.mini)
            .tint(.white)
            Text("\(Int(round(state.focusVolume * 100)))%")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(inkDim)
                .frame(minWidth: 32, alignment: .trailing)
        }
    }

    // MARK: - Helpers

    private func toggleOptions() {
        state.performHaptic()
        showOptions.toggle()
        DispatchQueue.main.async {
            onRequestResize?()
        }
    }

    private var timerStatusLabel: String {
        if let countdown = compactCountdown {
            return SatieL10n.format("common.minutes_remaining", countdown)
        }
        return state.flowMinutes > 0
            ? SatieL10n.format("common.fades_after_minutes", state.flowMinutes)
            : SatieL10n.string("common.no_limit")
    }

    private var heroTitle: String {
        state.focusMode.title
    }

    private var heroSubtitle: String {
        state.focusMode.subtitle.uppercased()
    }

    private var heroPlayIcon: String {
        state.isFocusPlaying ? "pause.fill" : "play.fill"
    }

    private var soundscapeAuraColor: Color {
        guard state.isFocusPlaying else {
            return Color(red: 0.72, green: 0.80, blue: 0.92)
        }
        switch state.focusMode {
        case .focus: return Color(red: 1.00, green: 0.78, blue: 0.52) // Warm cedar tungsten
        case .pulse: return Color(red: 0.62, green: 0.78, blue: 1.00) // Cool architectural indigo
        case .rain:  return Color(red: 0.52, green: 0.82, blue: 0.84) // Kyoto rain sea-glass
        case .drift: return Color(red: 0.92, green: 0.84, blue: 0.74) // Nocturnal lunar pearl
        case .still: return Color(red: 0.78, green: 0.82, blue: 0.88) // Pure obsidian mist
        case .dive:  return Color(red: 0.62, green: 0.88, blue: 0.94) // Iridescent opalescent prism
        }
    }

    private var compactCountdown: String? {
        guard state.isFocusPlaying, let rem = state.flowRemainingSeconds else { return nil }
        let sec = max(0, Int(ceil(rem)))
        return String(format: "%d:%02d", sec / 60, sec % 60)
    }
}

// MARK: - Editorial Button Chrome

private struct QuietIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(Color.white.opacity(hovered ? 0.95 : 0.48))
                .frame(width: 24, height: 24)
                .background(Color.white.opacity(hovered ? 0.12 : 0.04))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}

private struct CircularControlButton: View {
    let systemName: String
    let isActive: Bool
    var hasIndicatorDot: Bool = false
    var tintWarning: Bool = false
    var reduceMotion: Bool = false
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: systemName)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(tintWarning ? Color(red: 1.0, green: 0.62, blue: 0.56) : (isActive ? .black : Color.white.opacity(0.76)))
                    .frame(width: 34, height: 34)
                    .background(isActive && !tintWarning ? Color.white : Color.white.opacity(0.06))
                    .clipShape(Circle())
                    .overlay(Circle().stroke(isActive ? Color.clear : Color.white.opacity(0.10), lineWidth: 1))

                if hasIndicatorDot && !isActive {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 5, height: 5)
                        .offset(x: -2, y: 2)
                }
            }
        }
        .buttonStyle(MacBraunPressButtonStyle(pressedScale: 0.92, reduceMotion: reduceMotion))
        .help(help)
    }
}

struct HairlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10.5, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Color.white.opacity(configuration.isPressed ? 0.14 : 0.05))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 1))
    }
}

struct HairlineIconButtonStyle: ButtonStyle {
    var prominent: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.white)
            .background(Color.white.opacity(configuration.isPressed ? 0.18 : (prominent ? 0.10 : 0.04)))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.white.opacity(prominent ? 0.34 : 0.18), lineWidth: 1))
    }
}

private struct QuietTextLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 8.8, weight: .medium, design: .monospaced))
            .tracking(0.6)
            .foregroundColor(Color.white.opacity(configuration.isPressed ? 0.95 : 0.44))
            .contentShape(Rectangle())
    }
}
