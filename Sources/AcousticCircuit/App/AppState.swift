import AcousticCore
import AppKit
import Combine
import Foundation
#if APP_STORE
import StoreKit
#endif

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
    @Published var visualFollowsSoundscape: Bool {
        didSet { settings.visualFollowsSoundscape = visualFollowsSoundscape }
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
            if visualFollowsSoundscape {
                let target = VisualPreset.paired(for: focusMode)
                if preset != target {
                    preset = target
                }
            }
        }
    }
    @Published var focusVolume: Float {
        didSet {
            settings.focusVolume = focusVolume
            focusSound.setVolume(focusVolume)
        }
    }
    @Published var soundIntensity: SoundIntensity {
        didSet {
            settings.soundIntensity = soundIntensity
            focusSound.setIntensity(soundIntensity)
        }
    }
    @Published var maskingBed: MaskingBed {
        didSet {
            settings.maskingBed = maskingBed
            focusSound.setMaskingBed(maskingBed)
        }
    }
    @Published var circadianOverride: CircadianOverride {
        didSet {
            settings.circadianOverride = circadianOverride
            let resolved = circadianOverride.resolvedPhase()
            circadianPhase = resolved
            focusSound.setCircadianPhase(resolved)
        }
    }

    @Published var isFocusPlaying: Bool = false
    @Published var circadianPhase: CircadianPhase = .current()
    @Published var flowDuration: FlowDuration = .infinite
    @Published var flowMinutes: Int = 0
    @Published var flowRemainingSeconds: Double? = nil

    var effectiveCircadianPhase: CircadianPhase {
        circadianOverride.resolvedPhase()
    }

    var sessionProgress: Float? {
        guard flowMinutes > 0, let rem = flowRemainingSeconds else { return nil }
        let total = Double(flowMinutes * 60)
        guard total > 1 else { return nil }
        return Float(max(0.0, min(1.0, (total - rem) / total)))
    }

    @Published var launchAtLogin: Bool = false
    @Published var isPopoverOpen: Bool = false
    @Published var isMiniHUDOpen: Bool = false
    @Published var isStudioOpen: Bool = false
    @Published var isFullscreen: Bool = false
    @Published var isSystemMuted: Bool = SystemOutputMute.isMuted
    @Published var isStatusItemBehindNotch: Bool = false
    @Published var scoreTelemetry: ScoreTelemetry = .empty

    private(set) var snapshot: AcousticSnapshot = .empty
    @Published var displayKey: String = "STANDBY"
    @Published var displayEnergy: Float = 0
    @Published var displayFlux: Float = 0
    @Published var displayPhase: Float = 1
    @Published var displayFPS: Int = 60

    let focusRingBuffer: StereoRingBuffer
    let focusSound: FocusSoundEngine
    let dsp: AcousticDSP
    let nowPlaying = NowPlayingBridge()

    var onFrameTick: ((AcousticSnapshot) -> Void)?

    private var menuBarTimer: Timer?
    private var currentMenuBarHz: Double = 24.0
    private var housekeepingTimer: Timer?
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
        isFocusPlaying
    }

    var activeTitle: String {
        focusMode.title
    }

    var activeSourceLabel: String {
        if isFocusPlaying {
            let barNum = String(format: "%02d", scoreTelemetry.barInForm + 1)
            let passTag = scoreTelemetry.pass > 0
                ? (scoreTelemetry.didSwapFigure ? "PASS \(scoreTelemetry.pass + 1) · VARIED" : "PASS \(scoreTelemetry.pass + 1)")
                : effectiveCircadianPhase.label
            return "BAR \(barNum)/32 · \(passTag)"
        }
        return focusMode.subtitle.uppercased()
    }

    var effectiveKeyBadge: String {
        isFocusPlaying ? scoreTelemetry.chordLabel : "STANDBY"
    }

    var canTogglePrimaryPlayback: Bool {
        true
    }

    var isPrimaryPlaying: Bool {
        isFocusPlaying
    }

    private init() {
        let initialMode = settings.focusMode
        let autoVisual = settings.visualFollowsSoundscape
        self.visualFollowsSoundscape = autoVisual
        self.preset = autoVisual
            ? VisualPreset.paired(for: initialMode)
            : (VisualPreset(rawValue: settings.presetRaw) ?? VisualPreset.paired(for: initialMode))
        self.amberPhosphor = settings.amberPhosphor
        self.sensitivity = settings.sensitivity
        self.focusMode = initialMode
        self.focusVolume = settings.focusVolume
        self.soundIntensity = .flow
        self.maskingBed = settings.maskingBed
        self.circadianOverride = .auto
        self.flowMinutes = settings.flowMinutes
        self.launchAtLogin = settings.launchAtLogin

        self.focusRingBuffer = StereoRingBuffer()
        self.focusSound = FocusSoundEngine(ringBuffer: focusRingBuffer)
        self.focusSound.setMode(settings.focusMode)
        self.focusSound.setVolume(settings.focusVolume)
        self.focusSound.setIntensity(.flow)
        self.focusSound.setMaskingBed(settings.maskingBed)
        let initPhase = CircadianOverride.auto.resolvedPhase()
        self.circadianPhase = initPhase
        self.focusSound.setCircadianPhase(initPhase)
        self.dsp = AcousticDSP()
    }

    func boot() {
        installSleepObservers()

        nowPlaying.configureCommands(
            onPlay: { [weak self] in
                guard let self else { return }
                if !self.isFocusPlaying { self.toggleFocusSound(self.focusMode) }
            },
            onPause: { [weak self] in
                guard let self else { return }
                if self.isFocusPlaying { self.stopFocusSound() }
            },
            onToggle: { [weak self] in
                self?.togglePlayOrStartFocus()
            },
            onNext: { [weak self] in
                self?.cycleFocusMode(forward: true)
            },
            onPrevious: { [weak self] in
                self?.cycleFocusMode(forward: false)
            }
        )

        scheduleMenuBarTimer(hz: 4.0)

        // 1 Hz housekeeping: sleep timer countdown, automatic circadian voicing, mute status sync
        housekeepingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isSleeping else { return }
                self.tickHousekeeping()
            }
        }
        Log.app.info("Satie booted (preset=\(self.preset.title, privacy: .public), zero-permission generative mode)")
    }

    func shutdown() {
        for obs in sleepObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        sleepObservers.removeAll()
        menuBarTimer?.invalidate()
        housekeepingTimer?.invalidate()
        focusSound.stopImmediately()
        nowPlaying.clear()
        Log.app.info("Satie shut down cleanly")
    }

    func performHaptic() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    func toggleFocusSound(_ mode: FocusSoundscape) {
        performHaptic()
        if isFocusPlaying && focusMode == mode {
            stopFocusSound()
        } else {
            focusMode = mode
            let phase = circadianOverride.resolvedPhase()
            circadianPhase = phase
            focusSound.setCircadianPhase(phase)
            focusSound.start(mode: mode)
            isFocusPlaying = true
            scheduleMenuBarTimer(hz: 28.0)
            if flowMinutes > 0 {
                if flowRemainingSeconds == nil {
                    flowRemainingSeconds = Double(flowMinutes * 60)
                }
                focusSound.setSessionProgress(sessionProgress)
            } else {
                focusSound.setSessionProgress(nil)
            }
            syncNowPlaying()
        }
    }

    func stopFocusSound() {
        focusSound.stop()
        focusSound.setSessionProgress(nil)
        isFocusPlaying = false
        flowRemainingSeconds = nil
        syncNowPlaying()
    }

    func reseedFocusPhrase() {
        performHaptic()
        if !isFocusPlaying {
            toggleFocusSound(focusMode)
        } else {
            focusSound.reseedPhrase()
        }
    }

    func setFlowMinutes(_ minutes: Int) {
        let clamped = max(0, min(120, minutes))
        flowMinutes = clamped
        settings.flowMinutes = clamped
        if clamped == 0 {
            flowDuration = .infinite
            flowRemainingSeconds = nil
            focusSound.setSessionProgress(nil)
        } else {
            flowDuration = clamped == 25 ? .min25 : (clamped == 50 ? .min50 : .min25)
            flowRemainingSeconds = Double(clamped * 60)
            if isFocusPlaying {
                focusSound.setSessionProgress(0.0)
            }
        }
    }

    func cycleFocusMode(forward: Bool = true) {
        let all = FocusSoundscape.allCases
        guard let idx = all.firstIndex(of: focusMode) else { return }
        let nextIdx = (idx + (forward ? 1 : all.count - 1)) % all.count
        let next = all[nextIdx]
        if isFocusPlaying {
            performHaptic()
            focusMode = next
            syncNowPlaying()
        } else {
            toggleFocusSound(next)
        }
    }

    func togglePlayOrStartFocus() {
        if isFocusPlaying {
            performHaptic()
            stopFocusSound()
        } else {
            toggleFocusSound(focusMode)
        }
    }

    func adjustFocusVolume(delta: Float) {
        let next = max(0.05, min(1.0, focusVolume + delta))
        if abs(next - focusVolume) > 0.002 {
            focusVolume = next
        }
    }

    private func syncNowPlaying() {
        if isFocusPlaying {
            nowPlaying.update(
                isPlaying: true,
                title: focusMode.title,
                subtitle: focusMode.subtitle
            )
        } else {
            nowPlaying.clear()
        }
    }

    func cycleFlowDuration() {
        let cycle = [0, 15, 25, 45, 60, 90]
        let next: Int
        if let idx = cycle.firstIndex(of: flowMinutes) {
            next = cycle[(idx + 1) % cycle.count]
        } else {
            next = 25
        }
        setFlowMinutes(next)
    }

    func togglePrimaryPlayback() {
        togglePlayOrStartFocus()
    }

    func toggleSystemMute() {
        performHaptic()
        let nowMuted = SystemOutputMute.toggle()
        isSystemMuted = nowMuted
    }

    func stopPlayingAudioImmediately() {
        togglePlayOrStartFocus()
    }

    func toggleLaunchAtLogin() {
        let desired = !launchAtLogin
        if settings.setLaunchAtLogin(desired) {
            launchAtLogin = settings.launchAtLogin
        }
    }

    // MARK: - 1 Hz Sleep Timer & Automatic Circadian Voicing

    private func tickHousekeeping() {
        let muted = SystemOutputMute.isMuted
        if muted != isSystemMuted {
            isSystemMuted = muted
        }

        // Quietly adapt harmonic warmth to the time of day
        let nowPhase = CircadianOverride.auto.resolvedPhase()
        if nowPhase != circadianPhase {
            circadianPhase = nowPhase
            focusSound.setCircadianPhase(nowPhase)
        }

        // Sleep / Focus timer countdown + soft landing chime
        if isFocusPlaying, let rem = flowRemainingSeconds {
            let next = rem - 1.0
            if next <= 0 {
                flowRemainingSeconds = nil
                flowDuration = .infinite
                focusSound.setSessionProgress(1.0)
                focusSound.triggerSessionChime()
                settings.completedFocusSessions += 1
                Log.app.info("Focus session completed (#\(self.settings.completedFocusSessions)) — playing resolving fifth chime")
                #if APP_STORE
                let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                if settings.completedFocusSessions >= 5 && settings.lastReviewPromptVersion != ver {
                    settings.lastReviewPromptVersion = ver
                    SKStoreReviewController.requestReview()
                }
                #endif
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(4.0))
                    guard let self, self.isFocusPlaying, self.flowRemainingSeconds == nil else { return }
                    self.stopFocusSound()
                }
            } else {
                flowRemainingSeconds = next
                focusSound.setSessionProgress(sessionProgress)
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
            }
        }
        let onWake: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isSleeping else { return }
                self.isSleeping = false
                self.focusSound.handleSystemWake()
                self.scheduleMenuBarTimer(hz: 4.0)
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
                    let targetHz: Double = snap.isSilent ? 2.0 : 28.0
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

        let snap = dsp.process(
            ringBuffer: focusRingBuffer,
            sampleRate: 48_000.0,
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

        if isFocusPlaying && (isPopoverOpen || isStudioOpen) {
            let tel = focusSound.scoreTelemetry
            if tel.barInForm != scoreTelemetry.barInForm
                || tel.pass != scoreTelemetry.pass
                || tel.chordIndex != scoreTelemetry.chordIndex
                || tel.didSwapFigure != scoreTelemetry.didSwapFigure {
                scoreTelemetry = tel
            }
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
