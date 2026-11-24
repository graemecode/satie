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

    @State private var showOptions: Bool = false
    @State private var visualToastLabel: String? = nil
    @State private var visualToastTask: Task<Void, Never>? = nil
    @State private var presetTransitionVeil: Double = 0.0

    private let timerPresets: [Int] = [0, 15, 25, 45, 60, 90]

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

                // Click stage to quietly cycle visuals (zero chrome at rest, brief fading badge)
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        let all = VisualPreset.allCases
                        let next = all[(state.preset.rawValue + 1) % all.count]
                        state.preset = next
                        state.performHaptic()
                        flashVisualToast(next.cleanName.uppercased())
                    }

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
                            help: "Open Studio Visualizer (⌘F Fullscreen · ⌘M Mini HUD)",
                            action: onOpenStudio
                        )
                        .accessibilityLabel("Open Studio Visualizer")
                    }
                    .padding(.horizontal, 13)
                    .padding(.top, 11)

                    Spacer()

                    if let label = visualToastLabel {
                        Text(label)
                            .font(.system(size: 9.0, weight: .semibold, design: .monospaced))
                            .tracking(0.9)
                            .foregroundColor(Color.white.opacity(0.88))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background(Color.black.opacity(0.58))
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(hair, lineWidth: 0.75))
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
                                .tracking(0.5)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(MacBraunPressButtonStyle(pressedScale: 0.92, reduceMotion: reduceMotion))
                    .help("\(mode.title) — \(mode.subtitle)")
                    .accessibilityLabel("\(mode.title), \(mode.subtitle)")
                    .accessibilityHint(isActive ? "Press to pause" : "Press to play")
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
                        .help("Adjust or clear sleep timer")
                        .accessibilityLabel("Sleep timer, \(countdown) remaining")
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
                .help(state.isFocusPlaying ? "Pause \(state.focusMode.title) (Space)" : "Play \(state.focusMode.title) (Space)")
                .accessibilityLabel(state.isFocusPlaying ? "Pause \(state.focusMode.title)" : "Play \(state.focusMode.title)")

                // Right wing: One consolidated Options button (plus mute indicator only when Mac is muted)
                HStack(spacing: 10) {
                    CircularControlButton(
                        systemName: "slider.horizontal.3",
                        isActive: showOptions,
                        hasIndicatorDot: state.maskingBed != .off || state.flowMinutes > 0 || !state.visualFollowsSoundscape,
                        reduceMotion: reduceMotion,
                        help: "Options (Timer, Background noise, Visual)"
                    ) {
                        toggleOptions()
                    }
                    .accessibilityLabel("Options")

                    if state.isSystemMuted {
                        CircularControlButton(
                            systemName: "speaker.slash.fill",
                            isActive: true,
                            tintWarning: true,
                            reduceMotion: reduceMotion,
                            help: "Unmute Mac audio"
                        ) {
                            state.toggleSystemMute()
                        }
                        .accessibilityLabel("Unmute Mac audio")
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

    // MARK: - Consolidated Options Drawer (Timer + Background Noise + Visual + Volume + Utility Footer)

    private var optionsDrawer: some View {
        VStack(spacing: 12) {
            // Focus / Sleep Timer
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("TIMER")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(inkSoft)
                    Spacer()
                    Text(timerStatusLabel)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(state.flowMinutes > 0 ? inkSoft : inkDim)
                }

                HStack(spacing: 4) {
                    ForEach(timerPresets, id: \.self) { mins in
                        let on = state.flowMinutes == mins
                        Button {
                            state.setFlowMinutes(mins)
                            state.performHaptic()
                        } label: {
                            Text(mins == 0 ? "∞" : "\(mins)m")
                                .font(.system(size: 10, weight: on ? .semibold : .regular, design: .monospaced))
                                .foregroundColor(on ? .black : inkSoft)
                                .frame(maxWidth: .infinity)
                                .frame(height: 25)
                                .background(on ? Color.white : Color.white.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(MacBraunPressButtonStyle(pressedScale: 0.95, reduceMotion: reduceMotion))
                        .accessibilityLabel(mins == 0 ? "No timer limit" : "\(mins) minute timer")
                        .accessibilityAddTraits(on ? [.isSelected] : [])
                    }
                }
            }

            // Optional Background Noise Layer
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("BACKGROUND NOISE")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(inkSoft)
                    Spacer()
                    Text("LAYER UNDER ANY MODE")
                        .font(.system(size: 8.5, design: .monospaced))
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
                        .buttonStyle(MacBraunPressButtonStyle(pressedScale: 0.95, reduceMotion: reduceMotion))
                        .accessibilityAddTraits(on ? [.isSelected] : [])
                    }
                }
            }

            // Visual World Pairing / Override (Auto by default; click stage anytime)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("VISUAL")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(inkSoft)
                    Spacer()
                    Text(state.visualFollowsSoundscape ? "PAIRED · \(state.preset.cleanName.uppercased())" : "PINNED · \(state.preset.cleanName.uppercased())")
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundColor(inkDim)
                }

                visualOptionChip(label: "Auto (Paired to Sound)", selected: state.visualFollowsSoundscape) {
                    state.setVisualOverride(nil)
                }

                let cols = Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)
                LazyVGrid(columns: cols, spacing: 4) {
                    ForEach(VisualPreset.allCases) { p in
                        visualOptionChip(
                            label: p.cleanName,
                            selected: !state.visualFollowsSoundscape && state.preset == p
                        ) {
                            state.setVisualOverride(p)
                        }
                    }
                }
            }

            if state.preset == .phosphor {
                HStack {
                    Text("CRT PHOSPHOR")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(inkSoft)
                    Spacer()
                    HStack(spacing: 4) {
                        ForEach([(false, "P31 Emerald"), (true, "P39 Amber")], id: \.0) { isAmber, label in
                            let on = state.amberPhosphor == isAmber
                            Button {
                                state.amberPhosphor = isAmber
                                state.performHaptic()
                            } label: {
                                Text(label)
                                    .font(.system(size: 9.5, weight: on ? .semibold : .regular, design: .monospaced))
                                    .foregroundColor(on ? .black : inkSoft)
                                    .padding(.horizontal, 8)
                                    .frame(height: 22)
                                    .background(on ? Color.white : Color.white.opacity(0.05))
                                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            }
                            .buttonStyle(MacBraunPressButtonStyle(pressedScale: 0.95, reduceMotion: reduceMotion))
                            .accessibilityAddTraits(on ? [.isSelected] : [])
                        }
                    }
                }
            }

            Divider().background(hairSoft)

            volumeSliderRow

            // Quiet 1-line utility footer
            HStack(spacing: 12) {
                Button("MINI HUD") { onOpenMiniHUD() }
                    .buttonStyle(QuietTextLinkStyle())
                Button("FULLSCREEN") { onOpenFullscreen() }
                    .buttonStyle(QuietTextLinkStyle())
                Button("PRIVACY") {
                    if let privacyPolicyURL = URL(string: "https://strangechances.com/satie/privacy/") {
                        NSWorkspace.shared.open(privacyPolicyURL)
                    }
                }
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

    private func visualOptionChip(label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: selected ? .semibold : .regular))
                .foregroundColor(selected ? .black : inkSoft)
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

    private func flashVisualToast(_ text: String) {
        visualToastTask?.cancel()
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            visualToastLabel = text
        }
        visualToastTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1300))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.32)) {
                visualToastLabel = nil
            }
        }
    }

    private var timerStatusLabel: String {
        if let countdown = compactCountdown {
            return "\(countdown) REMAINING"
        }
        return state.flowMinutes > 0 ? "FADES OUT AFTER \(state.flowMinutes)M" : "NO LIMIT"
    }

    private var heroTitle: String {
        state.focusMode.title
    }

    private var heroSubtitle: String {
        let base = state.focusMode.subtitle.uppercased()
        if state.isFocusPlaying && state.maskingBed != .off {
            return "\(base) · +\(state.maskingBed.label.uppercased())"
        }
        return base
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
