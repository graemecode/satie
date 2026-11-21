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
    @State private var visualToastLabel: String? = nil
    @State private var visualToastTask: Task<Void, Never>? = nil
    @State private var presetTransitionVeil: Double = 0.0

    private let timerPresets: [Int] = [0, 15, 25, 45, 60, 90]
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
            .animation(.easeInOut(duration: 0.9), value: state.focusMode)
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
            .animation(.easeInOut(duration: 0.3), value: immersionMode)
            .allowsHitTesting(false)

            // 2. Floating Editorial HUD (hides cleanly in Immersion Mode)
            VStack(spacing: 0) {
                // Top Header: Title + Acoustic Palette on left, quiet AirPlay picker on right
                headerBar
                    .frame(maxWidth: contentMaxWidth)
                    .padding(.horizontal, 22)
                    .padding(.top, isCompactLandscape ? 10 : (isRegularCanvas ? 22 : 14))

                // Interactive open stage surface: tap for Immersion Mode, swipe left/right to explore visuals.
                // Scoped to the open canvas (not behind dock buttons) so a 2px mis-tap near a glyph never hides the HUD.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        toggleImmersion(true)
                    }
                    .gesture(stageSwipeGesture)
                    .overlay(alignment: .bottom) {
                        if let label = visualToastLabel {
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

                // Bottom Tactile Control Dock: pure Braun minimalism (5 soundscape worlds + Play/Pause + Options)
                if isCompactLandscape {
                    compactLandscapeDock
                        .frame(maxWidth: contentMaxWidth)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                } else {
                    portraitOrTabletDock
                        .frame(maxWidth: contentMaxWidth)
                        .padding(.horizontal, 20)
                        .padding(.bottom, isRegularCanvas ? 30 : 24)
                }
            }
            .opacity(immersionMode ? 0.0 : 1.0)
            .animation(.easeInOut(duration: 0.28), value: immersionMode)
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
                        if let label = visualToastLabel {
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
                            Text("TAP ANYWHERE TO SHOW CONTROLS")
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
                    .accessibilityLabel("Exit immersion mode")
                    .accessibilityHint("Double tap to show Satie controls")
            }
        }
        .statusBarHidden(immersionMode)
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
                    .height(state.preset == .phosphor ? 560 : 515),
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

                Text(heroSubtitle)
                    .font(.system(size: isCompactLandscape ? 9.5 : 10.5, weight: .regular, design: .monospaced))
                    .foregroundColor(inkSoft)
                    .tracking(0.6)
                    .lineLimit(1)
            }
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)

            Spacer()

            AirPlayRouteButton()
                .frame(width: 36, height: 36)
                .background(Color.white.opacity(0.07))
                .clipShape(Circle())
                .overlay(Circle().stroke(hairSoft, lineWidth: 1))
                .accessibilityLabel("Audio Output and AirPlay")
        }
    }

    private var portraitOrTabletDock: some View {
        VStack(spacing: isRegularCanvas ? 24 : 22) {
            // Five Iconic Circular Geometric Soundscape Worlds (FOCUS · PULSE · RAIN · STILL · NIGHT)
            HStack(spacing: 0) {
                ForEach(FocusSoundscape.allCases) { mode in
                    soundscapeButton(mode: mode, glyphSize: isRegularCanvas ? 52 : 48)
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
                    .tracking(0.6)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(BraunPressButtonStyle(pressedScale: 0.92, reduceMotion: reduceMotion))
        .accessibilityLabel("\(mode.title), \(mode.subtitle)")
        .accessibilityHint(isActive ? "Double tap to pause" : "Double tap to play")
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
        .accessibilityLabel(state.isFocusPlaying ? "Pause \(state.focusMode.title)" : "Play \(state.focusMode.title)")
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

                if state.maskingBed != .off || state.flowMinutes > 0 || state.mixWithOthers || !state.visualFollowsSoundscape {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 6, height: 6)
                        .offset(x: -3, y: 3)
                }
            }
        }
        .buttonStyle(BraunPressButtonStyle(pressedScale: 0.92, reduceMotion: reduceMotion))
        .accessibilityLabel("Options")
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
        .accessibilityLabel("Sleep timer, \(countdown) remaining")
    }

    private var stageSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 36, coordinateSpace: .local)
            .onEnded { value in
                if abs(value.translation.width) > abs(value.translation.height) * 1.4 {
                    state.cycleVisual(forward: value.translation.width < 0)
                    flashVisualToast(state.preset.cleanName.uppercased())
                }
            }
    }

    private func flashVisualToast(_ text: String) {
        visualToastTask?.cancel()
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            visualToastLabel = text
        }
        visualToastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.3))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.35)) {
                visualToastLabel = nil
            }
        }
    }

    private func toggleImmersion(_ enter: Bool) {
        state.performHaptic()
        immersionHintTask?.cancel()
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
                        Text("TIMER")
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
                                Text(mins == 0 ? "∞" : "\(mins)m")
                                    .font(.caption.monospaced().weight(on ? .semibold : .regular))
                                    .foregroundColor(on ? .black : inkSoft)
                                    .frame(maxWidth: .infinity)
                                    .frame(minHeight: 36)
                                    .background(on ? Color.white : Color.white.opacity(0.07))
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(BraunPressButtonStyle(pressedScale: 0.95, reduceMotion: reduceMotion))
                            .accessibilityLabel(mins == 0 ? "No timer limit" : "\(mins) minute timer")
                            .accessibilityAddTraits(on ? [.isSelected] : [])
                        }
                    }
                }

                // Optional Background Noise Layer
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("BACKGROUND NOISE")
                            .font(.caption2.monospaced().weight(.semibold))
                            .foregroundColor(inkSoft)
                            .tracking(0.8)
                        Text("Layer gentle rain or brown noise under any mode")
                            .font(.caption)
                            .foregroundColor(inkDim)
                    }

                    HStack(spacing: 6) {
                        ForEach(MaskingBed.allCases) { bed in
                            let on = state.maskingBed == bed
                            Button {
                                state.maskingBed = bed
                                state.performHaptic()
                            } label: {
                                Text(bed.label)
                                    .font(.footnote.weight(on ? .semibold : .regular))
                                    .foregroundColor(on ? .black : inkSoft)
                                    .frame(maxWidth: .infinity)
                                    .frame(minHeight: 36)
                                    .background(on ? Color.white : Color.white.opacity(0.07))
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(BraunPressButtonStyle(pressedScale: 0.95, reduceMotion: reduceMotion))
                            .accessibilityAddTraits(on ? [.isSelected] : [])
                        }
                    }
                }

                // Visual World Pairing / Override (Auto by default; swipe canvas anytime)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("VISUAL")
                            .font(.caption2.monospaced().weight(.semibold))
                            .foregroundColor(inkSoft)
                            .tracking(0.8)
                        Spacer()
                        Text(state.visualFollowsSoundscape ? "PAIRED · \(state.preset.cleanName.uppercased())" : "PINNED · \(state.preset.cleanName.uppercased())")
                            .font(.caption2.monospaced().weight(.medium))
                            .foregroundColor(inkDim)
                    }

                    let gridColumns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)
                    LazyVGrid(columns: gridColumns, spacing: 6) {
                        visualOptionChip(label: "Auto", selected: state.visualFollowsSoundscape) {
                            state.setVisualOverride(nil)
                        }
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
                            .font(.caption2.monospaced().weight(.semibold))
                            .foregroundColor(inkSoft)
                            .tracking(0.8)
                        Spacer()
                        HStack(spacing: 6) {
                            ForEach([(false, "P31 Emerald"), (true, "P39 Amber")], id: \.0) { isAmber, label in
                                let on = state.amberPhosphor == isAmber
                                Button {
                                    state.amberPhosphor = isAmber
                                    state.performHaptic()
                                } label: {
                                    Text(label)
                                        .font(.caption2.monospaced().weight(on ? .semibold : .regular))
                                        .foregroundColor(on ? .black : inkSoft)
                                        .padding(.horizontal, 10)
                                        .frame(minHeight: 28)
                                        .background(on ? Color.white : Color.white.opacity(0.07))
                                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                }
                                .buttonStyle(BraunPressButtonStyle(pressedScale: 0.95, reduceMotion: reduceMotion))
                                .accessibilityAddTraits(on ? [.isSelected] : [])
                            }
                        }
                    }
                }

                Divider().overlay(hairSoft)

                Toggle(isOn: $state.mixWithOthers) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MIX WITH OTHER AUDIO")
                            .font(.caption2.monospaced().weight(.semibold))
                            .foregroundColor(inkSoft)
                            .tracking(0.8)
                        Text("Play Satie underneath podcasts, videos, or other music")
                            .font(.caption)
                            .foregroundColor(inkDim)
                    }
                }
                .tint(.white)

                Toggle(isOn: $state.keepScreenAwake) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("KEEP SCREEN AWAKE")
                            .font(.caption2.monospaced().weight(.semibold))
                            .foregroundColor(inkSoft)
                            .tracking(0.8)
                        Text("Keep the visual display glowing on a desk or stand")
                            .font(.caption)
                            .foregroundColor(inkDim)
                    }
                }
                .tint(.white)

                Divider().overlay(hairSoft)

                HStack {
                    Text("100% OFFLINE · ZERO TRACKING")
                        .font(.caption2.monospaced())
                        .foregroundColor(inkDim)
                    Spacer()
                    if let privacyPolicyURL = URL(string: "https://strangechances.com/satie/privacy/") {
                        Link("Privacy Policy", destination: privacyPolicyURL)
                            .font(.caption.weight(.medium))
                            .foregroundColor(inkSoft)
                    }
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 22)
            .padding(.top, 24)
            .padding(.bottom, 18)
        }
    }

    private func visualOptionChip(label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.footnote.weight(selected ? .semibold : .regular))
                .foregroundColor(selected ? .black : inkSoft)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 34)
                .background(selected ? Color.white : Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(BraunPressButtonStyle(pressedScale: 0.95, reduceMotion: reduceMotion))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: - Helpers

    private var heroSubtitle: String {
        let base = state.focusMode.subtitle.uppercased()
        if state.isFocusPlaying && state.maskingBed != .off {
            return "\(base) · +\(state.maskingBed.label.uppercased())"
        }
        return base
    }

    private var compactCountdown: String? {
        guard state.isFocusPlaying, let rem = state.flowRemainingSeconds else { return nil }
        let sec = max(0, Int(ceil(rem)))
        return String(format: "%d:%02d", sec / 60, sec % 60)
    }

    private var timerStatusLabel: String {
        if let countdown = compactCountdown {
            return "\(countdown) REMAINING"
        }
        return state.flowMinutes > 0 ? "FADES OUT AFTER \(state.flowMinutes)M" : "NO LIMIT"
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
