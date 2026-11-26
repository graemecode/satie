import AcousticCore
import AppKit
import Metal
import QuartzCore
import SwiftUI
import simd

struct AcousticUniforms {
    var resolution: SIMD2<Float> = .zero
    var coreCenter: SIMD2<Float> = SIMD2<Float>(0.5, 0.5)
    var coreScale: Float = 1.0
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
    var isCompact: Float = 1
    var chordAge: Float = 99
    var barPhase: Float = 0
    var isPlaying: Float = 0
    var bands: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (
        .zero, .zero, .zero, .zero, .zero, .zero
    )
    var impulses: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (
        .zero, .zero, .zero, .zero, .zero, .zero
    )
    var noteA: (
        SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
        SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
        SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>
    ) = (
        .zero, .zero, .zero, .zero, .zero, .zero,
        .zero, .zero, .zero, .zero, .zero, .zero
    )
    var noteKinds: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero)
    var breathDepth: SIMD4<Float> = SIMD4<Float>(0.5, 0.0, 0.0, 0.0) // (breath01, depth01, isNight01, isDeepDive)
    var edrParams: SIMD4<Float> = SIMD4<Float>(1.0, 1.0, 0.0, 1.0)   // (edrLinearP3Enabled, edrHeadroom, frameIndex, reserved)
}

/// Shared Metal device + compiled pipelines (created once, shared across Popover, MiniHUD, and Studio windows).
@MainActor
final class SharedMetalPipelines {
    static let shared = SharedMetalPipelines()

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let blueNoiseTexture: MTLTexture
    let displayColorSpace: CGColorSpace?

    let circuitBgPipeline: MTLRenderPipelineState
    let circuitRibbonPipeline: MTLRenderPipelineState
    let circuitSpikePipeline: MTLRenderPipelineState
    let ecologyFieldPipeline: MTLRenderPipelineState
    let ecologyAgentPipeline: MTLRenderPipelineState
    let phosphorUpdatePipeline: MTLRenderPipelineState
    let phosphorDisplayPipeline: MTLRenderPipelineState
    let liquidUpdatePipeline: MTLRenderPipelineState
    let liquidDisplayPipeline: MTLRenderPipelineState
    let horizonPipeline: MTLRenderPipelineState
    let oculusPipeline: MTLRenderPipelineState

    private init() {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let queue = dev.makeCommandQueue() else {
            fatalError("Metal is required on Apple Silicon / macOS.")
        }
        self.device = dev
        self.commandQueue = queue
        self.displayColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)

        let bnDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: BlueNoise64.dimension,
            height: BlueNoise64.dimension,
            mipmapped: false
        )
        bnDesc.usage = .shaderRead
        bnDesc.storageMode = .shared
        guard let bnTex = dev.makeTexture(descriptor: bnDesc) else {
            fatalError("Could not allocate 64x64 BlueNoise texture.")
        }
        BlueNoise64.bytes.withUnsafeBytes { raw in
            bnTex.replace(
                region: MTLRegionMake2D(0, 0, BlueNoise64.dimension, BlueNoise64.dimension),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: BlueNoise64.dimension
            )
        }
        self.blueNoiseTexture = bnTex

        let library: MTLLibrary
        if let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
           let loaded = try? dev.makeLibrary(URL: url) {
            library = loaded
        } else if let def = dev.makeDefaultLibrary() {
            library = def
        } else {
            fatalError("Could not load default.metallib from app bundle.")
        }

        func makePipeline(vertex: String, fragment: String, pixelFormat: MTLPixelFormat = .rgba16Float, additive: Bool = false) -> MTLRenderPipelineState {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: vertex)
            desc.fragmentFunction = library.makeFunction(name: fragment)
            desc.colorAttachments[0].pixelFormat = pixelFormat
            if additive {
                let att = desc.colorAttachments[0]!
                att.isBlendingEnabled = true
                att.rgbBlendOperation = .add
                att.alphaBlendOperation = .add
                att.sourceRGBBlendFactor = .one
                att.destinationRGBBlendFactor = .one
                att.sourceAlphaBlendFactor = .one
                att.destinationAlphaBlendFactor = .one
            }
            return try! dev.makeRenderPipelineState(descriptor: desc)
        }

        self.circuitBgPipeline = makePipeline(vertex: "fullscreenVertex", fragment: "circuitBackgroundFragment")
        self.circuitRibbonPipeline = makePipeline(vertex: "circuitRibbonVertex", fragment: "circuitRibbonFragment", additive: true)
        self.circuitSpikePipeline = makePipeline(vertex: "circuitSpikeVertex", fragment: "softParticleFragment", additive: true)
        self.ecologyFieldPipeline = makePipeline(vertex: "fullscreenVertex", fragment: "ecologyFieldFragment")
        self.ecologyAgentPipeline = makePipeline(vertex: "ecologyAgentVertex", fragment: "softParticleFragment", additive: true)
        self.phosphorUpdatePipeline = makePipeline(vertex: "fullscreenVertex", fragment: "phosphorUpdateFragment", pixelFormat: .rgba16Float)
        self.phosphorDisplayPipeline = makePipeline(vertex: "fullscreenVertex", fragment: "phosphorDisplayFragment")
        self.liquidUpdatePipeline = makePipeline(vertex: "fullscreenVertex", fragment: "liquidUpdateFragment", pixelFormat: .rgba16Float)
        self.liquidDisplayPipeline = makePipeline(vertex: "fullscreenVertex", fragment: "liquidDisplayFragment")
        self.horizonPipeline = makePipeline(vertex: "fullscreenVertex", fragment: "horizonFragment")
        self.oculusPipeline = makePipeline(vertex: "fullscreenVertex", fragment: "oculusFragment")
    }
}

/// Weak proxy breaking retain cycles between `CAMetalDisplayLink` and `AcousticMetalView`.
@MainActor
private final class MetalDisplayLinkProxy: NSObject, CAMetalDisplayLinkDelegate {
    weak var owner: AcousticMetalView?

    init(owner: AcousticMetalView) {
        self.owner = owner
    }

    nonisolated func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        nonisolated(unsafe) let u = update
        MainActor.assumeIsolated {
            self.owner?.render(update: u)
        }
    }
}

/// Native macOS 15+ 120Hz Apple EDR visualizer backed directly by `CAMetalLayer` + `CAMetalDisplayLink`.
/// Avoids `MTKView`'s legacy `CVDisplayLink`, which macOS permanently tears down on `NSWindow.close()`
/// when reusing `isReleasedWhenClosed = false` windows (causing frozen Studio windows on reopen).
@MainActor
final class AcousticMetalView: NSView {
    let compactMode: Bool
    var onSnapshotRendered: ((AcousticSnapshot) -> Void)?

    private let pipelines: SharedMetalPipelines
    private let metalLayer: CAMetalLayer
    private let uniformBuffers: [MTLBuffer]
    private let waveBuffers: [MTLBuffer]
    private var displayLink: CAMetalDisplayLink?
    private var displayLinkProxy: MetalDisplayLinkProxy?
    private var currentTargetFPS: Int = 0
    private var frameSlot = 0
    private var lastDrawTime: CFTimeInterval = CACurrentMediaTime()

    private var pingPongTextures: [MTLTexture?] = [nil, nil]
    private var pingIndex = 0
    private var pingPongSize: CGSize = .zero
    private var lastPreset: VisualPreset = .circuit
    private var desiredActive: Bool = false
    private var lastRenderedWallTime: CFTimeInterval = 0
    nonisolated(unsafe) private var windowObservers: [NSObjectProtocol] = []
    nonisolated(unsafe) private var workspaceObservers: [NSObjectProtocol] = []

    init(frame: CGRect, compactMode: Bool) {
        self.compactMode = compactMode
        let p = SharedMetalPipelines.shared
        self.pipelines = p

        let layer = CAMetalLayer()
        layer.device = p.device
        layer.pixelFormat = .rgba16Float
        layer.colorspace = p.displayColorSpace
        layer.wantsExtendedDynamicRangeContent = true
        layer.framebufferOnly = true
        layer.maximumDrawableCount = 3
        layer.displaySyncEnabled = true
        layer.allowsNextDrawableTimeout = true
        layer.isOpaque = true
        self.metalLayer = layer

        self.uniformBuffers = (0..<3).map { _ in
            p.device.makeBuffer(length: MemoryLayout<AcousticUniforms>.stride, options: .storageModeShared)!
        }
        self.waveBuffers = (0..<3).map { _ in
            p.device.makeBuffer(length: MemoryLayout<SIMD2<Float>>.stride * 256, options: .storageModeShared)!
        }

        super.init(frame: frame)
        self.wantsLayer = true
        self.layer = layer
        installWorkspaceObservers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeBackingLayer() -> CALayer {
        metalLayer
    }

    deinit {
        for obs in windowObservers {
            NotificationCenter.default.removeObserver(obs)
        }
        let ws = NSWorkspace.shared.notificationCenter
        for obs in workspaceObservers {
            ws.removeObserver(obs)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            teardownDisplayLink()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureEDRLayer()
        updateDrawableSize()
        installWindowObservers()
        syncDisplayLink(forceRecreate: false)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        configureEDRLayer()
        updateDrawableSize()
    }

    override func layout() {
        super.layout()
        updateDrawableSize()
        if desiredActive && displayLink == nil {
            syncDisplayLink(forceRecreate: false)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    private func configureEDRLayer() {
        metalLayer.pixelFormat = .rgba16Float
        metalLayer.wantsExtendedDynamicRangeContent = true
        metalLayer.colorspace = pipelines.displayColorSpace
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        if metalLayer.contentsScale != scale {
            metalLayer.contentsScale = scale
        }
        let w = max(2, Int((bounds.width * scale).rounded()))
        let h = max(2, Int((bounds.height * scale).rounded()))
        let target = CGSize(width: w, height: h)
        if metalLayer.drawableSize != target {
            metalLayer.drawableSize = target
        }
    }

    /// Idempotent when already rendering; self-healing when the window just became visible after `makeNSView`.
    func setActive(_ active: Bool) {
        desiredActive = active
        if !active {
            teardownDisplayLink()
            return
        }
        syncDisplayLink(forceRecreate: false)
    }

    /// Rebuilds the `CAMetalDisplayLink` cleanly if it is missing or has not delivered a frame in > 250 ms.
    func recoverIfStalled() {
        guard desiredActive, let win = window, !isHidden, !win.isMiniaturized, win.isVisible else {
            teardownDisplayLink()
            return
        }
        let stalled = displayLink == nil || (CACurrentMediaTime() - lastRenderedWallTime) > 0.25
        syncDisplayLink(forceRecreate: stalled)
    }

    private func teardownDisplayLink() {
        if let link = displayLink {
            link.isPaused = true
            link.invalidate()
            displayLink = nil
        }
        displayLinkProxy = nil
        currentTargetFPS = 0
    }

    private func syncDisplayLink(forceRecreate: Bool) {
        guard desiredActive,
              let win = window,
              !isHidden,
              !win.isMiniaturized,
              win.isVisible else {
            teardownDisplayLink()
            return
        }
        if forceRecreate {
            teardownDisplayLink()
        }
        configureEDRLayer()
        updateDrawableSize()
        if displayLink == nil {
            let proxy = MetalDisplayLinkProxy(owner: self)
            let link = CAMetalDisplayLink(metalLayer: metalLayer)
            link.delegate = proxy
            let initialMax = Float(compactMode ? 60 : min(120, win.screen?.maximumFramesPerSecond ?? 120))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: initialMax, preferred: initialMax)
            link.add(to: .main, forMode: .common)
            self.displayLinkProxy = proxy
            self.displayLink = link
            self.currentTargetFPS = Int(initialMax)
        }
        displayLink?.isPaused = false
    }

    private func updateFrameRateRangeIfNeeded(_ desiredFPS: Int) {
        guard let link = displayLink, currentTargetFPS != desiredFPS else { return }
        currentTargetFPS = desiredFPS
        let fps = Float(max(15, min(120, desiredFPS)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(15, fps), maximum: fps, preferred: fps)
    }

    private func installWorkspaceObservers() {
        let ws = NSWorkspace.shared.notificationCenter
        let wakeNames: [NSNotification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification
        ]
        for name in wakeNames {
            let obs = ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.recoverIfStalled()
                }
            }
            workspaceObservers.append(obs)
        }
        let sleepNames: [NSNotification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification
        ]
        for name in sleepNames {
            let obs = ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.teardownDisplayLink()
                }
            }
            workspaceObservers.append(obs)
        }
    }

    private func installWindowObservers() {
        for obs in windowObservers {
            NotificationCenter.default.removeObserver(obs)
        }
        windowObservers.removeAll()
        guard let win = window else { return }

        let nc = NotificationCenter.default

        // Cleanly invalidate CAMetalDisplayLink on close/miniaturize so reopening creates a fresh live link
        let stopNames: [NSNotification.Name] = [
            NSWindow.willCloseNotification,
            NSWindow.didMiniaturizeNotification
        ]
        for name in stopNames {
            let obs = nc.addObserver(forName: name, object: win, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.teardownDisplayLink()
                }
            }
            windowObservers.append(obs)
        }

        let wakeNames: [NSNotification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didChangeScreenNotification,
            NSWindow.didDeminiaturizeNotification
        ]
        for name in wakeNames {
            let obs = nc.addObserver(forName: name, object: win, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.recoverIfStalled()
                }
            }
            windowObservers.append(obs)
        }

        let occObs = nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: win, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let w = self.window else { return }
                if w.occlusionState.contains(.visible) {
                    self.recoverIfStalled()
                } else {
                    self.displayLink?.isPaused = true
                }
            }
        }
        windowObservers.append(occObs)
    }

    private func ensurePingPongTextures(size: CGSize) {
        // Render offscreen RGBA16F feedback at 0.55x native Retina (~3.3x less GPU work);
        // the display pass still renders at full Retina resolution so CRT graticule stays razor-sharp.
        let scale: CGFloat = 0.55
        let w = max(2, Int((size.width * scale).rounded()))
        let h = max(2, Int((size.height * scale).rounded()))
        if Int(pingPongSize.width) == w && Int(pingPongSize.height) == h && pingPongTextures[0] != nil {
            return
        }
        pingPongSize = CGSize(width: w, height: h)
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: w,
            height: h,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .renderTarget]
        desc.storageMode = .private
        pingPongTextures = [
            pipelines.device.makeTexture(descriptor: desc),
            pipelines.device.makeTexture(descriptor: desc)
        ]
        clearPingPongTextures()
    }

    private func clearPingPongTextures() {
        guard let cmd = pipelines.commandQueue.makeCommandBuffer() else { return }
        for tex in pingPongTextures {
            guard let tex else { continue }
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = tex
            rp.colorAttachments[0].loadAction = .clear
            rp.colorAttachments[0].storeAction = .store
            rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            if let enc = cmd.makeRenderCommandEncoder(descriptor: rp) { enc.endEncoding() }
        }
        cmd.commit()
    }

    fileprivate func render(update: CAMetalDisplayLink.Update) {
        guard desiredActive,
              !isHidden,
              let win = window,
              !win.isMiniaturized,
              win.isVisible else {
            teardownDisplayLink()
            return
        }
        guard win.occlusionState.contains(.visible),
              bounds.width >= 2,
              bounds.height >= 2 else { return }

        lastRenderedWallTime = CACurrentMediaTime()

        let state = AppState.shared
        let snap = state.stepDSP(drivenByMetal: true)

        // Match display refresh rate cleanly with thermal, Low Power Mode, and Reduce Motion awareness
        let screenMax = win.screen?.maximumFramesPerSecond ?? 60
        let preset = state.preset
        let proc = ProcessInfo.processInfo
        let isPingPong = (preset == .phosphor || preset == .liquid)
        let activeCap: Int
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            activeCap = 15
        } else if proc.isLowPowerModeEnabled || proc.thermalState == .serious || proc.thermalState == .critical {
            activeCap = 30
        } else if proc.thermalState == .fair || isPingPong || compactMode {
            activeCap = min(60, screenMax)
        } else {
            activeCap = min(120, screenMax)
        }
        let desiredFPS = snap.isSilent ? 15 : activeCap
        updateFrameRateRangeIfNeeded(desiredFPS)

        let drawable = update.drawable
        let renderPassDesc = MTLRenderPassDescriptor()
        renderPassDesc.colorAttachments[0].texture = drawable.texture
        renderPassDesc.colorAttachments[0].loadAction = .clear
        renderPassDesc.colorAttachments[0].storeAction = .store
        renderPassDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0.0021, green: 0.0033, blue: 0.0061, alpha: 1.0)

        let now = CACurrentMediaTime()
        let frameDt = Float(max(0.002, min(0.05, now - lastDrawTime)))
        lastDrawTime = now

        if preset != lastPreset {
            lastPreset = preset
            if preset == .phosphor || preset == .liquid {
                clearPingPongTextures()
            }
        }

        let size = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        let slot = frameSlot % 3
        frameSlot &+= 1

        // Populate triple-buffered shared memory uniforms (zero PCIe copy on Apple Silicon)
        var uniforms = AcousticUniforms()
        uniforms.resolution = SIMD2<Float>(Float(size.width), Float(size.height))
        if compactMode {
            uniforms.coreCenter = SIMD2<Float>(0.5, 0.50)
            uniforms.coreScale = 1.05
        } else {
            // Leave crisp architectural room for top 24-band sensor mosaic & bottom Circle of Fifths box
            uniforms.coreCenter = SIMD2<Float>(0.5, 0.465)
            uniforms.coreScale = 0.66
        }
        uniforms.time = Float(snap.time)
        uniforms.dt = frameDt
        uniforms.bass = snap.bass
        uniforms.mid = snap.mid
        uniforms.treble = snap.treble
        uniforms.energy = snap.energy
        uniforms.flux = snap.flux
        uniforms.beat = snap.beat
        uniforms.stereoCorr = snap.stereoCorrelation
        uniforms.centroid = snap.centroid
        uniforms.amberMode = 0.0 // Emerald by day; the shader shifts the scope to amber at night on its own.
        uniforms.isCompact = compactMode ? 1.0 : 0.0
        let music = state.focusSound.snapshotVisualMusicalFrame()
        uniforms.chordAge = music.chordAge
        uniforms.barPhase = music.barPhase
        uniforms.isPlaying = music.isPlaying ? 1.0 : 0.0

        func pack4(_ arr: [Float], _ offset: Int) -> SIMD4<Float> {
            SIMD4<Float>(arr[offset], arr[offset + 1], arr[offset + 2], arr[offset + 3])
        }
        uniforms.bands = (
            pack4(snap.bands24, 0), pack4(snap.bands24, 4), pack4(snap.bands24, 8),
            pack4(snap.bands24, 12), pack4(snap.bands24, 16), pack4(snap.bands24, 20)
        )
        uniforms.impulses = (
            pack4(snap.impulses24, 0), pack4(snap.impulses24, 4), pack4(snap.impulses24, 8),
            pack4(snap.impulses24, 12), pack4(snap.impulses24, 16), pack4(snap.impulses24, 20)
        )
        func noteVec(_ idx: Int) -> SIMD4<Float> {
            let n = music.notes[idx]
            return SIMD4<Float>(n.pitchNorm, n.pan, n.velocity, n.age)
        }
        uniforms.noteA = (
            noteVec(0), noteVec(1), noteVec(2), noteVec(3),
            noteVec(4), noteVec(5), noteVec(6), noteVec(7),
            noteVec(8), noteVec(9), noteVec(10), noteVec(11)
        )
        uniforms.noteKinds = (
            SIMD4<Float>(music.notes[0].kind, music.notes[1].kind, music.notes[2].kind, music.notes[3].kind),
            SIMD4<Float>(music.notes[4].kind, music.notes[5].kind, music.notes[6].kind, music.notes[7].kind),
            SIMD4<Float>(music.notes[8].kind, music.notes[9].kind, music.notes[10].kind, music.notes[11].kind)
        )
        uniforms.breathDepth = SIMD4<Float>(
            music.breathPhase,
            music.meditationDepth,
            state.effectiveCircadianPhase == .night ? 1.0 : 0.0,
            music.isDeepDive ? 1.0 : 0.0
        )
        let liveHeadroom = Float(max(1.0, win.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0))
        uniforms.edrParams = SIMD4<Float>(1.0, liveHeadroom, Float(frameSlot & 4095), 1.0)

        let uBuf = uniformBuffers[slot]
        memcpy(uBuf.contents(), &uniforms, MemoryLayout<AcousticUniforms>.stride)

        let wBuf = waveBuffers[slot]
        let wPtr = wBuf.contents().assumingMemoryBound(to: SIMD2<Float>.self)
        for i in 0..<256 {
            wPtr[i] = SIMD2<Float>(snap.waveL[i], snap.waveR[i])
        }

        guard let cmd = pipelines.commandQueue.makeCommandBuffer() else { return }

        switch preset {
        case .circuit:
            if let enc = cmd.makeRenderCommandEncoder(descriptor: renderPassDesc) {
                enc.setRenderPipelineState(pipelines.circuitBgPipeline)
                enc.setFragmentBuffer(uBuf, offset: 0, index: 0)
                enc.setFragmentTexture(pipelines.blueNoiseTexture, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

                // 240 layered 3D curl-turbulence connectome silk filaments x 112 segments
                enc.setRenderPipelineState(pipelines.circuitRibbonPipeline)
                enc.setVertexBuffer(uBuf, offset: 0, index: 0)
                enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: 112 * 2, instanceCount: compactMode ? 160 : 240)

                // 3,200 luminous neural spike dots
                enc.setRenderPipelineState(pipelines.circuitSpikePipeline)
                enc.setVertexBuffer(uBuf, offset: 0, index: 0)
                enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: compactMode ? 1400 : 3200)
                enc.endEncoding()
            }

        case .ecology:
            if let enc = cmd.makeRenderCommandEncoder(descriptor: renderPassDesc) {
                enc.setRenderPipelineState(pipelines.ecologyFieldPipeline)
                enc.setFragmentBuffer(uBuf, offset: 0, index: 0)
                enc.setFragmentTexture(pipelines.blueNoiseTexture, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

                // 5,000 stippled acoustic colony agents
                enc.setRenderPipelineState(pipelines.ecologyAgentPipeline)
                enc.setVertexBuffer(uBuf, offset: 0, index: 0)
                enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: compactMode ? 2200 : 5000)
                enc.endEncoding()
            }

        case .phosphor, .liquid:
            ensurePingPongTextures(size: size)
            let nextIndex = 1 - pingIndex
            if let prevTex = pingPongTextures[pingIndex], let dstTex = pingPongTextures[nextIndex] {
                let fbPass = MTLRenderPassDescriptor()
                fbPass.colorAttachments[0].texture = dstTex
                fbPass.colorAttachments[0].loadAction = .dontCare
                fbPass.colorAttachments[0].storeAction = .store

                if let fbEnc = cmd.makeRenderCommandEncoder(descriptor: fbPass) {
                    fbEnc.setRenderPipelineState(preset == .phosphor ? pipelines.phosphorUpdatePipeline : pipelines.liquidUpdatePipeline)
                    fbEnc.setFragmentTexture(prevTex, index: 0)
                    fbEnc.setFragmentBuffer(uBuf, offset: 0, index: 0)
                    fbEnc.setFragmentBuffer(wBuf, offset: 0, index: 1)
                    fbEnc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    fbEnc.endEncoding()
                }

                if let enc = cmd.makeRenderCommandEncoder(descriptor: renderPassDesc) {
                    enc.setRenderPipelineState(preset == .phosphor ? pipelines.phosphorDisplayPipeline : pipelines.liquidDisplayPipeline)
                    enc.setFragmentTexture(dstTex, index: 0)
                    enc.setFragmentTexture(pipelines.blueNoiseTexture, index: 1)
                    enc.setFragmentBuffer(uBuf, offset: 0, index: 0)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    enc.endEncoding()
                }
                pingIndex = nextIndex
            }

        case .horizon, .oculus:
            if let enc = cmd.makeRenderCommandEncoder(descriptor: renderPassDesc) {
                enc.setRenderPipelineState(preset == .horizon ? pipelines.horizonPipeline : pipelines.oculusPipeline)
                enc.setFragmentBuffer(uBuf, offset: 0, index: 0)
                enc.setFragmentBuffer(wBuf, offset: 0, index: 1)
                enc.setFragmentTexture(pipelines.blueNoiseTexture, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
        }

        cmd.present(drawable)
        cmd.commit()

        onSnapshotRendered?(snap)
    }
}

/// SwiftUI wrapper for embedding the live Metal visualizer inside Popover / Mini HUD.
struct MetalVisualizerRepresentable: NSViewRepresentable {
    let compactMode: Bool
    var isActive: Bool = true

    func makeNSView(context: Context) -> AcousticMetalView {
        let view = AcousticMetalView(frame: .zero, compactMode: compactMode)
        view.setActive(isActive)
        return view
    }

    func updateNSView(_ nsView: AcousticMetalView, context: Context) {
        nsView.setActive(isActive)
    }
}
