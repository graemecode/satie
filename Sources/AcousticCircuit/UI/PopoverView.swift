import AcousticCore
import AppKit
import SwiftUI

/// Lightweight 24-band stark-white architectural bar strip rendered cleanly via CoreGraphics.
final class BarsStripNSView: NSView {
    private var bands: [Float] = [Float](repeating: 0, count: 24)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(_ bands24: [Float]) {
        self.bands = bands24
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)
        let w = bounds.width
        let h = bounds.height
        let gap: CGFloat = 2.5
        let bw = (w - gap * 23.0) / 24.0
        guard bw > 0.5 else { return }

        let fill = NSColor(calibratedWhite: 1.0, alpha: 0.78).cgColor
        let base = NSColor(calibratedWhite: 1.0, alpha: 0.14).cgColor

        for i in 0..<24 {
            let x = CGFloat(i) * (bw + gap)
            ctx.setFillColor(base)
            ctx.fill(CGRect(x: x, y: 0, width: bw, height: 1.5))

            let fh = max(1.5, CGFloat(bands[i]) * h)
            ctx.setFillColor(fill)
            ctx.fill(CGRect(x: x, y: 0, width: bw, height: fh))
        }
    }
}

struct BarsStripRepresentable: NSViewRepresentable {
    var isActive: Bool

    func makeNSView(context: Context) -> BarsStripNSView {
        let v = BarsStripNSView(frame: .zero)
        context.coordinator.view = v
        context.coordinator.setActive(isActive)
        return v
    }

    func updateNSView(_ nsView: BarsStripNSView, context: Context) {
        context.coordinator.setActive(isActive)
    }

    static func dismantleNSView(_ nsView: BarsStripNSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        weak var view: BarsStripNSView?
        private var timer: Timer?

        func setActive(_ active: Bool) {
            if active {
                guard timer == nil else { return }
                timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, let v = self.view, v.window?.isVisible == true else { return }
                        v.update(AppState.shared.snapshot.bands24)
                    }
                }
            } else {
                stop()
            }
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }
    }
}

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
    @State private var reseedSpinAngle: Double = 0

    private let hair = Color.white.opacity(0.14)
    private let hairSoft = Color.white.opacity(0.08)
    private let inkSoft = Color.white.opacity(0.72)
    private let inkDim = Color.white.opacity(0.42)

    var body: some View {
        VStack(spacing: 12) {
            // 1. Hero OLED Metal Stage with Floating Editorial Typography + Quiet Corner Utility Chrome
            ZStack {
                MetalVisualizerRepresentable(compactMode: true, isActive: state.isPopoverOpen)
                    .frame(height: 174)
                    .clipped()

                // Subtle top & bottom dark scrims for effortless text legibility
                VStack(spacing: 0) {
                    LinearGradient(
                        colors: [Color.black.opacity(0.78), Color.black.opacity(0.0)],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: 62)
                    Spacer()
                    LinearGradient(
                        colors: [Color.black.opacity(0.0), Color.black.opacity(0.84)],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: 52)
                }
                .allowsHitTesting(false)

                VStack(spacing: 0) {
                    // Floating Header Overlay: Title + Circadian Phase on left, Quiet Window Icons on right
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(heroTitle)
                                .font(.system(size: 16.5, weight: .medium))
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .truncationMode(.tail)

                            Text(heroSubtitle)
                                .font(.system(size: 9.2, weight: .regular, design: .monospaced))
                                .foregroundColor(inkSoft)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 4)

                        // Quiet utility icons (never compete with playback)
                        HStack(spacing: 4) {
                            QuietIconButton(systemName: "pip", help: "Mini HUD (⌘M)", action: onOpenMiniHUD)
                            QuietIconButton(systemName: "macwindow", help: "Studio Window", action: onOpenStudio)
                            QuietIconButton(systemName: "arrow.up.left.and.arrow.down.right", help: "Fullscreen (⌘F)", action: onOpenFullscreen)
                            QuietIconButton(systemName: "power", help: "Quit Satie (⌘Q)", action: onQuit)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)

                    Spacer()

                    // Bottom of Stage: Subtle 24-band level hairline / 32-bar form strip + 1-4 visual mode dots
                    HStack(alignment: .bottom, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            if state.isFocusAudible {
                                HStack(alignment: .bottom, spacing: 2) {
                                    ForEach(0..<SatieScore.barsPerForm, id: \.self) { idx in
                                        let fullness = SatieScore.fullnessCurve[idx]
                                        let isCurrent = idx == state.scoreTelemetry.barInForm
                                        let isPast = idx < state.scoreTelemetry.barInForm
                                        Rectangle()
                                            .fill(isCurrent ? Color.white : (isPast ? Color.white.opacity(0.45) : Color.white.opacity(0.16)))
                                            .frame(height: max(2.0, CGFloat(fullness) * 7.0))
                                            .frame(maxWidth: .infinity)
                                    }
                                }
                                .frame(height: 7, alignment: .bottom)
                            } else {
                                BarsStripRepresentable(isActive: state.isPopoverOpen)
                                    .frame(height: 14)
                            }
                        }
                        .frame(maxWidth: .infinity)

                        HStack(spacing: 3) {
                            ForEach(VisualPreset.allCases) { p in
                                Button {
                                    state.preset = p
                                    state.performHaptic()
                                } label: {
                                    Circle()
                                        .fill(state.preset == p ? Color.white : Color.white.opacity(0.28))
                                        .frame(width: state.preset == p ? 6 : 4.5, height: state.preset == p ? 6 : 4.5)
                                        .frame(width: 14, height: 14)
                                }
                                .buttonStyle(.plain)
                                .help(p.title)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
            }
            .frame(height: 174)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
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

            // One plain sentence on what the selected soundscape is for (hidden when visualizing other Mac audio)
            if !isExternalAudioVisualizing {
                Text(state.focusMode.promise)
                    .font(.system(size: 10.5))
                    .foregroundColor(inkDim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity)
            }

            // 3. Iconic Centered Transport Row: [↻ Refresh]  [▶/⏸ Hero White]  [⏱ Timer]  [≡ Sculpt]
            HStack(spacing: 14) {
                // Re-seed / Refresh harmonic phrase (or Previous Track for external media)
                if !state.isFocusAudible && state.metadata.canControlPlayback {
                    CircularControlButton(systemName: "backward.fill", isActive: false, help: "Previous Track") {
                        state.media.previousTrack()
                    }
                } else {
                    Button {
                        withAnimation(.easeOut(duration: 0.42)) {
                            reseedSpinAngle += 360
                        }
                        state.reseedFocusPhrase()
                    } label: {
                        Image(systemName: "arrow.trianglehead.2.clockwise")
                            .font(.system(size: 12.5, weight: .medium))
                            .rotationEffect(.degrees(reseedSpinAngle))
                            .foregroundColor(state.isFocusPlaying ? .white : inkDim)
                            .frame(width: 34, height: 34)
                            .background(Color.white.opacity(0.06))
                            .clipShape(Circle())
                            .overlay(Circle().stroke(hairSoft, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("Refresh phrase & harmonic variation")
                }

                // Hero High-Contrast White Play / Pause Circle
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

                // Radial Focus Timer Toggle
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
                .help("Focus Timer, Rounds & Breaks")

                // Live Sound Sculptor Toggle (Intensity + Rain/Brown Masking + Auto-Duck)
                CircularControlButton(
                    systemName: "slider.horizontal.3",
                    isActive: activeDrawer == .sculpt,
                    hasIndicatorDot: state.soundIntensity != .flow || state.maskingBed != .off,
                    help: "Sculpt sound (Depth, Rain/Brown Masking, Auto-Duck)"
                ) {
                    toggleDrawer(.sculpt)
                }

                // Instant Core Audio Mute (visible when muted or external audio active)
                if state.isSystemMuted || (!state.isFocusAudible && !state.snapshot.isSilent) {
                    CircularControlButton(
                        systemName: state.isSystemMuted ? "speaker.slash.fill" : "speaker.wave.2",
                        isActive: state.isSystemMuted,
                        tintWarning: state.isSystemMuted,
                        help: state.isSystemMuted ? "Unmute Mac audio" : "Mute Mac audio immediately"
                    ) {
                        state.toggleSystemMute()
                    }
                }
            }
            .padding(.vertical, 2)

            // 4. Inline Volume Hairline (always 1 drag away when playing and sculptor drawer is closed)
            if state.isFocusPlaying && activeDrawer != .sculpt {
                volumeSliderRow
                    .padding(.horizontal, 4)
            }

            // 5. Expandable Contextual Drawer: Braun/Leica Radial Timer OR Live Sound Sculptor
            if activeDrawer == .timer {
                RadialTimerView(
                    state: state,
                    onClose: { toggleDrawer(.none) },
                    onRequestResize: onRequestResize
                )
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

    // MARK: - Live Sound Sculptor Drawer (Intensity + Rain/Brown Masking + Auto-Duck + Volume)

    private var liveSculptorDrawer: some View {
        VStack(spacing: 10) {
            // Depth / Intensity (Modulation Depth)
            sculptRow(title: "DEPTH") {
                HStack(spacing: 3) {
                    ForEach(SoundIntensity.allCases) { level in
                        let on = state.soundIntensity == level
                        Button {
                            state.soundIntensity = level
                            state.performHaptic()
                        } label: {
                            Text(level.label)
                                .font(.system(size: 9, weight: on ? .semibold : .regular, design: .monospaced))
                                .foregroundColor(on ? .black : inkSoft)
                                .frame(maxWidth: .infinity)
                                .frame(height: 23)
                                .background(on ? Color.white : Color.white.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Independent Acoustic Masking Bed (OFF / RAIN / BROWN)
            sculptRow(title: "MASKING") {
                HStack(spacing: 3) {
                    ForEach(MaskingBed.allCases) { bed in
                        let on = state.maskingBed == bed
                        Button {
                            state.maskingBed = bed
                            state.performHaptic()
                        } label: {
                            Text(bed.label)
                                .font(.system(size: 9, weight: on ? .semibold : .regular, design: .monospaced))
                                .foregroundColor(on ? .black : inkSoft)
                                .frame(maxWidth: .infinity)
                                .frame(height: 23)
                                .background(on ? Color.white : Color.white.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Auto-Ducking toggle (Blend vs Step Aside for calls & music)
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("AUTO-DUCK")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(inkSoft)
                    Text("Steps aside for calls & music · ignores pings")
                        .font(.system(size: 9))
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
        }
        .padding(12)
        .background(Color.white.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.11), lineWidth: 1)
        )
    }

    private func sculptRow<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(inkDim)
                .frame(width: 54, alignment: .leading)
            content()
        }
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
            return "STEPPED ASIDE · MAC AUDIO"
        }
        let phase = state.effectiveCircadianPhase.detailedLabel
        if state.isOnBreak {
            return state.roundLabel.map { "ON BREAK · \($0)" } ?? "ON BREAK"
        }
        let intention = state.sessionIntention.trimmingCharacters(in: .whitespacesAndNewlines)
        if state.isFocusPlaying && state.flowMinutes > 0 && !intention.isEmpty {
            return intention.uppercased()
        }
        if state.isFocusPlaying {
            if state.maskingBed != .off {
                return "\(phase) · \(state.maskingBed.label)"
            }
            if state.soundIntensity != .flow {
                return "\(phase) · \(state.soundIntensity.label)"
            }
            return phase
        }
        return "READY · \(phase)"
    }

    private var heroPlayIcon: String {
        if state.isFocusPlaying { return "pause.fill" }
        if state.metadata.canControlPlayback && state.metadata.isPlaying && !state.snapshot.isSilent {
            return "pause.fill"
        }
        return "play.fill"
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
