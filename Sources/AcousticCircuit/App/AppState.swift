import AcousticCore
import AppKit
import Combine
import Foundation

enum VisualPreset: Int, CaseIterable, Identifiable, Sendable {
    case circuit = 0
    case ecology = 1
    case phosphor = 2
    case liquid = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .circuit: return "01 The Circuit"
        case .ecology: return "02 Ecology Wall"
        case .phosphor: return "03 Phosphor Scope"
        case .liquid: return "04 Liquid Warp"
        }
    }

    var shortTitle: String {
        switch self {
        case .circuit: return "01 Circuit"
        case .ecology: return "02 Ecology"
        case .phosphor: return "03 Scope"
        case .liquid: return "04 Liquid"
        }
    }
}

enum FlowDuration: Int, CaseIterable, Sendable {
    case infinite = 0
    case min25 = 1500
    case min50 = 3000

    var label: String {
        switch self {
        case .infinite: return "∞"
        case .min25: return "25M"
        case .min50: return "50M"
        }
    }

    var next: FlowDuration {
        switch self {
        case .infinite: return .min25
        case .min25: return .min50
        case .min50: return .infinite
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let settings = SettingsStore()

    @Published var preset: VisualPreset {
        didSet { settings.presetRaw = preset.rawValue }
    }
    @Published var amberPhosphor: Bool {
        didSet { settings.amberPhosphor = amberPhosphor }
    }
    @Published var sensitivity: SensitivityMode {
        didSet { settings.sensitivity = sensitivity }
    }
    @Published var focusMode: FocusSoundscape {
        didSet {
            settings.focusMode = focusMode
            focusSound.setMode(focusMode)
        }
    }
    @Published var focusVolume: Float {
        didSet {
            settings.focusVolume = focusVolume
            focusSound.setVolume(focusVolume)
        }
    }
    @Published var autoDuckEnabled: Bool {
        didSet {
            settings.autoDuck = autoDuckEnabled
            if !autoDuckEnabled && isAutoDucked {
                isAutoDucked = false
                duckedByAppName = nil
                focusSound.setDucked(false)
            }
        }
    }

    @Published var isFocusPlaying: Bool = false
    @Published var isAutoDucked: Bool = false
    @Published var duckedByAppName: String? = nil
    @Published var circadianPhase: CircadianPhase = .current()
    @Published var flowDuration: FlowDuration = .infinite
    @Published var flowRemainingSeconds: Double? = nil

    @Published var launchAtLogin: Bool = false
    @Published var tapTarget: TapTarget = .systemAll
    @Published var tapStatus: TapStatus = .stopped
    @Published var audioProcesses: [AudioProcessInfo] = []
    @Published var metadata: NowPlayingMetadata = .idle
    @Published var isPopoverOpen: Bool = false
    @Published var isMiniHUDOpen: Bool = false
    @Published var isStudioOpen: Bool = false
    @Published var isFullscreen: Bool = false

    private(set) var snapshot: AcousticSnapshot = .empty
    @Published var displayKey: String = "STANDBY"
    @Published var displayEnergy: Float = 0
    @Published var displayFlux: Float = 0
    @Published var displayPhase: Float = 1
    @Published var displayFPS: Int = 60

    let audioTap: ProcessAudioTap
    let focusRingBuffer: StereoRingBuffer
    let focusSound: FocusSoundEngine
    let dsp: AcousticDSP
    let media: MediaController

    var onFrameTick: ((AcousticSnapshot) -> Void)?

    private var menuBarTimer: Timer?
    private var currentMenuBarHz: Double = 24.0
    private var housekeepingTimer: Timer?
    private var externalSilentSince: CFTimeInterval?
    private var isSleeping: Bool = false
    private var sleepObservers: [NSObjectProtocol] = []

    private var lastFrameTime: CFTimeInterval = CACurrentMediaTime()
    private var uiThrottleAccum: Double = 0
    private var menuBarTickAccum: Double = 0
    private var lastMenuBarWasSilent: Bool = false
    private var fpsCounter: Int = 0
    private var fpsAccum: Double = 0
    private var lastRenderDrivenTime: CFTimeInterval = 0

    var isFocusAudible: Bool {
        isFocusPlaying && !isAutoDucked
    }

    var activeTitle: String {
        if isFocusPlaying && !isAutoDucked {
            return focusMode.title
        }
        return metadata.title
    }

    var activeSourceLabel: String {
        if isFocusPlaying && isAutoDucked, let app = duckedByAppName {
            return "DUCKED · \(app.uppercased())"
        }
        if isFocusPlaying {
            return "GENERATIVE · \(circadianPhase.label)"
        }
        return metadata.sourceApp
    }

    var canTogglePrimaryPlayback: Bool {
        isFocusAudible || metadata.canControlPlayback
    }

    var isPrimaryPlaying: Bool {
        isFocusAudible ? true : metadata.isPlaying
    }

    private init() {
        self.preset = VisualPreset(rawValue: settings.presetRaw) ?? .circuit
        self.amberPhosphor = settings.amberPhosphor
        self.sensitivity = settings.sensitivity
        self.focusMode = settings.focusMode
        self.focusVolume = settings.focusVolume
        self.autoDuckEnabled = settings.autoDuck
        self.launchAtLogin = settings.launchAtLogin

        self.audioTap = ProcessAudioTap()
        self.focusRingBuffer = StereoRingBuffer()
        self.focusSound = FocusSoundEngine(ringBuffer: focusRingBuffer)
        self.focusSound.setMode(settings.focusMode)
        self.focusSound.setVolume(settings.focusVolume)
        self.dsp = AcousticDSP()
        self.media = MediaController()

        audioTap.onStatusChange = { [weak self] status in
            Task { @MainActor in
                self?.tapStatus = status
            }
        }
        audioTap.onTargetFallback = { [weak self] fallback in
            Task { @MainActor in
                self?.tapTarget = fallback
            }
        }
        media.onMetadataUpdate = { [weak self] meta in
            Task { @MainActor in
                self?.metadata = meta
            }
        }
    }

    func boot() {
        installSleepObservers()
        refreshAudioProcesses()
        audioTap.start(target: .systemAll)
        media.start()

        scheduleMenuBarTimer(hz: 24.0)

        // 1 Hz housekeeping: auto-ducking monitor, flow timer countdown, circadian check, process refresh
        housekeepingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isSleeping else { return }
                self.tickHousekeeping()
            }
        }
        Log.app.info("Acoustic Circuit 2.0 booted (preset=\(self.preset.title, privacy: .public), autoDuck=\(self.autoDuckEnabled))")
    }

    func shutdown() {
        for obs in sleepObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        sleepObservers.removeAll()
        menuBarTimer?.invalidate()
        housekeepingTimer?.invalidate()
        focusSound.stopImmediately()
        media.stop()
        audioTap.stop()
        Log.app.info("Acoustic Circuit shut down cleanly")
    }

    func toggleFocusSound(_ mode: FocusSoundscape) {
        if isFocusPlaying && focusMode == mode {
            stopFocusSound()
        } else {
            focusMode = mode
            circadianPhase = .current()
            isAutoDucked = false
            duckedByAppName = nil
            externalSilentSince = nil
            focusSound.start(mode: mode)
            isFocusPlaying = true
            if flowDuration != .infinite && flowRemainingSeconds == nil {
                flowRemainingSeconds = Double(flowDuration.rawValue)
            }
        }
    }

    func stopFocusSound() {
        focusSound.stop()
        isFocusPlaying = false
        isAutoDucked = false
        duckedByAppName = nil
        flowRemainingSeconds = nil
    }

    func cycleFlowDuration() {
        flowDuration = flowDuration.next
        if flowDuration == .infinite {
            flowRemainingSeconds = nil
        } else if isFocusPlaying {
            flowRemainingSeconds = Double(flowDuration.rawValue)
        }
    }

    func togglePrimaryPlayback() {
        if isFocusAudible {
            stopFocusSound()
        } else if metadata.canControlPlayback {
            media.playPause()
        }
    }

    func toggleLaunchAtLogin() {
        let desired = !launchAtLogin
        if settings.setLaunchAtLogin(desired) {
            launchAtLogin = settings.launchAtLogin
        }
    }

    func refreshAudioProcesses() {
        audioProcesses = ProcessAudioTap.listAudioProcesses()
    }

    func selectTapTarget(_ target: TapTarget) {
        tapTarget = target
        audioTap.start(target: target)
    }

    func retryAudioTap() {
        audioTap.start(target: tapTarget)
    }

    // MARK: - 1 Hz Auto-Ducking, Flow Session Timer & Circadian Voicing

    private var housekeepingTickCount = 0

    private func tickHousekeeping() {
        housekeepingTickCount += 1

        // Refresh process list every 2s (or every 1s while Focus sound is playing for snappy auto-ducking)
        if isFocusPlaying || housekeepingTickCount % 3 == 0 {
            refreshAudioProcesses()
        }

        // Update circadian harmonic voicing if hour crossed boundary
        let nowPhase = CircadianPhase.current()
        if nowPhase != circadianPhase {
            circadianPhase = nowPhase
            focusSound.setCircadianPhase(nowPhase)
        }

        // Auto-duck Focus Sound when ANY external Mac app outputs audio (Zoom, Spotify, Chrome, Loom...)
        if isFocusPlaying && autoDuckEnabled {
            let activeExternal = audioProcesses.first(where: { $0.isRunningOutput })
            if let ext = activeExternal {
                externalSilentSince = nil
                if !isAutoDucked || duckedByAppName != ext.name {
                    isAutoDucked = true
                    duckedByAppName = ext.name
                    focusSound.setDucked(true)
                    Log.audio.info("Auto-ducked focus soundscape for external app: \(ext.name, privacy: .public)")
                }
            } else if isAutoDucked {
                let now = CACurrentMediaTime()
                if let since = externalSilentSince {
                    if now - since >= 2.5 {
                        isAutoDucked = false
                        duckedByAppName = nil
                        externalSilentSince = nil
                        focusSound.setDucked(false)
                        Log.audio.info("External audio ended; smoothly resuming focus soundscape")
                    }
                } else {
                    externalSilentSince = now
                }
            }
        }

        // Flow Session Timer countdown (pauses gracefully while auto-ducked on a call)
        if isFocusPlaying && !isAutoDucked, let rem = flowRemainingSeconds {
            let next = rem - 1.0
            if next <= 0 {
                flowRemainingSeconds = nil
                flowDuration = .infinite
                focusSound.triggerSessionChime()
                Log.app.info("Flow session completed — playing resolving fifth chime")
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(4.0))
                    guard let self, self.isFocusPlaying, self.flowRemainingSeconds == nil else { return }
                    self.stopFocusSound()
                }
            } else {
                flowRemainingSeconds = next
            }
        }
    }

    private func installSleepObservers() {
        let ws = NSWorkspace.shared.notificationCenter

        let onSleep: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isSleeping else { return }
                self.isSleeping = true
                if self.isFocusPlaying {
                    self.stopFocusSound()
                }
                self.menuBarTimer?.invalidate()
                self.menuBarTimer = nil
                self.media.stop()
                self.audioTap.pauseForSleep()
            }
        }
        let onWake: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isSleeping else { return }
                self.isSleeping = false
                self.audioTap.resumeFromSleep()
                self.media.start()
                self.scheduleMenuBarTimer(hz: 24.0)
            }
        }

        sleepObservers = [
            ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: onSleep),
            ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main, using: onSleep),
            ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: onWake),
            ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main, using: onWake)
        ]
    }

    private func scheduleMenuBarTimer(hz: Double) {
        if menuBarTimer != nil, abs(currentMenuBarHz - hz) < 0.5 { return }
        menuBarTimer?.invalidate()
        currentMenuBarHz = hz
        menuBarTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / hz, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isSleeping else { return }
                let now = CACurrentMediaTime()
                if now - self.lastRenderDrivenTime > 0.06 {
                    let snap = self.stepDSP(drivenByMetal: false)
                    let targetHz: Double = snap.isSilent ? 4.0 : 28.0
                    if abs(self.currentMenuBarHz - targetHz) > 1.0 {
                        self.scheduleMenuBarTimer(hz: targetHz)
                    }
                }
            }
        }
    }

    @discardableResult
    func stepDSP(drivenByMetal: Bool) -> AcousticSnapshot {
        let now = CACurrentMediaTime()
        if drivenByMetal {
            lastRenderDrivenTime = now
        }
        let dt = now - lastFrameTime
        if dt < 0.004 {
            return snapshot
        }
        lastFrameTime = now

        let activeBuffer = isFocusAudible ? focusRingBuffer : audioTap.ringBuffer
        let activeSR = isFocusAudible ? 48_000.0 : audioTap.sampleRate

        let snap = dsp.process(
            ringBuffer: activeBuffer,
            sampleRate: activeSR,
            dt: dt,
            demoMode: false,
            sensitivity: sensitivity
        )
        snapshot = snap

        menuBarTickAccum += dt
        let shouldRedrawMenuBar: Bool
        if snap.isSilent {
            shouldRedrawMenuBar = !lastMenuBarWasSilent
        } else {
            shouldRedrawMenuBar = (menuBarTickAccum >= 0.05)
        }
        if shouldRedrawMenuBar {
            menuBarTickAccum = 0
            lastMenuBarWasSilent = snap.isSilent
            onFrameTick?(snap)
        }

        fpsCounter += 1
        fpsAccum += dt
        if fpsAccum >= 1.0 {
            let newFPS = Int(round(Double(fpsCounter) / fpsAccum))
            if (isPopoverOpen || isStudioOpen) && abs(displayFPS - newFPS) >= 2 {
                displayFPS = newFPS
            }
            fpsCounter = 0
            fpsAccum = 0
        }

        if isPopoverOpen || isMiniHUDOpen || isStudioOpen {
            uiThrottleAccum += dt
            if uiThrottleAccum >= 0.25 {
                uiThrottleAccum = 0
                if displayKey != snap.detectedKey { displayKey = snap.detectedKey }
                let qEnergy = (snap.energy * 100).rounded() / 100
                let qFlux = (snap.flux * 100).rounded() / 100
                let qPhase = (snap.stereoCorrelation * 100).rounded() / 100
                if displayEnergy != qEnergy { displayEnergy = qEnergy }
                if displayFlux != qFlux { displayFlux = qFlux }
                if displayPhase != qPhase { displayPhase = qPhase }
            }
        }

        return snap
    }
}
