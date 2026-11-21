import AcousticCore
import Metal
import MetalKit
import SwiftUI
import UIKit
import simd

struct AcousticUniforms {
    var resolution: SIMD2<Float> = .zero
    var coreCenter: SIMD2<Float> = SIMD2<Float>(0.5, 0.44)
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
}

@MainActor
final class SharediOSMetalPipelines {
    static let shared = SharediOSMetalPipelines()

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
    let horizonPipeline: MTLRenderPipelineState

    private init() {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let queue = dev.makeCommandQueue() else {
            fatalError("Metal is required on iOS.")
        }
        self.device = dev
        self.commandQueue = queue

        guard let library = dev.makeDefaultLibrary() else {
            fatalError("Could not load default Metal library.")
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
        self.horizonPipeline = makePipeline(vertex: "fullscreenVertex", fragment: "horizonFragment")
    }
}

/// 120Hz ProMotion Metal visualizer for iPhone and iPad; automatically pauses in background (0% GPU).
final class iOSAcousticMetalView: MTKView, MTKViewDelegate {
    private let pipelines: SharediOSMetalPipelines
    private let uniformBuffers: [MTLBuffer]
    private let waveBuffers: [MTLBuffer]
    private var frameSlot = 0
    private var lastDrawTime: CFTimeInterval = CACurrentMediaTime()

    private var pingPongTextures: [MTLTexture?] = [nil, nil]
    private var pingIndex = 0
    private var pingPongSize: CGSize = .zero
    private var lastPreset: VisualPreset = .circuit
    private var pendingFPS: Int? = nil

    init(frame: CGRect) {
        let p = SharediOSMetalPipelines.shared
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
        self.preferredFramesPerSecond = 60
        self.enableSetNeedsDisplay = false
        self.isPaused = false
        self.delegate = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setActive(_ active: Bool) {
        let shouldPause = !active || (window == nil)
        if isPaused != shouldPause {
            isPaused = shouldPause
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        let active = SatieiOSState.shared.isForeground && (window != nil)
        isPaused = !active
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private func ensurePingPongTextures(drawableSize size: CGSize) {
        // Render offscreen RGBA16F feedback at 0.55x native Retina (~3.3x less GPU work);
        // the display pass still renders at full 3x native resolution so CRT graticule stays razor-sharp.
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

    private func scheduleFPS(_ desired: Int) {
        guard preferredFramesPerSecond != desired, pendingFPS != desired else { return }
        pendingFPS = desired
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingFPS == desired else { return }
            self.pendingFPS = nil
            if self.preferredFramesPerSecond != desired {
                self.preferredFramesPerSecond = desired
            }
        }
    }

    func draw(in view: MTKView) {
        guard !isHidden, window != nil else { return }
        let state = SatieiOSState.shared
        guard state.isForeground else { return }

        let snap = state.stepDSP()
        let preset = state.preset
        let maxFPS = window?.screen.maximumFramesPerSecond ?? 60
        let proc = ProcessInfo.processInfo
        let isPingPong = (preset == .phosphor || preset == .liquid)
        let activeCap: Int
        if proc.isLowPowerModeEnabled || proc.thermalState == .serious || proc.thermalState == .critical {
            activeCap = 30
        } else if proc.thermalState == .fair || isPingPong {
            activeCap = min(60, maxFPS)
        } else {
            activeCap = min(120, maxFPS)
        }
        let desiredFPS = snap.isSilent ? 20 : activeCap
        scheduleFPS(desiredFPS)

        guard let drawable = currentDrawable,
              let renderPassDesc = currentRenderPassDescriptor else { return }

        let now = CACurrentMediaTime()
        let frameDt = Float(max(0.002, min(0.05, now - lastDrawTime)))
        lastDrawTime = now

        if preset != lastPreset {
            lastPreset = preset
            if preset == .phosphor || preset == .liquid {
                clearPingPongTextures()
            }
        }

        let size = drawableSize
        let isPortrait = size.height > size.width
        let isCompactLandscape = !isPortrait && (traitCollection.verticalSizeClass == .compact)
        let slot = frameSlot % 3
        frameSlot &+= 1

        var uniforms = AcousticUniforms()
        uniforms.resolution = SIMD2<Float>(Float(size.width), Float(size.height))
        // Frame the luminous core gracefully in the open stage across iPhone Portrait, iPhone Landscape desk-stand, and iPad
        if isPortrait {
            uniforms.coreCenter = SIMD2<Float>(0.5, 0.44)
            uniforms.coreScale = 0.58
        } else if isCompactLandscape {
            uniforms.coreCenter = SIMD2<Float>(0.5, 0.46)
            uniforms.coreScale = 0.74
        } else {
            uniforms.coreCenter = SIMD2<Float>(0.5, 0.46)
            uniforms.coreScale = 0.74
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
        uniforms.isCompact = 1.0
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

                enc.setRenderPipelineState(pipelines.circuitRibbonPipeline)
                enc.setVertexBuffer(uBuf, offset: 0, index: 0)
                enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: 112 * 2, instanceCount: 200)

                enc.setRenderPipelineState(pipelines.circuitSpikePipeline)
                enc.setVertexBuffer(uBuf, offset: 0, index: 0)
                enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 2400)
                enc.endEncoding()
            }

        case .ecology:
            if let enc = cmd.makeRenderCommandEncoder(descriptor: renderPassDesc) {
                enc.setRenderPipelineState(pipelines.ecologyFieldPipeline)
                enc.setFragmentBuffer(uBuf, offset: 0, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

                enc.setRenderPipelineState(pipelines.ecologyAgentPipeline)
                enc.setVertexBuffer(uBuf, offset: 0, index: 0)
                enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 3600)
                enc.endEncoding()
            }

        case .phosphor, .liquid:
            ensurePingPongTextures(drawableSize: size)
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

        case .horizon:
            if let enc = cmd.makeRenderCommandEncoder(descriptor: renderPassDesc) {
                enc.setRenderPipelineState(pipelines.horizonPipeline)
                enc.setFragmentBuffer(uBuf, offset: 0, index: 0)
                enc.setFragmentBuffer(wBuf, offset: 0, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
        }

        cmd.present(drawable)
        cmd.commit()
    }
}

struct iOSMetalVisualizerRepresentable: UIViewRepresentable {
    var isActive: Bool
    var preset: VisualPreset

    func makeUIView(context: Context) -> iOSAcousticMetalView {
        let v = iOSAcousticMetalView(frame: .zero)
        v.setActive(isActive)
        return v
    }

    func updateUIView(_ uiView: iOSAcousticMetalView, context: Context) {
        uiView.setActive(isActive)
    }
}
