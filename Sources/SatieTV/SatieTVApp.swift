import AcousticCore
import Metal
import MetalKit
import SwiftUI
import UIKit
import simd

// MARK: - 4K Apple EDR Living-Room Skyspace State (tvOS 18+)

@MainActor
final class SatieTVState: ObservableObject {
    static let shared = SatieTVState()

    @Published var focusMode: FocusSoundscape = .dive {
        didSet {
            focusSound.setMode(focusMode)
            preset = VisualPreset.paired(for: focusMode)
        }
    }
    @Published var preset: VisualPreset = .oculus
    @Published var isPlaying: Bool = false
    @Published var showChrome: Bool = true

    let ringBuffer = StereoRingBuffer()
    let focusSound: FocusSoundEngine
    let dsp = AcousticDSP()
    private var lastFrameTime = CACurrentMediaTime()
    private var chromeHideTask: Task<Void, Never>?

    private init() {
        self.focusSound = FocusSoundEngine(ringBuffer: ringBuffer)
        self.focusSound.setMode(.dive)
        self.focusSound.setVolume(0.88)
        self.focusSound.setCircadianPhase(.current())
    }

    func togglePlay() {
        bumpChrome()
        if isPlaying {
            focusSound.stop()
            isPlaying = false
        } else {
            focusSound.setCircadianPhase(.current())
            isPlaying = focusSound.start(mode: focusMode)
        }
    }

    func select(_ mode: FocusSoundscape) {
        bumpChrome()
        focusMode = mode
        if !isPlaying {
            isPlaying = focusSound.start(mode: mode)
        }
    }

    func bumpChrome() {
        showChrome = true
        chromeHideTask?.cancel()
        chromeHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.showChrome = false
        }
    }

    func stepDSP() -> AcousticSnapshot {
        let now = CACurrentMediaTime()
        let dt = max(1.0 / 120.0, min(0.05, now - lastFrameTime))
        lastFrameTime = now
        return dsp.process(ringBuffer: ringBuffer, sampleRate: 48_000, dt: dt, demoMode: false, sensitivity: .balanced)
    }
}

// MARK: - 4K EDR Metal Renderer (Shared Shaders.metal + 64x64 Blue Noise)

private struct TVAcousticUniforms {
    var resolution: SIMD2<Float> = .zero
    var coreCenter: SIMD2<Float> = SIMD2<Float>(0.5, 0.5)
    var coreScale: Float = 0.85
    var time: Float = 0
    var dt: Float = 1.0 / 60.0
    var bass: Float = 0
    var mid: Float = 0
    var treble: Float = 0
    var energy: Float = 0
    var flux: Float = 0
    var beat: Float = 0
    var stereoCorr: Float = 1
    var centroid: Float = 0.4
    var amberMode: Float = 0
    var isCompact: Float = 0
    var chordAge: Float = 99
    var barPhase: Float = 0
    var isPlaying: Float = 0
    var bands: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero, .zero, .zero, .zero)
    var impulses: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero, .zero, .zero, .zero)
    var noteA: (
        SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
        SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
        SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>
    ) = (.zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero)
    var noteKinds: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero)
    var breathDepth: SIMD4<Float> = SIMD4<Float>(0.5, 0.0, 0.0, 0.0)
    var edrParams: SIMD4<Float> = SIMD4<Float>(1.0, 1.8, 0.0, 1.0)
}

@MainActor
private final class TVMetalView: MTKView, MTKViewDelegate {
    private let queue: MTLCommandQueue
    private let blueNoiseTex: MTLTexture
    private let oculusPipe: MTLRenderPipelineState
    private let horizonPipe: MTLRenderPipelineState
    private let circuitBgPipe: MTLRenderPipelineState
    private let circuitRibbonPipe: MTLRenderPipelineState
    private let ecologyBgPipe: MTLRenderPipelineState
    private let uBuf: MTLBuffer
    private let wBuf: MTLBuffer
    private var frameIdx: Int = 0
    private var lastDraw = CACurrentMediaTime()

    init() {
        let dev = MTLCreateSystemDefaultDevice()!
        self.queue = dev.makeCommandQueue()!
        let lib = dev.makeDefaultLibrary()!

        let bnDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 64, height: 64, mipmapped: false)
        bnDesc.usage = .shaderRead
        bnDesc.storageMode = .shared
        let bn = dev.makeTexture(descriptor: bnDesc)!
        BlueNoise64.bytes.withUnsafeBytes { raw in
            bn.replace(region: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: 64)
        }
        self.blueNoiseTex = bn

        func makePipe(_ v: String, _ f: String, additive: Bool = false) -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: v)
            d.fragmentFunction = lib.makeFunction(name: f)
            d.colorAttachments[0].pixelFormat = .rgba16Float
            if additive {
                let a = d.colorAttachments[0]!
                a.isBlendingEnabled = true
                a.sourceRGBBlendFactor = .one
                a.destinationRGBBlendFactor = .one
                a.sourceAlphaBlendFactor = .one
                a.destinationAlphaBlendFactor = .one
            }
            return try! dev.makeRenderPipelineState(descriptor: d)
        }
        self.oculusPipe = makePipe("fullscreenVertex", "oculusFragment")
        self.horizonPipe = makePipe("fullscreenVertex", "horizonFragment")
        self.circuitBgPipe = makePipe("fullscreenVertex", "circuitBackgroundFragment")
        self.circuitRibbonPipe = makePipe("circuitRibbonVertex", "circuitRibbonFragment", additive: true)
        self.ecologyBgPipe = makePipe("fullscreenVertex", "ecologyFieldFragment")

        self.uBuf = dev.makeBuffer(length: MemoryLayout<TVAcousticUniforms>.stride, options: .storageModeShared)!
        self.wBuf = dev.makeBuffer(length: MemoryLayout<SIMD2<Float>>.stride * 256, options: .storageModeShared)!

        super.init(frame: .zero, device: dev)
        self.colorPixelFormat = .rgba16Float
        self.clearColor = MTLClearColor(red: 0.0021, green: 0.0033, blue: 0.0061, alpha: 1.0)
        self.preferredFramesPerSecond = 60
        self.delegate = self
        if let ml = self.layer as? CAMetalLayer {
            ml.pixelFormat = .rgba16Float
            ml.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = currentDrawable, let rp = currentRenderPassDescriptor else { return }
        let state = SatieTVState.shared
        let snap = state.stepDSP()
        let music = state.focusSound.snapshotVisualMusicalFrame()

        let now = CACurrentMediaTime()
        let dt = Float(max(0.004, min(0.05, now - lastDraw)))
        lastDraw = now
        frameIdx &+= 1

        var u = TVAcousticUniforms()
        u.resolution = SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height))
        u.coreCenter = SIMD2<Float>(0.5, 0.5)
        u.coreScale = 0.80
        u.time = Float(snap.time)
        u.dt = dt
        u.bass = snap.bass; u.mid = snap.mid; u.treble = snap.treble
        u.energy = snap.energy; u.flux = snap.flux; u.beat = snap.beat
        u.stereoCorr = snap.stereoCorrelation; u.centroid = snap.centroid
        u.chordAge = music.chordAge; u.barPhase = music.barPhase
        u.isPlaying = music.isPlaying ? 1.0 : 0.0
        func n(_ i: Int) -> SIMD4<Float> {
            let e = music.notes[i]; return SIMD4<Float>(e.pitchNorm, e.pan, e.velocity, e.age)
        }
        u.noteA = (n(0), n(1), n(2), n(3), n(4), n(5), n(6), n(7), n(8), n(9), n(10), n(11))
        u.noteKinds = (
            SIMD4<Float>(music.notes[0].kind, music.notes[1].kind, music.notes[2].kind, music.notes[3].kind),
            SIMD4<Float>(music.notes[4].kind, music.notes[5].kind, music.notes[6].kind, music.notes[7].kind),
            SIMD4<Float>(music.notes[8].kind, music.notes[9].kind, music.notes[10].kind, music.notes[11].kind)
        )
        u.breathDepth = SIMD4<Float>(
            music.breathPhase,
            music.meditationDepth,
            CircadianPhase.current() == .night ? 1.0 : 0.0,
            music.isDeepDive ? 1.0 : 0.0
        )
        u.edrParams = SIMD4<Float>(1.0, 1.85, Float(frameIdx & 4095), 1.0)
        memcpy(uBuf.contents(), &u, MemoryLayout<TVAcousticUniforms>.stride)

        let wPtr = wBuf.contents().assumingMemoryBound(to: SIMD2<Float>.self)
        for i in 0..<256 { wPtr[i] = SIMD2<Float>(snap.waveL[i], snap.waveR[i]) }

        guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { return }
        switch state.preset {
        case .circuit:
            enc.setRenderPipelineState(circuitBgPipe)
            enc.setFragmentBuffer(uBuf, offset: 0, index: 0)
            enc.setFragmentTexture(blueNoiseTex, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.setRenderPipelineState(circuitRibbonPipe)
            enc.setVertexBuffer(uBuf, offset: 0, index: 0)
            enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: 224, instanceCount: 240)
        case .ecology:
            enc.setRenderPipelineState(ecologyBgPipe)
            enc.setFragmentBuffer(uBuf, offset: 0, index: 0)
            enc.setFragmentTexture(blueNoiseTex, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        case .horizon:
            enc.setRenderPipelineState(horizonPipe)
            enc.setFragmentBuffer(uBuf, offset: 0, index: 0)
            enc.setFragmentBuffer(wBuf, offset: 0, index: 1)
            enc.setFragmentTexture(blueNoiseTex, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        default:
            enc.setRenderPipelineState(oculusPipe)
            enc.setFragmentBuffer(uBuf, offset: 0, index: 0)
            enc.setFragmentBuffer(wBuf, offset: 0, index: 1)
            enc.setFragmentTexture(blueNoiseTex, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}

private struct TVMetalRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> TVMetalView { TVMetalView() }
    func updateUIView(_ uiView: TVMetalView, context: Context) {}
}

struct SatieTVRootView: View {
    @ObservedObject var state: SatieTVState

    var body: some View {
        ZStack {
            TVMetalRepresentable()
                .ignoresSafeArea()

            VStack {
                HStack {
                    Text("SATIE · 4K EDR SKYSPACE")
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .tracking(3.0)
                        .foregroundStyle(.white.opacity(0.65))
                    Spacer()
                    Text(state.focusMode.title.uppercased())
                        .font(.system(size: 16, weight: .medium, design: .monospaced))
                        .tracking(2.0)
                        .foregroundStyle(.white.opacity(0.85))
                }
                .padding(.horizontal, 72)
                .padding(.top, 52)
                .opacity(state.showChrome ? 1 : 0)

                Spacer()

                HStack(spacing: 18) {
                    Button(action: { state.togglePlay() }) {
                        Label(state.isPlaying ? "Pause" : "Play", systemImage: state.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    }
                    ForEach(FocusSoundscape.allCases) { mode in
                        Button(mode.shortLabel) {
                            state.select(mode)
                        }
                        .font(.system(size: 17, weight: state.focusMode == mode ? .bold : .medium, design: .monospaced))
                    }
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 20)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 54)
                .opacity(state.showChrome ? 1 : 0)
            }
            .animation(.easeInOut(duration: 0.7), value: state.showChrome)
        }
        .onPlayPauseCommand {
            state.togglePlay()
        }
        .onMoveCommand { _ in
            state.bumpChrome()
        }
        .onAppear {
            state.bumpChrome()
        }
    }
}

@main
struct SatieTVApp: App {
    @StateObject private var state = SatieTVState.shared

    var body: some Scene {
        WindowGroup {
            SatieTVRootView(state: state)
                .preferredColorScheme(.dark)
        }
    }
}
