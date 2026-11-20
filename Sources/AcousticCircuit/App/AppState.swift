import AcousticCore
import AppKit
import Combine
import Foundation
#if APP_STORE
import StoreKit
#endif

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
    @Published var autoDuckEnabled: Bool {
        didSet {
            settings.autoDuck = autoDuckEnabled
            if !autoDuckEnabled && isAutoDucked {
                autoDuckGate.reset()
                isAutoDucked = false
                duckedByAppName = nil
                focusSound.setDucked(false)
                syncNowPlaying()
            }
        }
    }

    @Published var isFocusPlaying: Bool = false
    @Published var isAutoDucked: Bool = false
    @Published var duckedByAppName: String? = nil
    @Published var circadianPhase: CircadianPhase = .current()
    @Published var flowDuration: FlowDuration = .infinite
    @Published var flowMinutes: Int = 0
    /// Seconds left in the current segment (focus round or break) while a timed session runs.
    @Published var flowRemainingSeconds: Double? = nil
    @Published var breakMinutes: Int = 5
    @Published var sessionRounds: Int = 1
    @Published var sessionIntention: String = "" {
        didSet { settings.sessionIntention = sessionIntention }
    }
    @Published private(set) var sessionClock: FocusSessionClock? = nil
    @Published private(set) var listeningStats = ListeningStats()

    var effectiveCircadianPhase: CircadianPhase {
        circadianOverride.resolvedPhase()
    }

    var sessionPlan: FocusSessionPlan {
        FocusSessionPlan(focusMinutes: flowMinutes, breakMinutes: breakMinutes, rounds: sessionRounds)
    }

    var isOnBreak: Bool {
        isFocusPlaying && (sessionClock?.isOnBreak ?? false)
    }

    /// Drives the Arrival / Deep Lock / Soft Landing sound arc. Nil while open-ended or on a break.
    var sessionProgress: Float? {
        guard let clock = sessionClock, let seg = clock.current, seg.kind == .focus else { return nil }
        return Float(clock.segmentProgress)
    }

    /// Fraction of the current segment still to run (1 at its start, 0 at its end).
    var segmentRemainingFraction: Double? {
        guard let clock = sessionClock, clock.current != nil else { return nil }
        return 1.0 - clock.segmentProgress
    }

    /// "ROUND 2/3", or nil for a single-round or open-ended session.
    var roundLabel: String? {
        guard let clock = sessionClock, let seg = clock.current, clock.plan.rounds > 1 else { return nil }
        return "ROUND \(seg.round)/\(clock.plan.rounds)"
    }

    @Published var launchAtLogin: Bool = false
    @Published var tapTarget: TapTarget = .systemAll
    @Published var tapStatus: TapStatus = .stopped
    @Published var audioProcesses: [AudioProcessInfo] = []
    @Published var metadata: NowPlayingMetadata = .idle
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

    let audioTap: ProcessAudioTap
    let focusRingBuffer: StereoRingBuffer
    let focusSound: FocusSoundEngine
    let dsp: AcousticDSP
    let media: MediaController
    let nowPlaying = NowPlayingBridge()

    var onFrameTick: ((AcousticSnapshot) -> Void)?

    private var menuBarTimer: Timer?
    private var currentMenuBarHz: Double = 24.0
    private var housekeepingTimer: Timer?
    private var duckMonitorTimer: Timer?
    private var autoDuckGate = AutoDuckGate()
    /// When the user explicitly clicks Play while external Mac audio is already playing,
    /// honor their intent (blend without immediately auto-ducking) until external audio stops once,
    /// then automatically re-arm Auto-Duck for future calls/videos.
    private var suppressAutoDuckUntilSilence: Bool = false
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
        if isFocusPlaying {
            return focusMode.title
        }
        if metadata.canControlPlayback && metadata.isPlaying {
            return metadata.title
        }
        return focusMode.title
    }

    var activeSourceLabel: String {
        if isFocusPlaying && isAutoDucked {
            return "AUTO-DUCKED"
        }
        if isFocusPlaying {
            let barNum = String(format: "%02d", scoreTelemetry.barInForm + 1)
            let passTag = scoreTelemetry.pass > 0
                ? (scoreTelemetry.didSwapFigure ? "PASS \(scoreTelemetry.pass + 1) · VARIED" : "PASS \(scoreTelemetry.pass + 1)")
                : effectiveCircadianPhase.label
            return "BAR \(barNum)/32 · \(passTag)"
        }
        if metadata.canControlPlayback && metadata.isPlaying {
            return metadata.sourceApp
        }
        return snapshot.isSilent ? effectiveCircadianPhase.detailedLabel : "LIVE INPUT"
    }

    var effectiveKeyBadge: String {
        if isFocusAudible {
            return scoreTelemetry.chordLabel
        }
        return displayKey
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
        self.soundIntensity = settings.soundIntensity
        self.maskingBed = settings.maskingBed
        self.circadianOverride = settings.circadianOverride
        self.flowMinutes = settings.flowMinutes
        self.breakMinutes = settings.breakMinutes
        self.sessionRounds = settings.sessionRounds
        self.sessionIntention = settings.sessionIntention
        self.listeningStats = settings.listeningStats
        self.autoDuckEnabled = settings.autoDuck
        self.launchAtLogin = settings.launchAtLogin

        self.audioTap = ProcessAudioTap()
        self.focusRingBuffer = StereoRingBuffer()
        self.focusSound = FocusSoundEngine(ringBuffer: focusRingBuffer)
        self.focusSound.setMode(settings.focusMode)
        self.focusSound.setVolume(settings.focusVolume)
        self.focusSound.setIntensity(settings.soundIntensity)
        self.focusSound.setMaskingBed(settings.maskingBed)
        let initPhase = settings.circadianOverride.resolvedPhase()
        self.circadianPhase = initPhase
        self.focusSound.setCircadianPhase(initPhase)
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

        scheduleMenuBarTimer(hz: 24.0)

        // 4 Hz notification-immune auto-ducking monitor (zero work when focus sound is off)
        duckMonitorTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isSleeping else { return }
                self.tickAutoDuck()
            }
        }

        // 1 Hz housekeeping: flow timer countdown, circadian check, mute sync, process refresh
        housekeepingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isSleeping else { return }
                self.tickHousekeeping()
            }
        }
        Log.app.info("Satie booted (preset=\(self.preset.title, privacy: .public), autoDuck=\(self.autoDuckEnabled))")
    }

    func shutdown() {
        for obs in sleepObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        sleepObservers.removeAll()
        menuBarTimer?.invalidate()
        housekeepingTimer?.invalidate()
        duckMonitorTimer?.invalidate()
        flushListening()
        focusSound.stopImmediately()
        nowPlaying.clear()
        media.stop()
        audioTap.stop()
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
            autoDuckGate.reset()
            // If external Mac audio is already audible when user explicitly clicks Play,
            // honor their click instead of letting Auto-Duck immediately silence Satie 1.5s later.
            suppressAutoDuckUntilSilence = !snapshot.isSilent
            isAutoDucked = false
            duckedByAppName = nil
            focusSound.start(mode: mode)
            isFocusPlaying = true
            if sessionClock == nil {
                beginSession()
            } else {
                focusSound.setSessionProgress(sessionProgress)
            }
            syncNowPlaying()
        }
    }

    func stopFocusSound() {
        flushListening()
        focusSound.stop()
        endSession()
        autoDuckGate.reset()
        suppressAutoDuckUntilSilence = false
        isFocusPlaying = false
        isAutoDucked = false
        duckedByAppName = nil
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
        flowDuration = clamped == 0 ? .infinite : (clamped == 50 ? .min50 : .min25)
        restartSessionIfPlaying()
    }

    func setBreakMinutes(_ minutes: Int) {
        let clamped = max(0, min(30, minutes))
        breakMinutes = clamped
        settings.breakMinutes = clamped
        restartSessionIfPlaying()
    }

    func setSessionRounds(_ rounds: Int) {
        let clamped = max(1, min(FocusSessionPlan.maxRounds, rounds))
        sessionRounds = clamped
        settings.sessionRounds = clamped
        restartSessionIfPlaying()
    }

    // MARK: - Session rounds & breaks

    /// Starts the plan from round 1. Open-ended plans have no clock.
    private func beginSession() {
        leaveBreakSound()
        sessionClock = FocusSessionClock(plan: sessionPlan)
        flowRemainingSeconds = sessionClock?.remaining
        focusSound.setSessionProgress(sessionProgress)
    }

    private func endSession() {
        leaveBreakSound()
        sessionClock = nil
        flowRemainingSeconds = nil
        focusSound.setSessionProgress(nil)
    }

    /// Changing the plan mid-session restarts it, so the dial always matches what is counting down.
    private func restartSessionIfPlaying() {
        if isFocusPlaying {
            beginSession()
        } else {
            endSession()
        }
    }

    /// Breaks drop to the quietest depth so the room audibly relaxes; the user's setting is untouched.
    private func enterBreakSound() {
        focusSound.setSessionProgress(nil)
        focusSound.setIntensity(.still)
    }

    private func leaveBreakSound() {
        focusSound.setIntensity(soundIntensity)
    }

    private func completeSession() {
        sessionClock = nil
        flowRemainingSeconds = nil
        flowDuration = .infinite
        focusSound.setSessionProgress(1.0)
        focusSound.triggerSessionChime()
        settings.completedFocusSessions += 1
        flushListening()
        Log.app.info("Flow session completed (#\(self.settings.completedFocusSessions)) — playing resolving fifth chime")
        #if APP_STORE
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        if settings.completedFocusSessions >= 5 && settings.lastReviewPromptVersion != ver {
            settings.lastReviewPromptVersion = ver
            SKStoreReviewController.requestReview()
        }
        #endif
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4.0))
            guard let self, self.isFocusPlaying, self.sessionClock == nil, self.flowMinutes > 0 else { return }
            self.stopFocusSound()
        }
    }

    // MARK: - Listening stats (local only)

    private var pendingListenSeconds: Double = 0
    private var pendingListenMode: FocusSoundscape = .focus

    var completedSessions: Int { settings.completedFocusSessions }

    private func accrueListening(seconds: Double) {
        if pendingListenMode != focusMode {
            flushListening()
            pendingListenMode = focusMode
        }
        pendingListenSeconds += seconds
        if pendingListenSeconds >= 30 {
            flushListening()
        }
    }

    private func flushListening() {
        guard pendingListenSeconds > 0 else { return }
        var stats = settings.listeningStats
        stats.record(seconds: pendingListenSeconds, mode: pendingListenMode)
        settings.listeningStats = stats
        listeningStats = stats
        pendingListenSeconds = 0
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
        } else if !snapshot.isSilent {
            stopPlayingAudioImmediately()
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
        if isFocusAudible {
            nowPlaying.update(
                isPlaying: true,
                title: focusMode.title,
                subtitle: "Procedural Furniture Music · \(circadianPhase.label)"
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
        if isFocusAudible {
            stopFocusSound()
        } else if metadata.canControlPlayback {
            media.playPause()
        } else {
            toggleSystemMute()
        }
    }

    func toggleSystemMute() {
        performHaptic()
        let nowMuted = SystemOutputMute.toggle()
        isSystemMuted = nowMuted
    }

    /// Stops or silences currently playing audio immediately with one action:
    /// stops Satie focus audio if playing, pauses Spotify/Music/Accessibility media if controllable,
    /// or toggles zero-permission Core Audio system mute for unscriptable browser audio.
    func stopPlayingAudioImmediately() {
        if isFocusPlaying {
            stopFocusSound()
            return
        }
        if metadata.canControlPlayback && metadata.isPlaying {
            media.playPause()
            return
        }
        toggleSystemMute()
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

        let muted = SystemOutputMute.isMuted
        if muted != isSystemMuted {
            isSystemMuted = muted
        }

        // Refresh process list every 3s when idle (4 Hz duck monitor refreshes when focus sound is active)
        if !isFocusPlaying && housekeepingTickCount % 3 == 0 {
            refreshAudioProcesses()
        }

        // Update circadian harmonic voicing if hour crossed boundary (respecting manual override)
        let nowPhase = circadianOverride.resolvedPhase()
        if nowPhase != circadianPhase {
            circadianPhase = nowPhase
            focusSound.setCircadianPhase(nowPhase)
        }

        // Everything below pauses while auto-ducked on a call: Satie is silent then.
        guard isFocusPlaying && !isAutoDucked else { return }

        // Breaks are not listening time worth counting toward focus stats.
        if !isOnBreak {
            accrueListening(seconds: 1.0)
        }

        // Session clock: focus rounds, breaks between them, and the Session-Arc audio choreography
        guard var clock = sessionClock else { return }
        let event = clock.tick(1.0)
        switch event {
        case .running:
            sessionClock = clock
            flowRemainingSeconds = clock.remaining
            focusSound.setSessionProgress(sessionProgress)
        case .segmentEnded(let next):
            sessionClock = clock
            flowRemainingSeconds = clock.remaining
            focusSound.triggerSessionChime()
            if next.kind == .rest {
                enterBreakSound()
                Log.app.info("Focus round \(next.round) done — \(Int(next.seconds / 60))m break")
            } else {
                leaveBreakSound()
                focusSound.setSessionProgress(0.0)
                Log.app.info("Break over — starting focus round \(next.round)")
            }
        case .finished:
            completeSession()
        }
    }

    private func tickAutoDuck() {
        guard isFocusPlaying && autoDuckEnabled else { return }
        let procs = ProcessAudioTap.listAudioProcesses()
        audioProcesses = procs
        let isTapActive: Bool
        if case .active = tapStatus { isTapActive = true } else { isTapActive = false }
        let externalRMS: Float? = isTapActive ? audioTap.ringBuffer.recentRMS(frameCount: 2048) : nil

        if suppressAutoDuckUntilSilence {
            // Re-arm Auto-Duck cleanly once the pre-existing external audio finishes
            if (externalRMS ?? 0) < 0.002 {
                suppressAutoDuckUntilSilence = false
                autoDuckGate.reset()
            }
            return
        }

        let decision = autoDuckGate.evaluate(now: CACurrentMediaTime(), activeProcesses: procs, externalRMS: externalRMS)
        if decision.isDucked != isAutoDucked || decision.duckedByAppName != duckedByAppName {
            isAutoDucked = decision.isDucked
            duckedByAppName = decision.duckedByAppName
            focusSound.setDucked(decision.isDucked)
            syncNowPlaying()
            if decision.isDucked, let app = decision.duckedByAppName {
                Log.audio.info("Auto-ducked focus soundscape for sustained audio from \(app, privacy: .public)")
            } else {
                Log.audio.info("Sustained external audio ended; smoothly resuming focus soundscape")
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
                self.focusSound.handleSystemWake()
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
