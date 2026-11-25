import AcousticCore
import AppKit
import SwiftUI

/// Composite native view pairing the 120Hz Metal engine underneath the crisp Retina CoreGraphics schematic layer.
final class StudioStageNSView: NSView {
    let metalView: AcousticMetalView
    let overlayView: SchematicOverlayView

    private var lastOverlayUpdate: CFTimeInterval = 0

    override init(frame frameRect: NSRect) {
        self.metalView = AcousticMetalView(frame: frameRect, compactMode: false)
        self.overlayView = SchematicOverlayView(frame: frameRect)
        super.init(frame: frameRect)

        metalView.translatesAutoresizingMaskIntoConstraints = false
        overlayView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(metalView)
        addSubview(overlayView)

        NSLayoutConstraint.activate([
            metalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            metalView.topAnchor.constraint(equalTo: topAnchor),
            metalView.bottomAnchor.constraint(equalTo: bottomAnchor),

            overlayView.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlayView.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlayView.topAnchor.constraint(equalTo: topAnchor),
            overlayView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        metalView.onSnapshotRendered = { [weak self] snap in
            guard let self else { return }
            let now = CACurrentMediaTime()
            guard now - self.lastOverlayUpdate >= (1.0 / 30.0) else { return }
            self.lastOverlayUpdate = now
            let state = AppState.shared
            let label = state.isFocusPlaying ? state.focusMode.title.uppercased() : SatieL10n.string("common.standby")
            self.overlayView.update(snapshot: snap, preset: state.preset, sourceLabel: label)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

struct StudioStageRepresentable: NSViewRepresentable {
    var isActive: Bool
    var preset: VisualPreset
    var onStageCreated: ((StudioStageNSView) -> Void)? = nil

    func makeNSView(context: Context) -> StudioStageNSView {
        let view = StudioStageNSView(frame: .zero)
        view.metalView.setActive(isActive)
        onStageCreated?(view)
        return view
    }

    func updateNSView(_ nsView: StudioStageNSView, context: Context) {
        // Strictly idempotent: never forces CVDisplayLink restart or synchronous draw() inside SwiftUI layout!
        nsView.metalView.setActive(isActive)
    }
}

struct StudioContentView: View {
    @ObservedObject var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onToggleFullscreen: () -> Void
    let onSwitchToMiniHUD: () -> Void
    var onStageCreated: ((StudioStageNSView) -> Void)? = nil

    @State private var hudVisible: Bool = true
    @State private var immersionMode: Bool = false
    @State private var showImmersionHint: Bool = false
    @State private var immersionHintTask: Task<Void, Never>?
    @State private var hideTask: Task<Void, Never>?
    @State private var presetTransitionVeil: Double = 0.0
    @Namespace private var worldPillNS

    private let hair = Color.white.opacity(0.14)
    private let hairSoft = Color.white.opacity(0.09)
    private let inkSoft = Color.white.opacity(0.76)
    private let inkDim = Color.white.opacity(0.46)

    private var showChrome: Bool {
        !immersionMode && (!state.isFullscreen || hudVisible)
    }

    var body: some View {
        ZStack {
            // 1. Full-bleed edge-to-edge 120Hz Metal + Retina Schematic Stage
            StudioStageRepresentable(isActive: state.isStudioOpen, preset: state.preset, onStageCreated: onStageCreated)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Smooth crossfade veil when switching visual worlds
            Color.black
                .opacity(presetTransitionVeil)
                .allowsHitTesting(false)

            // Soft top & bottom vignettes when chrome is visible
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [Color.black.opacity(0.62), Color.black.opacity(0.0)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 88)

                Spacer()

                LinearGradient(
                    colors: [Color.black.opacity(0.0), Color.black.opacity(0.72)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 92)
            }
            .opacity(showChrome ? 1.0 : 0.0)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.26), value: showChrome)
            .allowsHitTesting(false)

            // 2. Floating Braun Top Bar + Bottom Bar (click open stage for Immersion Mode)
            VStack(spacing: 0) {
                topBar
                    .opacity(showChrome ? 1.0 : 0.0)
                    .allowsHitTesting(showChrome)

                // Open canvas tap target toggles Immersion Mode cleanly without interfering with bar buttons
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        toggleImmersion(!immersionMode)
                    }
                    .overlay(alignment: .bottom) {
                        if immersionMode && showImmersionHint {
                            Text(SatieL10n.string("studio.click_to_show_controls"))
                                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                .tracking(0.8)
                                .foregroundColor(Color.white.opacity(0.78))
                                .padding(.horizontal, 13)
                                .padding(.vertical, 7)
                                .background(Color.black.opacity(0.56))
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                                .overlay(Capsule().stroke(hairSoft, lineWidth: 0.8))
                                .padding(.bottom, 22)
                                .transition(.opacity)
                                .allowsHitTesting(false)
                        }
                    }

                statusBar
                    .opacity(showChrome ? 1.0 : 0.0)
                    .allowsHitTesting(showChrome)
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.26), value: showChrome)
        }
        .background(Color(red: 0.022, green: 0.032, blue: 0.052))
        .onChange(of: state.preset) { _, _ in
            guard !reduceMotion else { return }
            presetTransitionVeil = 0.55
            withAnimation(.easeOut(duration: 0.26)) {
                presetTransitionVeil = 0.0
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                bumpFullscreenHUD()
            case .ended:
                break
            }
        }
        .onChange(of: state.isFullscreen) { _, isFS in
            if isFS {
                bumpFullscreenHUD()
            } else {
                hideTask?.cancel()
                hudVisible = true
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            // Spacer for macOS traffic lights when not fullscreen
            if !state.isFullscreen {
                Spacer().frame(width: 68)
            }

            // Primary Soundscape Worlds Pill (FOCUS · PULSE · RAIN · STILL · NIGHT)
            HStack(spacing: 2) {
                ForEach(FocusSoundscape.allCases) { mode in
                    let selected = (state.focusMode == mode)
                    Button {
                        withAnimation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.82)) {
                            if state.isFocusPlaying && state.focusMode == mode {
                                state.stopFocusSound()
                            } else {
                                state.toggleFocusSound(mode)
                            }
                        }
                    } label: {
                        Text(mode.shortLabel)
                            .font(.system(size: 10, weight: selected ? .semibold : .medium, design: .monospaced))
                            .tracking(0.4)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .foregroundColor(selected ? .black : inkSoft)
                            .padding(.horizontal, 11)
                            .frame(height: 24)
                            .background {
                                if selected {
                                    Capsule()
                                        .fill(Color.white)
                                        .matchedGeometryEffect(id: "studioWorldPill", in: worldPillNS)
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("\(mode.title) — \(mode.subtitle)")
                    .accessibilityLabel("\(mode.title), \(mode.subtitle)")
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
            .padding(3)
            .background(Color.black.opacity(0.46))
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(hair, lineWidth: 0.8))

            Spacer()

            // The visual always follows the soundscape; this quietly names it.
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 9.5))
                Text(state.preset.cleanName.uppercased())
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .lineLimit(1)
            }
            .foregroundColor(inkSoft)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Color.black.opacity(0.40))
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(hairSoft, lineWidth: 0.8))
            .accessibilityElement(children: .combine)

            Button {
                toggleImmersion(true)
            } label: {
                Image(systemName: "eye.slash")
                    .font(.system(size: 10.5))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(HairlineIconButtonStyle())
            .help(SatieL10n.string("studio.immersion_help"))

            if !state.isFullscreen {
                Button(action: onSwitchToMiniHUD) {
                    Image(systemName: "pip")
                        .font(.system(size: 11))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(HairlineIconButtonStyle())
                .help(SatieL10n.string("studio.mini_hud_help"))
            }

            Button(action: onToggleFullscreen) {
                Image(systemName: state.isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10.5))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(HairlineIconButtonStyle())
            .help(state.isFullscreen ? SatieL10n.string("studio.exit_fullscreen_help") : SatieL10n.string("studio.enter_fullscreen_help"))
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 10) {
                Button {
                    state.togglePlayOrStartFocus()
                } label: {
                    Image(systemName: state.isFocusPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.black)
                        .offset(x: state.isFocusPlaying ? 0 : 1)
                        .frame(width: 30, height: 30)
                        .background(Color.white)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help(state.isFocusPlaying ? SatieL10n.format("common.pause_mode_space", state.focusMode.title) : SatieL10n.format("common.play_mode_space", state.focusMode.title))
                .accessibilityLabel(state.isFocusPlaying ? SatieL10n.format("common.pause_mode", state.focusMode.title) : SatieL10n.format("common.play_mode", state.focusMode.title))

                VStack(alignment: .leading, spacing: 1) {
                    Text(state.activeTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(state.focusMode.subtitle.uppercased())
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                        .foregroundColor(inkSoft)
                        .tracking(0.5)
                        .lineLimit(1)
                }
            }

            Spacer()

            HStack(spacing: 12) {
                if let countdown = compactCountdown {
                    HStack(spacing: 4) {
                        Image(systemName: "timer")
                            .font(.system(size: 10))
                        Text(countdown)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(Color.white.opacity(0.10))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(hairSoft, lineWidth: 0.8))
                }

                // Quiet volume hairline
                HStack(spacing: 6) {
                    Button {
                        state.toggleSystemMute()
                    } label: {
                        Image(systemName: state.isSystemMuted ? "speaker.slash.fill" : "speaker.wave.2")
                            .font(.system(size: 10))
                            .foregroundColor(state.isSystemMuted ? Color(red: 1.0, green: 0.65, blue: 0.58) : inkSoft)
                    }
                    .buttonStyle(.plain)
                    .help(state.isSystemMuted ? SatieL10n.string("studio.unmute_help") : SatieL10n.string("studio.mute_help"))

                    Slider(
                        value: Binding(
                            get: { Double(state.focusVolume) },
                            set: { state.focusVolume = Float($0) }
                        ),
                        in: 0.05...1.0
                    )
                    .controlSize(.mini)
                    .tint(.white)
                    .frame(width: 90)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var compactCountdown: String? {
        guard state.isFocusPlaying, let rem = state.flowRemainingSeconds else { return nil }
        let sec = max(0, Int(ceil(rem)))
        return String(format: "%d:%02d", sec / 60, sec % 60)
    }

    private func toggleImmersion(_ enter: Bool) {
        state.performHaptic()
        immersionHintTask?.cancel()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.26)) {
            immersionMode = enter
            showImmersionHint = enter
        }
        if enter {
            immersionHintTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.8))
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.4)) {
                    showImmersionHint = false
                }
            }
        }
    }

    private func bumpFullscreenHUD() {
        guard state.isFullscreen, !immersionMode else { return }
        if !hudVisible {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { hudVisible = true }
        }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, state.isFullscreen else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) { hudVisible = false }
        }
    }
}

/// Custom NSWindow handling 1–4 preset switching, Space play/pause, ⌘F fullscreen, and ⌘M Mini HUD.
final class StudioNSWindow: NSWindow {
    var onMiniHUDShortcut: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let chars = event.charactersIgnoringModifiers ?? ""
        if event.modifierFlags.contains(.command) {
            if chars.lowercased() == "f" {
                toggleFullScreen(nil)
                return
            }
            if chars.lowercased() == "m" {
                onMiniHUDShortcut?()
                return
            }
        }
        switch chars.lowercased() {
        case "1", "2", "3", "4", "5", "6": AppState.shared.selectFocusMode(number: Int(chars) ?? 0); return
        case " ": AppState.shared.togglePlayOrStartFocus(); return
        case "m": AppState.shared.toggleSystemMute(); return
        default: break
        }
        if event.keyCode == 53, styleMask.contains(.fullScreen) { // Esc
            toggleFullScreen(nil)
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
final class StudioWindowController: NSObject, NSWindowDelegate {
    private var window: StudioNSWindow?
    private weak var stageView: StudioStageNSView?
    private var lifecycle = StudioLifecycleMachine()
    private var onSwitchToMiniHUD: (() -> Void)?

    func show(fullscreen: Bool = false, onSwitchToMiniHUD: @escaping () -> Void) {
        self.onSwitchToMiniHUD = onSwitchToMiniHUD
        let effects = lifecycle.requestOpen(fullscreen: fullscreen)
        applyLifecycleStateAndEffects(effects)
    }

    func close() {
        if let w = window, !w.styleMask.contains(.fullScreen) {
            AppState.shared.settings.studioFrame = w.frame
        }
        let effects = lifecycle.requestClose()
        applyLifecycleStateAndEffects(effects)
    }

    private func applyLifecycleStateAndEffects(_ effects: [StudioLifecycleMachine.Effect]) {
        // Always sync published AppState flags BEFORE ordering window front so window notifications see the new state
        AppState.shared.isStudioOpen = lifecycle.isStudioOpen
        AppState.shared.isFullscreen = lifecycle.isFullscreen

        for effect in effects {
            switch effect {
            case .createAndShowWindow(let fullscreen):
                createWindowAndShow(fullscreen: fullscreen)

            case .deminiaturizeAndShow(let fullscreen):
                guard let existing = window else { continue }
                NSApp.activate(ignoringOtherApps: true)
                if existing.isMiniaturized {
                    existing.deminiaturize(nil)
                }
                existing.orderFrontRegardless()
                existing.makeKeyAndOrderFront(nil)
                if fullscreen && !existing.styleMask.contains(.fullScreen) {
                    existing.toggleFullScreen(nil)
                }
                schedulePostOpenRecovery()

            case .orderFrontWindow(let fullscreen):
                guard let existing = window else { continue }
                NSApp.activate(ignoringOtherApps: true)
                existing.orderFrontRegardless()
                existing.makeKeyAndOrderFront(nil)
                if fullscreen && !existing.styleMask.contains(.fullScreen) {
                    existing.toggleFullScreen(nil)
                }
                schedulePostOpenRecovery()

            case .orderOutWindow:
                window?.orderOut(nil)

            case .requestToggleFullscreen:
                if let w = window, w.styleMask.contains(.fullScreen) {
                    w.toggleFullScreen(nil)
                }

            case .setMetalActive(let active):
                stageView?.metalView.setActive(active)

            case .recoverMetalIfStalled:
                stageView?.metalView.recoverIfStalled()
            }
        }
    }

    private func createWindowAndShow(fullscreen: Bool) {
        let onSwitch = onSwitchToMiniHUD
        let content = StudioContentView(
            state: AppState.shared,
            onToggleFullscreen: { [weak self] in
                self?.window?.toggleFullScreen(nil)
            },
            onSwitchToMiniHUD: { [weak self] in
                self?.close()
                onSwitch?()
            },
            onStageCreated: { [weak self] stage in
                self?.stageView = stage
            }
        )

        let win = StudioNSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "Satie"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.backgroundColor = NSColor(calibratedRed: 0.028, green: 0.043, blue: 0.071, alpha: 1.0)
        win.minSize = NSSize(width: 720, height: 500)
        win.collectionBehavior = [.fullScreenPrimary, .moveToActiveSpace]
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.onMiniHUDShortcut = { [weak self] in
            self?.close()
            onSwitch?()
        }
        win.contentView = NSHostingView(rootView: content)
        if let saved = AppState.shared.settings.studioFrame,
           NSScreen.screens.contains(where: { $0.visibleFrame.intersects(saved) }) {
            win.setFrame(saved, display: false)
        } else {
            win.center()
        }

        self.window = win
        NSApp.activate(ignoringOtherApps: true)
        win.orderFrontRegardless()
        win.makeKeyAndOrderFront(nil)
        schedulePostOpenRecovery()

        if fullscreen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak win] in
                win?.toggleFullScreen(nil)
            }
        }
    }

    private func schedulePostOpenRecovery() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.lifecycle.isStudioOpen else { return }
            self.stageView?.metalView.recoverIfStalled()
        }
    }

    func windowDidResize(_ notification: Notification) {
        if let w = window, !w.styleMask.contains(.fullScreen) {
            AppState.shared.settings.studioFrame = w.frame
        }
    }

    func windowDidMove(_ notification: Notification) {
        if let w = window, !w.styleMask.contains(.fullScreen) {
            AppState.shared.settings.studioFrame = w.frame
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let w = window, !w.styleMask.contains(.fullScreen) {
            AppState.shared.settings.studioFrame = w.frame
        }
        let effects = lifecycle.handleWindowWillClose()
        applyLifecycleStateAndEffects(effects)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        let effects = lifecycle.handleWindowDidMiniaturize()
        applyLifecycleStateAndEffects(effects)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        let effects = lifecycle.handleWindowDidDeminiaturize()
        applyLifecycleStateAndEffects(effects)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        let effects = lifecycle.handleDidEnterFullScreen()
        applyLifecycleStateAndEffects(effects)
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        lifecycle.handleWillExitFullScreen()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        let effects = lifecycle.handleDidExitFullScreen()
        applyLifecycleStateAndEffects(effects)
    }
}
