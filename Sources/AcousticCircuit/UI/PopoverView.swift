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

        let hair = NSColor(calibratedRed: 0.86, green: 0.91, blue: 0.98, alpha: 0.22).cgColor
        let fill = NSColor(calibratedRed: 0.94, green: 0.96, blue: 1.0, alpha: 0.96).cgColor

        for i in 0..<24 {
            let x = CGFloat(i) * (bw + gap)
            ctx.setStrokeColor(hair)
            ctx.setLineWidth(0.75)
            ctx.stroke(CGRect(x: x + 0.3, y: 0.5, width: bw - 0.6, height: h - 1.0))

            let fh = max(2.0, CGFloat(bands[i]) * (h - 2.0))
            ctx.setFillColor(fill)
            ctx.fill(CGRect(x: x + 0.8, y: 1.0, width: max(1.0, bw - 1.6), height: fh))
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

struct PopoverView: View {
    @ObservedObject var state: AppState
    let onOpenMiniHUD: () -> Void
    let onOpenStudio: () -> Void
    let onOpenFullscreen: () -> Void
    let onQuit: () -> Void

    private let hairColor = Color(red: 0.86, green: 0.91, blue: 0.98).opacity(0.22)
    private let hairSoft = Color(red: 0.86, green: 0.91, blue: 0.98).opacity(0.11)
    private let inkSoft = Color(red: 0.88, green: 0.92, blue: 0.98).opacity(0.70)
    private let inkDim = Color(red: 0.84, green: 0.89, blue: 0.96).opacity(0.42)

    var body: some View {
        VStack(spacing: 10) {
            // Top header: Source kicker + Title + Detected Key Pill
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(state.activeSourceLabel)
                        Text("·")
                        Text("\(Int(round((state.isFocusPlaying ? 48_000 : state.audioTap.sampleRate) / 1000))) KHZ")
                    }
                    .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                    .foregroundColor(inkDim)

                    Text(state.activeTitle)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 4)

                Text(state.displayKey)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.05))
                    .overlay(Rectangle().stroke(hairColor, lineWidth: 1))
            }

            // Permission banner if Core Audio Process Tap failed
            if case .permissionOrError = state.tapStatus {
                HStack(spacing: 8) {
                    Text("Grant System Audio Recording permission to tap live sound.")
                        .font(.system(size: 10.5))
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
                .overlay(Rectangle().stroke(Color.orange.opacity(0.35), lineWidth: 1))
            }

            // Ruthlessly quiet, pure Metal stage (pauses to 0% GPU the instant popover closes)
            ZStack(alignment: .bottomTrailing) {
                MetalVisualizerRepresentable(compactMode: true, isActive: state.isPopoverOpen)
                    .frame(height: 176)
                    .clipped()
                    .overlay(Rectangle().stroke(hairSoft, lineWidth: 1))

                // Subtle preset dot switcher on bottom-right corner
                HStack(spacing: 4) {
                    ForEach(VisualPreset.allCases) { p in
                        Button {
                            state.preset = p
                        } label: {
                            Text("\(p.rawValue + 1)")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .frame(width: 18, height: 18)
                                .background(state.preset == p ? Color.white : Color(red: 0.04, green: 0.06, blue: 0.10).opacity(0.75))
                                .foregroundColor(state.preset == p ? Color(red: 0.04, green: 0.06, blue: 0.10) : inkSoft)
                                .overlay(Rectangle().stroke(hairColor, lineWidth: 0.75))
                        }
                        .buttonStyle(.plain)
                        .help(p.title)
                    }
                }
                .padding(7)
            }

            // 24-band stark-white architectural level strip
            BarsStripRepresentable(isActive: state.isPopoverOpen)
                .frame(height: 24)
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.38))
                .overlay(Rectangle().stroke(hairSoft, lineWidth: 1))

            // Transport + Scrub / Flow Arc bar (only shows transport buttons when a verified control path exists)
            HStack(spacing: 10) {
                if state.canTogglePrimaryPlayback {
                    HStack(spacing: 4) {
                        if !state.isFocusAudible {
                            Button { state.media.previousTrack() } label: {
                                Image(systemName: "backward.fill").font(.system(size: 10))
                                    .frame(width: 26, height: 26)
                            }
                            .buttonStyle(HairlineIconButtonStyle())
                        }

                        Button { state.togglePrimaryPlayback() } label: {
                            Image(systemName: state.isPrimaryPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 11))
                                .frame(width: 28, height: 26)
                        }
                        .buttonStyle(HairlineIconButtonStyle(prominent: true))

                        if !state.isFocusAudible {
                            Button { state.media.nextTrack() } label: {
                                Image(systemName: "forward.fill").font(.system(size: 10))
                                    .frame(width: 26, height: 26)
                            }
                            .buttonStyle(HairlineIconButtonStyle())
                        }
                    }
                }

                VStack(spacing: 4) {
                    GeometryReader { geo in
                        let frac = progressFraction
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.white.opacity(0.14))
                            Rectangle()
                                .fill(Color.white.opacity(0.94))
                                .frame(width: max(2, geo.size.width * frac))
                        }
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onEnded { val in
                                    guard !state.isFocusAudible, state.metadata.canSeek, geo.size.width > 1 else { return }
                                    state.media.seek(to: Double(val.location.x / geo.size.width))
                                }
                        )
                    }
                    .frame(height: 3)

                    HStack {
                        Text(elapsedLabel)
                        Spacer()
                        Text(remainingLabel)
                    }
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundColor(inkDim)
                }
            }

            // Generative Work Soundscape strip (FOCUS / PULSE / RAIN / DRIFT + inline volume + flow timer)
            VStack(spacing: 7) {
                HStack(spacing: 6) {
                    HStack(spacing: 2) {
                        ForEach(FocusSoundscape.allCases) { mode in
                            let active = state.isFocusPlaying && state.focusMode == mode
                            Button {
                                state.toggleFocusSound(mode)
                            } label: {
                                Text(mode.shortLabel)
                                    .font(.system(size: 9.2, weight: active ? .semibold : .regular, design: .monospaced))
                                    .foregroundColor(active ? Color(red: 0.03, green: 0.05, blue: 0.09) : inkDim)
                                    .padding(.horizontal, 7.5)
                                    .frame(height: 22)
                                    .background(active ? Color(red: 0.93, green: 0.96, blue: 1.0) : Color.clear)
                            }
                            .buttonStyle(.plain)
                            .help("Play \(mode.title) generative work soundscape")
                        }
                    }
                    .padding(2)
                    .background(Color.white.opacity(0.025))
                    .overlay(Rectangle().stroke(hairSoft, lineWidth: 1))

                    Spacer()

                    if state.isFocusPlaying {
                        Button {
                            state.cycleFlowDuration()
                        } label: {
                            Text(state.flowDuration.label)
                                .font(.system(size: 9.2, weight: .medium, design: .monospaced))
                                .foregroundColor(state.flowDuration == .infinite ? inkDim : .white)
                                .padding(.horizontal, 7)
                                .frame(height: 24)
                                .background(Color.white.opacity(state.flowDuration == .infinite ? 0.03 : 0.10))
                                .overlay(Rectangle().stroke(hairSoft, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .help("Cycle flow session timer (∞ / 25m / 50m)")
                    } else {
                        Text("WORK SOUND")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(inkDim)
                    }
                }

                if state.isFocusPlaying {
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
                        Text(state.isAutoDucked ? "AUTO-DUCKED" : "\(Int(round(state.focusVolume * 100)))%")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(inkDim)
                            .frame(minWidth: 30, alignment: .trailing)
                    }
                }
            }

            // Expansion action strip
            HStack(spacing: 6) {
                Button(action: onOpenMiniHUD) {
                    Label("Mini HUD", systemImage: "pip")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(HairlineButtonStyle())

                Button(action: onOpenStudio) {
                    Label("Studio Window", systemImage: "macwindow")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(HairlineButtonStyle())

                Button(action: onOpenFullscreen) {
                    Label("Fullscreen", systemImage: "arrow.up.left.and.arrow.down.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(HairlineButtonStyle())

                Button(action: onQuit) {
                    Image(systemName: "power")
                        .font(.system(size: 10))
                        .frame(width: 26, height: 25)
                }
                .buttonStyle(HairlineIconButtonStyle())
                .help("Quit Acoustic Circuit")
            }
            .padding(.top, 2)
        }
        .padding(14)
        .frame(width: 392)
        .background(
            RadialGradient(
                colors: [
                    Color(red: 0.075, green: 0.118, blue: 0.188),
                    Color(red: 0.038, green: 0.062, blue: 0.106),
                    Color(red: 0.025, green: 0.040, blue: 0.068)
                ],
                center: .center,
                startRadius: 10,
                endRadius: 260
            )
        )
    }

    private var progressFraction: CGFloat {
        if state.isFocusAudible, let rem = state.flowRemainingSeconds, state.flowDuration.rawValue > 0 {
            let total = Double(state.flowDuration.rawValue)
            return CGFloat(max(0.02, min(1.0, (total - rem) / total)))
        }
        if !state.isFocusAudible, let el = state.metadata.elapsed, let dur = state.metadata.duration, dur > 0 {
            return CGFloat(max(0, min(1, el / dur)))
        }
        return CGFloat(max(0.02, min(1, state.displayEnergy * 1.15)))
    }

    private var elapsedLabel: String {
        if state.isFocusAudible, let rem = state.flowRemainingSeconds, state.flowDuration.rawValue > 0 {
            return "FLOW \(formatClock(Double(state.flowDuration.rawValue) - rem))"
        }
        if state.isFocusAudible { return "FLOW · \(state.circadianPhase.label)" }
        if let el = state.metadata.elapsed { return formatClock(el) }
        return state.snapshot.isSilent ? "STANDBY" : "LIVE"
    }

    private var remainingLabel: String {
        if state.isFocusAudible, let rem = state.flowRemainingSeconds {
            return "-" + formatClock(rem)
        }
        if !state.isFocusAudible, let el = state.metadata.elapsed, let dur = state.metadata.duration {
            return "-" + formatClock(max(0, dur - el))
        }
        return "\(state.displayFPS) FPS"
    }

    private func formatClock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

struct HairlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(configuration.isPressed ? .white : Color(red: 0.88, green: 0.92, blue: 0.98).opacity(0.84))
            .padding(.horizontal, 7)
            .frame(height: 25)
            .background(Color.white.opacity(configuration.isPressed ? 0.16 : 0.04))
            .overlay(Rectangle().stroke(Color(red: 0.86, green: 0.91, blue: 0.98).opacity(0.20), lineWidth: 1))
    }
}

struct HairlineIconButtonStyle: ButtonStyle {
    var prominent: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(prominent ? .white : Color(red: 0.88, green: 0.92, blue: 0.98).opacity(0.82))
            .background(Color.white.opacity(configuration.isPressed ? 0.20 : (prominent ? 0.08 : 0.03)))
            .overlay(Rectangle().stroke(Color(red: 0.86, green: 0.91, blue: 0.98).opacity(prominent ? 0.34 : 0.14), lineWidth: 1))
    }
}
