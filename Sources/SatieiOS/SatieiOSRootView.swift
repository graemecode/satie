import AcousticCore
import AVKit
import SwiftUI

private struct BraunPressButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.93
    var reduceMotion: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect((configuration.isPressed && !reduceMotion) ? pressedScale : 1.0)
            .opacity(configuration.isPressed ? 0.84 : 1.0)
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

struct SatieiOSRootView: View {
    @ObservedObject var state: SatieiOSState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showOptions: Bool = false
    @State private var immersionMode: Bool = false
    @State private var showImmersionHint: Bool = false
    @State private var immersionHintTask: Task<Void, Never>? = nil
    @State private var worldToastLabel: String? = nil
    @State private var worldToastTask: Task<Void, Never>? = nil
    @State private var presetTransitionVeil: Double = 0.0
    /// Fade length for entering or leaving Immersion Mode: quick when tapped, slow when it happens on its own.
    @State private var immersionFade: Double = 0.28
    @State private var autoImmersionTask: Task<Void, Never>? = nil
    @State private var lastInteraction: Date = .distantPast

    /// After this long without a touch while playing, the controls fade away and the visual fills the screen.
    private let autoImmersionDelay: Duration = .seconds(10)

    private let timerPresets: [Int] = [0, 25, 45, 90]
    private let hair = Color.white.opacity(0.14)
    private let hairSoft = Color.white.opacity(0.09)
    private let inkSoft = Color.white.opacity(0.74)
    private let inkDim = Color.white.opacity(0.46)

    private var isCompactLandscape: Bool {
        verticalSizeClass == .compact
    }

    private var isRegularCanvas: Bool {
        horizontalSizeClass == .regular && verticalSizeClass == .regular
    }

    private var contentMaxWidth: CGFloat {
        if isCompactLandscape { return 720 }
        if isRegularCanvas { return 580 }
        return 430
    }

    var body: some View {
        ZStack {
            // 1. Full-bleed edge-to-edge Metal OLED stage
            iOSMetalVisualizerRepresentable(isActive: state.isForeground, preset: state.preset)
                .ignoresSafeArea()

            // Subtle dissolve veil on visual preset switch so transitions glide instead of snapping
            Color.black
                .opacity(presetTransitionVeil)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            // Soundscape-matched whisper-subtle atmospheric light aura
            RadialGradient(
                colors: [soundscapeAuraColor.opacity(0.20), Color.clear],
                center: UnitPoint(x: 0.5, y: 0.44),
                startRadius: 24,
                endRadius: isRegularCanvas ? 440 : 340
            )
            .blendMode(.screen)
            .ignoresSafeArea()
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.9), value: state.focusMode)
            .allowsHitTesting(false)

            // Soft top & bottom vignettes so chrome floats effortlessly over bright peaks
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [Color.black.opacity(0.68), Color.black.opacity(0.0)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: isCompactLandscape ? 92 : 150)

                Spacer()

                LinearGradient(
                    colors: [Color.black.opacity(0.0), Color.black.opacity(0.84)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: isCompactLandscape ? 112 : 270)
            }
            .ignoresSafeArea()
            .opacity(immersionMode ? 0.12 : 1.0)
            .animation(.easeInOut(duration: immersionFade), value: immersionMode)
            .allowsHitTesting(false)

            // 2. Floating Editorial HUD (hides cleanly in Immersion Mode)
            VStack(spacing: 0) {
                // Top Header: Title + Acoustic Palette on left, quiet AirPlay picker on right
                headerBar
                    .frame(maxWidth: contentMaxWidth)
                    .padding(.horizontal, 22)
                    .padding(.top, isCompactLandscape ? 10 : (isRegularCanvas ? 22 : 14))

                // Interactive open stage surface: tap for Immersion Mode, swipe left/right to change soundscape.
                // Scoped to the open canvas (not behind dock buttons) so a 2px mis-tap near a glyph never hides the HUD.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        toggleImmersion(true)
                    }
                    .gesture(stageSwipeGesture)
                    .overlay(alignment: .bottom) {
                        if let label = worldToastLabel {
                            Text(label)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .tracking(1.0)
                                .foregroundColor(Color.white.opacity(0.86))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(Color.black.opacity(0.56))
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                                .overlay(Capsule().stroke(hair, lineWidth: 0.8))
                                .padding(.bottom, 16)
                                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityHidden(true)

                // Bottom Tactile Control Dock: pure Braun minimalism (6 soundscape worlds + Play/Pause + Options)
                if isCompactLandscape {
                    compactLandscapeDock
                        .frame(maxWidth: contentMaxWidth)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                } else {
                    portraitOrTabletDock
                        .frame(maxWidth: contentMaxWidth)
                        .padding(.horizontal, isRegularCanvas ? 20 : 14)
                        .padding(.bottom, isRegularCanvas ? 30 : 24)
                }
            }
            .opacity(immersionMode ? 0.0 : 1.0)
            .offset(y: immersionMode && !reduceMotion ? 10 : 0)
            .animation(.easeInOut(duration: immersionFade), value: immersionMode)
            .allowsHitTesting(!immersionMode)

            // 3. Full-screen tap/swipe catcher ONLY while in Immersion Mode
            if immersionMode {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture {
                        toggleImmersion(false)
                    }
                    .gesture(stageSwipeGesture)
                    .overlay(alignment: .bottom) {
                        if let label = worldToastLabel {
                            Text(label)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .tracking(1.0)
                                .foregroundColor(Color.white.opacity(0.86))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(Color.black.opacity(0.56))
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                                .overlay(Capsule().stroke(hair, lineWidth: 0.8))
                                .padding(.bottom, 36)
                                .transition(.opacity)
                                .allowsHitTesting(false)
                        } else if showImmersionHint {
                            Text(SatieL10n.string("ios.tap_to_show_controls"))
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .tracking(0.8)
                                .foregroundColor(Color.white.opacity(0.76))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Color.black.opacity(0.55))
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                                .overlay(Capsule().stroke(hairSoft, lineWidth: 0.8))
                                .padding(.bottom, 36)
                                .transition(.opacity)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel(SatieL10n.string("ios.exit_immersion"))
                    .accessibilityHint(SatieL10n.string("ios.exit_immersion_hint"))
            }
        }
        .statusBarHidden(immersionMode)
        // Keep the screen on while it is being watched: on its side in a stand, or in Immersion Mode.
        .onAppear { syncScreenAwake() }
        .onChange(of: immersionMode) { _, entered in
            syncScreenAwake()
            if !entered { scheduleAutoImmersion() }
        }
        // Any touch postpones the automatic fade; it never blocks the touch itself.
        .simultaneousGesture(
            DragGesture(minimumDistance: 0).onChanged { _ in noteInteraction() }
        )
        .onChange(of: state.isFocusPlaying) { _, playing in
            if !playing && immersionMode {
                // Music stopped (paused elsewhere or the timer ended): bring the controls back.
                exitImmersion()
            }
            scheduleAutoImmersion()
        }
        .onChange(of: state.focusMode) { _, _ in scheduleAutoImmersion() }
        .onChange(of: showOptions) { _, _ in scheduleAutoImmersion() }
        .onChange(of: verticalSizeClass) { _, _ in syncScreenAwake() }
        .onChange(of: state.preset) { _, _ in
            guard !reduceMotion else { return }
            presetTransitionVeil = 0.55
            withAnimation(.easeOut(duration: 0.28)) {
                presetTransitionVeil = 0.0
            }
        }
        .sheet(isPresented: $showOptions) {
            optionsSheet
                .presentationDetents([
                    .height(250),
                    .large
                ])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color(red: 0.055, green: 0.062, blue: 0.078))
        }
    }

    // MARK: - Header & Docks

    private var headerBar: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(state.focusMode.title)
                    .font(.system(size: isCompactLandscape ? 22 : (isRegularCanvas ? 32 : 28), weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Text(heroSubtitle)
                    .font(.system(size: isCompactLandscape ? 9.5 : 10.5, weight: .regular, design: .monospaced))
                    .foregroundColor(inkSoft)
                    .tracking(0.6)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)

            Spacer()

            AirPlayRouteButton()
                .frame(width: 36, height: 36)
                .background(Color.white.opacity(0.07))
                .clipShape(Circle())
                .overlay(Circle().stroke(hairSoft, lineWidth: 1))
                .accessibilityLabel(SatieL10n.string("ios.airplay_a11y"))
        }
    }

    private var portraitOrTabletDock: some View {
        VStack(spacing: isRegularCanvas ? 24 : 22) {
            // Six Iconic Circular Geometric Soundscape Worlds (FOCUS · PULSE · RAIN · STILL · DIVE · NIGHT)
            HStack(spacing: 0) {
                ForEach(FocusSoundscape.allCases) { mode in
                    soundscapeButton(mode: mode, glyphSize: isRegularCanvas ? 52 : 44)
                }
            }

            // Dead-Center Play / Pause + One Consolidated Options Button
            HStack(spacing: 22) {
                HStack {
                    if let countdown = compactCountdown {
                        countdownPill(countdown)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)

                playPauseButton(diameter: isRegularCanvas ? 68 : 64, iconSize: 22)

                HStack {
                    optionsButton(diameter: 44, iconSize: 16)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 2)
        }
    }

    /// Single-row Braun desktop-instrument bar for iPhone landscape MagSafe desk-stand orientation.
    private var compactLandscapeDock: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                ForEach(FocusSoundscape.allCases) { mode in
                    soundscapeButton(mode: mode, glyphSize: 40)
                }
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 12) {
                if let countdown = compactCountdown {
                    countdownPill(countdown)
                }
                playPauseButton(diameter: 52, iconSize: 18)
                optionsButton(diameter: 40, iconSize: 15)
            }
        }
    }

    // MARK: - Controls

    private func soundscapeButton(mode: FocusSoundscape, glyphSize: CGFloat) -> some View {
        let isSelected = (state.focusMode == mode)
        let isActive = state.isFocusPlaying && (state.focusMode == mode)
        return Button {
            if isActive {
                state.stopFocusSound()
            } else {
                state.toggleFocusSound(mode)
            }
        } label: {
            VStack(spacing: isCompactLandscape ? 4 : 7) {
                SoundscapeGlyph(mode: mode, isActive: isActive, isSelected: isSelected, size: glyphSize)
                Text(mode.shortLabel)
                    .font(.system(size: isCompactLandscape ? 8.5 : 9.5, weight: isActive ? .semibold : .regular, design: .monospaced))
                    .foregroundColor(isActive ? .white : (isSelected ? inkSoft : inkDim))
                    .tracking(0.4)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(BraunPressButtonStyle(pressedScale: 0.92, reduceMotion: reduceMotion))
        .accessibilityLabel("\(mode.title), \(mode.subtitle)")
        .accessibilityHint(isActive ? SatieL10n.string("ios.double_tap_pause") : SatieL10n.string("ios.double_tap_play"))
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    private func playPauseButton(diameter: CGFloat, iconSize: CGFloat) -> some View {
        Button {
            state.togglePlayOrPause()
        } label: {
            Image(systemName: state.isFocusPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundColor(.black)
                .offset(x: state.isFocusPlaying ? 0 : 2)
                .frame(width: diameter, height: diameter)
                .background(Color.white)
                .clipShape(Circle())
                .shadow(color: Color.white.opacity(state.isFocusPlaying ? 0.24 : 0.08), radius: 18)
        }
        .buttonStyle(BraunPressButtonStyle(pressedScale: 0.91, reduceMotion: reduceMotion))
        .accessibilityLabel(state.isFocusPlaying ? SatieL10n.format("common.pause_mode", state.focusMode.title) : SatieL10n.format("common.play_mode", state.focusMode.title))
    }

    private func optionsButton(diameter: CGFloat, iconSize: CGFloat) -> some View {
        Button {
            state.performHaptic()
            showOptions = true
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: iconSize, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.84))
                    .frame(width: diameter, height: diameter)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
                    .overlay(Circle().stroke(hair, lineWidth: 1))

                if state.flowMinutes > 0 || state.mixWithOthers {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 6, height: 6)
                        .offset(x: -3, y: 3)
                }
            }
        }
        .buttonStyle(BraunPressButtonStyle(pressedScale: 0.92, reduceMotion: reduceMotion))
        .accessibilityLabel(SatieL10n.string("popover.options"))
    }

    private func countdownPill(_ countdown: String) -> some View {
        Button {
            state.performHaptic()
            showOptions = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "timer")
                    .font(.system(size: 12, weight: .medium))
                Text(countdown)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Color.white.opacity(0.12))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(hairSoft, lineWidth: 1))
        }
        .buttonStyle(BraunPressButtonStyle(pressedScale: 0.94, reduceMotion: reduceMotion))
        .accessibilityLabel(SatieL10n.format("common.timer_remaining_a11y", countdown))
    }

    private var stageSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 36, coordinateSpace: .local)
            .onEnded { value in
                if abs(value.translation.width) > abs(value.translation.height) * 1.4 {
                    state.stepFocusMode(forward: value.translation.width < 0)
                    flashWorldToast(state.focusMode.title.uppercased())
                }
            }
    }

    private func flashWorldToast(_ text: String) {
        worldToastTask?.cancel()
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            worldToastLabel = text
        }
        worldToastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.3))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.35)) {
                worldToastLabel = nil
            }
        }
    }

    private func syncScreenAwake() {
        state.wantsScreenAwake = immersionMode || isCompactLandscape
    }

    private func noteInteraction() {
        let now = Date()
        guard now.timeIntervalSince(lastInteraction) > 0.5 else { return }
        lastInteraction = now
        scheduleAutoImmersion()
    }

    /// Restart the countdown to Immersion Mode. It only runs while music plays and nothing else needs the controls.
    private func scheduleAutoImmersion() {
        autoImmersionTask?.cancel()
        guard state.isFocusPlaying, !immersionMode, !showOptions, !UIAccessibility.isVoiceOverRunning else { return }
        autoImmersionTask = Task { @MainActor in
            try? await Task.sleep(for: autoImmersionDelay)
            guard !Task.isCancelled, state.isFocusPlaying, state.isForeground, !immersionMode, !showOptions,
                  !UIAccessibility.isVoiceOverRunning else { return }
            immersionFade = 1.6
            withAnimation(.easeInOut(duration: 1.6)) {
                immersionMode = true
            }
        }
    }

    private func exitImmersion() {
        immersionHintTask?.cancel()
        immersionFade = 0.45
        withAnimation(.easeOut(duration: 0.45)) {
            immersionMode = false
            showImmersionHint = false
        }
    }

    private func toggleImmersion(_ enter: Bool) {
        state.performHaptic()
        immersionHintTask?.cancel()
        autoImmersionTask?.cancel()
        immersionFade = 0.28
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) {
            immersionMode = enter
            showImmersionHint = enter
        }
        if enter {
            immersionHintTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.8))
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.45)) {
                    showImmersionHint = false
                }
            }
        }
    }

    // MARK: - Consolidated Native Options Sheet

    private var optionsSheet: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                // Sleep / Focus Timer
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(SatieL10n.string("options.timer"))
                            .font(.caption2.monospaced().weight(.semibold))
                            .foregroundColor(inkSoft)
                            .tracking(0.8)
                        Spacer()
                        Text(timerStatusLabel)
                            .font(.caption2.monospaced().weight(.medium))
                            .foregroundColor(state.flowMinutes > 0 ? .white : inkDim)
                    }

                    HStack(spacing: 6) {
                        ForEach(timerPresets, id: \.self) { mins in
                            let on = state.flowMinutes == mins
                            Button {
                                state.setFlowMinutes(mins)
                                state.performHaptic()
                            } label: {
                                Text(mins == 0 ? "∞" : SatieL10n.format("common.minutes_short", mins))
                                    .font(.caption.monospaced().weight(on ? .semibold : .regular))
                                    .foregroundColor(on ? .black : inkSoft)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                                    .frame(maxWidth: .infinity)
                                    .frame(minHeight: 36)
                                    .background(on ? Color.white : Color.white.opacity(0.07))
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(BraunPressButtonStyle(pressedScale: 0.95, reduceMotion: reduceMotion))
                            .accessibilityLabel(mins == 0 ? SatieL10n.string("common.timer_no_limit_a11y") : SatieL10n.format("common.timer_minutes_a11y", mins))
                            .accessibilityAddTraits(on ? [.isSelected] : [])
                        }
                    }
                }

                Divider().overlay(hairSoft)

                Toggle(isOn: $state.mixWithOthers) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(SatieL10n.string("ios.mix_audio"))
                            .font(.caption2.monospaced().weight(.semibold))
                            .foregroundColor(inkSoft)
                            .tracking(0.8)
                        Text(SatieL10n.string("ios.mix_audio_desc"))
                            .font(.caption)
                            .foregroundColor(inkDim)
                    }
                }
                .tint(.white)

                Divider().overlay(hairSoft)

                HStack(spacing: 8) {
                    Spacer(minLength: 4)
                    if let privacyPolicyURL = URL(string: "https://strangechances.com/satie/privacy/") {
                        Link(SatieL10n.string("ios.privacy_policy"), destination: privacyPolicyURL)
                            .font(.caption.weight(.medium))
                            .foregroundColor(inkSoft)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 22)
            .padding(.top, 24)
            .padding(.bottom, 18)
        }
    }

    // MARK: - Helpers

    private var heroSubtitle: String {
        state.focusMode.subtitle.uppercased()
    }

    private var compactCountdown: String? {
        guard state.isFocusPlaying, let rem = state.flowRemainingSeconds else { return nil }
        let sec = max(0, Int(ceil(rem)))
        return String(format: "%d:%02d", sec / 60, sec % 60)
    }

    private var timerStatusLabel: String {
        if let countdown = compactCountdown {
            return SatieL10n.format("common.minutes_remaining", countdown)
        }
        return state.flowMinutes > 0
            ? SatieL10n.format("common.fades_after_minutes", state.flowMinutes)
            : SatieL10n.string("common.no_limit")
    }

    private var soundscapeAuraColor: Color {
        guard state.isFocusPlaying else {
            return Color(red: 0.72, green: 0.80, blue: 0.92)
        }
        switch state.focusMode {
        case .focus: return Color(red: 1.00, green: 0.78, blue: 0.52)
        case .pulse: return Color(red: 0.62, green: 0.78, blue: 1.00)
        case .rain:  return Color(red: 0.52, green: 0.82, blue: 0.84)
        case .still: return Color(red: 0.78, green: 0.82, blue: 0.88)
        case .dive:  return Color(red: 0.62, green: 0.88, blue: 0.94)
        case .drift: return Color(red: 0.92, green: 0.84, blue: 0.74)
        }
    }
}

private struct AirPlayRouteButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = UIColor.white.withAlphaComponent(0.75)
        picker.activeTintColor = .white
        picker.prioritizesVideoDevices = false
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
