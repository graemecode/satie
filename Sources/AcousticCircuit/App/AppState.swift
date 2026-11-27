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
        case .min25: return SatieL10n.format("common.minutes_upper", 25)
        case .min50: return SatieL10n.format("common.minutes_upper", 50)
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

    /// The visual always belongs to the soundscape; choosing a soundscape chooses its visual.
    @Published private(set) var preset: VisualPreset
    @Published var focusMode: FocusSoundscape {
        didSet {
            settings.focusMode = focusMode
            focusSound.setMode(focusMode)
            let target = VisualPreset.paired(for: focusMode)
            if preset != target {
                preset = target
            }
        }
    }
    @Published var focusVolume: Float {
        didSet {
            settings.focusVolume = focusVolume
            focusSound.setVolume(focusVolume)
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
    @Published var displayKey: String = SatieL10n.string("common.standby")
    @Published var displayEnergy: Float = 0

    let focusRingBuffer: StereoRingBuffer
    let focusSound: FocusSoundEngine
    let dsp: AcousticDSP
    let nowPlaying = NowPlayingBridge()

    var onFrameTick: ((AcousticSnapshot) -> Void)?

    private var menuBarTimer: Timer?
    private var currentMenuBarHz: Double = 24.0
    private var housekeepingTimer: Timer?
    private var flowEndDate: Date? = nil
    private let handoff = SatieHandoffPublisher()
    private var isSleeping: Bool = false
    private var sleepObservers: [NSObjectProtocol] = []

    private var lastFrameTime: CFTimeInterval = CACurrentMediaTime()
    private var uiThrottleAccum: Double = 0
    private var menuBarTickAccum: Double = 0
    private var lastMenuBarWasSilent: Bool = false
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
                ? (scoreTelemetry.didSwapFigure
                    ? SatieL10n.format("common.pass_varied", scoreTelemetry.pass + 1)
                    : SatieL10n.format("common.pass", scoreTelemetry.pass + 1))
                : effectiveCircadianPhase.label
            return SatieL10n.format("common.bar_progress", barNum, passTag)
        }
        return focusMode.subtitle.uppercased()
    }

    var effectiveKeyBadge: String {
        isFocusPlaying ? scoreTelemetry.chordLabel : SatieL10n.string("common.standby")
    }

    var canTogglePrimaryPlayback: Bool {
        true
    }

    var isPrimaryPlaying: Bool {
        isFocusPlaying
    }

    private init() {
        let initialMode = settings.focusMode
        self.preset = VisualPreset.paired(for: initialMode)
        self.focusMode = initialMode
        self.focusVolume = settings.focusVolume
        self.circadianOverride = .auto
        self.flowMinutes = settings.flowMinutes
        self.launchAtLogin = settings.launchAtLogin

        self.focusRingBuffer = StereoRingBuffer()
        self.focusSound = FocusSoundEngine(ringBuffer: focusRingBuffer)
        self.focusSound.setMode(settings.focusMode)
        self.focusSound.setVolume(settings.focusVolume)
        self.focusSound.setIntensity(.flow)
        self.focusSound.setMaskingBed(.off)
        let initPhase = CircadianOverride.auto.resolvedPhase()
        self.circadianPhase = initPhase
        self.focusSound.setCircadianPhase(initPhase)
        self.dsp = AcousticDSP()
        // When an iPhone or iPad continues this session, fade out here.
        handoff.onContinuedElsewhere = { [weak self] in
            guard let self, self.isFocusPlaying else { return }
            self.stopFocusSound()
        }
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

    /// Idempotent start for Shortcuts, Focus Filters, and Spotlight actions (never accidentally toggles off).
    func startFocusSound(_ mode: FocusSoundscape, durationMinutes: Int? = nil) {
        if let mins = durationMinutes {
            setFlowMinutes(mins)
        }
        if isFocusPlaying {
            if focusMode != mode {
                focusMode = mode
                syncNowPlaying()
            }
            return
        }
        toggleFocusSound(mode)
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
            let started = focusSound.start(mode: mode)
            guard started else {
                isFocusPlaying = false
                flowEndDate = nil
                flowRemainingSeconds = nil
                syncNowPlaying()
                return
            }
            isFocusPlaying = true
            scheduleMenuBarTimer(hz: 28.0)
            if flowMinutes > 0 {
                if flowEndDate == nil {
                    let dur = Double(flowMinutes * 60)
                    flowEndDate = Date().addingTimeInterval(dur)
                    flowRemainingSeconds = dur
                } else {
                    refreshCountdownFromWallClock()
                }
                focusSound.setSessionProgress(sessionProgress)
            } else {
                flowEndDate = nil
                flowRemainingSeconds = nil
                focusSound.setSessionProgress(nil)
            }
            syncNowPlaying()
        }
    }

    /// Continue a session handed over from another device: same soundscape, and the timer ends at the same moment.
    func continueHandoff(_ session: SatieHandoff) {
        guard !session.isFinished() else { return }
        flowMinutes = session.flowMinutes
        settings.flowMinutes = session.flowMinutes
        flowDuration = session.flowMinutes == 0 ? .infinite : (session.flowMinutes == 50 ? .min50 : .min25)
        flowEndDate = session.endDate
        flowRemainingSeconds = session.endDate?.timeIntervalSinceNow
        if isFocusPlaying {
            focusMode = session.mode
            refreshCountdownFromWallClock()
            focusSound.setSessionProgress(sessionProgress)
            syncNowPlaying()
        } else {
            toggleFocusSound(session.mode)
        }
    }

    func stopFocusSound() {
        focusSound.stop()
        focusSound.setSessionProgress(nil)
        isFocusPlaying = false
        flowEndDate = nil
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
            flowEndDate = nil
            flowRemainingSeconds = nil
            focusSound.setSessionProgress(nil)
        } else {
            flowDuration = clamped == 25 ? .min25 : (clamped == 50 ? .min50 : .min25)
            let dur = Double(clamped * 60)
            flowRemainingSeconds = dur
            if isFocusPlaying {
                flowEndDate = Date().addingTimeInterval(dur)
                focusSound.setSessionProgress(0.0)
            } else {
                flowEndDate = nil
            }
        }
        syncHandoff()
    }

    /// Move to the neighboring soundscape (and its visual) without starting or stopping playback.
    func stepFocusMode(forward: Bool) {
        let all = FocusSoundscape.shipping
        guard let idx = all.firstIndex(of: focusMode) else { return }
        performHaptic()
        focusMode = all[(idx + (forward ? 1 : all.count - 1)) % all.count]
        if isFocusPlaying { syncNowPlaying() }
    }

    /// Number keys and the View menu: choose a soundscape by position (1 = Focus … 7 = Low Sun).
    func selectFocusMode(number: Int) {
        let all = FocusSoundscape.shipping
        guard (1...all.count).contains(number) else { return }
        startFocusSound(all[number - 1])
    }

    func cycleFocusMode(forward: Bool = true) {
        let all = FocusSoundscape.shipping
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

    private func syncHandoff() {
        handoff.update(isFocusPlaying ? SatieHandoff(mode: focusMode, flowMinutes: flowMinutes, endDate: flowEndDate) : nil)
    }

    /// Paused stays in Now Playing (marked paused) so AirPods, the Lock Screen and media keys can resume it.
    private func syncNowPlaying() {
        syncHandoff()
        nowPlaying.update(
            isPlaying: isFocusPlaying,
            title: focusMode.title,
            subtitle: focusMode.subtitle
        )
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

        // Wall-clock sleep / focus timer countdown (zero drift under macOS App Nap timer coalescing)
        refreshCountdownFromWallClock()
    }

    private func refreshCountdownFromWallClock() {
        guard isFocusPlaying, let endDate = flowEndDate else { return }
        let rem = endDate.timeIntervalSinceNow
        if rem <= 0 {
            flowEndDate = nil
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
                guard let self, self.isFocusPlaying, self.flowEndDate == nil else { return }
                self.stopFocusSound()
            }
        } else {
            flowRemainingSeconds = rem
            focusSound.setSessionProgress(sessionProgress)
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
            sensitivity: .balanced
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
                if drivenByMetal {
                    DispatchQueue.main.async { [weak self] in
                        self?.scoreTelemetry = tel
                    }
                } else {
                    scoreTelemetry = tel
                }
            }
        }

        if isMiniHUDOpen {
            uiThrottleAccum += dt
            if uiThrottleAccum >= 0.25 {
                uiThrottleAccum = 0
                let nextKey = SatieL10n.displayKey(snap.detectedKey)
                let qEnergy = (snap.energy * 100).rounded() / 100
                if displayKey != nextKey || displayEnergy != qEnergy {
                    if drivenByMetal {
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            if self.displayKey != nextKey { self.displayKey = nextKey }
                            if self.displayEnergy != qEnergy { self.displayEnergy = qEnergy }
                        }
                    } else {
                        if displayKey != nextKey { displayKey = nextKey }
                        if displayEnergy != qEnergy { displayEnergy = qEnergy }
                    }
                }
            }
        }

        return snap
    }
}
