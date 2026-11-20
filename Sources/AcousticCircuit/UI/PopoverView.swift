import AcousticCore
import AppKit
import SwiftUI

private enum PopoverDrawer: Equatable {
    case none
    case timer
    case sculpt
}

struct PopoverView: View {
    @ObservedObject var state: AppState
    let onOpenMiniHUD: () -> Void
    let onOpenStudio: () -> Void
    let onOpenFullscreen: () -> Void
    let onQuit: () -> Void
    var onRequestResize: (() -> Void)? = nil

    @State private var activeDrawer: PopoverDrawer = .none
    @State private var presetWhisper: String? = nil

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

                // Whisper-subtle atmospheric light temperature matched to the active soundscape
                RadialGradient(
                    colors: [soundscapeAuraColor.opacity(0.22), Color.clear],
                    center: .center,
                    startRadius: 16,
                    endRadius: 185
                )
                .blendMode(.screen)
                .animation(.easeInOut(duration: 0.9), value: state.focusMode)
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

                // Tap anywhere on the stage to cycle 120Hz Metal visual modes effortlessly
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        let all = VisualPreset.allCases
                        let next = all[(state.preset.rawValue + 1) % all.count]
                        state.preset = next
                        state.performHaptic()
                        withAnimation(.easeOut(duration: 0.16)) {
                            presetWhisper = next.shortTitle.uppercased()
                        }
                        let currentLabel = next.shortTitle.uppercased()
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(1100))
                            if presetWhisper == currentLabel {
                                withAnimation(.easeOut(duration: 0.35)) {
                                    presetWhisper = nil
                                }
                            }
                        }
                    }

                VStack(spacing: 0) {
                    // Floating Header: Title + Biological Phase on left, ONE quiet Studio expand button on right
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

                        Spacer(minLength: 4)

                        QuietIconButton(
                            systemName: "arrow.up.left.and.arrow.down.right",
                            help: "Open Studio Visualizer (⌘F Fullscreen · ⌘M Mini HUD)",
                            action: onOpenStudio
                        )
                    }
                    .padding(.horizontal, 13)
                    .padding(.top, 11)

                    Spacer()

                    if let whisper = presetWhisper {
                        Text(whisper)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundColor(Color.white.opacity(0.78))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.55))
                            .clipShape(Capsule())
                            .padding(.bottom, 10)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(height: 192)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(hairSoft, lineWidth: 1)
            )

            // Permission banner if Core Audio Process Tap needs approval
            if case .permissionOrError = state.tapStatus {
                HStack(spacing: 8) {
                    Text("Enable System Audio Recording for auto-ducking & live visuals.")
                        .font(.system(size: 10))
                        .foregroundColor(Color(red: 1.0, green: 0.86, blue: 0.62))
                        .lineLimit(2)
                    Spacer()
                    Button("Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(HairlineButtonStyle())
                    Button("Retry") {
                        state.retryAudioTap()
                    }
                    .buttonStyle(HairlineButtonStyle())
                }
                .padding(8)
                .background(Color.orange.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.orange.opacity(0.35), lineWidth: 1))
            }

            // 2. Five Iconic Circular Geometric Soundscape Glyphs (Focus · Pulse · Rain · Drift · Still)
            HStack(spacing: 0) {
                ForEach(FocusSoundscape.allCases) { mode in
                    let isSelected = (state.focusMode == mode) && !isExternalAudioVisualizing
                    let isActive = state.isFocusPlaying && (state.focusMode == mode)
                    Button {
                        if isActive {
                            state.stopFocusSound()
                        } else {
                            state.toggleFocusSound(mode)
                        }
                    } label: {
                        VStack(spacing: 5) {
                            SoundscapeGlyph(mode: mode, isActive: isActive, size: 38)
                                .overlay(
                                    Circle()
                                        .stroke(isSelected && !isActive ? Color.white.opacity(0.55) : Color.clear, lineWidth: 1)
                                        .frame(width: 34, height: 34)
                                )
                            Text(mode.shortLabel)
                                .font(.system(size: 8.6, weight: isActive ? .semibold : .regular, design: .monospaced))
                                .foregroundColor(isActive ? .white : (isSelected ? inkSoft : inkDim))
                                .tracking(0.5)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(mode.title) — \(mode.subtitle)")
                }
            }
            .padding(.top, 1)

            // 3. Dead-Center Braun Transport Triad: [⏱ Timer]   [▶/⏸ Hero White]   [≡ Sculpt]
            HStack(spacing: 16) {
                // Left wing (right-aligned so countdown pill expands leftward without shifting Play/Pause)
                HStack(spacing: 10) {
                    if !state.isFocusAudible && state.metadata.canControlPlayback {
                        CircularControlButton(systemName: "backward.fill", isActive: false, help: "Previous Track") {
                            state.media.previousTrack()
                        }
                    } else {
                        Button {
                            toggleDrawer(.timer)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "timer")
                                    .font(.system(size: 12.5, weight: .medium))
                                if let countdown = compactCountdown {
                                    Text(countdown)
                                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                }
                            }
                            .foregroundColor(activeDrawer == .timer ? .black : (state.flowMinutes > 0 ? .white : inkSoft))
                            .padding(.horizontal, compactCountdown != nil ? 10 : 0)
                            .frame(minWidth: 34, minHeight: 34)
                            .frame(height: 34)
                            .background(activeDrawer == .timer ? Color.white : Color.white.opacity(state.flowMinutes > 0 ? 0.13 : 0.06))
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(activeDrawer == .timer ? Color.clear : hairSoft, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .help("Focus Timer & Circadian Curve")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)

                // Hero High-Contrast White Play / Pause Circle (100% dead-center beneath center glyph)
                Button {
                    if state.isFocusPlaying {
                        state.performHaptic()
                        state.stopFocusSound()
                    } else if state.metadata.canControlPlayback && !state.snapshot.isSilent {
                        state.media.playPause()
                    } else {
                        state.toggleFocusSound(state.focusMode)
                    }
                } label: {
                    Image(systemName: heroPlayIcon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.black)
                        .offset(x: heroPlayIcon == "play.fill" ? 1.5 : 0)
                        .frame(width: 46, height: 46)
                        .background(Color.white)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help(state.isFocusPlaying ? "Pause \(state.focusMode.title) (Space)" : "Play \(state.focusMode.title) (Space)")

                // Right wing (left-aligned to mirror left wing)
                HStack(spacing: 10) {
                    if !state.isFocusAudible && state.metadata.canControlPlayback {
                        CircularControlButton(systemName: "forward.fill", isActive: false, help: "Next Track") {
                            state.media.nextTrack()
                        }
                    } else {
                        CircularControlButton(
                            systemName: "slider.horizontal.3",
                            isActive: activeDrawer == .sculpt,
                            hasIndicatorDot: state.maskingBed != .off,
                            help: "Sound options (Background noise, Pause for calls)"
                        ) {
                            toggleDrawer(.sculpt)
                        }
                    }

                    if state.isSystemMuted {
                        CircularControlButton(
                            systemName: "speaker.slash.fill",
                            isActive: true,
                            tintWarning: true,
                            help: "Unmute Mac audio"
                        ) {
                            state.toggleSystemMute()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 2)

            // 4. Inline Volume Hairline (always 1 drag away when playing and sculptor drawer is closed)
            if state.isFocusPlaying && activeDrawer != .sculpt {
                volumeSliderRow
                    .padding(.horizontal, 4)
            }

            // 5. Expandable Contextual Drawer: Braun/Leica Radial Timer OR Live Sound Sculptor
            if activeDrawer == .timer {
                RadialTimerView(state: state) {
                    toggleDrawer(.none)
                }
                .transition(.opacity)
            } else if activeDrawer == .sculpt {
                liveSculptorDrawer
                    .transition(.opacity)
            }

            // Notch hint only when status bar icon is genuinely hidden behind the camera notch
            if state.isStatusItemBehindNotch {
                Text("⌥⌘S summon · ⌥⌘Space play/stop · ⌘-drag icon right of notch")
                    .font(.system(size: 8.8, design: .monospaced))
                    .foregroundColor(inkDim)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .frame(width: 392)
        .background(Color(red: 0.032, green: 0.036, blue: 0.044))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(hair, lineWidth: 1)
        )
    }

    // MARK: - Sound Options Drawer (Background Noise + Pause for Calls + Volume + Window Actions)

    private var liveSculptorDrawer: some View {
        VStack(spacing: 11) {
            // Optional Rain or Brown Noise layer underneath any soundscape
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("BACKGROUND NOISE")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(inkSoft)
                    Text("Layer gentle rain or brown noise under any mode")
                        .font(.system(size: 9.5))
                        .foregroundColor(inkDim)
                }

                HStack(spacing: 4) {
                    ForEach(MaskingBed.allCases) { bed in
                        let on = state.maskingBed == bed
                        Button {
                            state.maskingBed = bed
                            state.performHaptic()
                        } label: {
                            Text(bed.label)
                                .font(.system(size: 10, weight: on ? .semibold : .regular))
                                .foregroundColor(on ? .black : inkSoft)
                                .frame(maxWidth: .infinity)
                                .frame(height: 25)
                                .background(on ? Color.white : Color.white.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Auto-Ducking toggle
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("PAUSE FOR CALLS & MUSIC")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(inkSoft)
                    Text("Steps aside automatically · ignores notifications")
                        .font(.system(size: 9.5))
                        .foregroundColor(inkDim)
                }
                Spacer()
                Toggle("", isOn: $state.autoDuckEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }

            Divider().background(hairSoft)

            volumeSliderRow

            // Quiet 1-line utility footer (keeps main face pure while leaving every window/quit action 1 click away)
            HStack(spacing: 12) {
                Button("MINI HUD") { onOpenMiniHUD() }
                    .buttonStyle(QuietTextLinkStyle())
                Button("FULLSCREEN") { onOpenFullscreen() }
                    .buttonStyle(QuietTextLinkStyle())
                Spacer()
                Button("QUIT") { onQuit() }
                    .buttonStyle(QuietTextLinkStyle())
            }
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

    private var volumeSliderRow: some View {
        HStack(spacing: 8) {
            Image(systemName: state.isAutoDucked ? "speaker.slash" : "speaker.wave.2")
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
            Text(state.isAutoDucked ? "DUCKED" : "\(Int(round(state.focusVolume * 100)))%")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(inkDim)
                .frame(minWidth: 32, alignment: .trailing)
        }
    }

    // MARK: - Helpers

    private func toggleDrawer(_ target: PopoverDrawer) {
        state.performHaptic()
        activeDrawer = (activeDrawer == target) ? .none : target
        DispatchQueue.main.async {
            onRequestResize?()
        }
    }

    private var isShowingVerifiedExternalTrack: Bool {
        !state.isFocusPlaying && state.metadata.canControlPlayback && state.metadata.isPlaying
    }

    private var isExternalAudioVisualizing: Bool {
        !state.isFocusPlaying && !state.snapshot.isSilent && !isShowingVerifiedExternalTrack
    }

    private var heroTitle: String {
        if isShowingVerifiedExternalTrack {
            return state.metadata.title
        }
        if isExternalAudioVisualizing {
            return "Listening"
        }
        return state.focusMode.title
    }

    private var heroSubtitle: String {
        if isShowingVerifiedExternalTrack {
            let artist = state.metadata.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
            return artist.isEmpty ? state.metadata.sourceApp : "\(state.metadata.sourceApp) · \(artist.uppercased())"
        }
        if isExternalAudioVisualizing {
            return "MAC AUDIO ACTIVE"
        }
        if state.isFocusPlaying && state.isAutoDucked {
            return "PAUSED FOR MAC AUDIO"
        }
        let base = state.focusMode.subtitle.uppercased()
        if state.isFocusPlaying && state.maskingBed != .off {
            return "\(base) · +\(state.maskingBed.label.uppercased())"
        }
        return base
    }

    private var heroPlayIcon: String {
        if state.isFocusPlaying { return "pause.fill" }
        if state.metadata.canControlPlayback && state.metadata.isPlaying && !state.snapshot.isSilent {
            return "pause.fill"
        }
        return "play.fill"
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
        .buttonStyle(.plain)
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
