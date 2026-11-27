import AcousticCore
import SwiftUI

/// Native Apple Vision Pro Spatial Skyspace (`visionOS 2.0+`):
/// Combines Satie's full 48 kHz generative `AcousticCore` engine with a live Turrell Oculus
/// architectural canvas and a floating spatial glass ornament Braun 6-world dock.
@MainActor
final class SatieVisionState: ObservableObject {
    static let shared = SatieVisionState()

    @Published var focusMode: FocusSoundscape = .dive {
        didSet { focusSound.setMode(focusMode) }
    }
    @Published var isPlaying: Bool = false

    let ringBuffer = StereoRingBuffer()
    let focusSound: FocusSoundEngine

    private init() {
        self.focusSound = FocusSoundEngine(ringBuffer: ringBuffer)
        self.focusSound.setMode(.dive)
        self.focusSound.setVolume(0.85)
        self.focusSound.setCircadianPhase(.current())
    }

    func togglePlay() {
        if isPlaying {
            focusSound.stop()
            isPlaying = false
        } else {
            focusSound.setCircadianPhase(.current())
            isPlaying = focusSound.start(mode: focusMode)
        }
    }

    func select(_ mode: FocusSoundscape) {
        focusMode = mode
        if !isPlaying {
            isPlaying = focusSound.start(mode: mode)
        }
    }
}

/// Live spatial Turrell *Aten Reign* / *Skyspace* dome driven directly by Satie's audio-rate breath & bowl state.
struct VisionOculusSkyspaceView: View {
    @ObservedObject var state: SatieVisionState

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 90.0)) { _ in
            let frame = state.focusSound.snapshotVisualMusicalFrame()
            let isNight = CircadianPhase.current() == .night
            let breath = Double(frame.breathPhase)
            let depth = Double(frame.meditationDepth)

            Canvas { ctx, size in
                let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
                let minDim = min(size.width, size.height)
                let dilate = state.isPlaying ? (1.0 + (breath - 0.5) * 0.055) : 0.96

                // Deep architectural obsidian room backdrop
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))

                let tierColors: [Color] = isNight
                    ? [
                        Color(red: 0.10, green: 0.036, blue: 0.022),
                        Color(red: 0.28, green: 0.088, blue: 0.044),
                        Color(red: 0.56, green: 0.205, blue: 0.078),
                        Color(red: 0.84, green: 0.495, blue: 0.185)
                    ]
                    : [
                        Color(red: 0.11 - 0.07 * depth, green: 0.08 + 0.01 * depth, blue: 0.24 - 0.04 * depth),
                        Color(red: 0.36 - 0.28 * depth, green: 0.14 + 0.06 * depth, blue: 0.31 + 0.03 * depth),
                        Color(red: 0.73 - 0.58 * depth, green: 0.30 + 0.08 * depth, blue: 0.28 + 0.19 * depth),
                        Color(red: 0.95 - 0.31 * depth, green: 0.72 + 0.09 * depth, blue: 0.50 + 0.37 * depth)
                    ]

                let radii: [CGFloat] = [0.46, 0.35, 0.25, 0.155].map { $0 * minDim * dilate }
                for idx in 0..<4 {
                    let r = radii[idx]
                    let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
                    let grad = Gradient(colors: [
                        tierColors[idx].opacity(idx == 3 ? (0.85 + 0.15 * breath) : 0.78),
                        tierColors[idx].opacity(0.28)
                    ])
                    ctx.fill(
                        Path(ellipseIn: rect),
                        with: .radialGradient(grad, center: center, startRadius: idx == 3 ? 0 : r * 0.45, endRadius: r)
                    )
                    ctx.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.08)), lineWidth: 1.0)
                }

                // Faraday bowl ripples emerging across the skylight when singing bowls speak
                if state.isPlaying {
                    for note in frame.notes where note.age > 0.01 && note.age < 12.0 && note.velocity > 0.01 {
                        let env = exp(-Double(note.age) * 0.34) * Double(note.velocity)
                        let rr = (0.04 + Double(note.age) * 0.055) * minDim
                        let rc = CGRect(x: center.x - rr, y: center.y - rr, width: rr * 2, height: rr * 2)
                        ctx.stroke(
                            Path(ellipseIn: rc),
                            with: .color(tierColors[3].opacity(min(0.65, env * 0.55))),
                            lineWidth: 1.5
                        )
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
        .ornament(attachmentAnchor: .scene(.bottom)) {
            HStack(spacing: 12) {
                Button(action: { state.togglePlay() }) {
                    Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)

                ForEach(FocusSoundscape.shipping) { mode in
                    Button(mode.shortLabel) {
                        state.select(mode)
                    }
                    .font(.system(size: 13, weight: state.focusMode == mode ? .bold : .medium, design: .monospaced))
                    .buttonStyle(.bordered)
                    .tint(state.focusMode == mode ? .white : .secondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .glassBackgroundEffect()
        }
    }
}

@main
struct SatieVisionApp: App {
    @StateObject private var state = SatieVisionState.shared

    var body: some Scene {
        WindowGroup(SatieL10n.string("vision.window_title")) {
            VisionOculusSkyspaceView(state: state)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.plain)
        .defaultSize(width: 960, height: 640)
    }
}
