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
            self.overlayView.update(snapshot: snap, preset: state.preset, sourceLabel: state.tapTarget.shortLabel)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

struct StudioStageRepresentable: NSViewRepresentable {
    var isActive: Bool

    func makeNSView(context: Context) -> StudioStageNSView {
        let view = StudioStageNSView(frame: .zero)
        view.metalView.setActive(isActive)
        return view
    }

    func updateNSView(_ nsView: StudioStageNSView, context: Context) {
        nsView.metalView.setActive(isActive)
    }
}

struct StudioContentView: View {
    @ObservedObject var state: AppState
    let onToggleFullscreen: () -> Void
    let onSwitchToMiniHUD: () -> Void

    @State private var hudVisible: Bool = true
    @State private var hideTask: Task<Void, Never>?

    private let hair = Color(red: 0.86, green: 0.91, blue: 0.98).opacity(0.22)
    private let hairSoft = Color(red: 0.86, green: 0.91, blue: 0.98).opacity(0.11)
    private let inkSoft = Color(red: 0.88, green: 0.92, blue: 0.98).opacity(0.76)
    private let inkDim = Color(red: 0.84, green: 0.89, blue: 0.96).opacity(0.45)

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Top Studio Titlebar Chrome (collapses smoothly in fullscreen idle)
                if !state.isFullscreen || hudVisible {
                    topBar
                        .transition(.opacity)
                }

                // Main Metal + Retina Schematic Stage
                StudioStageRepresentable(isActive: state.isStudioOpen)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Bottom Status Bar (collapses smoothly in fullscreen idle)
                if !state.isFullscreen || hudVisible {
                    statusBar
                        .transition(.opacity)
                }
            }
            .background(Color(red: 0.028, green: 0.043, blue: 0.071))
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

            // Preset Tabs (01 - 04)
            HStack(spacing: 2) {
                ForEach(VisualPreset.allCases) { p in
                    Button {
                        state.preset = p
                    } label: {
                        Text(p.title.uppercased())
                            .font(.system(size: 10, weight: state.preset == p ? .semibold : .regular, design: .monospaced))
                            .foregroundColor(state.preset == p ? Color(red: 0.03, green: 0.05, blue: 0.09) : inkDim)
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .background(state.preset == p ? Color(red: 0.93, green: 0.96, blue: 1.0) : Color.clear)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(Color.white.opacity(0.025))
            .overlay(Rectangle().stroke(hairSoft, lineWidth: 1))

            if state.preset == .phosphor {
                Button {
                    state.amberPhosphor.toggle()
                } label: {
                    Text(state.amberPhosphor ? "P39 AMBER" : "P31 EMERALD")
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundColor(state.amberPhosphor ? Color(red: 1.0, green: 0.72, blue: 0.30) : Color(red: 0.38, green: 1.0, blue: 0.62))
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(Color.white.opacity(0.04))
                        .overlay(Rectangle().stroke(hairSoft, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            Spacer()

            // Core Audio Process Tap Source Picker
            Menu {
                Button {
                    state.selectTapTarget(.systemAll)
                } label: {
                    if case .systemAll = state.tapTarget {
                        Label("System Output (All Apps)", systemImage: "checkmark")
                    } else {
                        Text("System Output (All Apps)")
                    }
                }

                if !state.audioProcesses.isEmpty {
                    Divider()
                    ForEach(state.audioProcesses) { proc in
                        Button {
                            state.selectTapTarget(.process(proc))
                        } label: {
                            let label = proc.isRunningOutput ? "● \(proc.name) (PID \(proc.pid))" : "\(proc.name) (PID \(proc.pid))"
                            if case .process(let current) = state.tapTarget, current.objectID == proc.objectID {
                                Label(label, systemImage: "checkmark")
                            } else {
                                Text(label)
                            }
                        }
                    }
                }

                Divider()
                Button("Refresh Active Apps") {
                    state.refreshAudioProcesses()
                }
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(tapDotColor)
                        .frame(width: 6, height: 6)
                    Text("TAP: \(state.tapTarget.displayLabel)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(inkSoft)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundColor(inkDim)
                }
                .padding(.horizontal, 9)
                .frame(height: 25)
                .background(Color.white.opacity(0.04))
                .overlay(Rectangle().stroke(hairSoft, lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            if !state.isFullscreen {
                Button(action: onSwitchToMiniHUD) {
                    Image(systemName: "pip")
                        .font(.system(size: 11))
                        .frame(width: 26, height: 25)
                }
                .buttonStyle(HairlineIconButtonStyle())
                .help("Shrink to Floating Mini HUD (⌘M)")
            }

            Button(action: onToggleFullscreen) {
                Image(systemName: state.isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10.5))
                    .frame(width: 26, height: 25)
            }
            .buttonStyle(HairlineIconButtonStyle())
            .help(state.isFullscreen ? "Exit Fullscreen (Esc)" : "Fullscreen Wall (⌘F)")
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Color(red: 0.045, green: 0.068, blue: 0.110))
        .overlay(alignment: .bottom) {
            Rectangle().fill(hairSoft).frame(height: 1)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                if state.metadata.canControlPlayback {
                    Button {
                        state.media.playPause()
                    } label: {
                        Image(systemName: state.metadata.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 9.5))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(HairlineIconButtonStyle(prominent: true))
                }

                Text(state.metadata.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }

            Spacer()

            HStack(spacing: 14) {
                Text(state.displayKey)
                    .foregroundColor(.white)
                    .fontWeight(.semibold)
                Text(String(format: "ENERGY %.2f", state.displayEnergy))
                Text(String(format: "FLUX %.2f", state.displayFlux))
                Text(String(format: "PHASE %+.2f", state.displayPhase))
                Text("\(state.displayFPS) HZ METAL")
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(inkDim)
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(Color(red: 0.038, green: 0.058, blue: 0.095))
        .overlay(alignment: .top) {
            Rectangle().fill(hairSoft).frame(height: 1)
        }
    }

    private var tapDotColor: Color {
        switch state.tapStatus {
        case .active: return Color(red: 0.25, green: 0.88, blue: 0.54)
        case .permissionOrError: return Color(red: 1.0, green: 0.52, blue: 0.32)
        case .stopped, .sleeping: return .gray
        }
    }

    private func bumpFullscreenHUD() {
        guard state.isFullscreen else { return }
        if !hudVisible {
            withAnimation(.easeOut(duration: 0.2)) { hudVisible = true }
        }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, state.isFullscreen else { return }
            withAnimation(.easeInOut(duration: 0.35)) { hudVisible = false }
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
        switch chars {
        case "1": AppState.shared.preset = .circuit; return
        case "2": AppState.shared.preset = .ecology; return
        case "3": AppState.shared.preset = .phosphor; return
        case "4": AppState.shared.preset = .liquid; return
        case " ": AppState.shared.media.playPause(); return
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
    private var onSwitchToMiniHUD: (() -> Void)?

    func show(fullscreen: Bool = false, onSwitchToMiniHUD: @escaping () -> Void) {
        self.onSwitchToMiniHUD = onSwitchToMiniHUD

        if let existing = window {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            AppState.shared.isStudioOpen = true
            if fullscreen && !existing.styleMask.contains(.fullScreen) {
                existing.toggleFullScreen(nil)
            }
            return
        }

        let content = StudioContentView(
            state: AppState.shared,
            onToggleFullscreen: { [weak self] in
                self?.window?.toggleFullScreen(nil)
            },
            onSwitchToMiniHUD: { [weak self] in
                self?.close()
                onSwitchToMiniHUD()
            }
        )

        let win = StudioNSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "Acoustic Circuit"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.backgroundColor = NSColor(calibratedRed: 0.028, green: 0.043, blue: 0.071, alpha: 1.0)
        win.minSize = NSSize(width: 720, height: 500)
        win.collectionBehavior = [.fullScreenPrimary]
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.onMiniHUDShortcut = { [weak self] in
            self?.close()
            onSwitchToMiniHUD()
        }
        win.contentView = NSHostingView(rootView: content)
        if let saved = AppState.shared.settings.studioFrame,
           NSScreen.screens.contains(where: { $0.visibleFrame.intersects(saved) }) {
            win.setFrame(saved, display: false)
        } else {
            win.center()
        }

        self.window = win
        AppState.shared.isStudioOpen = true
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)

        if fullscreen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                win.toggleFullScreen(nil)
            }
        }
    }

    func close() {
        if let w = window {
            if !w.styleMask.contains(.fullScreen) {
                AppState.shared.settings.studioFrame = w.frame
            } else {
                w.toggleFullScreen(nil)
            }
        }
        window?.orderOut(nil)
        AppState.shared.isStudioOpen = false
        AppState.shared.isFullscreen = false
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
        AppState.shared.isStudioOpen = false
        AppState.shared.isFullscreen = false
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        AppState.shared.isFullscreen = true
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        AppState.shared.isFullscreen = false
    }
}
