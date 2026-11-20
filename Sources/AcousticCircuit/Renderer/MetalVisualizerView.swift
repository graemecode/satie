import AcousticCore
import AppKit
import Metal
import MetalKit
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
    var _pad0: Float = 0
    var _pad1: Float = 0
    var _pad2: Float = 0
    var bands: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (
        .zero, .zero, .zero, .zero, .zero, .zero
    )
    var impulses: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (
        .zero, .zero, .zero, .zero, .zero, .zero
    )
}

/// Shared Metal device + compiled pipelines (created once, shared across Popover, MiniHUD, and Studio windows).
@MainActor
final class SharedMetalPipelines {
    static let shared = SharedMetalPipelines()

    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    let circuitBgPipeline: MTLRenderPipelineState
    let circuitRibbonPipeline: MTLRenderPipelineState
    let circuitSpikePipeline: MTLRenderPipelineState
    let ecologyFieldPipeline: MTLRenderPipelineState
    let ecologyAgentPipeline: MTLRenderPipelineState
    let phosphorUpdatePipeline: MTLRenderPipelineState
    let phosphorDisplayPipeline: MTLRenderPipelineState
    let liquidUpdatePipeline: MTLRenderPipelineState
    let liquidDisplayPipeline: MTLRenderPipelineState

    private init() {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let queue = dev.makeCommandQueue() else {
            fatalError("Metal is required on Apple Silicon / macOS.")
        }
        self.device = dev
        self.commandQueue = queue

        let library: MTLLibrary
        if let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
           let loaded = try? dev.makeLibrary(URL: url) {
            library = loaded
        } else if let def = dev.makeDefaultLibrary() {
            library = def
        } else {
            fatalError("Could not load default.metallib from app bundle.")
        }

        func makePipeline(vertex: String, fragment: String, pixelFormat: MTLPixelFormat = .bgra8Unorm, additive: Bool = false) -> MTLRenderPipelineState {
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
    }
}

/// High-efficiency 120Hz ProMotion Metal visualizer view with optional Retina schematic overlay callback.
final class AcousticMetalView: MTKView, MTKViewDelegate {
    let compactMode: Bool
    var onSnapshotRendered: ((AcousticSnapshot) -> Void)?

    private let pipelines: SharedMetalPipelines
    private let uniformBuffers: [MTLBuffer]
    private let waveBuffers: [MTLBuffer]
    private var frameSlot = 0
    private var lastDrawTime: CFTimeInterval = CACurrentMediaTime()

    private var pingPongTextures: [MTLTexture?] = [nil, nil]
    private var pingIndex = 0
    private var pingPongSize: CGSize = .zero
    private var lastPreset: VisualPreset = .circuit

    init(frame: CGRect, compactMode: Bool) {
        self.compactMode = compactMode
        let p = SharedMetalPipelines.shared
        self.pipelines = p

        self.uniformBuffers = (0..<3).map { _ in
            p.device.makeBuffer(length: MemoryLayout<AcousticUniforms>.stride, options: .storageModeShared)!
        }
        self.waveBuffers = (0..<3).map { _ in
            p.device.makeBuffer(length: MemoryLayout<SIMD2<Float>>.stride * 256, options: .storageModeShared)!
        }

        super.init(frame: frame, device: p.device)
        self.colorPixelFormat = .bgra8Unorm
        self.clearColor = MTLClearColor(red: 0.027, green: 0.043, blue: 0.071, alpha: 1.0)
        self.framebufferOnly = true
        self.preferredFramesPerSecond = compactMode ? 60 : 120
        self.enableSetNeedsDisplay = false
        self.isPaused = false
        self.delegate = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        self.isPaused = (window == nil)
    }

    func setActive(_ active: Bool) {
        let shouldPause = !active || (window == nil)
        if isPaused != shouldPause {
            isPaused = shouldPause
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Ping-pong buffers reallocate lazily on next draw
    }

    private func ensurePingPongTextures(size: CGSize) {
        let w = max(2, Int(size.width))
        let h = max(2, Int(size.height))
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

    func draw(in view: MTKView) {
        guard !isHidden,
              let win = window,
              win.isVisible,
              win.occlusionState.contains(.visible) else { return }

        let state = AppState.shared
        let snap = state.stepDSP(drivenByMetal: true)

        // Match display refresh rate cleanly (60Hz cap in compact popover, up to 120Hz ProMotion in Studio/Fullscreen, 15Hz quiet standby)
        let screenMax = win.screen?.maximumFramesPerSecond ?? 60
        let activeCap = compactMode ? min(60, screenMax) : min(120, screenMax)
        let desiredFPS = snap.isSilent ? 15 : activeCap
        if preferredFramesPerSecond != desiredFPS {
            preferredFramesPerSecond = desiredFPS
        }

        guard let drawable = currentDrawable,
              let renderPassDesc = currentRenderPassDescriptor else { return }

        let now = CACurrentMediaTime()
        let frameDt = Float(max(0.002, min(0.05, now - lastDrawTime)))
        lastDrawTime = now

        let preset = state.preset
        if preset != lastPreset {
            lastPreset = preset
            if preset == .phosphor || preset == .liquid {
                clearPingPongTextures()
            }
        }

        let size = drawableSize
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
        uniforms.amberMode = state.amberPhosphor ? 1.0 : 0.0
        uniforms.isCompact = compactMode ? 1.0 : 0.0

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
                    enc.setFragmentBuffer(uBuf, offset: 0, index: 0)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    enc.endEncoding()
                }
                pingIndex = nextIndex
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
